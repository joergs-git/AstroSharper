// TransitDetector — native Swift port of the validated Python `ser_transit.py`.
//
// Decides whether an ISS / aircraft transit occurred in a SharpCap .ser capture
// and measures it. The algorithm and every constant are a faithful port of the
// reference (see the acceptance table in tasks/todo.md); do not retune the
// constants without re-validating against the three real captures.
//
// Extensions beyond the reference, driven by the real captures:
//   • MULTIPLE transits per video (rare — ~1% of captures) via iterative RANSAC.
//   • MOON mode (bright disc, identical silhouette math, lunar plate scale).
//   • Dual-polarity search in disc modes: a dark silhouette ON the disc AND a
//     bright transient passing OFF to the side can both be caught.
//   • Graceful disc-fit BAIL when no clean full disc is present (Barlow
//     full-frame surface, or a partial / off-centre disc).
//
// Pipeline: mmap the SER (SerReader), block-mean bin every frame into a float
// stack, temporal-median background, σ-image residuals, per-frame argmax,
// persistence removal, RANSAC constant-velocity line, contiguity gate, decide.
//
// All heavy elementwise math is vDSP; the per-pixel temporal median is the one
// non-trivial op and uses an approximate median over ~60 evenly-sampled frames
// (as the reference did in testing).
import Foundation
import Accelerate

struct TransitConfig {
    /// Binning factor. nil → auto: b=4 for the big star-field sensors, b=3 for
    /// the ~1936-wide solar sensor (matches the reference's per-file choice).
    var bin: Int? = nil
    var zThreshold: Float = 6.0
    var medianSamples: Int = 60
    var maxEvents: Int = 4
    /// Disc modes: also search for a bright transient OFF the disc (a plane/ISS
    /// passing beside the Sun/Moon). Off by nothing in the common single case.
    var dualPolarity: Bool = true
    /// Optional plate-scale cross-check / fallback for disc modes when the
    /// disc-fit is unreliable (Barlow full-frame, partial disc).
    var focalLengthMM: Double? = nil
    var pixelSizeUM: Double? = nil
    /// If set, a debug proof PNG (max-z map + markers + fit line + target) is
    /// written here.
    var proofImageURL: URL? = nil
    /// Print candidate diagnostics to stderr (development only).
    var debug: Bool = false
}

enum TransitDetectorError: Error {
    case cannotOpen(URL)
    case emptyStack
}

enum TransitDetector {

    // MARK: - Public entry

    static func detect(url: URL, config: TransitConfig = .init()) throws -> TransitResult {
        guard let reader = try? SerReader(url: url) else { throw TransitDetectorError.cannotOpen(url) }
        let b = config.bin ?? autoBin(width: reader.header.imageWidth)

        let clock = Date()
        func lap(_ label: String) {
            guard config.debug else { return }
            FileHandle.standardError.write("[transit] \(label): \(String(format: "%.1f", Date().timeIntervalSince(clock)))s\n".data(using: .utf8)!)
        }

        // 1–2. Read + block-mean bin every frame into a float stack (F, H, W).
        let stk = try loadBinnedStack(reader: reader, bin: b)
        let F = stk.F, H = stk.H, W = stk.W, P = H * W
        guard F > 0, P > 0 else { throw TransitDetectorError.emptyStack }
        lap("load+bin")

        // 3. Background = per-pixel temporal median (removes the tracked target,
        //    static stars/hot pixels; on the Sun it removes the disc itself).
        let bg = perPixelMedian(stack: stk.buf, F: F, P: P, samples: config.medianSamples)
        lap("median")

        // 4. Mode detect from the background disc coverage.
        var bgMax: Float = 0
        vDSP_maxv(bg, 1, &bgMax, vDSP_Length(P))
        let discThresh = max(8.0, 0.12 * bgMax)
        var disc = [Bool](repeating: false, count: P)
        var discCount = 0
        for p in 0..<P where bg[p] > discThresh { disc[p] = true; discCount += 1 }
        let discFrac = Double(discCount) / Double(P)
        let isDisc = discFrac > 0.08
        let mode: TransitMode = isDisc
            ? (url.lastPathComponent.lowercased().contains("moon") ? .moon : .sun)
            : .starfield

        // 5. Border mask — sensor amp-glow / row-0 banding produces bright
        //    moving artifacts that mimic a track; invalidate a margin.
        let mgn = max(3, Int(0.02 * Double(min(H, W))))
        var border = [Bool](repeating: false, count: P)
        for y in 0..<H {
            let edgeRow = y < mgn || y >= H - mgn
            let base = y * W
            for x in 0..<W where edgeRow || x < mgn || x >= W - mgn { border[base + x] = true }
        }

        // 6. σ-image scaffolding: per-pixel temporal std, inverted.
        let pstd = perPixelStd(stack: stk.buf, F: F, P: P)
        var inv = [Float](repeating: 0, count: P)
        for p in 0..<P where pstd[p] > 1e-3 { inv[p] = 1.0 / pstd[p] }
        lap("std")

        // Target the separation is measured from.
        let target: (x: Double, y: Double)
        if isDisc {
            var sy = 0.0, sx = 0.0
            for p in 0..<P where disc[p] { sy += Double(p / W); sx += Double(p % W) }
            target = (x: sx / Double(discCount), y: sy / Double(discCount))
        } else {
            var mi: vDSP_Length = 0; var mv: Float = 0
            vDSP_maxvi(bg, 1, &mv, &mi, vDSP_Length(P))
            let j = Int(mi); target = (x: Double(j % W), y: Double(j / W))
        }

        // 7–11. Detection passes. Star-field: one bright-transient pass. Disc
        //        modes: a silhouette pass (dark on disc) plus, optionally, a
        //        bright pass (object passing off the disc).
        var maxZ = [Float](repeating: 0, count: P)   // for the proof image
        var passResults: [PassResult] = []

        if isDisc {
            let eroded = erode(disc, H: H, W: W, iterations: 2)
            var validSil = [Bool](repeating: false, count: P)
            for p in 0..<P { validSil[p] = eroded[p] && !border[p] }
            passResults.append(findEvents(sign: -1, valid: validSil, onDisc: true,
                                          stack: stk.buf, bg: bg, inv: inv, F: F, H: H, W: W,
                                          b: b, target: target, config: config, maxZ: &maxZ))

            if config.dualPolarity {
                var validBright = [Bool](repeating: false, count: P)
                var offCount = 0
                for p in 0..<P where !disc[p] && !border[p] { validBright[p] = true; offCount += 1 }
                if offCount > P / 20 {   // skip when the disc fills the frame (Barlow)
                    passResults.append(findEvents(sign: 1, valid: validBright, onDisc: false,
                                                  stack: stk.buf, bg: bg, inv: inv, F: F, H: H, W: W,
                                                  b: b, target: target, config: config, maxZ: &maxZ))
                }
            }
        } else {
            var valid = [Bool](repeating: false, count: P)
            for p in 0..<P { valid[p] = !border[p] }
            passResults.append(findEvents(sign: 1, valid: valid, onDisc: nil,
                                          stack: stk.buf, bg: bg, inv: inv, F: F, H: H, W: W,
                                          b: b, target: target, config: config, maxZ: &maxZ))
        }

        // Select the real events across all passes (fragment-merge + distinctness).
        var events = selectEvents(passResults.flatMap { $0.tracks }, maxEvents: config.maxEvents)
        // No track anywhere → fall back to the strongest single blob (a one-frame
        // ISS flare, say). Prefer the silhouette/star pass over the bright pass.
        if events.isEmpty,
           let blob = passResults.compactMap({ $0.blob }).max(by: { ($0.peakZAtObject ?? 0) < ($1.peakZAtObject ?? 0) }) {
            events = [blob]
        }

        var result = TransitResult(mode: mode, frames: F, detected: !events.isEmpty, transits: events)

        // Disc-mode plate scale (with graceful bail + optional focal-length path).
        if isDisc {
            applyPlateScale(to: &result, mode: mode, disc: disc, discCount: discCount,
                            H: H, W: W, b: b, config: config)
            // When the disc fit is unreliable (Barlow full-frame / partial disc),
            // the on-disc vs off-disc classification is meaningless — null it.
            if result.discReliable == false {
                for i in result.transits.indices { result.transits[i].onDisc = nil }
            }
        }
        events = result.transits

        // Optional proof image.
        if let out = config.proofImageURL {
            TransitProofImage.write(to: out, maxZ: maxZ, H: H, W: W, b: b,
                                    target: target, events: events)
        }

        return result
    }

    // MARK: - Auto bin

    /// b=4 for the big star-field sensors (≥~2.5k wide), b=3 for the ~1936-wide
    /// solar sensor. Matches the reference's per-capture choice.
    static func autoBin(width: Int) -> Int { width >= 2500 ? 4 : 3 }

    // MARK: - Load + bin

    struct BinnedStack { var buf: [Float]; var F: Int; var H: Int; var W: Int; var b: Int }

    static func loadBinnedStack(reader: SerReader, bin b: Int) throws -> BinnedStack {
        let h = reader.header
        let F = reader.readableFrameCount
        let W0 = h.imageWidth, H0 = h.imageHeight
        let H = (H0 / b) * b, W = (W0 / b) * b     // crop to a multiple of b
        let hb = H / b, wb = W / b, P = hb * wb
        let planes = h.planesPerPixel
        let is16 = h.bytesPerPlane == 2
        let littleEndian = h.isLittleEndian

        var buf = [Float](repeating: 0, count: F * P)
        let bpf = h.bytesPerFrame

        // I/O dominates: reading the multi-GB frame region via SerReader's
        // memory map (opened `.uncached`) faults 16 KB pages one at a time with
        // no readahead — measured ~70 MB/s on the same drive that streams
        // sequentially at ~460 MB/s. So read the frames SEQUENTIALLY through a
        // FileHandle (OS readahead kicks in), a core-sized batch at a time, and
        // bin that batch in PARALLEL — one frame per worker, each with its own
        // scratch (no shared mutable state). This overlaps the block-mean
        // compute with the next batch's read and turns a ~1-minute scan into
        // seconds. Falls back to the mmap path if the handle can't open.
        let cores = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        let handle = try? FileHandle(forReadingFrom: reader.url)
        if let handle { try? handle.seek(toOffset: 178) }
        defer { try? handle?.close() }

        // Per-worker scratch as raw pointers, allocated once. Worker w always
        // uses slot w and at most `cores` run at once, so the buffers never
        // alias. Using an array of POINTERS (only read concurrently) rather
        // than [[Float]] avoids a data race — concurrent
        // `array[w].withUnsafeMutableBufferPointer` would invoke Array's modify
        // accessor on the shared array from multiple threads.
        let frameScratch = (0..<cores).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: H0 * W0) }
        let rowScratch = (0..<cores).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: W) }
        defer {
            frameScratch.forEach { $0.deallocate() }
            rowScratch.forEach { $0.deallocate() }
        }

        buf.withUnsafeMutableBufferPointer { outAll in
            let outBase = outAll.baseAddress!

            // Bin one already-in-memory raw frame into buf[frameIndex].
            func binFrame(rawFrame: UnsafePointer<UInt8>, frameIndex: Int, worker: Int) {
                var divisor = Float(b * b)
                let fF = frameScratch[worker]
                let rAcc = rowScratch[worker]
                convertToFloat(ptr: rawFrame, out: fF, count: H0 * W0,
                               is16: is16, littleEndian: littleEndian, planes: planes)
                let outFrame = outBase + frameIndex * P
                for by in 0..<hb {
                    let r0 = (by * b) * W0
                    vDSP_vclr(rAcc, 1, vDSP_Length(W))
                    for dy in 0..<b {
                        vDSP_vadd(rAcc, 1, fF + r0 + dy * W0, 1, rAcc, 1, vDSP_Length(W))
                    }
                    let outRow = outFrame + by * wb
                    vDSP_vclr(outRow, 1, vDSP_Length(wb))
                    for dx in 0..<b {
                        vDSP_vadd(outRow, 1, rAcc + dx, vDSP_Stride(b), outRow, 1, vDSP_Length(wb))
                    }
                }
                vDSP_vsdiv(outFrame, 1, &divisor, outFrame, 1, vDSP_Length(P))
            }

            if let handle {
                var t = 0
                while t < F {
                    let n = min(cores, F - t)
                    guard let raw = try? handle.read(upToCount: n * bpf), raw.count == n * bpf else { break }
                    raw.withUnsafeBytes { (rb: UnsafeRawBufferPointer) in
                        let base = rb.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        DispatchQueue.concurrentPerform(iterations: n) { k in
                            binFrame(rawFrame: base + k * bpf, frameIndex: t + k, worker: k)
                        }
                    }
                    t += n
                }
            } else {
                // Fallback: mmap path (serial), if the FileHandle wouldn't open.
                for t in 0..<F where reader.canReadFrame(at: t) {
                    reader.withFrameBytes(at: t) { ptr, _ in binFrame(rawFrame: ptr, frameIndex: t, worker: 0) }
                }
            }
        }
        return BinnedStack(buf: buf, F: F, H: hb, W: wb, b: b)
    }

    /// Convert one raw SER frame to Float luminance of length `count` (= H0·W0).
    /// Mono/Bayer pass straight through (block-mean later averages the CFA);
    /// interleaved RGB is averaged to luminance per pixel.
    private static func convertToFloat(ptr: UnsafePointer<UInt8>, out: UnsafeMutablePointer<Float>,
                                       count: Int, is16: Bool, littleEndian: Bool, planes: Int) {
        if planes == 3 {
            // Interleaved RGB(8/16) → per-pixel mean.
            if is16 {
                ptr.withMemoryRebound(to: UInt16.self, capacity: count * 3) { u16 in
                    for i in 0..<count {
                        let r = load16(u16[i*3], littleEndian)
                        let g = load16(u16[i*3+1], littleEndian)
                        let bl = load16(u16[i*3+2], littleEndian)
                        out[i] = Float(Int(r) + Int(g) + Int(bl)) / 3.0
                    }
                }
            } else {
                for i in 0..<count {
                    out[i] = Float(Int(ptr[i*3]) + Int(ptr[i*3+1]) + Int(ptr[i*3+2])) / 3.0
                }
            }
            return
        }
        if is16 {
            ptr.withMemoryRebound(to: UInt16.self, capacity: count) { u16 in
                if littleEndian {
                    vDSP_vfltu16(u16, 1, out, 1, vDSP_Length(count))
                } else {
                    for i in 0..<count { out[i] = Float(UInt16(bigEndian: u16[i])) }
                }
            }
        } else {
            vDSP_vfltu8(ptr, 1, out, 1, vDSP_Length(count))
        }
    }

    @inline(__always)
    private static func load16(_ v: UInt16, _ little: Bool) -> UInt16 {
        little ? UInt16(littleEndian: v) : UInt16(bigEndian: v)
    }

    // MARK: - Background + noise

    /// Per-pixel temporal median from ~`samples` evenly-spaced frames.
    /// Parallelized across pixel ranges — a per-pixel 60-element sort over a
    /// few million pixels is ~20 s single-threaded; each worker sorts into its
    /// OWN scratch and writes a disjoint slice of `bg`, so it drops to a couple
    /// of seconds.
    static func perPixelMedian(stack: [Float], F: Int, P: Int, samples: Int) -> [Float] {
        let n = min(samples, F)
        var idx = [Int](repeating: 0, count: n)
        for k in 0..<n { idx[k] = F == 1 ? 0 : Int((Double(k) * Double(F - 1) / Double(max(1, n - 1))).rounded()) }
        var bg = [Float](repeating: 0, count: P)
        let cores = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        stack.withUnsafeBufferPointer { s in
            bg.withUnsafeMutableBufferPointer { bgp in
                idx.withUnsafeBufferPointer { idxp in
                    DispatchQueue.concurrentPerform(iterations: cores) { chunk in
                        let lo = chunk * P / cores
                        let hi = (chunk + 1) * P / cores
                        guard lo < hi else { return }
                        var tmp = [Float](repeating: 0, count: n)
                        for p in lo..<hi {
                            for k in 0..<n { tmp[k] = s[idxp[k] * P + p] }
                            tmp.sort()
                            bgp[p] = n % 2 == 1 ? tmp[n/2] : 0.5 * (tmp[n/2 - 1] + tmp[n/2])
                        }
                    }
                }
            }
        }
        return bg
    }

    /// Per-pixel temporal standard deviation over all frames. Two-pass with
    /// DOUBLE accumulators: a one-pass `E[x²]−E[x]²` in float32 suffers
    /// catastrophic cancellation on bright 8-bit pixels (mean²≈E[x²]), which
    /// manufactures spurious near-zero variances → huge `1/pstd` → the σ-image
    /// collapses and every frame lights up above threshold. The mean is
    /// subtracted BEFORE squaring so the summed magnitudes stay small.
    static func perPixelStd(stack: [Float], F: Int, P: Int) -> [Float] {
        var mean = [Float](repeating: 0, count: P)
        var m2 = [Float](repeating: 0, count: P)
        var d = [Float](repeating: 0, count: P)
        stack.withUnsafeBufferPointer { s in
            mean.withUnsafeMutableBufferPointer { mp in
                m2.withUnsafeMutableBufferPointer { m2p in
                    d.withUnsafeMutableBufferPointer { dp in
                        // Pass 1: mean (float32 sum of 8-bit values is exact enough).
                        for t in 0..<F {
                            vDSP_vadd(mp.baseAddress!, 1, s.baseAddress! + t * P, 1, mp.baseAddress!, 1, vDSP_Length(P))
                        }
                        var invF = Float(1.0 / Double(F))
                        vDSP_vsmul(mp.baseAddress!, 1, &invF, mp.baseAddress!, 1, vDSP_Length(P))
                        // Pass 2: sum of squared deviations ABOUT the mean. Subtracting
                        // the mean first keeps the summed magnitudes tiny, so float32 no
                        // longer cancels catastrophically the way E[x²]−E[x]² does.
                        for t in 0..<F {
                            vDSP_vsub(mp.baseAddress!, 1, s.baseAddress! + t * P, 1, dp.baseAddress!, 1, vDSP_Length(P))
                            vDSP_vsq(dp.baseAddress!, 1, dp.baseAddress!, 1, vDSP_Length(P))
                            vDSP_vadd(m2p.baseAddress!, 1, dp.baseAddress!, 1, m2p.baseAddress!, 1, vDSP_Length(P))
                        }
                    }
                }
            }
        }
        var std = [Float](repeating: 0, count: P)
        let invF = 1.0 / Float(F)
        for p in 0..<P {
            let v = m2[p] * invF
            std[p] = v > 0 ? sqrt(v) : 0
        }
        return std
    }

    // MARK: - Per-pass event finding

    /// The raw output of one polarity pass: every contiguous track it could fit
    /// (strongest first) plus the single strongest blob, which the caller uses
    /// only as a fallback when NO track is selected anywhere. Selection /
    /// fragment-merging happens once, across all passes, in `selectEvents`.
    struct PassResult { var tracks: [TransitEvent]; var blob: TransitEvent? }

    /// Run one polarity pass: build the σ-image argmax candidates, strip
    /// persistent locations, then fit as many contiguous tracks as RANSAC finds
    /// (iterative), plus the strongest single blob.
    private static func findEvents(sign: Float, valid: [Bool], onDisc: Bool?,
                                   stack: [Float], bg: [Float], inv: [Float],
                                   F: Int, H: Int, W: Int, b: Int,
                                   target: (x: Double, y: Double),
                                   config: TransitConfig, maxZ: inout [Float]) -> PassResult {
        let P = H * W
        // Fold the pass sign + valid mask into the inverse-σ weights.
        var invPass = [Float](repeating: 0, count: P)
        for p in 0..<P where valid[p] { invPass[p] = sign * inv[p] }

        var Zpk = [Float](repeating: 0, count: F)
        var Xp = [Int](repeating: 0, count: F)
        var Yp = [Int](repeating: 0, count: F)
        var z = [Float](repeating: 0, count: P)

        stack.withUnsafeBufferPointer { s in
            bg.withUnsafeBufferPointer { bgp in
                invPass.withUnsafeBufferPointer { ip in
                    z.withUnsafeMutableBufferPointer { zp in
                        maxZ.withUnsafeMutableBufferPointer { mz in
                            for t in 0..<F {
                                let f = s.baseAddress! + t * P
                                // z = (frame - bg) * invPass   (sign already folded)
                                vDSP_vsub(bgp.baseAddress!, 1, f, 1, zp.baseAddress!, 1, vDSP_Length(P))
                                vDSP_vmul(zp.baseAddress!, 1, ip.baseAddress!, 1, zp.baseAddress!, 1, vDSP_Length(P))
                                var mv: Float = 0; var mi: vDSP_Length = 0
                                vDSP_maxvi(zp.baseAddress!, 1, &mv, &mi, vDSP_Length(P))
                                Zpk[t] = mv; let j = Int(mi); Yp[t] = j / W; Xp[t] = j % W
                                // Running max-z map for the proof image (in-place max).
                                vDSP_vmax(mz.baseAddress!, 1, zp.baseAddress!, 1, mz.baseAddress!, 1, vDSP_Length(P))
                            }
                        }
                    }
                }
            }
        }

        // Candidates above threshold.
        let zthr = config.zThreshold
        var cand: [Int] = []
        for t in 0..<F where Zpk[t] > zthr { cand.append(t) }
        if cand.isEmpty { return PassResult(tracks: [], blob: nil) }

        // 8. Remove persistent locations (fixed hot/bright pixels, Vega leakage):
        //    bin positions on a /4 grid, drop cells chosen in too many frames.
        var cellCount: [Int64: Int] = [:]
        func cellKey(_ x: Int, _ y: Int) -> Int64 { Int64(x / 4) << 32 | Int64(y / 4) }
        for t in cand { cellCount[cellKey(Xp[t], Yp[t]), default: 0] += 1 }
        let persistLimit = max(4, Int(0.06 * Double(F)))
        var pts: [(f: Double, x: Double, y: Double, z: Double)] = []
        for t in cand where cellCount[cellKey(Xp[t], Yp[t])]! <= persistLimit {
            pts.append((Double(t), Double(Xp[t]), Double(Yp[t]), Double(Zpk[t])))
        }
        if config.debug {
            let top = pts.sorted { $0.z > $1.z }.prefix(15)
            FileHandle.standardError.write("[transit] pass sign=\(Int(sign)) cand=\(cand.count) nonPersist=\(pts.count) persistLimit=\(persistLimit)\n".data(using: .utf8)!)
            for p in top {
                FileHandle.standardError.write(String(format: "  f=%.0f x=%.0f y=%.0f z=%.1f\n", p.f, p.x, p.y, p.z).data(using: .utf8)!)
            }
        }
        // Strongest single blob — the fallback if no track is selected anywhere.
        var blob: TransitEvent? = nil
        if let best = pts.max(by: { $0.z < $1.z }) {
            let sep = hypot(best.x - target.x, best.y - target.y) * Double(b)
            blob = TransitEvent(
                moving: false, nActive: 1, activeFrames: [Int(best.f)],
                entryPx: [Int(best.x) * b, Int(best.y) * b],
                separationPx: (sep * 10).rounded() / 10,
                peakZAtObject: (best.z * 10).rounded() / 10,
                onDisc: onDisc)
        }
        if pts.isEmpty { return PassResult(tracks: [], blob: nil) }

        // 9. Iterative RANSAC: pull out every contiguous track RANSAC can fit,
        //    strongest first. Fragment-merging + the final keep/drop decision
        //    are deferred to selectEvents so cross-pass duplicates collapse.
        var tracks: [TransitEvent] = []
        var pool = pts
        var iter = 0
        while pool.count >= 3 && tracks.count < 12 && iter < 24 {
            iter += 1
            guard let trk = ransacTrack(pool, tol: 3.0) else { break }
            let event = makeTrackEvent(trk, pool: pool, b: b, target: target, onDisc: onDisc)
            // Reference contiguity gate: skip a track that is BOTH sparse and
            // few (scattered noise); keep everything else for selectEvents.
            let inlierFrames = trk.inliers.map { pool[$0].f }.sorted()
            let span = (inlierFrames.last! - inlierFrames.first!) + 1
            let drop = Set(trk.inliers)
            pool = pool.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
            if Double(trk.n) / span < 0.25 && trk.n < 8 { continue }
            tracks.append(event)
        }
        return PassResult(tracks: tracks, blob: blob)
    }

    // MARK: - Event selection across passes

    /// Fragment span/direction helpers for the selection stage.
    private static func eventSpan(_ e: TransitEvent) -> Int {
        e.activeFrames.count >= 2 ? max(1, e.activeFrames[1] - e.activeFrames[0] + 1) : 1
    }
    private static func framesOverlap(_ a: TransitEvent, _ b: TransitEvent) -> Bool {
        guard a.activeFrames.count >= 2, b.activeFrames.count >= 2 else { return false }
        return a.activeFrames[0] <= b.activeFrames[1] && b.activeFrames[0] <= a.activeFrames[1]
    }
    private static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// Pick the events to report from every pass's raw tracks. The strongest
    /// track (most inliers) is the PRIMARY and is kept on the reference gate
    /// alone. Because ~99% of captures have exactly one transit, ADDITIONAL
    /// objects are admitted only when they're clearly real AND distinct: dense,
    /// substantial (relative to the primary), and neither a time+direction
    /// fragment of an already-kept track nor a duplicate from the other
    /// polarity pass. This collapses the fragmentation the raw iterative RANSAC
    /// produces (e.g. one plane split into several overlapping sub-tracks).
    private static func selectEvents(_ rawTracks: [TransitEvent], maxEvents: Int) -> [TransitEvent] {
        let sorted = rawTracks.sorted { $0.nActive > $1.nActive }
        var accepted: [TransitEvent] = []
        for e in sorted {
            let span = eventSpan(e)
            let density = Double(e.nActive) / Double(span)
            if accepted.isEmpty {
                // Primary: reference gate (reject only if sparse AND few).
                if density < 0.25 && e.nActive < 8 { continue }
                accepted.append(e)
                continue
            }
            let primaryN = accepted[0].nActive
            // Additional object must be dense, substantial, and distinct.
            if density < 0.25 { continue }
            if e.nActive < 12 { continue }
            if Double(e.nActive) < 0.4 * Double(primaryN) { continue }
            let isFragment = accepted.contains { a in
                framesOverlap(a, e) && angleDiff(a.directionDeg ?? 0, e.directionDeg ?? 0) < 25
            }
            if isFragment { continue }
            accepted.append(e)
            if accepted.count >= maxEvents { break }
        }
        return accepted
    }

    private static func makeTrackEvent(_ trk: Track, pool: [(f: Double, x: Double, y: Double, z: Double)],
                                       b: Int, target: (x: Double, y: Double), onDisc: Bool?) -> TransitEvent {
        let inl = trk.inliers.map { pool[$0] }.sorted { $0.f < $1.f }
        let f0 = inl.first!.f, f1 = inl.last!.f
        let x0 = trk.ax * f0 + trk.bx, y0 = trk.ay * f0 + trk.by
        let x1 = trk.ax * f1 + trk.bx, y1 = trk.ay * f1 + trk.by
        let bf = Double(b)
        let sep = pointToSeg(p: (target.x, target.y), a: (x0, y0), c: (x1, y1)) * bf
        return TransitEvent(
            moving: true, nActive: trk.n, activeFrames: [Int(f0), Int(f1)],
            entryPx: [Int((x0 * bf).rounded()), Int((y0 * bf).rounded())],
            exitPx: [Int((x1 * bf).rounded()), Int((y1 * bf).rounded())],
            trackLenPx: (hypot(x1 - x0, y1 - y0) * bf * 10).rounded() / 10,
            speedPxPerFrame: (hypot(trk.ax, trk.ay) * bf * 10).rounded() / 10,
            directionDeg: (atan2(trk.ay, trk.ax) * 180 / .pi * 10).rounded() / 10,
            straightnessR2: (trk.r2 * 1000).rounded() / 1000,
            separationPx: (sep * 10).rounded() / 10,
            onDisc: onDisc)
    }

    // MARK: - RANSAC constant-velocity line

    struct Track { var inliers: [Int]; var ax: Double; var bx: Double; var ay: Double; var by: Double; var n: Int; var r2: Double }

    /// Fit x=ax·f+bx, y=ay·f+by through pairs of the strongest candidates; keep
    /// the line with the most inliers (tol px), require real motion, then refit
    /// inliers by least squares and compute R².
    static func ransacTrack(_ pts: [(f: Double, x: Double, y: Double, z: Double)], tol: Double) -> Track? {
        guard pts.count >= 3 else { return nil }
        let order = pts.indices.sorted { pts[$0].z > pts[$1].z }
        let cand = Array(order.prefix(min(pts.count, 40)))
        var bestN = 0
        var bestInliers: [Int] = []
        for ii in 0..<cand.count {
            for jj in (ii+1)..<cand.count {
                let i = cand[ii], j = cand[jj]
                if pts[i].f == pts[j].f { continue }
                let ax = (pts[j].x - pts[i].x) / (pts[j].f - pts[i].f)
                let bx = pts[i].x - ax * pts[i].f
                let ay = (pts[j].y - pts[i].y) / (pts[j].f - pts[i].f)
                let by = pts[i].y - ay * pts[i].f
                if hypot(ax, ay) < 0.05 { continue }   // reject near-stationary
                var inliers: [Int] = []
                for k in pts.indices {
                    let px = ax * pts[k].f + bx, py = ay * pts[k].f + by
                    if hypot(pts[k].x - px, pts[k].y - py) < tol { inliers.append(k) }
                }
                if inliers.count > bestN { bestN = inliers.count; bestInliers = inliers }
            }
        }
        guard bestN >= 3 else { return nil }
        // Refit inliers by least squares.
        let fi = bestInliers.map { pts[$0].f }
        let xi = bestInliers.map { pts[$0].x }
        let yi = bestInliers.map { pts[$0].y }
        let (ax, bx) = lstsqLine(fi, xi)
        let (ay, by) = lstsqLine(fi, yi)
        var ss = 0.0, mx = xi.reduce(0,+)/Double(xi.count), my = yi.reduce(0,+)/Double(yi.count), st = 0.0
        for k in 0..<fi.count {
            let px = ax * fi[k] + bx, py = ay * fi[k] + by
            ss += (xi[k]-px)*(xi[k]-px) + (yi[k]-py)*(yi[k]-py)
            st += (xi[k]-mx)*(xi[k]-mx) + (yi[k]-my)*(yi[k]-my)
        }
        let r2 = 1 - ss / (st + 1e-9)
        return Track(inliers: bestInliers, ax: ax, bx: bx, ay: ay, by: by, n: bestN, r2: r2)
    }

    /// Least-squares fit y = a·x + b.
    private static func lstsqLine(_ x: [Double], _ y: [Double]) -> (Double, Double) {
        let n = Double(x.count)
        let sx = x.reduce(0,+), sy = y.reduce(0,+)
        let sxx = zip(x,x).reduce(0){ $0 + $1.0*$1.1 }
        let sxy = zip(x,y).reduce(0){ $0 + $1.0*$1.1 }
        let denom = n*sxx - sx*sx
        if abs(denom) < 1e-12 { return (0, sy/n) }
        let a = (n*sxy - sx*sy) / denom
        let bb = (sy - a*sx) / n
        return (a, bb)
    }

    /// Distance from point p to the segment a→c.
    static func pointToSeg(p: (Double, Double), a: (Double, Double), c: (Double, Double)) -> Double {
        let acx = c.0 - a.0, acy = c.1 - a.1
        let L = acx*acx + acy*acy
        if L < 1e-9 { return hypot(p.0 - a.0, p.1 - a.1) }
        var tParam = ((p.0 - a.0)*acx + (p.1 - a.1)*acy) / L
        tParam = max(0, min(1, tParam))
        return hypot(p.0 - (a.0 + tParam*acx), p.1 - (a.1 + tParam*acy))
    }

    // MARK: - Morphology

    /// Binary erosion with a 4-neighbour (cross) structuring element, matching
    /// scipy.ndimage.binary_erosion's default; `iterations` passes. Edge pixels
    /// (outside the frame) count as background, so the disc shrinks inward.
    static func erode(_ mask: [Bool], H: Int, W: Int, iterations: Int) -> [Bool] {
        var cur = mask
        var next = mask
        for _ in 0..<iterations {
            for y in 0..<H {
                for x in 0..<W {
                    let idx = y*W + x
                    if !cur[idx] { next[idx] = false; continue }
                    let up    = y > 0     && cur[idx - W]
                    let down  = y < H-1   && cur[idx + W]
                    let left  = x > 0     && cur[idx - 1]
                    let right = x < W-1   && cur[idx + 1]
                    next[idx] = up && down && left && right
                }
            }
            swap(&cur, &next)
        }
        return cur
    }

    // MARK: - Plate scale (disc modes)

    /// Disc-fit plate scale (reference path), with a graceful bail when no clean
    /// full disc is present, and an optional focal-length cross-check / fallback.
    private static func applyPlateScale(to result: inout TransitResult, mode: TransitMode,
                                        disc: [Bool], discCount: Int, H: Int, W: Int, b: Int,
                                        config: TransitConfig) {
        guard let diamDeg = mode.discDiameterDeg else { return }

        // Disc reliability: a Barlow full-frame surface fills the frame; a
        // partial disc touches all four borders. Either breaks radius-from-area.
        let fillsFrame = Double(discCount) / Double(H * W) > 0.85
        let touchesAll = discTouchesAllBorders(disc, H: H, W: W)
        let discReliable = !fillsFrame && !touchesAll && discCount > 0
        result.discReliable = discReliable

        // Focal-length plate scale (physically correct, per FULL-res pixel).
        var degPerFullPxFL: Double?
        if let fl = config.focalLengthMM, let px = config.pixelSizeUM, fl > 0 {
            degPerFullPxFL = atan((px * 1e-3) / fl) * 180 / .pi
        }

        if discReliable {
            // Reference arithmetic (kept for acceptance parity): radius in BINNED
            // px, and separation_deg = separation_px(full) × deg_per_binned_px.
            let rBinned = (Double(discCount) / .pi).squareRoot()
            let degPerBinnedPx = diamDeg / (2 * rBinned)
            result.plateScaleArcsecPx = (degPerBinnedPx * 3600 * 100).rounded() / 100
            var source: PlateScaleSource = .discFit
            if let flPx = degPerFullPxFL {
                // Disc-fit is per binned px ≈ FL per-full-px × b. Agree within 15%?
                let expected = flPx * Double(b)
                if abs(degPerBinnedPx - expected) / expected < 0.15 { source = .crossCheck }
            }
            result.plateScaleSource = source
            for i in result.transits.indices {
                result.transits[i].separationDeg =
                    (result.transits[i].separationPx * degPerBinnedPx * 1000).rounded() / 1000
            }
        } else if let flPx = degPerFullPxFL {
            // Disc-fit bailed but we have focal length: physically-correct degrees.
            result.plateScaleSource = .focalLength
            result.plateScaleArcsecPx = (flPx * 3600 * 100).rounded() / 100
            for i in result.transits.indices {
                result.transits[i].separationDeg =
                    (result.transits[i].separationPx * flPx * 1000).rounded() / 1000
            }
        } else {
            result.plateScaleSource = PlateScaleSource.none
        }
    }

    private static func discTouchesAllBorders(_ disc: [Bool], H: Int, W: Int) -> Bool {
        var top = false, bottom = false, left = false, right = false
        for x in 0..<W { if disc[x] { top = true }; if disc[(H-1)*W + x] { bottom = true } }
        for y in 0..<H { if disc[y*W] { left = true }; if disc[y*W + W-1] { right = true } }
        return top && bottom && left && right
    }
}
