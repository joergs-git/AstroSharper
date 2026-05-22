// Folder watcher for the auto-stack "realtime" mode (LSW 5.2 parity).
//
// Watches a single directory for content changes (files added / removed)
// and fires a coalesced callback. AppModel uses it to pick up freshly-
// captured SER files from a SharpCap / FireCapture output folder and feed
// them into the lucky-stack queue automatically — "go to bed, wake up to
// stacked TIFFs."
//
// Mechanism: a `DispatchSource` file-system-object source (kqueue) on the
// directory's file descriptor with the `.write` event flag. The kernel
// raises `.write` on a directory vnode whenever an entry is added or
// removed. We don't try to diff WHAT changed here — the callback just
// says "something moved", and AppModel re-scans + diffs against its own
// seen-set. That keeps this type tiny and side-effect-free.
//
// Sandbox: the caller must already hold a security scope on `url` (via the
// app-scope bookmark path AppModel uses for the output folder). Opening
// the directory fd with `O_EVTONLY` requires only read access, which the
// user-selected-read-write entitlement grants once the scope is held.
//
// Coalescing: directory writes during an active capture can fire many
// times per second. The source callback hops to `callbackQueue` (main by
// default) where AppModel's own poll timer does the heavy re-scan, so we
// don't need extra debouncing here — but we DO guard against re-entrant
// teardown by checking `isCancelled`.
import Foundation

final class FolderWatcher {

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let callbackQueue: DispatchQueue
    private let onChange: () -> Void

    /// - Parameters:
    ///   - callbackQueue: where `onChange` is delivered. Defaults to main
    ///     because AppModel (the only caller) is `@MainActor`.
    ///   - onChange: invoked (coalesced by the kernel + dispatch) whenever
    ///     the watched directory's contents change.
    init(callbackQueue: DispatchQueue = .main, onChange: @escaping () -> Void) {
        self.callbackQueue = callbackQueue
        self.onChange = onChange
    }

    deinit { stop() }

    /// Begin watching `url`. Returns false if the directory couldn't be
    /// opened (bad path, missing scope) so the caller can surface an error
    /// instead of silently never firing. Calling `start` again replaces
    /// any prior watch.
    @discardableResult
    func start(url: URL) -> Bool {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: callbackQueue
        )
        src.setEventHandler { [weak self] in
            guard let self, let s = self.source, !s.isCancelled else { return }
            // `.rename` / `.delete` on the directory itself means the
            // watched folder was moved or removed — the fd is stale, so
            // tear down. Content changes (`.write`) just re-notify.
            let flags = s.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.stop()
                return
            }
            self.onChange()
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        source = src
        src.resume()
        return true
    }

    /// Stop watching and release the directory fd. Idempotent.
    func stop() {
        if let src = source {
            source = nil
            src.cancel()   // cancel handler closes the fd
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    var isWatching: Bool { source != nil }
}

// MARK: - Stability tracking (pure, testable)

/// Tracks per-file size samples to decide when a freshly-appearing SER is
/// "done being written". SharpCap / FireCapture stream a SER over many
/// seconds; stacking a half-written file would read garbage past the
/// truncation point. A file is considered COMPLETE once its size has been
/// observed unchanged (and non-zero) across at least `requiredStableSamples`
/// consecutive polls — i.e. the capture stopped growing it.
///
/// Pure value logic so the unit tests can drive it with synthetic size
/// sequences without touching the filesystem or a real timer. AppModel
/// feeds it real `FileManager` sizes on each poll tick.
struct WatchStabilityTracker {

    /// How many consecutive equal-size polls mark a file complete. With a
    /// 2 s poll interval, 2 samples ≈ 4 s of no growth — comfortably past
    /// the inter-buffer flush cadence of typical capture software without
    /// making the user wait too long after a capture finishes.
    let requiredStableSamples: Int

    init(requiredStableSamples: Int = 2) {
        self.requiredStableSamples = max(1, requiredStableSamples)
    }

    private struct Sample {
        var lastSize: Int
        var stableCount: Int
        var fired: Bool      // already reported complete once
    }
    private var samples: [URL: Sample] = [:]

    /// Feed the current size of a tracked file. Returns true the FIRST
    /// time the file is judged complete (so the caller enqueues it exactly
    /// once); subsequent calls for the same URL return false until it's
    /// dropped via `forget`. A zero / negative size never completes (the
    /// file may have just been created with no data yet).
    mutating func observe(url: URL, size: Int) -> Bool {
        if size <= 0 {
            // Empty placeholder — reset the stability run, never complete.
            samples[url] = Sample(lastSize: size, stableCount: 0, fired: false)
            return false
        }

        // First sighting: record the size but DON'T count it as a stable
        // sample. Stability requires `requiredStableSamples` SUBSEQUENT
        // observations at the same size, so the first one just establishes
        // the baseline.
        guard var s = samples[url] else {
            samples[url] = Sample(lastSize: size, stableCount: 0, fired: false)
            return false
        }

        if s.lastSize == size {
            s.stableCount += 1
        } else {
            s.lastSize = size
            s.stableCount = 0
        }

        let complete = !s.fired && s.stableCount >= requiredStableSamples
        if complete { s.fired = true }
        samples[url] = s
        return complete
    }

    /// Stop tracking a URL (after it's been enqueued, or when it vanished).
    mutating func forget(_ url: URL) {
        samples.removeValue(forKey: url)
    }

    /// Drop everything (watch stopped).
    mutating func reset() {
        samples.removeAll()
    }

    /// URLs currently being tracked but not yet reported complete.
    var pendingCount: Int {
        samples.values.filter { !$0.fired }.count
    }
}
