// Sigma-clipped mean — outlier-robust per-pixel stack reduction.
//
// AS!4 and PSS both use sigma-clipping as their default outlier
// rejection during stack accumulation: cosmic rays, hot pixels, the
// occasional satellite trail or wind-jolted frame all produce
// outliers that contaminate a plain arithmetic mean. Sigma-clipping
// rejects them.
//
// Algorithm (per-pixel, across N frames):
//   1. Compute mean μ and standard deviation σ across all N samples.
//   2. Recompute mean using only samples where |x - μ| ≤ k·σ.
//   3. Optionally iterate (default 1 pass; AS!4 uses 1).
//
// CPU reference + tests here. The Metal kernel that lands in
// LuckyStack writes its own (Welford accumulator → second-pass
// rejection) and validates against this code on a fixed-pixel
// synthetic.
//
// Pure-Swift / Foundation. Defensive on degenerate inputs:
//   * empty samples       → 0
//   * single sample       → that value
//   * σ = 0 (all equal)   → arithmetic mean, no clipping
//   * all clipped         → falls back to arithmetic mean (shouldn't
//                           happen mathematically — clipping at k > 0
//                           cannot reject every sample — but the guard
//                           is cheap insurance for floating-point
//                           edge cases).
import Foundation

enum SigmaClip {

    /// Default rejection threshold. AS!4 ships at 2.5 σ; BiggSky's docs
    /// don't expose this directly but the underlying algorithm is the
    /// same family. 2.5 rejects ~1.2% of samples in a Gaussian
    /// distribution — clean cosmic rays / hot pixels are usually 5–10 σ
    /// away from the mean and get caught in pass 1.
    static let defaultSigmaThreshold: Float = 2.5

    /// Per-pixel sigma-clipped mean across the supplied samples.
    static func clippedMean(
        samples: [Float],
        sigmaThreshold: Float = defaultSigmaThreshold,
        iterations: Int = 1
    ) -> Float {
        guard !samples.isEmpty else { return 0 }
        if samples.count == 1 { return samples[0] }

        var meanValue = arithmeticMean(samples)
        var current = samples
        for _ in 0..<max(1, iterations) {
            let stddevValue = stddev(current, mean: meanValue)
            if stddevValue <= 0 {
                // All samples equal — no further refinement possible.
                return meanValue
            }
            let cutoff = sigmaThreshold * stddevValue
            let filtered = current.filter { abs($0 - meanValue) <= cutoff }
            if filtered.isEmpty {
                // Defensive: return current best estimate; further
                // iterations would be no-ops.
                return meanValue
            }
            let nextMean = arithmeticMean(filtered)
            // Stop iterating early if the mean stabilised.
            let delta = abs(nextMean - meanValue)
            current = filtered
            meanValue = nextMean
            if delta < 1e-6 { break }
        }
        return meanValue
    }

    /// Per-pixel sigma-clipped stack of N frames. Each frame is a
    /// row-major luminance buffer of `width * height` Floats; output is
    /// the same shape, where each output pixel is the sigma-clipped
    /// mean across the N input frames at that location.
    ///
    /// Empty `frames` returns an all-zero buffer.
    static func clippedMeanStack(
        frames: [[Float]],
        width: Int,
        height: Int,
        sigmaThreshold: Float = defaultSigmaThreshold,
        iterations: Int = 1
    ) -> [Float] {
        let n = width * height
        guard !frames.isEmpty else { return [Float](repeating: 0, count: n) }
        for f in frames { precondition(f.count == n, "frame size mismatch") }

        var out = [Float](repeating: 0, count: n)
        var perPixelSamples = [Float](repeating: 0, count: frames.count)
        for i in 0..<n {
            for (k, f) in frames.enumerated() {
                perPixelSamples[k] = f[i]
            }
            out[i] = clippedMean(
                samples: perPixelSamples,
                sigmaThreshold: sigmaThreshold,
                iterations: iterations
            )
        }
        return out
    }

    /// How many samples were rejected as outliers in a single
    /// clipping pass. Diagnostic — the regression harness logs this
    /// per stack so the user can verify "1–3% rejected on good seeing,
    /// more on cosmic-ray-affected captures" matches BiggSky guidance.
    static func clipCount(
        samples: [Float],
        sigmaThreshold: Float = defaultSigmaThreshold
    ) -> Int {
        guard samples.count > 1 else { return 0 }
        let m = arithmeticMean(samples)
        let s = stddev(samples, mean: m)
        guard s > 0 else { return 0 }
        let cutoff = sigmaThreshold * s
        return samples.reduce(0) { $0 + (abs($1 - m) > cutoff ? 1 : 0) }
    }

    // MARK: - Helpers

    private static func arithmeticMean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sum: Double = 0
        for v in values { sum += Double(v) }
        return Float(sum / Double(values.count))
    }

    /// Population stddev (divide by N). Single-pass via the supplied
    /// `mean` so we don't spend a second pass when the caller already
    /// has it.
    private static func stddev(_ values: [Float], mean m: Float) -> Float {
        guard values.count > 1 else { return 0 }
        var sumSq: Double = 0
        let mD = Double(m)
        for v in values {
            let d = Double(v) - mD
            sumSq += d * d
        }
        return Float((sumSq / Double(values.count)).squareRoot())
    }
}
