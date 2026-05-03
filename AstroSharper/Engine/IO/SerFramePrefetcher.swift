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
    private let prefetchQueue = DispatchQueue(
        label: "com.joergsflow.AstroSharper.serPrefetch",
        qos: .userInitiated
    )
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
    private let lookAhead: Int

    init(device: MTLDevice, capacity: Int = 16, lookAhead: Int = 4) {
        self.device = device
        self.capacity = max(2, capacity)
        self.lookAhead = max(1, min(capacity - 1, lookAhead))
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
            prefetchQueue.async { [weak self] in
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
