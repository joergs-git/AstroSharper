// Low-resolution thumbnail cache for fast SER scrubbing on big files.
//
// Why this exists: the full-resolution SerFramePrefetcher hits the
// shared MetalDevice.commandQueue on every decode (Bayer demosaic +
// upload kernel). On 4 GB+ SERs the user's drag rate outpaces what
// that pipeline can sustain, and 16 sparse-prefill decodes there
// saturate the queue badly enough that the MAIN frame-0 load on
// `userInitiated.async` silently stalls — the preview stays black.
//
// This cache decodes 100% on the CPU and uploads a tiny
// (256-wide, byte-per-channel) MTLTexture per frame. No Metal
// kernels, no shared command queue, no contention with the main
// preview pipeline. Each entry ~150-200 KB; a 64-slot ring fits in
// ~12 MB so we can prefill a lot of frames without worrying about
// RAM. Background queue is concurrent (multiple CPU decodes run
// in parallel — they read disjoint regions of the same mmap'd file
// so I/O is parallelisable) but the Metal upload is serialised
// through one shared-storage texture per slot.
//
// Public API mirrors SerFramePrefetcher: setURL, cachedThumb,
// requestThumb, prefillSparse. PreviewView checks this cache
// FIRST during scrub; misses fall back to the full-res prefetcher.
import Foundation
import Metal

final class SerScrubLowResCache {
    private let device: MTLDevice
    /// Concurrent — CPU stride-sample + Texture.replace doesn't hit
    /// the shared MetalCommandQueue, so multiple decodes in flight
    /// don't race the main preview pipeline.
    private let workQueue = DispatchQueue(
        label: "com.joergsflow.AstroSharper.serScrubLowRes",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()

    private var currentURL: URL? = nil
    private var cache: [Int: MTLTexture] = [:]
    private var cacheOrder: [Int] = []
    private var pending: Set<Int> = []

    /// Target longest-side of the thumbnail. 256 is a sweet spot —
    /// big enough that drag-preview shows recognisable detail
    /// (sunspot positions, granulation pattern), small enough to
    /// decode in single-digit ms even for 1936×1216 sources.
    let maxDimension: Int
    /// Soft cap on cached slots. 64 × ~200 KB = ~13 MB.
    let capacity: Int

    init(device: MTLDevice, maxDimension: Int = 256, capacity: Int = 64) {
        self.device = device
        self.maxDimension = max(64, maxDimension)
        self.capacity = max(8, capacity)
    }

    /// Bind to a new SER. Clears the cache and drops any in-flight
    /// pending decodes (they'll no-op when they wake up because
    /// `currentURL` no longer matches).
    func setURL(_ newURL: URL?) {
        lock.lock()
        defer { lock.unlock() }
        if currentURL == newURL { return }
        currentURL = newURL
        cache.removeAll()
        cacheOrder.removeAll()
        pending.removeAll()
    }

    /// Sync cache lookup. nil on miss.
    func cachedThumb(at index: Int) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return cache[index]
    }

    /// Return the cached thumbnail closest to `target`. Used during
    /// fast drags so the preview always shows SOMETHING even when
    /// the exact frame isn't decoded yet.
    func nearestCachedThumb(to target: Int) -> (index: Int, texture: MTLTexture)? {
        lock.lock(); defer { lock.unlock() }
        guard !cache.isEmpty else { return nil }
        var bestIdx = -1; var bestDist = Int.max
        for k in cache.keys {
            let d = abs(k - target)
            if d < bestDist { bestDist = d; bestIdx = k }
        }
        guard let tex = cache[bestIdx] else { return nil }
        return (bestIdx, tex)
    }

    /// Asynchronously decode a single frame's thumbnail (no-op when
    /// the frame is already cached or pending). Called from
    /// PreviewView during a drag so the EXACT frame the user is
    /// currently over starts loading.
    func requestThumb(at index: Int) {
        guard let url = lockedURL() else { return }
        lock.lock()
        if cache[index] != nil { lock.unlock(); return }
        if pending.contains(index) { lock.unlock(); return }
        pending.insert(index)
        lock.unlock()
        workQueue.async { [weak self] in
            self?.decode(url: url, index: index)
        }
    }

    /// Kick `capacity / 4` background decodes spaced evenly across
    /// the SER so the first drag has visual feedback all along the
    /// bar. Skips entries already cached or pending.
    func prefillSparse(totalFrames: Int) {
        guard totalFrames > 0, let url = lockedURL() else { return }
        let slots = min(capacity / 2, 32)        // 32-frame coverage; rest free for on-demand requests
        var toFetch: [Int] = []
        lock.lock()
        for i in 0..<slots {
            let target = (slots == 1) ? 0 : Int(Double(i) * Double(totalFrames - 1) / Double(slots - 1))
            if cache[target] != nil { continue }
            if pending.contains(target) { continue }
            pending.insert(target)
            toFetch.append(target)
        }
        lock.unlock()
        for target in toFetch {
            workQueue.async { [weak self] in
                self?.decode(url: url, index: target)
            }
        }
    }

    // MARK: - Private

    private func lockedURL() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return currentURL
    }

    private func decode(url: URL, index: Int) {
        defer {
            lock.lock(); pending.remove(index); lock.unlock()
        }
        // Bail if the user switched files while we were queued.
        if lockedURL() != url { return }
        guard let reader = try? SerReader(url: url) else { return }
        let h = reader.header
        guard index >= 0, index < h.frameCount, reader.canReadFrame(at: index) else { return }
        let srcW = h.imageWidth, srcH = h.imageHeight
        let longest = max(srcW, srcH)
        let scale = max(1, longest / maxDimension)
        let dstW = max(1, srcW / scale)
        let dstH = max(1, srcH / scale)

        // 8-bit-per-channel RGBA output buffer. R=G=B=sample for mono;
        // simple 2×2 tile sample for Bayer (good enough for a drag
        // preview, the user gets the full-res frame on release).
        var rgba = [UInt8](repeating: 0, count: dstW * dstH * 4)
        let isBayer = h.colorID.isBayer
        // 16-bit sampling must cover BOTH mono and Bayer. The old `mono16`
        // flag excluded Bayer, so a 16-bit OSC SER (the common case) read
        // its 16-bit buffer with 8-bit byte indexing while actively
        // scrubbing → undebayered colour chaos that only resolved once
        // the drag stopped and the full GPU loader redrew the frame.
        let is16 = h.bytesPerPlane == 2 && !h.colorID.isRGB

        let bayerOffsets: (rx: Int, ry: Int) = {
            switch h.colorID {
            case .bayerRGGB: return (0, 0)
            case .bayerGRBG: return (1, 0)
            case .bayerGBRG: return (0, 1)
            case .bayerBGGR: return (1, 1)
            default: return (0, 0)
            }
        }()

        reader.withFrameBytes(at: index) { ptr, _ in
            func sample8(_ x: Int, _ y: Int) -> UInt8 {
                let xi = min(srcW - 1, max(0, x))
                let yi = min(srcH - 1, max(0, y))
                let idx = yi * srcW + xi
                if is16 {
                    let p16 = ptr.advanced(by: idx * 2).withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }
                    return UInt8(min(UInt32(p16) >> 8, 255))
                }
                return ptr[idx]
            }
            for y in 0..<dstH {
                let sy = min(srcH - 1, y * scale)
                for x in 0..<dstW {
                    let sx = min(srcW - 1, x * scale)
                    let outIdx = (y * dstW + x) * 4
                    if isBayer {
                        // Snap to even tile origin to sample one full
                        // RGGB unit; cheap-and-correct enough for the
                        // drag preview.
                        let tx = sx - (sx & 1)
                        let ty = sy - (sy & 1)
                        let r  = sample8(tx + bayerOffsets.rx,           ty + bayerOffsets.ry)
                        let b  = sample8(tx + (1 - bayerOffsets.rx),     ty + (1 - bayerOffsets.ry))
                        let g1 = sample8(tx + (1 - bayerOffsets.rx),     ty + bayerOffsets.ry)
                        let g2 = sample8(tx + bayerOffsets.rx,           ty + (1 - bayerOffsets.ry))
                        let g  = UInt8((Int(g1) + Int(g2)) >> 1)
                        rgba[outIdx + 0] = r
                        rgba[outIdx + 1] = g
                        rgba[outIdx + 2] = b
                    } else {
                        let v = sample8(sx, sy)
                        rgba[outIdx + 0] = v
                        rgba[outIdx + 1] = v
                        rgba[outIdx + 2] = v
                    }
                    rgba[outIdx + 3] = 255
                }
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: dstW, height: dstH, mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        rgba.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: dstW, height: dstH, depth: 1)),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: dstW * 4
            )
        }
        insert(index: index, texture: tex, ifURLMatches: url)
    }

    private func insert(index: Int, texture: MTLTexture, ifURLMatches url: URL) {
        lock.lock(); defer { lock.unlock() }
        guard currentURL == url else { return }
        if cache[index] == nil { cacheOrder.append(index) }
        cache[index] = texture
        while cacheOrder.count > capacity {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
