// Gray-world automatic white balance for OSC (one-shot color) captures.
//
// BiggSky's documented "Calc White Balance" computes RGB background
// offsets + per-channel scalings such that the post-correction
// histograms are roughly aligned. The classical "gray-world"
// hypothesis: the average of a natural scene tends toward neutral
// grey, so each channel's mean should equal the reference channel's
// mean after correction.
//
// Refinements over plain gray-world:
//
//   * Background subtraction. Per-channel low percentile (5th by
//     default) is treated as the dark / sky / bias floor and removed
//     before scaling. Without this, a bright planet on a dark sky
//     pulls the gray-world mean toward the planet's colour rather
//     than toward "neutral".
//
//   * Reference is green by default. Bayer green photosites have 2×
//     the photon count of red and blue, so green has the best SNR and
//     usually needs the least correction.
//
// CPU + Foundation. Applied per-channel by the GPU display path or
// the deconvolution module — that wiring lands when D.3 plugs into
// Pipeline.process.
import Foundation

/// Output of an auto-WB analysis. Apply per-pixel:
///
///   out = (in - offset) * scale
///
/// One offset + scale per RGB channel. Identity = (0, 0, 0) offsets
/// and (1, 1, 1) scales — leaves the input unchanged.
struct WhiteBalanceCorrection: Equatable, Codable {
    var redOffset: Float
    var greenOffset: Float
    var blueOffset: Float
    var redScale: Float
    var greenScale: Float
    var blueScale: Float

    static let identity = WhiteBalanceCorrection(
        redOffset: 0, greenOffset: 0, blueOffset: 0,
        redScale: 1,  greenScale: 1,  blueScale: 1
    )
}

enum WhiteBalance {

    /// Reference channel for the gray-world scaling. The non-reference
    /// channels get scaled to match the reference's post-offset mean.
    enum ReferenceChannel: String, Codable, CaseIterable {
        case red, green, blue
    }

    /// Compute a gray-world WB correction from per-channel float planes.
    ///
    /// - Parameters:
    ///   - red, green, blue: row-major luminance planes, all the same
    ///     size = `width * height`. For OSC sources these are the
    ///     debayered channels.
    ///   - width, height: plane dimensions.
    ///   - reference: which channel is held fixed; the other two are
    ///     scaled to match its mean. Default `.green` (highest SNR on
    ///     Bayer sensors).
    ///   - backgroundPercentile: sample percentile to treat as the
    ///     dark / sky floor and subtract before computing scales.
    ///     Default 0.05 (5th percentile). Set to 0 to disable.
    /// - Returns: a `WhiteBalanceCorrection` to apply to each channel
    ///   independently. Returns `.identity` on empty / degenerate input.
    static func computeGrayWorld(
        red: [Float],
        green: [Float],
        blue: [Float],
        width: Int,
        height: Int,
        reference: ReferenceChannel = .green,
        backgroundPercentile: Double = 0.05
    ) -> WhiteBalanceCorrection {
        let n = width * height
        guard n > 0,
              red.count == n,
              green.count == n,
              blue.count == n
        else {
            return .identity
        }

        // Per-channel background floor.
        let pctl = clamp(backgroundPercentile, 0, 0.5)
        let rOff = pctl > 0 ? percentile(red,   pctl) : 0
        let gOff = pctl > 0 ? percentile(green, pctl) : 0
        let bOff = pctl > 0 ? percentile(blue,  pctl) : 0

        // Per-channel mean above the floor.
        let rMean = meanAbove(red,   offset: rOff)
        let gMean = meanAbove(green, offset: gOff)
        let bMean = meanAbove(blue,  offset: bOff)

        // Pick reference + compute scales. If the reference channel's
        // post-offset mean is too small to divide by, fall back to
        // identity scaling on that channel and leave the others alone.
        let rScale: Float
        let gScale: Float
        let bScale: Float
        let eps: Float = 1e-6
        switch reference {
        case .green:
            guard gMean > eps else { return defaultsWith(rOff, gOff, bOff) }
            rScale = rMean > eps ? gMean / rMean : 1
            gScale = 1
            bScale = bMean > eps ? gMean / bMean : 1
        case .red:
            guard rMean > eps else { return defaultsWith(rOff, gOff, bOff) }
            rScale = 1
            gScale = gMean > eps ? rMean / gMean : 1
            bScale = bMean > eps ? rMean / bMean : 1
        case .blue:
            guard bMean > eps else { return defaultsWith(rOff, gOff, bOff) }
            rScale = rMean > eps ? bMean / rMean : 1
            gScale = gMean > eps ? bMean / gMean : 1
            bScale = 1
        }

        return WhiteBalanceCorrection(
            redOffset: rOff, greenOffset: gOff, blueOffset: bOff,
            redScale: rScale, greenScale: gScale, blueScale: bScale
        )
    }

    /// Apply a correction to one channel buffer, returning a fresh
    /// buffer. Negative results are clamped to 0 so a shadow pixel
    /// below the background floor doesn't go negative after offset
    /// subtraction.
    static func apply(
        channel pixels: [Float],
        offset: Float,
        scale: Float
    ) -> [Float] {
        var out = pixels
        for i in 0..<out.count {
            let v = (out[i] - offset) * scale
            out[i] = v > 0 ? v : 0
        }
        return out
    }

    // MARK: - Helpers

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    /// Mean of `(values[i] - offset)` clamped to ≥ 0. The clamp keeps
    /// floor-pixels from contributing negative values to the mean (which
    /// would inflate it), matching BiggSky's behaviour.
    private static func meanAbove(_ values: [Float], offset: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        var sum: Double = 0
        for v in values {
            let d = v - offset
            sum += Double(d > 0 ? d : 0)
        }
        return Float(sum / Double(values.count))
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, v))
    }

    private static func defaultsWith(_ rOff: Float, _ gOff: Float, _ bOff: Float) -> WhiteBalanceCorrection {
        WhiteBalanceCorrection(
            redOffset: rOff, greenOffset: gOff, blueOffset: bOff,
            redScale: 1, greenScale: 1, blueScale: 1
        )
    }
}
