// Pre-stack calibration math.
//
// Standard astrophotography frame chain:
//
//   calibrated_pixel = (light_pixel - dark_pixel) / flat_norm_pixel
//
// where `flat_norm` is the master flat divided by its own global mean
// (so its average is 1.0 — applying it normalises vignetting / dust
// shadows without changing overall brightness). For lucky planetary
// imaging on bright targets calibration is often skipped (see D.2),
// but the math has to be right when it IS applied — Mars, Saturn,
// long-exposure lunar Hα all benefit.
//
// Master frames are produced by averaging N raw frames of the same
// kind. Bias frames are conventionally rolled into the master dark
// for short-exposure work (matched-exposure darks already capture
// bias), so we don't expose a bias path separately at v0.
//
// Pure-CPU + Foundation. The GPU implementation lands when D.1 wires
// into the LuckyStack runner; this commit ships the math + tests so
// the kernel can validate against it.
import Foundation

enum Calibration {

    /// Apply calibration to one luminance frame.
    ///
    /// Steps (all per-pixel):
    ///   1. If `masterDark` is provided, subtract it: `light - dark`.
    ///   2. If `masterFlatNormalized` is provided AND its pixel is
    ///      > epsilon, divide: `result / flat`.
    ///
    /// Pixels where the flat is at-or-below epsilon are passed through
    /// unchanged (avoids `/ 0` blowing up in deep-dust regions of a
    /// bad flat). Negative results are clamped to 0 so downstream
    /// log/sqrt-style ops don't NaN.
    ///
    /// `masterFlatNormalized` MUST already be divided by its own mean
    /// (see `buildMasterFlat`). Passing a raw flat will scale the
    /// output by the inverse of the flat's average brightness — the
    /// exact bug the normalised input prevents.
    static func calibrate(
        light: [Float],
        masterDark: [Float]?,
        masterFlatNormalized: [Float]?,
        width: Int,
        height: Int,
        flatEpsilon: Float = 1e-4
    ) -> [Float] {
        let n = width * height
        precondition(light.count == n, "light buffer size mismatch")
        if let d = masterDark { precondition(d.count == n, "dark buffer size mismatch") }
        if let f = masterFlatNormalized { precondition(f.count == n, "flat buffer size mismatch") }

        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var v = light[i]
            if let d = masterDark { v -= d[i] }
            if let f = masterFlatNormalized {
                let denom = f[i]
                if denom > flatEpsilon {
                    v /= denom
                }
                // else pass through — bad flat pixel
            }
            out[i] = max(0, v)
        }
        return out
    }

    /// Average N dark frames into a master dark. Caller is responsible
    /// for matching exposure / temperature; this just averages.
    /// Returns the all-zero buffer when `darks` is empty.
    static func buildMasterDark(
        darks: [[Float]],
        width: Int,
        height: Int
    ) -> [Float] {
        let n = width * height
        guard !darks.isEmpty else { return [Float](repeating: 0, count: n) }
        for d in darks { precondition(d.count == n, "dark frame size mismatch") }

        var sum = [Float](repeating: 0, count: n)
        for d in darks {
            for i in 0..<n { sum[i] += d[i] }
        }
        let scale = 1.0 / Float(darks.count)
        for i in 0..<n { sum[i] *= scale }
        return sum
    }

    /// Build a normalised master flat from N raw flats and an optional
    /// master dark.
    ///
    ///   master_flat_norm = (avg(flats) - dark) / mean(avg(flats) - dark)
    ///
    /// The result has global mean ≈ 1.0 so applying it preserves
    /// overall brightness. Empty input returns an all-1.0 buffer
    /// (identity flat). All-zero or negative-mean input returns the
    /// identity to avoid divide-by-zero or sign-flip.
    static func buildMasterFlat(
        flats: [[Float]],
        masterDark: [Float]?,
        width: Int,
        height: Int
    ) -> [Float] {
        let n = width * height
        guard !flats.isEmpty else { return [Float](repeating: 1, count: n) }

        // Average + dark subtraction.
        var avg = [Float](repeating: 0, count: n)
        for f in flats {
            precondition(f.count == n, "flat frame size mismatch")
            for i in 0..<n { avg[i] += f[i] }
        }
        let scale = 1.0 / Float(flats.count)
        for i in 0..<n { avg[i] *= scale }
        if let d = masterDark {
            precondition(d.count == n, "dark size mismatch")
            for i in 0..<n { avg[i] -= d[i] }
        }

        // Global mean.
        var sum: Double = 0
        for i in 0..<n { sum += Double(avg[i]) }
        let mean = sum / Double(n)
        guard mean > 0 else {
            // Flat is degenerate — fall back to identity.
            return [Float](repeating: 1, count: n)
        }

        // Normalise.
        let inv = Float(1.0 / mean)
        for i in 0..<n { avg[i] *= inv }
        return avg
    }
}
