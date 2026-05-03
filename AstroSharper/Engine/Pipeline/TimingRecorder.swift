// Per-phase wall-clock timing collector.
//
// The regression harness needs to detect performance drift across
// algorithm changes — adding a metric like "stacking went from 60 s to
// 120 s on the same SER" is the only way the F3 baseline JSON catches
// when an otherwise-correct refactor blows the perf budget. F.3 lands
// the recorder; integration into BatchJob / LuckyStack lands when the
// CLI's `stack` subcommand goes in. Tests stay GPU-independent.
//
// Thread-safety: each TimingRecorder instance is owned by exactly one
// runner. We don't share recorders across threads — make a fresh one
// per invocation so concurrent BatchJobs don't trample each other.
import Foundation

/// Single completed phase entry written to the metrics JSON.
struct TimingRecord: Codable, Equatable {
    let label: String
    let elapsedSeconds: Double
}

/// Lightweight phase recorder. Pattern: `start("grade") → ... →
/// start("align") → ... → finish()`. Calling `start` while a phase is
/// open auto-closes that phase first, so the typical use is
/// "checkpoint at every stage boundary, the recorder builds the
/// per-phase breakdown automatically".
final class TimingRecorder {

    /// Snapshot of all completed phases in start order.
    private(set) var records: [TimingRecord] = []

    /// Time source — overridable for deterministic unit tests. Default
    /// returns Date.now seconds-since-1970. Tests inject a Clock that
    /// advances on demand so the elapsedSeconds assertions are stable.
    typealias Clock = () -> Double
    private let clock: Clock

    private var pendingLabel: String?
    private var pendingStartedAt: Double?

    init(clock: @escaping Clock = { Date().timeIntervalSince1970 }) {
        self.clock = clock
    }

    /// Open a new phase. Closes any phase that's still open first.
    func start(_ label: String) {
        finish()
        pendingLabel = label
        pendingStartedAt = clock()
    }

    /// Close the current phase, returning its record. Returns nil when
    /// no phase is pending.
    @discardableResult
    func finish() -> TimingRecord? {
        guard let label = pendingLabel, let startedAt = pendingStartedAt else {
            return nil
        }
        let elapsed = max(0, clock() - startedAt)
        let r = TimingRecord(label: label, elapsedSeconds: elapsed)
        records.append(r)
        pendingLabel = nil
        pendingStartedAt = nil
        return r
    }

    /// Total wall-clock across every recorded phase. Excludes any
    /// pending-but-unfinished phase.
    var totalElapsedSeconds: Double {
        records.reduce(0) { $0 + $1.elapsedSeconds }
    }

    /// Discard all state and reset for re-use. Useful for the runner
    /// that wants to batch many SERs through the same recorder
    /// instance per invocation.
    func reset() {
        records.removeAll()
        pendingLabel = nil
        pendingStartedAt = nil
    }
}
