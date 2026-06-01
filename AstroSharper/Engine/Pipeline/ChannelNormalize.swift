// Per-channel histogram normalisation (LSW 7.2.1 parity).
//
// Auto-WB (gray-world) only aligns per-channel MEANS, which works on
// the bulk of natural OSC scenes but leaves planetary captures with
// skewed histograms — Bayer green often has 2× the photon count of
// red/blue, so even after gray-world's mean alignment the per-channel
// HIGH percentiles can stay far apart (greenish highlights). LSW's
// "Normalize" tab fixes that by stretching each channel so its [p1,
// p99] window lands on a common range.
//
// This module computes that affine correction in the same
// (offset, scale) shape `WhiteBalanceCorrection` already uses, so the
// existing `apply_white_balance` Metal kernel can apply it without a
// new GPU pass. The two ops compose: gray-world WB first (mean align)
// → channel-normalize (range align) → tone curve.
//
// Algebra. Per channel C with low percentile `low_C` and high
// percentile `high_C`, the LSW-style stretch is:
//
//     out = (in - low_C) · S_C + new_low      where S_C = (new_high - new_low) / (high_C - low_C)
//
// We want this in the kernel's form `out = (in - offset_C) · S_C`:
//
//     out = in·S_C − low_C·S_C + new_low
//         = (in − (low_C − new_low / S_C)) · S_C
//
// → offset_C = low_C − new_low / S_C
//
// For the reference channel (where low_C = new_low and high_C = new_high)
// this collapses to offset = 0 / scale = 1, i.e. identity. Confirmed
// by `referenceChannelIsIdentity` in the unit suite.
//
// Auto-engagement heuristic (`shouldEngage`): trigger only when the
// per-channel p99 spread exceeds 30% — below that the channels are
// already well aligned and re-mapping risks blooming faint detail.
import Foundation

enum ChannelNormalize {

    /// Output matches `WhiteBalanceCorrection` so the existing
    /// `apply_white_balance` Metal kernel can consume it directly.
    /// Reference is green by default (highest SNR on Bayer); other
    /// channels stretch to match green's [p1, p99] window.
    static func compute(
        red: [Float],
        green: [Float],
        blue: [Float],
        width: Int,
        height: Int,
        reference: WhiteBalance.ReferenceChannel = .green,
        lowPercentile: Double = 0.01,
        highPercentile: Double = 0.99
    ) -> WhiteBalanceCorrection {
        let n = width * height
        guard n > 0,
              red.count   == n,
              green.count == n,
              blue.count  == n
        else { return .identity }

        let lo = clamp(lowPercentile, 0, 0.5)
        let hi = clamp(highPercentile, 0.5, 1.0)

        let rLow  = percentile(red,   lo);  let rHigh = percentile(red,   hi)
        let gLow  = percentile(green, lo);  let gHigh = percentile(green, hi)
        let bLow  = percentile(blue,  lo);  let bHigh = percentile(blue,  hi)

        // Pick the reference channel's [low, high] as the target range.
        // Falls back to identity when the reference is degenerate
        // (uniform plane → high == low → divide-by-zero downstream).
        let newLow:  Float
        let newHigh: Float
        switch reference {
        case .red:   newLow = rLow;  newHigh = rHigh
        case .green: newLow = gLow;  newHigh = gHigh
        case .blue:  newLow = bLow;  newHigh = bHigh
        }
        guard newHigh > newLow + 1e-6 else { return .identity }

        let rScale = channelScale(low: rLow, high: rHigh, newLow: newLow, newHigh: newHigh)
        let gScale = channelScale(low: gLow, high: gHigh, newLow: newLow, newHigh: newHigh)
        let bScale = channelScale(low: bLow, high: bHigh, newLow: newLow, newHigh: newHigh)

        let rOffset = rLow - newLow / rScale
        let gOffset = gLow - newLow / gScale
        let bOffset = bLow - newLow / bScale

        return WhiteBalanceCorrection(
            redOffset: rOffset, greenOffset: gOffset, blueOffset: bOffset,
            redScale: rScale,   greenScale: gScale,    blueScale: bScale
        )
    }

    /// Auto-engagement gate. Fires when any channel's high percentile
    /// is more than 30% off the reference channel's high percentile.
    /// Below that the histograms are already aligned closely enough
    /// that LSW's Normalize is a no-op on screen.
    static func shouldEngage(
        red: [Float],
        green: [Float],
        blue: [Float],
        threshold: Double = 0.30
    ) -> Bool {
        guard !red.isEmpty, !green.isEmpty, !blue.isEmpty else { return false }
        let rHigh = percentile(red,   0.99)
        let gHigh = percentile(green, 0.99)
        let bHigh = percentile(blue,  0.99)
        let highs = [rHigh, gHigh, bHigh]
        guard let lo = highs.min(), let hi = highs.max(), lo > 1e-4 else { return false }
        // Relative spread: (hi - lo) / lo. > 0.30 means one channel sits
        // 30%+ above the dimmest, which is the LSW-described OSC pattern.
        return Double((hi - lo) / lo) > threshold
    }

    /// Apply the correction to a single channel buffer. Mirrors
    /// `WhiteBalance.apply` so per-channel test code can verify the
    /// math without a Metal device.
    static func apply(
        channel pixels: [Float],
        offset: Float,
        scale: Float
    ) -> [Float] {
        var out = pixels
        for i in 0..<out.count {
            out[i] = (out[i] - offset) * scale
        }
        return out
    }

    // MARK: - Helpers

    private static func channelScale(low: Float, high: Float, newLow: Float, newHigh: Float) -> Float {
        let range = high - low
        guard range > 1e-6 else { return 1 }  // degenerate channel; pass-through
        return (newHigh - newLow) / range
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, v))
    }
}
