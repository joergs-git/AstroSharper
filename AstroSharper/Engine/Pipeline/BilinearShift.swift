// Sub-pixel translation of a single-channel float buffer.
//
// Used by atmospheric dispersion correction (D.4) — when light passes
// through atmosphere R/G/B channels refract slightly differently, so
// the per-channel images are offset from each other; correcting the
// dispersion means independently shifting each channel by a small
// fractional pixel amount. Also re-usable by any post-alignment warp
// that needs sub-pixel accuracy without invoking the full Stabilizer
// pipeline (the per-tile re-warp inside C.3 tiled deconvolution will
// likely call this).
//
// Bilinear interpolation: each output pixel reads four input pixels
// at (floor x, floor y), (floor x + 1, floor y), (floor x, floor y +
// 1), (floor x + 1, floor y + 1) and weights them by the fractional
// part of the shifted source coordinate. Out-of-bounds reads return
// 0 — equivalent to a pad-to-zero boundary.
//
// Pure-Swift / Foundation. The Metal kernel that lands when D.4
// integrates with the GPU pipeline mirrors this CPU reference for
// validation.
import Foundation

enum BilinearShift {

    /// Apply a sub-pixel shift to a single-channel buffer.
    ///
    /// `shift.dx` / `shift.dy` are in pixels and follow the same sign
    /// convention as `Align.phaseCorrelate`: positive `dx` means the
    /// returned image is the source content shifted to the RIGHT by
    /// `dx` pixels. Equivalent statement: `out[x, y] = in[x - dx, y - dy]`.
    ///
    /// The output buffer is always the same size as the input; pixels
    /// whose source coordinate falls outside the input bounds read 0.
    ///
    /// - Parameters:
    ///   - channel: row-major luminance buffer (`width * height` Floats).
    ///   - width, height: image dimensions.
    ///   - shift: translation in pixels.
    /// - Returns: a freshly allocated shifted buffer of the same size.
    ///   Empty input or non-finite shift returns the input unchanged.
    static func apply(
        channel pixels: [Float],
        width: Int,
        height: Int,
        shift: AlignShift
    ) -> [Float] {
        precondition(pixels.count == width * height, "buffer size mismatch")
        guard width > 0, height > 0 else { return pixels }
        guard shift.dx.isFinite, shift.dy.isFinite else { return pixels }

        // Identity shift: skip the work and return a copy.
        if shift.dx == 0 && shift.dy == 0 {
            return pixels
        }

        var out = [Float](repeating: 0, count: pixels.count)
        for y in 0..<height {
            // Source y = output y - shift.dy.
            let srcY = Float(y) - shift.dy
            let y0 = Int(floor(srcY))
            let fy = srcY - Float(y0)
            let y1 = y0 + 1

            for x in 0..<width {
                let srcX = Float(x) - shift.dx
                let x0 = Int(floor(srcX))
                let fx = srcX - Float(x0)
                let x1 = x0 + 1

                let v00 = sample(pixels, width: width, height: height, x: x0, y: y0)
                let v10 = sample(pixels, width: width, height: height, x: x1, y: y0)
                let v01 = sample(pixels, width: width, height: height, x: x0, y: y1)
                let v11 = sample(pixels, width: width, height: height, x: x1, y: y1)

                let top    = v00 * (1 - fx) + v10 * fx
                let bottom = v01 * (1 - fx) + v11 * fx
                out[y * width + x] = top * (1 - fy) + bottom * fy
            }
        }
        return out
    }

    /// Boundary-safe sampler. Out-of-bounds → 0 (matches the GPU
    /// implementation's `address::clamp_to_zero`).
    @inline(__always)
    private static func sample(
        _ pixels: [Float],
        width: Int,
        height: Int,
        x: Int,
        y: Int
    ) -> Float {
        if x < 0 || y < 0 || x >= width || y >= height { return 0 }
        return pixels[y * width + x]
    }
}
