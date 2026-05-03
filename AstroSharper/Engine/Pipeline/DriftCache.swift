// Cumulative drift tracking for phase-correlation alignment.
//
// PSS's `dy_min_cum` / `dx_min_cum` accumulators in stack_frames.py
// keep a running prior on the next frame's shift so the cross-power
// spectrum search can either (a) start from the predicted location
// (smaller search window, less FFT cost) or (b) reject outliers when
// a single frame's correlation peak lands far from the trend.
//
// We start with the data structure + outlier detection — Stabilizer
// integration (passing the prediction into Align.phaseCorrelate's
// IFFT-result masking) follows once the GPU phase-correlation path is
// re-enabled (F.1). Until then DriftCache is consumed by the post-
// alignment validation pass: any frame whose computed shift differs
// from the predicted shift by more than `outlierThresholdPx` is
// flagged so the caller can choose to clamp / re-correlate / drop it.
//
// Pure-Swift, fully testable, GPU-independent.
import Foundation

/// One cached per-frame shift entry — the same shape as `Align.AlignShift`
/// minus the live texture handles.
struct DriftCacheEntry: Equatable {
    let frameIndex: Int
    let shift: AlignShift
}

final class DriftCache {

    /// Recorded shifts in the order the caller appended them. We keep
    /// the full history so velocity prediction has a window to work
    /// with — the long-video win comes from the trend, not just the
    /// last sample.
    private(set) var entries: [DriftCacheEntry] = []

    /// How many of the most-recent shifts the velocity estimator
    /// considers. Smaller = more responsive to direction changes;
    /// larger = smoother prediction. 4 is a reasonable default for
    /// typical 30-100 fps planetary captures where the true drift
    /// rate changes slowly over many frames.
    var velocityWindow: Int = 4

    init() {}

    /// Reset to an empty history. Use when starting a new SER / batch
    /// so prior captures' drift patterns don't bleed into the new run.
    func reset() {
        entries.removeAll()
    }

    /// Append a measured shift. Frames must arrive in monotonically
    /// increasing index order; the cache silently ignores out-of-order
    /// inserts (caller likely raced the alignment pass).
    func append(frameIndex: Int, shift: AlignShift) {
        if let last = entries.last, last.frameIndex >= frameIndex {
            return
        }
        entries.append(DriftCacheEntry(frameIndex: frameIndex, shift: shift))
    }

    /// Predict the shift the *next* (unseen) frame is likely to have.
    ///
    /// 0 entries  → nil ("no prior; use full search").
    /// 1 entry    → that entry's shift unchanged.
    /// ≥ 2 entries → linear extrapolation: lastShift + estimatedVelocity.
    ///   `estimatedVelocity` is the average per-frame shift across the
    ///   last `velocityWindow` entries.
    func predictNextShift() -> AlignShift? {
        guard let last = entries.last else { return nil }
        guard entries.count >= 2 else { return last.shift }

        let windowStart = max(0, entries.count - velocityWindow - 1)
        let window = Array(entries[windowStart...])
        guard window.count >= 2 else { return last.shift }

        // Per-frame velocity = average of (Δshift / Δframes) across the
        // window's adjacent pairs.
        var sumVx: Float = 0
        var sumVy: Float = 0
        var pairs: Float = 0
        for i in 1..<window.count {
            let prev = window[i - 1]
            let curr = window[i]
            let dFrames = Float(curr.frameIndex - prev.frameIndex)
            guard dFrames > 0 else { continue }
            sumVx += (curr.shift.dx - prev.shift.dx) / dFrames
            sumVy += (curr.shift.dy - prev.shift.dy) / dFrames
            pairs += 1
        }
        guard pairs > 0 else { return last.shift }
        let velX = sumVx / pairs
        let velY = sumVy / pairs

        // Extrapolate one frame forward.
        return AlignShift(
            dx: last.shift.dx + velX,
            dy: last.shift.dy + velY
        )
    }

    /// Distance (px) between two shifts. Useful for outlier scoring.
    static func distance(_ a: AlignShift, _ b: AlignShift) -> Float {
        let dx = a.dx - b.dx
        let dy = a.dy - b.dy
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Is `shift` far enough from the predicted next shift to count as
    /// an outlier? Returns false when there's no prediction (no prior
    /// data) — the caller's job to handle "first frame" sensibly.
    func isOutlier(shift: AlignShift, thresholdPx: Float) -> Bool {
        guard let predicted = predictNextShift() else { return false }
        return DriftCache.distance(shift, predicted) > thresholdPx
    }

    // MARK: - Stabilizer integration (B.4)

    /// Default outlier threshold for the post-alignment validation pass.
    /// 10 px sits well above the typical frame-to-frame drift on
    /// planetary captures (1-3 px) and only fires on gross phase-corr
    /// peak-finding failures (which usually return shifts of 50+ px
    /// landing on noise). Tunable per call via the `outlierThresholdPx`
    /// parameter on `validateChronologically`.
    static let defaultOutlierThresholdPx: Float = 10

    /// Replay a chronologically-ordered list of (frameIndex, shift)
    /// entries, replacing outlier shifts with the linear-extrapolated
    /// prediction from the trailing history. Returns the corrected
    /// shifts in input order and the number of replacements.
    ///
    /// Reference frames (where `frameIndex == referenceIndex`) are
    /// always emitted as `(0, 0)` and counted as a clean entry in the
    /// cache so predictions across the reference stay continuous.
    ///
    /// Pure Swift; called by Stabilizer.run after the phase-correlation
    /// loop. Same logic is reusable from CLI or batch pipelines.
    static func validateChronologically(
        shifts: [(frameIndex: Int, shift: AlignShift)],
        referenceIndex: Int,
        outlierThresholdPx: Float = defaultOutlierThresholdPx
    ) -> (corrected: [AlignShift], outlierCount: Int) {
        let cache = DriftCache()
        var corrected: [AlignShift] = []
        corrected.reserveCapacity(shifts.count)
        var outliers = 0
        for entry in shifts {
            // Reference frame: shift is (0,0) by definition. Anchor it
            // in the cache so predictions on either side of it remain
            // chronologically consistent.
            if entry.frameIndex == referenceIndex {
                let zero = AlignShift(dx: 0, dy: 0)
                cache.append(frameIndex: entry.frameIndex, shift: zero)
                corrected.append(zero)
                continue
            }
            if let predicted = cache.predictNextShift(),
               DriftCache.distance(entry.shift, predicted) > outlierThresholdPx {
                cache.append(frameIndex: entry.frameIndex, shift: predicted)
                corrected.append(predicted)
                outliers += 1
            } else {
                cache.append(frameIndex: entry.frameIndex, shift: entry.shift)
                corrected.append(entry.shift)
            }
        }
        return (corrected, outliers)
    }
}
