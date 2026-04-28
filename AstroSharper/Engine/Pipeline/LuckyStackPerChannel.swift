// Path B per-channel lucky stacking.
//
// Foundation flag wired in commit 8e2a023; this file is the runner branch
// — the actual implementation that fires when `--per-channel` is passed
// on a Bayer SER capture.
//
// Why per-channel: see project memory `project_path_b_diagnosis.md`.
// Short version: averaging multiple lucky frames after Malvar/Cutler
// demosaic smears sub-pixel detail because R/G/B channels each have
// independent atmospheric chromatic dispersion shifts. A whole-frame
// phase-correlation lock can only correct the average shift across
// the three channels — per-channel residuals leak in as smearing.
// BiggSky's documented differentiator (and our empirical evidence
// from `--keep-count 1` showing the detail IS in single SER frames)
// points to: align + accumulate each channel against ITS OWN
// reference, then recombine.
//
// v0 scope: lightspeed mode only. No multi-AP / sigma-clip / drizzle
// / two-stage on the per-channel path until empirical validation
// closes the BiggSky reference gap. Once it does, we can layer those
// back on.
//
// Architecture:
//   1. Open SER once.
//   2. For each channel ∈ {R, G, B}:
//        - Pass 1 (`gradeAllFrames`): unpack each frame via
//          unpack_bayer*_channel_to_rgba into a half-res
//          (W/2 × H/2) rgba16Float plane (channel value replicated
//          into all four components), grade quality with the existing
//          quality_partials kernel, cache half-res luma for alignment.
//        - Sort by quality, pick top-N% (or top --keep-count).
//        - Pass 2 (`alignAgainstReference`): phase-correlate the
//          cached half-res luma of each kept frame against the best
//          frame's luma. Sub-pixel-precise alignment in half-res
//          space — equivalent to pixel precision in the full-res
//          mosaic, which is enough to undo per-channel atmospheric
//          dispersion drift.
//        - Pass 3 (`accumulateAligned`): quality-weighted-mean
//          accumulator into a half-res rgba32Float buffer.
//   3. Combine the three half-res accumulators into a single full-
//      res rgba32Float via `lucky_combine_channel_planes`. Bilinear
//      upsample puts the data back at the SER's native resolution
//      so the bake-in (sharpen / wavelet / tone curve) and the
//      final TIFF export contract are unchanged.
//
// Mono SER captures fall through to the existing `LuckyRunner` path
// (the dispatcher in LuckyStack.run gates on `colorID.isBayer`).
import Accelerate
import Foundation
import Metal

// MARK: - Bayer site spec
//
// Pure-Swift reference implementation of the Bayer-pattern → channel-
// site math the Metal kernels (`unpack_bayer*_channel_to_rgba`)
// implement. Exists so the unit-test target — which is intentionally
// pure-Foundation, never touching a Metal device — can validate the
// spec without spinning up an MPS pipeline. Keep this in lockstep
// with `bayer_channel_site_u` in Shaders.metal: any change there
// must update both places. The Metal kernel is authoritative for the
// running pipeline; this helper is the testable spec.
//
// Pattern encoding (matches SerColorID.bayerPatternIndex):
//   0 = RGGB → R at (0,0) of every 2×2 cell
//   1 = GRBG → R at (1,0)
//   2 = GBRG → R at (0,1)
//   3 = BGGR → R at (1,1)
//
// Channel encoding (matches the kernel's `channel` parameter):
//   0 = R, 1 = G, 2 = B
//
// G has TWO sites per 2×2 cell — gIdx selects which:
//   gIdx 0 → the G site sharing R's row (Gr)
//   gIdx 1 → the G site sharing B's row (Gb)
//
// Returns raw-frame `(x, y)` for the site within the cell anchored at
// `(cell.x * 2, cell.y * 2)`. Out-of-range inputs are NOT clamped — the
// Metal kernel handles edge clamping at read time, but this helper is
// a pure spec.
enum BayerChannelSite {
    static func site(cell: (x: Int, y: Int), pattern: Int, channel: Int, gIdx: Int = 0) -> (x: Int, y: Int) {
        let rOffX = pattern & 1
        let rOffY = (pattern >> 1) & 1
        let originX = cell.x * 2
        let originY = cell.y * 2
        switch channel {
        case 0: // R
            return (originX + rOffX, originY + rOffY)
        case 2: // B (diagonally opposite of R within the 2×2 cell)
            return (originX + (1 - rOffX), originY + (1 - rOffY))
        default: // G
            // gIdx 0 = Gr (same row as R), gIdx 1 = Gb (same row as B).
            if gIdx == 0 {
                return (originX + (1 - rOffX), originY + rOffY)
            } else {
                return (originX + rOffX, originY + (1 - rOffY))
            }
        }
    }
}

enum LuckyStackPerChannel {

    /// Public entry. Mirrors `LuckyRunner.run` so `LuckyStack.run` can
    /// dispatch here without changing its bake-in / writing contract.
    static func run(
        reader: SerReader,
        pipeline: Pipeline,
        options: LuckyStackOptions,
        progress: @escaping (LuckyStackProgress) -> Void
    ) async throws -> MTLTexture {
        let stacker = LuckyChannelStacker(reader: reader, pipeline: pipeline, options: options)
        return try await stacker.run(progress: progress)
    }
}

// MARK: - Internal stacker

private final class LuckyChannelStacker {
    let reader: SerReader
    let pipeline: Pipeline
    let options: LuckyStackOptions

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    // Per-channel pipelines (lazy: only built once per stacker instance).
    let bayerChan16PSO: MTLComputePipelineState
    let bayerChan8PSO:  MTLComputePipelineState
    let qualityPSO:     MTLComputePipelineState
    let lumaPSO:        MTLComputePipelineState
    let accumPSO:       MTLComputePipelineState
    let normalizePSO:   MTLComputePipelineState
    let combinePSO:     MTLComputePipelineState

    // Raw SER frame dimensions (the staging texture size).
    let rawW: Int
    let rawH: Int
    /// Half-res output dimensions. Each Bayer 2×2 cell contributes one
    /// pixel to the per-channel plane, so output is `rawW/2 × rawH/2`.
    /// Odd raw dimensions round down — the last column / row of half-
    /// pixels is dropped so the cell grid stays aligned.
    let halfW: Int
    let halfH: Int
    let bytesPerPlane: Int
    let isMono16: Bool
    let bayerPattern: UInt32

    // Staging pool for SER → GPU upload. One pool, reused across all
    // three channels (each channel does its own full read of the SER).
    let stagingTextures: [MTLTexture]
    /// Half-res frame textures, one per staging slot. rgba16Float is fine
    /// here — the channel-extract kernel writes a scalar replicated to
    /// rgba, so we don't lose anything by going half-precision in the
    /// pre-accumulator stage. The 32-bit precision lives in the
    /// accumulator (per-pipeline lessons.md).
    let frameTextures: [MTLTexture]
    let stagingSemaphore: DispatchSemaphore

    init(reader: SerReader, pipeline: Pipeline, options: LuckyStackOptions) {
        self.reader = reader
        self.pipeline = pipeline
        self.options = options
        self.device = MetalDevice.shared.device
        self.queue = MetalDevice.shared.commandQueue
        guard let lib = MetalDevice.shared.library else {
            fatalError("Metal library missing")
        }
        self.library = lib

        self.bayerChan16PSO = Self.makePSO(library: lib, device: device, fn: "unpack_bayer16_channel_to_rgba")
        self.bayerChan8PSO  = Self.makePSO(library: lib, device: device, fn: "unpack_bayer8_channel_to_rgba")
        self.qualityPSO     = Self.makePSO(library: lib, device: device, fn: "quality_partials")
        self.lumaPSO        = Self.makePSO(library: lib, device: device, fn: "extract_luma_downsample")
        self.accumPSO       = Self.makePSO(library: lib, device: device, fn: "lucky_accumulate")
        self.normalizePSO   = Self.makePSO(library: lib, device: device, fn: "lucky_normalize")
        self.combinePSO     = Self.makePSO(library: lib, device: device, fn: "lucky_combine_channel_planes")

        let W = reader.header.imageWidth
        let H = reader.header.imageHeight
        self.rawW = W
        self.rawH = H
        // Round DOWN for odd raw dimensions: the last column / row of
        // half-pixels is dropped so the 2×2 Bayer cell grid stays aligned.
        // Output is later upsampled back to (rawW, rawH) by the combine
        // kernel — the dropped half-pixel becomes 1 row/col of edge
        // extrapolation in the upsample, which is invisible against
        // the limb / background of a planetary frame.
        self.halfW = W / 2
        self.halfH = H / 2

        self.bytesPerPlane = reader.header.bytesPerPlane
        self.isMono16 = self.bytesPerPlane == 2
        self.bayerPattern = reader.header.colorID.bayerPatternIndex

        // Capture locals (not self.* properties) so the .map closures
        // don't trigger 'self captured before all members initialized'.
        let dev = self.device
        let stagingMono16 = (reader.header.bytesPerPlane == 2)
        self.stagingTextures = (0..<options.stagingPoolSize).map { _ in
            Self.makeStaging(device: dev, w: W, h: H, mono16: stagingMono16)
        }
        self.frameTextures = (0..<options.stagingPoolSize).map { _ in
            Self.makeFrameTexture(device: dev, w: W / 2, h: H / 2)
        }
        self.stagingSemaphore = DispatchSemaphore(value: options.stagingPoolSize)
    }

    static func makePSO(library: MTLLibrary, device: MTLDevice, fn: String) -> MTLComputePipelineState {
        guard let f = library.makeFunction(name: fn) else { fatalError("Missing kernel \(fn)") }
        return try! device.makeComputePipelineState(function: f)
    }

    static func makeStaging(device: MTLDevice, w: Int, h: Int, mono16: Bool) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mono16 ? .r16Uint : .r8Unorm,
            width: w, height: h, mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = [.shaderRead]
        return device.makeTexture(descriptor: desc)!
    }

    static func makeFrameTexture(device: MTLDevice, w: Int, h: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: desc)!
    }

    static func makeAccumulator(device: MTLDevice, w: Int, h: Int) -> MTLTexture {
        // rgba32Float to avoid the colour-banding issue documented in
        // lessons.md (2026-04-27). Hundreds of weighted-mean updates
        // exhaust ~10 bits of mantissa in rgba16Float around the
        // mid-range, surfacing as visible bands on smooth Jupiter cloud
        // detail. 32-bit gives 23 bits of mantissa, plenty of headroom.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: desc)!
    }

    static func makeOutputFullRes(device: MTLDevice, w: Int, h: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: desc)!
    }

    // MARK: - Driver

    /// Per-channel run with a SHARED grading + reference frame across
    /// all three channels. Per-channel grading + per-channel reference
    /// (the v0 design) was the source of the visible chromatic
    /// fringing reported on first runs:
    ///
    ///   1. Each channel's argmax-by-quality picked a different "best
    ///      frame", so the three accumulators ended up centred on three
    ///      different physical scene moments. Per-frame seeing jitter
    ///      between those reference frames showed as channel-vs-channel
    ///      offset in the recombined output.
    ///   2. Each channel's quality-weight curve was scaled to ITS OWN
    ///      [lo..hi] score range, so the same physical frame
    ///      contributed at very different weights to R vs G vs B —
    ///      another channel-bias source.
    ///
    /// Fix: grade ONCE, on green (the channel with the most measured
    /// pixels under any Bayer pattern → best signal for the LAPD
    /// variance score). The same scores → same sort → same reference
    /// frame index → same kept set → same per-frame quality weights
    /// drive all three channel runs. Only the alignment phase remains
    /// per-channel, because that's the actual atmospheric-chromatic-
    /// dispersion correction Path B exists to make.
    func run(progress: @escaping (LuckyStackProgress) -> Void) async throws -> MTLTexture {
        let total = reader.header.frameCount

        // 1. Single grading + luma-cache pass on the green channel.
        let gradeResult = try await gradeAndCacheLuma(channel: 1, progress: progress)
        progress(.sorting)

        let scores = gradeResult.scores
        let kept: [Int]
        if let count = options.keepCount, count > 0 {
            kept = topNIndices(scores: scores, count: count)
        } else {
            kept = topNIndices(scores: scores, percent: options.keepPercent)
        }
        let referenceIndex = scores.argmax()

        _ = total

        // Quality-weight curve (shared across channels — see fix note above).
        let keptScores = kept.map { scores[$0] }
        let lo = keptScores.min() ?? 0
        let hi = keptScores.max() ?? 1
        let span = max(1e-6, hi - lo)
        @inline(__always) func qualityWeight(_ score: Float) -> Float {
            let t = (score - lo) / span
            let shaped = t * t
            return 0.05 + shaped * 1.45
        }
        var qWeights = [Int: Float]()
        for idx in kept { qWeights[idx] = qualityWeight(scores[idx]) }
        let totalWeight = qWeights.values.reduce(0.0) { $0 + Double($1) }

        // 2. Three sequential channel passes — each does its own per-
        // channel phase correlation against the shared reference frame
        // (in its own channel-extract space) and accumulates. Phase
        // correlation re-uses the green-channel luma cache only for
        // the green pass; R and B re-extract on the fly because their
        // luma differs from green's (no benefit to cross-channel cache).
        let greenStack = try await stackChannel(
            channel: 1,
            kept: kept,
            referenceIndex: referenceIndex,
            quality: qWeights,
            totalWeight: totalWeight,
            cachedLumas: gradeResult.lumas,
            progress: progress
        )
        let redStack = try await stackChannel(
            channel: 0,
            kept: kept,
            referenceIndex: referenceIndex,
            quality: qWeights,
            totalWeight: totalWeight,
            cachedLumas: nil,
            progress: progress
        )
        let blueStack = try await stackChannel(
            channel: 2,
            kept: kept,
            referenceIndex: referenceIndex,
            quality: qWeights,
            totalWeight: totalWeight,
            cachedLumas: nil,
            progress: progress
        )

        progress(.writing)

        // Combine: 3 half-res mono-replicated rgba32Float planes →
        // 1 full-res rgba32Float. The combine kernel applies per-
        // channel Bayer-site sampling offsets so R / G / B sample
        // from raw-coord-aligned half-res positions for every output
        // pixel, eliminating the 1-raw-pixel R-vs-B diagonal mismatch
        // the v0 same-coord sampling produced.
        let output = Self.makeOutputFullRes(device: device, w: rawW, h: rawH)
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            throw NSError(domain: "LuckyChannel", code: 1)
        }
        enc.setComputePipelineState(combinePSO)
        enc.setTexture(redStack,   index: 0)
        enc.setTexture(greenStack, index: 1)
        enc.setTexture(blueStack,  index: 2)
        enc.setTexture(output,     index: 3)
        var combineP = LuckyCombineParamsCPU(pattern: bayerPattern)
        enc.setBytes(&combineP, length: MemoryLayout<LuckyCombineParamsCPU>.stride, index: 0)
        let (tgC, tgS) = dispatchThreadgroups(for: output, pso: combinePSO)
        enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        return output
    }

    // MARK: - Phase 1: grade green + cache its half-res luma

    private struct GradeResult {
        let scores: [Float]
        let lumas: [Int: [Float]]
    }

    /// Streams every frame, runs the channel-extract unpack for the
    /// requested channel (green by default — the best LAPD signal),
    /// grades it via `quality_partials`, and caches the half-res luma
    /// for downstream phase correlation. Returns per-frame quality
    /// scores + the green luma cache. The same buffers feed all three
    /// channel-stack passes.
    private func gradeAndCacheLuma(
        channel: UInt32,
        progress: @escaping (LuckyStackProgress) -> Void
    ) async throws -> GradeResult {
        let total = reader.header.frameCount
        let n = options.alignmentResolution

        let grader = LuckyChannelQualityGrader(
            device: device, frameCount: total, w: halfW, h: halfH, pso: qualityPSO
        )
        var lumaCache = [Int: [Float]]()
        let lumaCacheLock = NSLock()

        for frameIndex in 0..<total {
            stagingSemaphore.wait()
            let slot = frameIndex % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            reader.withFrameBytes(at: frameIndex) { ptr, _ in
                let bytesPerRow = rawW * bytesPerPlane
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: rawW, height: rawH, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: bytesPerRow
                )
            }

            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }

            encodeChannelUnpack(cmd: cmd, staging: staging, frameTex: frameTex, channel: channel)
            grader.encodeGrade(commandBuffer: cmd, frameTex: frameTex, frameIndex: frameIndex)

            let lumaBuf = device.makeBuffer(
                length: n * n * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            if let buf = lumaBuf, let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(lumaPSO)
                enc.setTexture(frameTex, index: 0)
                enc.setBuffer(buf, offset: 0, index: 0)
                var dstSize = SIMD2<UInt32>(UInt32(n), UInt32(n))
                enc.setBytes(&dstSize, length: 8, index: 1)
                let tgw = lumaPSO.threadExecutionWidth
                let tgh = lumaPSO.maxTotalThreadsPerThreadgroup / tgw
                enc.dispatchThreadgroups(
                    MTLSize(width: (n + tgw - 1) / tgw, height: (n + tgh - 1) / tgh, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tgw, height: tgh, depth: 1)
                )
                enc.endEncoding()
            }

            let captured = frameIndex
            cmd.addCompletedHandler { [weak self] _ in
                if let buf = lumaBuf {
                    let ptr = buf.contents().assumingMemoryBound(to: Float.self)
                    let array = Array(UnsafeBufferPointer(start: ptr, count: n * n))
                    lumaCacheLock.lock(); lumaCache[captured] = array; lumaCacheLock.unlock()
                }
                self?.stagingSemaphore.signal()
            }
            cmd.commit()

            if frameIndex % 32 == 0 || frameIndex == total - 1 {
                progress(.grading(done: frameIndex + 1, total: total))
            }
        }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }

        return GradeResult(scores: grader.computeVariances(), lumas: lumaCache)
    }

    // MARK: - Phase 2: stack one channel using the shared grading

    /// Aligns and accumulates the kept frames for a single channel,
    /// using the SHARED `referenceIndex` and `quality` weights.
    /// `cachedLumas` holds the green-channel luma cache from phase 1
    /// — passed in for the green run only (re-using saves the second
    /// extract pass). For R and B the function does its own per-frame
    /// channel-extract + luma-extract during the align pass since the
    /// green luma can't be reused (different physical samples).
    private func stackChannel(
        channel: UInt32,
        kept: [Int],
        referenceIndex: Int,
        quality: [Int: Float],
        totalWeight: Double,
        cachedLumas: [Int: [Float]]?,
        progress: @escaping (LuckyStackProgress) -> Void
    ) async throws -> MTLTexture {
        let n = options.alignmentResolution
        let scaleX = Float(halfW) / Float(n)
        let scaleY = Float(halfH) / Float(n)

        // Phase 2a: gather (or extract) the half-res luma for the
        // reference frame + every kept frame, on this channel.
        let refLuma: [Float]
        if let cached = cachedLumas?[referenceIndex] {
            refLuma = cached
        } else {
            refLuma = try await extractLumaFromIndex(referenceIndex, channel: channel, n: n)
        }

        var lumas: [(idx: Int, data: [Float])] = []
        lumas.reserveCapacity(kept.count)
        for idx in kept {
            if let cached = cachedLumas?[idx] {
                lumas.append((idx, cached))
            } else {
                let extracted = try await extractLumaFromIndex(idx, channel: channel, n: n)
                lumas.append((idx, extracted))
            }
        }

        // Phase 2b: phase-correlate every kept frame against the
        // reference (in this channel's space).
        var shifts = [SIMD2<Float>](repeating: .zero, count: lumas.count)
        shifts.withUnsafeMutableBufferPointer { buf in
            let cpu = SharedCPUFFT(log2n: Int(log2(Double(n))))
            DispatchQueue.concurrentPerform(iterations: lumas.count) { i in
                if let shift = cpu.phaseCorrelate(ref: refLuma, frame: lumas[i].data, n: n) {
                    var dx = shift.dx, dy = shift.dy
                    if dx > Float(n / 2) { dx -= Float(n) }
                    if dy > Float(n / 2) { dy -= Float(n) }
                    buf[i] = SIMD2<Float>(dx * scaleX, dy * scaleY)
                }
            }
        }
        var shiftMap: [Int: SIMD2<Float>] = [:]
        for (i, item) in lumas.enumerated() { shiftMap[item.idx] = shifts[i] }

        // Phase 2c: accumulate.
        let accum = Self.makeAccumulator(device: device, w: halfW, h: halfH)
        progress(.stacking(done: 0, total: kept.count))

        for (i, idx) in kept.enumerated() {
            stagingSemaphore.wait()
            let slot = i % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            reader.withFrameBytes(at: idx) { ptr, _ in
                let bytesPerRow = rawW * bytesPerPlane
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: rawW, height: rawH, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: bytesPerRow
                )
            }

            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }

            encodeChannelUnpack(cmd: cmd, staging: staging, frameTex: frameTex, channel: channel)

            let weight = quality[idx] ?? 0.05
            let shift = shiftMap[idx] ?? SIMD2<Float>(0, 0)

            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(accumPSO)
                enc.setTexture(frameTex, index: 0)
                enc.setTexture(accum, index: 1)
                var p = LuckyAccumParamsCPU(weight: weight, shift: shift)
                enc.setBytes(&p, length: MemoryLayout<LuckyAccumParamsCPU>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: accumPSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }

            cmd.addCompletedHandler { [weak self] _ in self?.stagingSemaphore.signal() }
            cmd.commit()

            if i % 32 == 0 || i == kept.count - 1 {
                progress(.stacking(done: i + 1, total: kept.count))
            }
        }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }

        // Normalize using the SHARED total weight so all three channels
        // share the same overall scale — preserves white balance across
        // the recombined output.
        if let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(normalizePSO)
            enc.setTexture(accum, index: 0)
            var p = LuckyNormalizeParamsCPU(invTotalWeight: 1.0 / Float(totalWeight))
            enc.setBytes(&p, length: MemoryLayout<LuckyNormalizeParamsCPU>.stride, index: 0)
            let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: normalizePSO)
            enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        return accum
    }

    /// Encode the channel-extract unpack from `staging` (raw mosaic) →
    /// `frameTex` (half-res mono-replicated rgba) for a given channel.
    private func encodeChannelUnpack(
        cmd: MTLCommandBuffer,
        staging: MTLTexture,
        frameTex: MTLTexture,
        channel: UInt32
    ) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        let pso = isMono16 ? bayerChan16PSO : bayerChan8PSO
        enc.setComputePipelineState(pso)
        let scale: Float = isMono16 ? 1.0 / 65535.0 : 1.0
        let flip: UInt32 = options.meridianFlipped ? 1 : 0
        var p = BayerChannelParamsCPU(
            scale: scale, flip: flip,
            pattern: bayerPattern, channel: channel
        )
        enc.setBytes(&p, length: MemoryLayout<BayerChannelParamsCPU>.stride, index: 0)
        enc.setTexture(staging, index: 0)
        enc.setTexture(frameTex, index: 1)
        let (tgC, tgS) = dispatchThreadgroups(for: frameTex, pso: pso)
        enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        enc.endEncoding()
    }

    /// Cold-path luma extractor. Reads the SER frame, runs the channel-
    /// extract unpack into a fresh half-res texture, then runs the
    /// downsample-luma kernel. Used only as a fallback if pass 1 didn't
    /// cache the luma for an index — typically because the staging
    /// completion handler hadn't fired before pass 2 needed the data.
    private func extractLumaFromIndex(_ idx: Int, channel: UInt32, n: Int) async throws -> [Float] {
        let staging = Self.makeStaging(device: device, w: rawW, h: rawH, mono16: isMono16)
        let frameTex = Self.makeFrameTexture(device: device, w: halfW, h: halfH)

        reader.withFrameBytes(at: idx) { ptr, _ in
            let bytesPerRow = rawW * bytesPerPlane
            staging.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                   size: MTLSize(width: rawW, height: rawH, depth: 1)),
                mipmapLevel: 0, withBytes: ptr, bytesPerRow: bytesPerRow
            )
        }

        guard let cmd = queue.makeCommandBuffer() else {
            throw NSError(domain: "LuckyChannel", code: 2)
        }
        if let enc = cmd.makeComputeCommandEncoder() {
            let pso = isMono16 ? bayerChan16PSO : bayerChan8PSO
            enc.setComputePipelineState(pso)
            let scale: Float = isMono16 ? 1.0 / 65535.0 : 1.0
            let flip: UInt32 = options.meridianFlipped ? 1 : 0
            var p = BayerChannelParamsCPU(scale: scale, flip: flip, pattern: bayerPattern, channel: channel)
            enc.setBytes(&p, length: MemoryLayout<BayerChannelParamsCPU>.stride, index: 0)
            enc.setTexture(staging, index: 0)
            enc.setTexture(frameTex, index: 1)
            let (tgC, tgS) = dispatchThreadgroups(for: frameTex, pso: pso)
            enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
            enc.endEncoding()
        }
        let buf = device.makeBuffer(length: n * n * MemoryLayout<Float>.size, options: .storageModeShared)!
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(lumaPSO)
            enc.setTexture(frameTex, index: 0)
            enc.setBuffer(buf, offset: 0, index: 0)
            var dstSize = SIMD2<UInt32>(UInt32(n), UInt32(n))
            enc.setBytes(&dstSize, length: 8, index: 1)
            let tgw = lumaPSO.threadExecutionWidth
            let tgh = lumaPSO.maxTotalThreadsPerThreadgroup / tgw
            enc.dispatchThreadgroups(
                MTLSize(width: (n + tgw - 1) / tgw, height: (n + tgh - 1) / tgh, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tgw, height: tgh, depth: 1)
            )
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        let ptr = buf.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: n * n))
    }

    private func topNIndices(scores: [Float], percent: Int) -> [Int] {
        topNIndices(scores: scores, count: max(1, scores.count * percent / 100))
    }

    private func topNIndices(scores: [Float], count: Int) -> [Int] {
        let n = max(1, min(scores.count, count))
        let sorted = scores.enumerated().sorted { $0.element > $1.element }
        return sorted.prefix(n).map { $0.offset }
    }
}

// MARK: - GPU/CPU param mirrors
//
// Standalone mirrors so the per-channel path can stay in its own file
// without making the (private) param structs in LuckyStack.swift
// internal. Same byte layout — keep these in lockstep with
// `BayerChannelParams`, `LuckyAccumParams`, `LuckyNormalizeParams` in
// Shaders.metal.

private struct BayerChannelParamsCPU {
    var scale: Float
    var flip: UInt32
    var pattern: UInt32
    var channel: UInt32
}

private struct LuckyAccumParamsCPU {
    var weight: Float
    var shift: SIMD2<Float>
}

private struct LuckyNormalizeParamsCPU {
    var invTotalWeight: Float
}

private struct LuckyCombineParamsCPU {
    var pattern: UInt32
}

// MARK: - Quality grading helper
//
// Same shape as the private QualityGrader in LuckyStack.swift, but
// scoped to this file so we don't have to expose internals across
// files. Reads the per-AP partials buffer the existing `quality_partials`
// kernel writes; computes per-frame Laplacian variance on CPU.

private struct LuckyChannelQualityPartial {
    var sum: Float
    var sumSq: Float
    var count: UInt32
    var pad: UInt32
}

private final class LuckyChannelQualityGrader {
    let frameCount: Int
    let groupsPerFrame: Int
    let groupsX: Int
    let groupsY: Int
    let pso: MTLComputePipelineState
    let partialsBuffer: MTLBuffer

    init(device: MTLDevice, frameCount: Int, w: Int, h: Int, pso: MTLComputePipelineState) {
        self.frameCount = frameCount
        self.pso = pso
        let tgw = 16, tgh = 16
        self.groupsX = (w + tgw - 1) / tgw
        self.groupsY = (h + tgh - 1) / tgh
        self.groupsPerFrame = groupsX * groupsY
        let total = frameCount * groupsPerFrame
        let stride = MemoryLayout<LuckyChannelQualityPartial>.stride
        self.partialsBuffer = device.makeBuffer(length: total * stride, options: .storageModeShared)!
    }

    func encodeGrade(commandBuffer cmd: MTLCommandBuffer, frameTex: MTLTexture, frameIndex: Int) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pso)
        enc.setTexture(frameTex, index: 0)
        enc.setBuffer(partialsBuffer, offset: 0, index: 0)
        var fIdx = UInt32(frameIndex)
        var gpf = UInt32(groupsPerFrame)
        enc.setBytes(&fIdx, length: 4, index: 1)
        enc.setBytes(&gpf,  length: 4, index: 2)
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(width: groupsX, height: groupsY, depth: 1)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
    }

    func computeVariances() -> [Float] {
        let ptr = partialsBuffer.contents().assumingMemoryBound(to: LuckyChannelQualityPartial.self)
        var variances = [Float](repeating: 0, count: frameCount)
        for f in 0..<frameCount {
            var s: Double = 0, sq: Double = 0
            var cnt: UInt64 = 0
            for g in 0..<groupsPerFrame {
                let r = ptr[f * groupsPerFrame + g]
                s  += Double(r.sum)
                sq += Double(r.sumSq)
                cnt += UInt64(r.count)
            }
            if cnt > 0 {
                let n = Double(cnt)
                let mean = s / n
                let varV = sq / n - mean * mean
                variances[f] = Float(max(0, varV))
            }
        }
        return variances
    }
}

private extension Array where Element: Comparable {
    func argmax() -> Int {
        guard !isEmpty else { return 0 }
        var best = 0
        for i in 1..<count where self[i] > self[best] { best = i }
        return best
    }
}
