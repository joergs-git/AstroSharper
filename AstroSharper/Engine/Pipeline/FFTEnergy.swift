// Frequency-domain quality metrics for the regression harness (F3 v1.2).
//
// Reads back the luma channel of an `rgba16Float` MTLTexture, runs a 2D
// FFT on the largest power-of-two centre-crop, and reports the fraction
// of total energy falling in mid- and high-frequency bands. These are
// complementary to the variance-of-Laplacian sharpness metric:
// sharpness conflates "edge content" with "fine-grain noise"; the FFT
// fractions separate medium-scale structure (e.g. Jupiter's banding)
// from fine-scale content (texture / noise / sub-pixel detail).
//
// Bands are defined by spectral radius (cycles per crop side):
//   - low   :  0 < r < N/8        (large-scale gradients, planet body)
//   - mid   : N/8 ≤ r < N/4       (medium structure — bands, prominences)
//   - high  : N/4 ≤ r ≤ N/2       (fine detail, noise, sub-pixel)
//
// DC (the (0,0) bin = total mean) is explicitly excluded from the
// total so the fractions don't drift with overall brightness.
//
// Output range: both fractions are in [0, 1]; mid + high < 1 because
// the low band carries the rest.
import Accelerate
import Foundation
import Metal

enum FFTEnergy {

    struct Bands: Equatable {
        /// Fraction of non-DC energy in the mid-frequency band.
        let midFraction: Double
        /// Fraction of non-DC energy in the high-frequency band.
        let highFraction: Double
    }

    /// Compute the band fractions for `texture`. Returns nil when the
    /// texture is too small (< 16 px) or readback fails. Cropped to
    /// the largest power-of-two ≤ min(width, height, 512) — anchored
    /// on the centre so off-axis subjects (Saturn ring, partial-disc
    /// solar) still get representative coverage.
    static func compute(texture src: MTLTexture, device: MTLDevice) -> Bands? {
        let w = src.width
        let h = src.height
        let maxN = Swift.min(w, h, 512)
        guard maxN >= 16 else { return nil }
        let log2n = Int(log2(Double(maxN)))
        let n = 1 << log2n
        let offX = (w - n) / 2
        let offY = (h - n) / 2

        guard let luma = readLuma(texture: src, x: offX, y: offY, size: n, device: device),
              luma.count == n * n
        else { return nil }

        // 2D forward FFT.
        var real = luma
        var imag = [Float](repeating: 0, count: n * n)
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n + 1), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0, vDSP_Length(log2n), vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
            }
        }

        // Sum |F|² in each band. vDSP_fft2d_zip lays out frequencies in
        // the natural [0..N) ordering with wrap at N/2; convert to a
        // signed cycle index by subtracting N when > N/2.
        let half = n / 2
        let lowEdge  = Double(n) / 8.0
        let midEdge  = Double(n) / 4.0
        var midSum:  Double = 0
        var highSum: Double = 0
        var totalSum: Double = 0

        for v in 0..<n {
            let vc = v <= half ? Double(v) : Double(v - n)
            for u in 0..<n {
                if u == 0 && v == 0 { continue }   // exclude DC
                let uc = u <= half ? Double(u) : Double(u - n)
                let r = (uc * uc + vc * vc).squareRoot()
                let mag2 = Double(real[v * n + u]) * Double(real[v * n + u])
                          + Double(imag[v * n + u]) * Double(imag[v * n + u])
                totalSum += mag2
                if r >= midEdge {
                    highSum += mag2
                } else if r >= lowEdge {
                    midSum += mag2
                }
            }
        }
        guard totalSum > 0 else { return nil }
        return Bands(
            midFraction:  midSum  / totalSum,
            highFraction: highSum / totalSum
        )
    }

    /// CPU-side readback of an `rgba16Float` region as Rec. 709 luma
    /// (Float32). Allocates a shared-storage staging texture and
    /// blits — necessary because the source is typically `.private`
    /// storage (the lucky-stack runner allocates its outputs that way).
    private static func readLuma(
        texture src: MTLTexture, x: Int, y: Int, size n: Int, device: MTLDevice
    ) -> [Float]? {
        let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: n, height: n, mipmapped: false
        )
        stageDesc.storageMode = .shared
        stageDesc.usage = [.shaderRead, .shaderWrite]
        guard let staging = device.makeTexture(descriptor: stageDesc),
              let queue = device.makeCommandQueue(),
              let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(
            from: src,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: n, height: n, depth: 1),
            to: staging,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        // Pull RGBA Float16 → mono Float32 luma.
        var halfPixels = [UInt16](repeating: 0, count: n * n * 4)
        halfPixels.withUnsafeMutableBufferPointer { ptr in
            staging.getBytes(
                ptr.baseAddress!,
                bytesPerRow: n * 4 * MemoryLayout<UInt16>.size,
                from: MTLRegionMake2D(0, 0, n, n),
                mipmapLevel: 0
            )
        }
        var out = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            let off = i * 4
            let r = Float(Float16(bitPattern: halfPixels[off + 0]))
            let g = Float(Float16(bitPattern: halfPixels[off + 1]))
            let b = Float(Float16(bitPattern: halfPixels[off + 2]))
            out[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return out
    }
}
