// LRU-bounded frame cache + look-ahead prefetcher for SER playback.
//
// Background: SER playback under the timer-driven path runs
// `SerFrameLoader.loadFrame` on every tick. On a NAS share each
// load hits ~10–30 ms of disk-read latency; the timer cadence then
// drops visible frames whenever the cadence is faster than the
// disk. The fix is two-pronged:
//
//   1. Frame cache  — keep up to `capacity` recently-decoded frames
//                     in RAM, keyed by index. The next playback tick
//                     hits the cache instead of disk.
//   2. Prefetcher   — when a frame is requested, asynchronously load
//                     the next `lookAhead` frames on a serial helper
//                     queue. By the time the timer asks for the
//                     next frame, it's typically already cached.
//
// The cache is per-prefetcher-instance (one per active SER); switching
// the file via `setURL(_:)` drops any in-flight prefetches and clears
// the cache so the next file starts fresh.
//
// Implementation notes:
//   - Lock-protected mutable state. The prefetch queue is async, so
//     cache reads/writes can race with the foreground call site.
//   - Capacity is conservative: 16 × (typical 1280×720×8 B rgba16Float)
//     ≈ 118 MB upper bound. AVI frames at 1080p eat more; users with
//     huge sensors can dial it down via the constructor.
//   - Eviction is FIFO-by-insertion (cheap O(1)). Strict LRU would
//     need touch-tracking on every read — overkill for a 16-slot
//     cache scrolling forward through a SER.
import Foundation
import Metal

final class SerFramePrefetcher {
    private let device: MTLDevice
    // Bounded-parallel decoder pool (max 2 concurrent decodes).
    //
    // Earlier this was a serial DispatchQueue because an unbounded
    // concurrent dispatch on a 4 GB SER produced black-frame-zero
    // (16+ kernel dispatches racing the initial frame-0 decode).
    // Serial fixed that race but capped throughput at 1 frame's
    // worth of disk-I/O + Metal-dispatch latency — which on a 4 GB
    // SER is too slow to keep up with an 18 fps playback timer
    // (the "Standbild → burst → Standbild" stutter).
    //
    // OperationQueue.maxConcurrentOperationCount = 2 gives us two
    // workers — enough to hide disk-read latency behind GPU dispatch
    // — without saturating the shared Metal command queue. The
    // pending-set guard prevents double-decoding the same frame from
    // multiple workers.
    private let decodeQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.joergsflow.AstroSharper.serPrefetch"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()
    private let lock = NSLock()

    private var currentURL: URL? = nil
    /// frameIndex → texture. Mutated under `lock`.
    private var cache: [Int: MTLTexture] = [:]
    /// Insertion order, for eviction. Mutated under `lock`.
    private var cacheOrder: [Int] = []
    /// Frames currently queued for prefetch. Avoids double-dispatch
    /// when the user scrubs back into already-pending frames.
    private var pendingLoads: Set<Int> = []
    private let capacity: Int
    /// How many upcoming frames to schedule on each prefetch call.
    /// 4 covers ~250 ms at 18 fps, comfortably ahead of the timer.
    /// Bumped to `playbackLookAhead` (12) while the user is playing
    /// the SER, so the serial decode queue stays deep enough that a
    /// 100 ms NAS read can't visibly stall a 30 fps timer.
    private var lookAhead: Int
    private let idleLookAhead: Int
    private let playbackLookAhead: Int

    init(device: MTLDevice, capacity: Int = 16, lookAhead: Int = 4) {
        self.device = device
        self.capacity = max(2, capacity)
        let la = max(1, min(capacity - 1, lookAhead))
        self.lookAhead = la
        self.idleLookAhead = la
        // capacity - 1 would max-fill but risk evicting frames the
        // user just played (visible content still on screen). 12 of
        // 16 leaves headroom while giving ~400 ms of buffer at 30 fps.
        self.playbackLookAhead = max(la, min(capacity - 4, 12))
    }

    /// Toggle playback mode. ON = deeper look-ahead so the serial
    /// decode queue can stay ahead of the playback timer even on
    /// slow-disk SERs. Returns the new look-ahead size.
    @discardableResult
    func setPlaybackMode(_ on: Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        lookAhead = on ? playbackLookAhead : idleLookAhead
        return lookAhead
    }

    /// Switch to a different SER (or clear when nil). Drops the
    /// cache + cancels in-flight prefetch slots so the new file
    /// starts with a clean state.
    func setURL(_ newURL: URL?) {
        lock.lock()
        if currentURL == newURL { lock.unlock(); return }
        currentURL = newURL
        cache.removeAll()
        cacheOrder.removeAll()
        // Pending loads against the old URL just no-op when they
        // wake up — `currentURL` no longer matches.
        pendingLoads.removeAll()
        lock.unlock()
        // Cancel in-flight decode operations whose URL guard is now
        // stale. They'd no-op via the urlStillMatches check anyway,
        // but cancelling frees the worker thread for the new URL's
        // prefetch faster.
        decodeQueue.cancelAllOperations()
    }

    /// Synchronous cache lookup. nil = miss.
    func cachedFrame(at index: Int) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return cache[index]
    }

    /// Cache hit → return synchronously. Miss → disk-load on the
    /// caller's thread, insert, return. Caller is responsible for
    /// dispatching this to a background queue if blocking is bad.
    func loadFrameSync(at index: Int) -> MTLTexture? {
        if let hit = cachedFrame(at: index) { return hit }
        guard let url = lockedURL() else { return nil }
        let tex = try? SerFrameLoader.loadFrame(
            url: url, frameIndex: index, device: device
        )
        if let tex { insert(index: index, texture: tex, ifURLMatches: url) }
        return tex
    }

    /// Return the cached frame whose index is closest to `target`, or
    /// nil if the cache is empty. Used by the scrub bar to show
    /// instant feedback during a drag — instead of decoding every
    /// scrub position (slow on remote files / huge frames), the UI
    /// snaps to whichever nearby frame is already decoded.
    func nearestCachedFrame(to target: Int) -> (index: Int, texture: MTLTexture)? {
        lock.lock(); defer { lock.unlock() }
        guard !cache.isEmpty else { return nil }
        var bestIdx = -1
        var bestDist = Int.max
        for k in cache.keys {
            let d = abs(k - target)
            if d < bestDist { bestDist = d; bestIdx = k }
        }
        guard let tex = cache[bestIdx] else { return nil }
        return (bestIdx, tex)
    }

    /// Background-fill the cache with frames spaced evenly across the
    /// SER, up to `capacity` slots. Called once per SER-load so a
    /// fresh drag immediately has scrub-preview material everywhere.
    /// Frames currently cached or pending are skipped, so calling this
    /// multiple times is harmless. Quietly aborts if the URL changes
    /// while loading (setURL clears `currentURL`).
    func prefillSparse(totalFrames: Int) {
        guard totalFrames > 0, let url = lockedURL() else { return }
        let slots = capacity
        var toFetch: [Int] = []
        lock.lock()
        for i in 0..<slots {
            // Spread evenly: frame 0, frame N/slots, ..., frame N-1
            let target = (slots == 1) ? 0 : Int(Double(i) * Double(totalFrames - 1) / Double(slots - 1))
            if cache[target] != nil { continue }
            if pendingLoads.contains(target) { continue }
            pendingLoads.insert(target)
            toFetch.append(target)
        }
        lock.unlock()
        for target in toFetch {
            decodeQueue.addOperation { [weak self] in
                guard let self else { return }
                guard self.urlStillMatches(url) else {
                    self.markPendingDone(index: target)
                    return
                }
                let tex = try? SerFrameLoader.loadFrame(
                    url: url, frameIndex: target, device: self.device
                )
                if let tex {
                    self.insert(index: target, texture: tex, ifURLMatches: url)
                }
                self.markPendingDone(index: target)
            }
        }
    }

    /// Schedule the next `lookAhead` frames after `index` for
    /// background loading. No-op when the next frames are already
    /// cached or pending.
    func prefetch(after index: Int, totalFrames: Int) {
        guard let url = lockedURL() else { return }
        var toFetch: [Int] = []
        lock.lock()
        for offset in 1...lookAhead {
            let target = index + offset
            if target >= totalFrames { break }
            if cache[target] != nil { continue }
            if pendingLoads.contains(target) { continue }
            pendingLoads.insert(target)
            toFetch.append(target)
        }
        lock.unlock()
        for target in toFetch {
            decodeQueue.addOperation { [weak self] in
                guard let self else { return }
                guard self.urlStillMatches(url) else {
                    self.markPendingDone(index: target)
                    return
                }
                let tex = try? SerFrameLoader.loadFrame(
                    url: url, frameIndex: target, device: self.device
                )
                if let tex {
                    self.insert(index: target, texture: tex, ifURLMatches: url)
                }
                self.markPendingDone(index: target)
            }
        }
    }

    // MARK: - Internal

    private func lockedURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return currentURL
    }

    private func urlStillMatches(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentURL == url
    }

    private func insert(index: Int, texture: MTLTexture, ifURLMatches url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard currentURL == url else { return }
        if cache[index] == nil {
            cacheOrder.append(index)
        }
        cache[index] = texture
        // Evict oldest until under capacity.
        while cacheOrder.count > capacity {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func markPendingDone(index: Int) {
        lock.lock()
        defer { lock.unlock() }
        pendingLoads.remove(index)
    }
}
