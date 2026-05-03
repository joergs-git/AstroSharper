// Strehl-ratio analogue for frame quality scoring.
//
// In adaptive-optics literature the Strehl ratio is `peak(actual PSF) /
// peak(diffraction-limited PSF)`. We don't have a reference diffraction-
// limited PSF for the actual scope + camera + atmosphere combination at
// capture time, so we compute the *empirical* central concentration —
// the ratio of the brightest pixel to the total flux in a window
// around it. The metric tracks Strehl in the relative ranking sense:
//
//   - turbulent seeing → energy smeared over many pixels → low ratio
//   - sharp moment      → energy concentrated at the peak → high ratio
//
// Used as a complement to the LAPD variance metric (which scores edge
// crispness) in the high-frame-count regime where the lucky tail's
// 1-5% of frames is what matters and the academic Strehl definition
// is the right framing.
//
// CPU-reference here is intentional: A.3 ships the math + tests now;
// the Metal-accelerated path lands alongside A.2's bulk grader once
// the per-AP local-quality pass needs it. The CPU reference is also
// a forever-test for the GPU implementation when it arrives.
import Foundation

enum Strehl {
    /// Strehl-style central-concentration metric.
    ///
    /// - Parameters:
    ///   - pixels: row-major luminance buffer of length `width * height`
    ///   - width: image width
    ///   - height: image height
    ///   - windowRadius: half-width of the analysis window centred on
    ///     the brightest pixel. Default 8 → 17×17 px window which covers
    ///     a typical planetary disc detail patch but stays small enough
    ///     that limb-glow doesn't dominate the sum.
    /// - Returns: `peak / sum_in_window` clamped to `[0, 1]`. 0 when the
    ///   buffer is empty or all zero. 1.0 means the peak holds all of
    ///   the window's flux (delta-function concentration).
    static func computeConcentration(
        luma pixels: [Float],
        width: Int,
        height: Int,
        windowRadius: Int = 8
    ) -> Float {
        precondition(pixels.count == width * height, "buffer size mismatch")
        guard !pixels.isEmpty, windowRadius > 0, width > 0, height > 0 else {
            return 0
        }

        // Pass 1: find the brightest pixel. Float scan; vDSP is overkill
        // for the test-target's small inputs and would add an Accelerate
        // dependency to keep the engine module lean.
        var peak: Float = 0
        var peakIdx = 0
        for i in 0..<pixels.count {
            let v = pixels[i]
            if v > peak {
                peak = v
                peakIdx = i
            }
        }
        guard peak > 0 else { return 0 }

        let px = peakIdx % width
        let py = peakIdx / width
        let x0 = Swift.max(0, px - windowRadius)
        let y0 = Swift.max(0, py - windowRadius)
        let x1 = Swift.min(width - 1, px + windowRadius)
        let y1 = Swift.min(height - 1, py + windowRadius)

        // Pass 2: sum the analysis window. Negative values are clamped
        // to 0 — they aren't physical for luminance and would otherwise
        // let the ratio exceed 1.0 for synthetic test inputs.
        var sum: Float = 0
        for y in y0...y1 {
            for x in x0...x1 {
                let v = pixels[y * width + x]
                if v > 0 { sum += v }
            }
        }
        guard sum > 0 else { return 0 }

        return Swift.min(1.0, peak / sum)
    }

    /// Convenience: full-frame analysis (entire image as window).
    /// Stays as a separate API so the default `computeConcentration` can
    /// keep its small fixed window — the full-frame variant is rarely
    /// what callers want for planetary work but useful for tiny crops.
    static func computeConcentrationFullFrame(
        luma pixels: [Float],
        width: Int,
        height: Int
    ) -> Float {
        guard !pixels.isEmpty, width > 0, height > 0 else { return 0 }
        var peak: Float = 0
        var sum: Float = 0
        for v in pixels {
            if v > 0 {
                sum += v
                if v > peak { peak = v }
            }
        }
        guard sum > 0 else { return 0 }
        return Swift.min(1.0, peak / sum)
    }
}
