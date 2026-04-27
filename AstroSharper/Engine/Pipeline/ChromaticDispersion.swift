// Atmospheric Chromatic Dispersion Correction (ACDC) for OSC stacks.
//
// Atmospheric refraction is wavelength-dependent — blue refracts more than
// red — so a planet at altitude < ~50° appears as three slightly-offset
// colour images. Bayer demosaic produces an RGB image whose three planes
// are sub-pixel-misregistered, which:
//   - blurs edges (each channel is shifted by a different amount)
//   - creates coloured fringes at limbs (red on one side, blue on the other)
//
// This module performs *post-stack* ACDC: phase-correlate R/G and B/G on
// the stacked output, apply the resulting sub-pixel shifts to R and B
// (G stays anchored), recombine into RGB. One correction per stack run —
// captures the average dispersion across the capture window. Per-frame
// dispersion variation needs the per-channel-stacking refactor (Path B,
// scheduled separately).
//
// Defaults:
//   - Search uses a 256×256 downsample for the FFT (more than enough for
//     planetary dispersion, which rarely exceeds 5 px even at low alt).
//   - Sub-pixel precision via the existing Align parabolic fit.
//   - Returned offsets are in pixels of the ORIGINAL texture's coordinate
//     system (the downsample scale factor is undone before returning).
//   - On mono / pre-aligned sources the channel offsets come out near zero
//     and the pipeline can short-circuit the GPU shift entirely.
import Foundation
import Metal
import MetalPerformanceShaders

/// Per-channel offsets relative to the green reference, in pixels of the
/// original (full-resolution) texture. Apply by sampling R/B at
/// `gid - offset` so the misregistered channel re-aligns onto green.
struct ChannelOffsets: Equatable {
    var red:  SIMD2<Float>
    var blue: SIMD2<Float>

    static let identity = ChannelOffsets(red: .zero, blue: .zero)

    /// True when both channels are within `eps` pixels of zero — the
    /// caller can skip the GPU shift entirely in this case.
    func isIdentity(eps: Float = 0.05) -> Bool {
        return abs(red.x)  < eps && abs(red.y)  < eps &&
               abs(blue.x) < eps && abs(blue.y) < eps
    }
}

enum ChromaticDispersion {

    /// Compute red and blue channel offsets relative to green for a stacked
    /// RGBA texture. CPU readback + 2-D FFT-based phase correlation; cost
    /// dominated by the 256×256 downsample readback (~1 ms on Apple Silicon).
    /// Safe to call on mono inputs — both offsets come out near zero because
    /// all three channels share the same statistics.
    static func compute(
        input: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        targetSize: Int = 256
    ) -> ChannelOffsets {
        let srcW = input.width
        let srcH = input.height
        guard srcW > 0, srcH > 0 else { return .identity }

        // Largest power-of-two ≤ targetSize; vDSP FFT requires pow2.
        let log2n = max(6, Int(log2(Double(min(targetSize, min(srcW, srcH))))))
        let n = 1 << log2n
        guard n >= 64 else { return .identity }

        // Downsample to n×n via MPS bilinear scaler. Shared-storage so we
        // can read it back synchronously after the GPU pass completes.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: n, height: n, mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .shaderWrite]
        guard let staging = device.makeTexture(descriptor: desc),
              let cmd = commandQueue.makeCommandBuffer() else {
            return .identity
        }

        let scaler = MPSImageBilinearScale(device: device)
        var transform = MPSScaleTransform(
            scaleX: Double(n) / Double(srcW),
            scaleY: Double(n) / Double(srcH),
            translateX: 0, translateY: 0
        )
        withUnsafePointer(to: &transform) { ptr in
            scaler.scaleTransform = ptr
            scaler.encode(commandBuffer: cmd, sourceTexture: input, destinationTexture: staging)
        }
        cmd.commit()
        cmd.waitUntilCompleted()

        // Read back as interleaved RGBA float32, split into 3 planes.
        let pixelCount = n * n
        var rgba = [Float](repeating: 0, count: pixelCount * 4)
        rgba.withUnsafeMutableBufferPointer { buf in
            staging.getBytes(
                buf.baseAddress!,
                bytesPerRow: n * MemoryLayout<Float>.size * 4,
                from: MTLRegionMake2D(0, 0, n, n),
                mipmapLevel: 0
            )
        }
        var red   = [Float](repeating: 0, count: pixelCount)
        var green = [Float](repeating: 0, count: pixelCount)
        var blue  = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            red[i]   = rgba[i * 4 + 0]
            green[i] = rgba[i * 4 + 1]
            blue[i]  = rgba[i * 4 + 2]
        }

        // Hann + DC-remove each channel so the phase-correlation peak isn't
        // dominated by edge wrap-around or the global DC offset.
        Align.prepareBuffer(&red,   size: n)
        Align.prepareBuffer(&green, size: n)
        Align.prepareBuffer(&blue,  size: n)

        // Phase-correlate G→R and G→B. Shifts are in n×n grid pixels;
        // scale back to original-texture pixels before returning.
        let scaleX = Float(srcW) / Float(n)
        let scaleY = Float(srcH) / Float(n)

        let rShift = Align.phaseCorrelateBuffers(reference: green, frame: red,  log2n: log2n)
                     ?? AlignShift(dx: 0, dy: 0)
        let bShift = Align.phaseCorrelateBuffers(reference: green, frame: blue, log2n: log2n)
                     ?? AlignShift(dx: 0, dy: 0)

        return ChannelOffsets(
            red:  SIMD2<Float>(rShift.dx * scaleX, rShift.dy * scaleY),
            blue: SIMD2<Float>(bShift.dx * scaleX, bShift.dy * scaleY)
        )
    }
}
