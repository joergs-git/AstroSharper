// Scrub proxy atlas — a persistent, complete low-res proxy of a SER so
// scrubbing huge (8-20 GB) captures is instant instead of laggy.
//
// Why this exists (over the on-demand SerScrubLowResCache): that cache
// holds only ~64 thumbnails and decodes them lazily, so most scrub
// positions miss → a cold random multi-MB read into the giant file
// (worst on external SSD / NAS) → the "jump + catch-up" lag the user
// sees. This builds ONE compact proxy file ONCE (opt-in, cached, keyed
// by path+size+mtime) covering up to ~1500 frames spread across the
// whole SER. At runtime scrubbing reads from that small file (memory-
// mapped) and uploads decode-FREE raw RGBA8 thumbnails — no random
// seeks into the original, every position covered.
//
// IMPORTANT: this is a READ-ONLY preview accelerator. It never feeds the
// export / stacking paths and the scrub index stays the TRUE SER frame
// index, so trim Start/End markers and exports are completely unaffected.
//
// Format (.lrproxy, little-endian):
//   magic "ASLR" (4) · version u32 · frameCount u32 · atlasCount u32
//   · stride u32 · thumbW u32 · thumbH u32           (28-byte header)
//   then atlasCount fixed-size RGBA8 thumbnails, each thumbW·thumbH·4
//   bytes. Entry i corresponds to true frame min(i·stride, frameCount-1).
import Foundation
import Metal

final class ScrubProxyAtlas {
    private let device: MTLDevice
    private let lock = NSLock()

    // Loaded-for-reading state.
    private var mapped: Data? = nil            // mmap'd proxy file
    private var openURL: URL? = nil            // SER this atlas is bound to
    private var frameCount = 0
    private var atlasCount = 0
    private var stride = 1
    private var thumbW = 0
    private var thumbH = 0
    private var dataStart = 0                   // byte offset of first thumb
    // Small LRU of decoded textures (decode is just a buffer copy, but
    // we still cache to avoid re-uploading the same entry every redraw).
    private var texCache: [Int: MTLTexture] = [:]
    private var texOrder: [Int] = []
    private let texCapacity = 96

    private static let magic: [UInt8] = [0x41, 0x53, 0x4C, 0x52]  // "ASLR"
    private static let version: UInt32 = 1
    private static let headerSize = 28

    init(device: MTLDevice) { self.device = device }

    // MARK: - Cache location + key

    /// `~/Library/Caches/<bundle>/scrubproxy/<key>.lrproxy`, key derived
    /// from path + size + mtime so an edited / replaced SER invalidates.
    static func cacheURL(for ser: URL) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: ser.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(ser.path)|\(size)|\(Int(mtime))"
        let hash = UInt64(bitPattern: Int64(key.hashValue))
        let dir = cacheDir()
        return dir?.appendingPathComponent(String(format: "%016llx.lrproxy", hash))
    }

    private static func cacheDir() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "com.joergsflow.AstroSharper"
        let dir = base.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("scrubproxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// True when a valid cached proxy already exists for this SER.
    static func cachedAtlasExists(for ser: URL) -> Bool {
        guard let url = cacheURL(for: ser) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Build (call off the main thread; opt-in)

    /// Decode up to `maxEntries` frames spread across the SER to
    /// `longestSide`-px RGBA8 and write the proxy file atomically.
    /// Reuses a single SerReader for the whole build (no per-frame
    /// re-open). Returns true on success. `isCancelled` is polled so a
    /// file switch / app quit can abort cleanly.
    @discardableResult
    func build(
        serURL: URL,
        maxEntries: Int = 1500,
        longestSide: Int = 192,
        progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) -> Bool {
        guard let outURL = Self.cacheURL(for: serURL),
              let reader = try? SerReader(url: serURL) else { return false }
        let h = reader.header
        let total = h.frameCount
        guard total > 0 else { return false }

        let srcW = h.imageWidth, srcH = h.imageHeight
        let longest = max(srcW, srcH)
        // Ratio downscale to ~longestSide on the long edge (never upscale),
        // so even small-frame SERs produce a compact proxy instead of one
        // ~as big as the source (integer-step scaling left those at 1×).
        let ratio = min(1.0, Double(max(64, longestSide)) / Double(longest))
        let dstW = max(1, Int((Double(srcW) * ratio).rounded()))
        let dstH = max(1, Int((Double(srcH) * ratio).rounded()))
        // Bound the proxy by both an entry cap AND a total-size budget so a
        // huge-frame SER can't produce a multi-GB cache file. Whichever is
        // smaller wins; coverage stays as dense as the budget allows.
        let thumbBytesPerEntry = dstW * dstH * 4
        let budgetBytes = 256 * 1024 * 1024
        let byBudget = max(1, budgetBytes / max(1, thumbBytesPerEntry))
        let count = min(maxEntries, min(byBudget, total))
        let strideVal = max(1, Int(ceil(Double(total) / Double(count))))
        let realCount = (total + strideVal - 1) / strideVal   // ceil(total/stride)

        let isBayer = h.colorID.isBayer
        let mono16 = !isBayer && h.bytesPerPlane == 2 && !h.colorID.isRGB
        let bayerOffsets: (rx: Int, ry: Int) = {
            switch h.colorID {
            case .bayerRGGB: return (0, 0)
            case .bayerGRBG: return (1, 0)
            case .bayerGBRG: return (0, 1)
            case .bayerBGGR: return (1, 1)
            default: return (0, 0)
            }
        }()

        let thumbBytes = dstW * dstH * 4
        var out = Data(capacity: Self.headerSize + realCount * thumbBytes)
        out.append(contentsOf: Self.magic)
        func appendU32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        appendU32(Self.version)
        appendU32(UInt32(total))
        appendU32(UInt32(realCount))
        appendU32(UInt32(strideVal))
        appendU32(UInt32(dstW))
        appendU32(UInt32(dstH))

        var rgba = [UInt8](repeating: 0, count: thumbBytes)
        for i in 0..<realCount {
            if isCancelled() { return false }
            let frame = min(i * strideVal, total - 1)
            // Zero the buffer for safety; unreadable frames stay black.
            for k in 0..<thumbBytes { rgba[k] = (k % 4 == 3) ? 255 : 0 }
            if reader.canReadFrame(at: frame) {
                reader.withFrameBytes(at: frame) { ptr, _ in
                    func sample8(_ x: Int, _ y: Int) -> UInt8 {
                        let xi = min(srcW - 1, max(0, x)), yi = min(srcH - 1, max(0, y))
                        let idx = yi * srcW + xi
                        if mono16 {
                            let p16 = ptr.advanced(by: idx * 2).withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }
                            return UInt8(min(UInt32(p16) >> 8, 255))
                        }
                        return ptr[idx]
                    }
                    // Map each dst pixel back to a src pixel (nearest).
                    let stepX = Double(srcW) / Double(dstW)
                    let stepY = Double(srcH) / Double(dstH)
                    for y in 0..<dstH {
                        let sy = min(srcH - 1, Int(Double(y) * stepY))
                        for x in 0..<dstW {
                            let sx = min(srcW - 1, Int(Double(x) * stepX))
                            let o = (y * dstW + x) * 4
                            if isBayer {
                                let tx = sx - (sx & 1), ty = sy - (sy & 1)
                                let r  = sample8(tx + bayerOffsets.rx,       ty + bayerOffsets.ry)
                                let b  = sample8(tx + (1 - bayerOffsets.rx), ty + (1 - bayerOffsets.ry))
                                let g1 = sample8(tx + (1 - bayerOffsets.rx), ty + bayerOffsets.ry)
                                let g2 = sample8(tx + bayerOffsets.rx,       ty + (1 - bayerOffsets.ry))
                                rgba[o] = r; rgba[o + 1] = UInt8((Int(g1) + Int(g2)) >> 1); rgba[o + 2] = b
                            } else {
                                let v = sample8(sx, sy)
                                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v
                            }
                            rgba[o + 3] = 255
                        }
                    }
                }
            }
            out.append(contentsOf: rgba)
            if i % 32 == 0 { progress(Double(i) / Double(realCount)) }
        }
        progress(1.0)
        // Atomic write so a partial / cancelled build never looks valid.
        do { try out.write(to: outURL, options: .atomic) } catch { return false }
        return true
    }

    // MARK: - Open for reading

    /// Memory-map an existing proxy for `serURL`. Returns true when a
    /// valid atlas is loaded. No-op (returns true) if already open for
    /// the same URL.
    @discardableResult
    func open(serURL: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if openURL == serURL, mapped != nil { return true }
        reset()
        guard let url = Self.cacheURL(for: serURL),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url, options: [.alwaysMapped]),
              data.count >= Self.headerSize else { return false }
        // Validate header.
        let ok: Bool = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<4 where bytes[i] != Self.magic[i] { return false }
            func u32(_ off: Int) -> UInt32 {
                raw.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian
            }
            let ver = u32(4)
            guard ver == Self.version else { return false }
            frameCount = Int(u32(8)); atlasCount = Int(u32(12)); stride = max(1, Int(u32(16)))
            thumbW = Int(u32(20)); thumbH = Int(u32(24))
            return frameCount > 0 && atlasCount > 0 && thumbW > 0 && thumbH > 0
        }
        guard ok else { reset(); return false }
        // Sanity: file must hold the full thumbnail payload.
        let need = Self.headerSize + atlasCount * thumbW * thumbH * 4
        guard data.count >= need else { reset(); return false }
        mapped = data
        openURL = serURL
        dataStart = Self.headerSize
        return true
    }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return mapped != nil }
    var coverageCount: Int { lock.lock(); defer { lock.unlock() }; return atlasCount }

    private func reset() {
        mapped = nil; openURL = nil
        frameCount = 0; atlasCount = 0; stride = 1; thumbW = 0; thumbH = 0; dataStart = 0
        texCache.removeAll(); texOrder.removeAll()
    }

    // MARK: - Runtime lookup

    /// Texture for the atlas entry nearest the given TRUE frame index.
    /// Decode-free (raw RGBA8 upload); cached in a small LRU. nil only
    /// when no atlas is open.
    func nearestTexture(toFrame frame: Int) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard mapped != nil, atlasCount > 0 else { return nil }
        let entry = max(0, min(atlasCount - 1, Int((Double(frame) / Double(stride)).rounded())))
        if let tex = texCache[entry] { return tex }
        guard let tex = makeTexture(entry: entry) else { return nil }
        texCache[entry] = tex
        texOrder.append(entry)
        while texOrder.count > texCapacity {
            let old = texOrder.removeFirst()
            if old != entry { texCache.removeValue(forKey: old) }
        }
        return tex
    }

    private func makeTexture(entry: Int) -> MTLTexture? {
        guard let data = mapped else { return nil }
        let thumbBytes = thumbW * thumbH * 4
        let offset = dataStart + entry * thumbBytes
        guard offset + thumbBytes <= data.count else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: thumbW, height: thumbH, mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        data.withUnsafeBytes { raw in
            let p = raw.baseAddress!.advanced(by: offset)
            tex.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: thumbW, height: thumbH, depth: 1)),
                mipmapLevel: 0, withBytes: p, bytesPerRow: thumbW * 4
            )
        }
        return tex
    }
}
