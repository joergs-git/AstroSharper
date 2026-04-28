// Wiener deconvolution with a synthetic Gaussian PSF.
//
// The Wiener filter is the linear minimum-MSE inverse for a known PSF and
// noise/signal ratio:
//
//   W(f) = K*(f) / ( |K(f)|² + 1/SNR )
//
// where K(f) is the PSF in frequency space. For a Gaussian PSF of pixel
// stddev σ, the transform is itself Gaussian:
//
//   K(fx, fy) = exp( -2π²σ² (fx² + fy²) )    fx, fy in cycles/pixel
//
// We work with K real-valued, so K* = K and W = K / (K² + 1/SNR).
//
// Implementation: 2D vDSP FFT on each colour plane, multiply by the
// pre-computed Wiener mask, inverse FFT, normalize. Runs on CPU because the
// stage fires once per processed image — typically <50 ms for 1k×1k on
// Apple Silicon, which is well below the preview throttle (33 ms) so it
// trades cleanly with debounce. GPU FFT (MPSGraph) is a future swap-in.
import Accelerate
import Foundation
import Metal

enum Wiener {
    /// Deconvolves `input` with a Gaussian PSF of stddev `sigma` (px) and
    /// signal-to-noise ratio `snr`, writing the result into `output`. Both
    /// must be the same size; `output` is allowed to be private-storage.
    static func deconvolve(
        input: MTLTexture,
        output: MTLTexture,
        sigma: Float,
        snr: Float,
        device: MTLDevice
    ) {
        let W = input.width
        let H = input.height
        precondition(output.width == W && output.height == H, "Wiener: I/O size mismatch")

        // Step 1: read input bytes via a shared staging texture matching
        // the input's actual pixel format. The earlier hard-coded
        // rgba16Float staging produced visible byte-stride artifacts (a
        // checkerboard / tile pattern) once the lucky-stack accumulator
        // was upgraded to rgba32Float — Metal's blit copy does NOT
        // format-convert between mismatched textures, so reading rgba32
        // bytes as rgba16 misaligned every pixel.
        let inputFormat = input.pixelFormat
        let bytesPerChannel: Int
        let isFloat32: Bool
        switch inputFormat {
        case .rgba32Float:
            bytesPerChannel = 4
            isFloat32 = true
        case .rgba16Float:
            bytesPerChannel = 2
            isFloat32 = false
        default:
            // Unsupported format — bail out via blit-copy of the input
            // so the caller still gets a valid texture, just unaffected.
            let queue = MetalDevice.shared.commandQueue
            if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
                blit.copy(from: input, to: output)
                blit.endEncoding()
                cmd.commit()
                cmd.waitUntilCompleted()
            }
            return
        }

        let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: inputFormat, width: W, height: H, mipmapped: false
        )
        stageDesc.storageMode = .shared
        stageDesc.usage = [.shaderRead, .shaderWrite]
        guard let staging = device.makeTexture(descriptor: stageDesc) else { return }

        let queue = MetalDevice.shared.commandQueue
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: input, to: staging)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        let bytesPerRow = W * bytesPerChannel * 4
        let plane = W * H
        var rPlane = [Float](repeating: 0, count: plane)
        var gPlane = [Float](repeating: 0, count: plane)
        var bPlane = [Float](repeating: 0, count: plane)

        if isFloat32 {
            // rgba32Float: read directly into Float buffers.
            var raw = [Float](repeating: 0, count: W * H * 4)
            raw.withUnsafeMutableBufferPointer { buf in
                staging.getBytes(
                    buf.baseAddress!,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegion(
                        origin: MTLOrigin(x: 0, y: 0, z: 0),
                        size: MTLSize(width: W, height: H, depth: 1)
                    ),
                    mipmapLevel: 0
                )
            }
            for i in 0..<plane {
                rPlane[i] = raw[i * 4 + 0]
                gPlane[i] = raw[i * 4 + 1]
                bPlane[i] = raw[i * 4 + 2]
            }
        } else {
            // rgba16Float: read as UInt16 bitpatterns then convert.
            var raw = [UInt16](repeating: 0, count: W * H * 4)
            raw.withUnsafeMutableBufferPointer { buf in
                staging.getBytes(
                    buf.baseAddress!,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegion(
                        origin: MTLOrigin(x: 0, y: 0, z: 0),
                        size: MTLSize(width: W, height: H, depth: 1)
                    ),
                    mipmapLevel: 0
                )
            }
            for i in 0..<plane {
                rPlane[i] = Float(Float16(bitPattern: raw[i * 4 + 0]))
                gPlane[i] = Float(Float16(bitPattern: raw[i * 4 + 1]))
                bPlane[i] = Float(Float16(bitPattern: raw[i * 4 + 2]))
            }
        }

        // Step 3: pad to next power of two (padding = 0). Mirror padding would
        // reduce edge ringing further but doubles complexity — for typical
        // lucky-stack outputs the result is a centred object on a dark field,
        // so zero-pad is fine.
        let N = nextPow2(max(W, H))
        let log2N = Int(log2(Double(N)))
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2N + 1), FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(setup) }

        // Step 4: pre-compute the Wiener mask (same for all channels).
        let invSNR = 1.0 / max(snr, 1e-3)
        let twoPi2σ2 = 2 * Float.pi * Float.pi * sigma * sigma
        var wiener = [Float](repeating: 0, count: N * N)
        for j in 0..<N {
            // FFT layout puts the negative frequencies in the upper half.
            let fy = Float(j < N / 2 ? j : j - N) / Float(N)
            for i in 0..<N {
                let fx = Float(i < N / 2 ? i : i - N) / Float(N)
                let K = expf(-twoPi2σ2 * (fx * fx + fy * fy))
                wiener[j * N + i] = K / (K * K + invSNR)
            }
        }

        // Step 5: process each channel.
        rPlane = wienerProcess(channel: rPlane, srcW: W, srcH: H, N: N, log2N: log2N, mask: wiener, setup: setup)
        gPlane = wienerProcess(channel: gPlane, srcW: W, srcH: H, N: N, log2N: log2N, mask: wiener, setup: setup)
        bPlane = wienerProcess(channel: bPlane, srcW: W, srcH: H, N: N, log2N: log2N, mask: wiener, setup: setup)

        // Step 6: pack back into RGBA at the input's native precision,
        // clamped to [0, 1]. Branch on isFloat32 so the byte layout matches
        // the staging texture's format — same fix as the readback above.
        if isFloat32 {
            var rawOut = [Float](repeating: 0, count: plane * 4)
            for i in 0..<plane {
                rawOut[i * 4 + 0] = max(0, min(1, rPlane[i]))
                rawOut[i * 4 + 1] = max(0, min(1, gPlane[i]))
                rawOut[i * 4 + 2] = max(0, min(1, bPlane[i]))
                rawOut[i * 4 + 3] = 1.0
            }
            rawOut.withUnsafeBufferPointer { buf in
                staging.replace(
                    region: MTLRegion(
                        origin: MTLOrigin(x: 0, y: 0, z: 0),
                        size: MTLSize(width: W, height: H, depth: 1)
                    ),
                    mipmapLevel: 0,
                    withBytes: buf.baseAddress!,
                    bytesPerRow: bytesPerRow
                )
            }
        } else {
            var rawOut = [UInt16](repeating: 0, count: plane * 4)
            let one16 = Float16(1.0).bitPattern
            for i in 0..<plane {
                rawOut[i * 4 + 0] = Float16(max(0, min(1, rPlane[i]))).bitPattern
                rawOut[i * 4 + 1] = Float16(max(0, min(1, gPlane[i]))).bitPattern
                rawOut[i * 4 + 2] = Float16(max(0, min(1, bPlane[i]))).bitPattern
                rawOut[i * 4 + 3] = one16
            }
            rawOut.withUnsafeBufferPointer { buf in
                staging.replace(
                    region: MTLRegion(
                        origin: MTLOrigin(x: 0, y: 0, z: 0),
                        size: MTLSize(width: W, height: H, depth: 1)
                    ),
                    mipmapLevel: 0,
                    withBytes: buf.baseAddress!,
                    bytesPerRow: bytesPerRow
                )
            }
        }
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: staging, to: output)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
    }

    // MARK: - Per-channel pipeline

    private static func wienerProcess(
        channel: [Float],
        srcW: Int, srcH: Int,
        N: Int, log2N: Int,
        mask: [Float],
        setup: FFTSetup
    ) -> [Float] {
        // Pad into N×N float buffer.
        var real = [Float](repeating: 0, count: N * N)
        var imag = [Float](repeating: 0, count: N * N)
        for j in 0..<srcH {
            for i in 0..<srcW {
                real[j * N + i] = channel[j * srcW + i]
            }
        }

        // Forward FFT in place.
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(
                    setup, &split, 1, 0,
                    vDSP_Length(log2N), vDSP_Length(log2N),
                    FFTDirection(FFT_FORWARD)
                )
            }
        }

        // Multiply spectrum by the (real-valued) Wiener mask.
        for k in 0..<(N * N) {
            real[k] *= mask[k]
            imag[k] *= mask[k]
        }

        // Inverse FFT.
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(
                    setup, &split, 1, 0,
                    vDSP_Length(log2N), vDSP_Length(log2N),
                    FFTDirection(FFT_INVERSE)
                )
            }
        }

        // Normalize and crop back to source size.
        let invN = 1.0 / Float(N * N)
        var result = [Float](repeating: 0, count: srcW * srcH)
        for j in 0..<srcH {
            for i in 0..<srcW {
                result[j * srcW + i] = real[j * N + i] * invN
            }
        }
        return result
    }

    private static func nextPow2(_ n: Int) -> Int {
        var v = 1
        while v < n { v <<= 1 }
        return v
    }
}
