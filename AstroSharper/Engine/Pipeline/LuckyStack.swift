// Lucky-imaging stacking pipeline.
//
// Two modes:
//   Lightspeed   — Laplacian-variance grading, top-N% global selection,
//                  phase-correlation against best frame, quality-weighted mean.
//                  AutoStakkert!-equivalent quality at the speed limit of the
//                  hardware. Single-AP / global only.
//   Scientific   — Reference stack from top 5%, then top-N% selection against
//                  that reference, quality-weighted accumulation, optional
//                  Wiener-deconvolution post-stack with a synthetic Airy PSF.
//
// Frames flow through a streaming staging-pool: SER frame bytes are memcpy'd
// from the memory-mapped file into a small ring of GPU staging textures, the
// quality pass writes per-threadgroup partials into a single big buffer, the
// CPU resolves variances, sorts, then a second streaming pass aligns and
// accumulates the keepers. Memory usage is O(staging-pool-size) regardless of
// frame count.
import Accelerate
import Foundation
import Metal
import MetalPerformanceShaders

enum LuckyStackMode: String, CaseIterable, Identifiable, Codable {
    case lightspeed = "Lightspeed"
    case scientific = "Scientific"
    var id: String { rawValue }

    var description: String {
        switch self {
        case .lightspeed:
            return "AutoStakkert-equivalent. Laplacian quality, single-AP global alignment, fast."
        case .scientific:
            return "Reference-stack alignment, LoG quality, post-stack Wiener deconv. Slower, higher fidelity."
        }
    }
}

/// Optional bundle to bake the standard sharpen + tone pipeline into the
/// stacked output before writing. The lucky-stack runner stops at the
/// quality-weighted accumulation; with this set, that result then runs
/// through `Pipeline.process` with the user's current settings so the
/// saved file matches the live preview.
struct LuckyStackBakeIn {
    var sharpen: SharpenSettings
    var toneCurve: ToneCurveSettings
    var toneCurveLUT: MTLTexture?
}

/// Optional extra stack outputs requested per .ser, on top of the default
/// "keep best N%" slider value. Each non-zero entry triggers a *separate*
/// stack run for that file, written to a subdirectory of the output folder
/// (e.g. `f100/`, `p25/`). Default values are all zero meaning "off".
///
/// Lives in Engine because Preset.swift carries it; the GUI owns its own
/// editing surface in AppModel.luckyStackUI.
struct LuckyStackVariants: Codable, Equatable {
    var absoluteCounts: [Int] = [0, 0, 0]   // f-slots
    var percentages: [Int] = [0, 0, 0]      // p-slots

    var isEmpty: Bool {
        absoluteCounts.allSatisfy { $0 == 0 } && percentages.allSatisfy { $0 == 0 }
    }
}

struct LuckyStackOptions {
    var mode: LuckyStackMode = .lightspeed
    var keepPercent: Int = 25            // top-N% of frames to stack
    /// If set, overrides `keepPercent` — keep this many frames absolutely.
    var keepCount: Int? = nil
    var alignmentResolution: Int = 256    // FFT size for phase correlation
    var stagingPoolSize: Int = 32         // GPU upload pipelining
    var doWienerDeconv: Bool = false      // scientific only
    var wienerSigma: Double = 1.4         // PSF sigma in pixels
    var meridianFlipped: Bool = false    // rotate every unpacked frame 180°
    /// Multi-AP local refinement (Scientific only).
    var useMultiAP: Bool = false
    var multiAPGrid: Int = 8
    var multiAPSearch: Int = 8
    /// When set, the stacked output is post-processed through the standard
    /// pipeline (sharpen + wavelet + tone-curve) before being written.
    var bakeIn: LuckyStackBakeIn? = nil

    /// Sigma-clipped outlier rejection during accumulation. nil = the
    /// existing single-pass quality-weighted mean; non-nil triggers a
    /// two-pass Welford → clipped re-accumulate path that rejects
    /// per-pixel samples > k·σ from the running mean. AS!4 ships a
    /// k=2.5 default; values below 1.5 reject too aggressively, above
    /// 3.5 nothing meaningful gets clipped. Pass-1 + pass-2 doubles
    /// the disk read and GPU time of the accumulation phase.
    ///
    /// CPU reference: Engine/Pipeline/SigmaClip.swift.
    var sigmaThreshold: Float? = nil

    /// Drizzle reconstruction factor. 1 = off (default — output at
    /// input dimensions via the standard accumulator). 2 or 3 = drop-
    /// based splat onto an upsampled grid; output is `scale²` larger
    /// in pixel area. Best for undersampled subjects (lunar / solar
    /// surface at 0.5–1.5 "/px); minimal benefit on well-sampled
    /// planetary data. Per BiggSky / AS!4 docs the typical operating
    /// point is 2× with `drizzlePixfrac` 0.7.
    ///
    /// CPU reference: Engine/Pipeline/Drizzle.swift.
    var drizzleScale: Int = 1

    /// Drop size relative to one input pixel (0..1]. 0.7 is the
    /// AS!4 / BiggSky default; smaller values increase sharpness at
    /// the cost of coverage gaps in the output (handled by the
    /// per-pixel weight texture).
    var drizzlePixfrac: Float = 0.7

    /// Per-AP local quality re-ranking (PSS / AS!4 two-stage grading).
    /// false = single global ranking (existing); true = each AP cell
    /// picks its own top-k frames independently. Directly addresses
    /// the "Jupiter limb dented because band-sharp frames dominated
    /// the global ranking and limb-sharp frames lost out" failure
    /// mode by giving each region its own keep set.
    var useTwoStageQuality: Bool = false

    /// AP grid edge length when `useTwoStageQuality` is on. 8 → 8×8 =
    /// 64 cells. Matches the multi-AP grid convention; bigger grids
    /// give finer regional adaptivity but reduce the per-cell sample
    /// count (a 16×16 grid on a 640×640 frame = 40×40 px cells, close
    /// to the LAPD stencil's effective scale).
    var twoStageAPGrid: Int = 8

    /// Per-AP keep fraction (0..1). Defaults to `keepPercent / 100`
    /// when nil — same selectivity as the global path. Pass a
    /// smaller value to be picky per-AP independently of the global
    /// keep slider.
    var twoStageKeepFraction: Double? = nil
}

enum LuckyStackProgress {
    case opening(url: URL)
    case grading(done: Int, total: Int)
    case sorting
    case buildingReference(done: Int, total: Int)
    case stacking(done: Int, total: Int)
    case writing
    case finished(URL)
    case error(String)
}

enum LuckyStack {

    static func run(
        sourceURL: URL,
        outputURL: URL,
        options: LuckyStackOptions,
        pipeline: Pipeline,
        onProgress: @escaping @MainActor (LuckyStackProgress) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            await onProgress(.opening(url: sourceURL))

            let reader: SerReader
            do {
                reader = try SerReader(url: sourceURL)
            } catch {
                await onProgress(.error("\(error)")); return
            }

            // Mono 8/16 and the four Bayer patterns are supported. Packed
            // RGB SERs (.rgb / .bgr) are still rejected; conversion would
            // mostly duplicate the Bayer path with permuted channels.
            guard reader.header.colorID.isMono || reader.header.colorID.isBayer else {
                await onProgress(.error("RGB-packed SER not yet supported (got \(reader.header.colorID))"))
                return
            }

            let runner = LuckyRunner(reader: reader, pipeline: pipeline, options: options)
            do {
                let stacked = try await runner.run(progress: { p in
                    Task { @MainActor in onProgress(p) }
                })
                await onProgress(.writing)

                // Optional bake-in: route the stacked texture through the
                // user's current sharpen + tone pipeline before writing so
                // the saved file matches the live preview.
                let final: MTLTexture
                if let bake = options.bakeIn {
                    final = pipeline.process(
                        input: stacked,
                        sharpen: bake.sharpen,
                        toneCurve: bake.toneCurve,
                        toneCurveLUT: bake.toneCurveLUT
                    )
                } else {
                    final = stacked
                }
                try ImageTexture.write(texture: final, to: outputURL)
                await onProgress(.finished(outputURL))
            } catch {
                await onProgress(.error("\(error)"))
            }
        }
    }
}

// MARK: - Internal runner

private final class LuckyRunner {
    let reader: SerReader
    let pipeline: Pipeline
    let options: LuckyStackOptions

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    let unpack16PSO: MTLComputePipelineState
    let unpack8PSO: MTLComputePipelineState
    let bayer16PSO: MTLComputePipelineState
    let bayer8PSO: MTLComputePipelineState
    let qualityPSO: MTLComputePipelineState
    let lumaPSO: MTLComputePipelineState
    let accumPSO: MTLComputePipelineState
    let normalizePSO: MTLComputePipelineState
    let apShiftPSO: MTLComputePipelineState
    let accumLocalPSO: MTLComputePipelineState
    // B.1 sigma-clip kernels — only built when options.sigmaThreshold is set.
    lazy var welfordPSO: MTLComputePipelineState = Self.makePSO(library: library, device: device, fn: "lucky_welford_step")
    lazy var clippedAccumPSO: MTLComputePipelineState = Self.makePSO(library: library, device: device, fn: "lucky_accumulate_clipped")
    lazy var perPixelNormPSO: MTLComputePipelineState = Self.makePSO(library: library, device: device, fn: "lucky_normalize_per_pixel")
    // B.6 drizzle splat — only built when options.drizzleScale > 1.
    lazy var drizzlePSO: MTLComputePipelineState = Self.makePSO(library: library, device: device, fn: "lucky_drizzle_splat")
    // A.2 two-stage quality kernels — only built when useTwoStageQuality is on.
    lazy var perAPGradePSO: MTLComputePipelineState = Self.makePSO(library: library, device: device, fn: "quality_partials_per_ap")
    lazy var perAPAccumPSO: MTLComputePipelineState = Self.makePSO(library: library, device: device, fn: "lucky_accumulate_per_ap_keep")

    let W: Int, H: Int
    let bytesPerPlane: Int
    let isMono16: Bool
    let isBayer: Bool
    let bayerPattern: UInt32

    // Staging pool for SER → GPU upload.
    let stagingTextures: [MTLTexture]
    let frameTextures: [MTLTexture]      // unpacked rgba16Float, paired with staging
    let stagingSemaphore: DispatchSemaphore

    // Quality grading buffers.
    let quality: QualityGrader

    /// Cached downsampled-luma buffer per frame (size N×N), populated during
    /// the quality-grade pass. Skips the second SER-mmap-read + GPU unpack
    /// + GPU luma-extract during alignment — typically halves alignment
    /// cost. Memory: ~256KB × frameCount = 1.25GB at 5000 frames worst case.
    ///
    /// Access is locked because writes come from Metal's completion-handler
    /// queue (not main) and reads happen from the Task running the runner.
    private var _lumaCache: [Int: [Float]] = [:]
    private let lumaCacheLock = NSLock()
    private func cacheLuma(_ idx: Int, _ data: [Float]) {
        lumaCacheLock.lock(); _lumaCache[idx] = data; lumaCacheLock.unlock()
    }
    private func cachedLuma(_ idx: Int) -> [Float]? {
        lumaCacheLock.lock(); defer { lumaCacheLock.unlock() }
        return _lumaCache[idx]
    }

    /// GPU phase correlator via MPSGraph FFT. Currently disabled — the
    /// parallel-CPU path is already fast enough on Apple Silicon (8+ cores
    /// running shared-FFTSetup vDSP) and avoids MPSGraph buffer-storage
    /// edge-cases that surfaced in testing. Re-enable by returning the
    /// constructed correlator from this lazy var.
    private lazy var gpuCorrelator: GPUPhaseCorrelator? = nil

    init(reader: SerReader, pipeline: Pipeline, options: LuckyStackOptions) {
        self.reader = reader
        self.pipeline = pipeline
        self.options = options
        self.device = MetalDevice.shared.device
        self.queue = MetalDevice.shared.commandQueue
        guard let lib = MetalDevice.shared.library else { fatalError("Metal library missing") }
        self.library = lib

        self.unpack16PSO = Self.makePSO(library: lib, device: device, fn: "unpack_mono16_to_rgba")
        self.unpack8PSO  = Self.makePSO(library: lib, device: device, fn: "unpack_mono8_to_rgba")
        self.bayer16PSO  = Self.makePSO(library: lib, device: device, fn: "unpack_bayer16_to_rgba")
        self.bayer8PSO   = Self.makePSO(library: lib, device: device, fn: "unpack_bayer8_to_rgba")
        self.qualityPSO  = Self.makePSO(library: lib, device: device, fn: "quality_partials")
        self.lumaPSO     = Self.makePSO(library: lib, device: device, fn: "extract_luma_downsample")
        self.accumPSO    = Self.makePSO(library: lib, device: device, fn: "lucky_accumulate")
        self.normalizePSO = Self.makePSO(library: lib, device: device, fn: "lucky_normalize")
        self.apShiftPSO  = Self.makePSO(library: lib, device: device, fn: "compute_ap_shifts")
        self.accumLocalPSO = Self.makePSO(library: lib, device: device, fn: "lucky_accumulate_local")

        let W = reader.header.imageWidth
        let H = reader.header.imageHeight
        let bytesPerPlane = reader.header.bytesPerPlane
        self.W = W
        self.H = H
        self.bytesPerPlane = bytesPerPlane
        self.isMono16 = bytesPerPlane == 2
        self.isBayer = reader.header.colorID.isBayer
        self.bayerPattern = reader.header.colorID.bayerPatternIndex

        let dev = self.device
        self.stagingTextures = (0..<options.stagingPoolSize).map { _ in
            Self.makeStaging(device: dev, w: W, h: H, mono16: bytesPerPlane == 2)
        }
        self.frameTextures = (0..<options.stagingPoolSize).map { _ in
            Self.makeFrameTexture(device: dev, w: W, h: H)
        }
        self.stagingSemaphore = DispatchSemaphore(value: options.stagingPoolSize)

        self.quality = QualityGrader(device: dev, frameCount: reader.header.frameCount, w: W, h: H, pso: qualityPSO)
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

    /// Centralised SER → rgba16Float dispatcher. Handles mono and the four
    /// Bayer patterns at 8/16 bit. Picks the right kernel and parameter
    /// struct based on this runner's flags.
    private func encodeUnpack(
        commandBuffer cmd: MTLCommandBuffer,
        staging: MTLTexture,
        frameTex: MTLTexture
    ) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        let scale: Float = isMono16 ? 1.0 / 65535.0 : 1.0
        let flip: UInt32 = options.meridianFlipped ? 1 : 0

        if isBayer {
            let pso = isMono16 ? bayer16PSO : bayer8PSO
            enc.setComputePipelineState(pso)
            var p = BayerUnpackParamsCPU(scale: scale, flip: flip, pattern: bayerPattern)
            enc.setBytes(&p, length: MemoryLayout<BayerUnpackParamsCPU>.stride, index: 0)
            enc.setTexture(staging, index: 0)
            enc.setTexture(frameTex, index: 1)
            let (tgC, tgS) = dispatchThreadgroups(for: frameTex, pso: pso)
            enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        } else {
            let pso = isMono16 ? unpack16PSO : unpack8PSO
            enc.setComputePipelineState(pso)
            var p = UnpackParamsCPU(scale: scale, flip: flip)
            enc.setBytes(&p, length: MemoryLayout<UnpackParamsCPU>.stride, index: 0)
            enc.setTexture(staging, index: 0)
            enc.setTexture(frameTex, index: 1)
            let (tgC, tgS) = dispatchThreadgroups(for: frameTex, pso: pso)
            enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        }
        enc.endEncoding()
    }

    static func makeFrameTexture(device: MTLDevice, w: Int, h: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        return device.makeTexture(descriptor: desc)!
    }

    // MARK: - Public driver

    func run(progress: @escaping (LuckyStackProgress) -> Void) async throws -> MTLTexture {
        let total = reader.header.frameCount

        // Stage 1: grade every frame.
        try await gradeAllFrames(progress: progress)
        progress(.sorting)
        let scores = quality.computeVariances()  // [Float] of length frameCount
        // `keepCount` (absolute frame count) overrides `keepPercent` so the
        // user can request fixed-N stacks (e.g. "best 100 frames") for
        // direct comparison across SERs of different lengths.
        let kept: [Int]
        if let count = options.keepCount, count > 0 {
            kept = topNIndices(scores: scores, count: count)
        } else {
            kept = topNIndices(scores: scores, percent: options.keepPercent)
        }

        // Stage 2: pick reference.
        let referenceIndex: Int
        var referenceShifts: [Int: SIMD2<Float>] = [:]
        let outputSize = (W: W, H: H)

        let referenceTex: MTLTexture
        if options.mode == .scientific {
            // Two-stage reference build:
            //   1. Take the top ~5% of frames (sorted by quality).
            //   2. ALIGN them against the single best frame and accumulate
            //      → a clean, sharp reference (instead of a blurry unaligned
            //      mean, which makes phase-correlation in the next pass
            //      lock onto smeared edges).
            let topPct = max(2, min(20, options.keepPercent / 5))
            let refKept = topNIndices(scores: scores, percent: topPct)
            referenceIndex = refKept.first ?? scores.argmax()

            let anchor = try await loadAndUnpack(frameIndex: referenceIndex, into: nil)
            let anchorShifts = try await alignAgainstReference(referenceTex: anchor, indices: refKept)
            let refStack = try await accumulateAlignedSubset(
                indices: refKept, shifts: anchorShifts, progress: progress
            )
            referenceTex = refStack

            // Now phase-correlate ALL kept frames against the clean reference.
            referenceShifts = try await alignAgainstReference(referenceTex: refStack, indices: kept)
        } else {
            referenceIndex = scores.argmax()
            let refTex = try await loadAndUnpack(frameIndex: referenceIndex, into: nil)
            referenceShifts = try await alignAgainstReference(referenceTex: refTex, indices: kept)
            referenceTex = refTex
        }

        // Stage 3: weighted accumulation. Four paths, picked in order:
        //   - useTwoStageQuality : per-AP local quality re-rank,
        //                          per-AP keep-mask accumulator. PSS /
        //                          AS!4 two-stage grading. Directly
        //                          targets the "limb dented because the
        //                          global ranking favoured band-sharp
        //                          frames" failure mode.
        //   - drizzleScale > 1   : per-output reverse-map splatter
        //                          onto an upsampled grid. v0 integer
        //                          scales only.
        //   - sigmaThreshold ≠ nil: two-pass Welford → clipped re-
        //                          accumulate.
        //   - else                : existing single-pass quality-
        //                          weighted mean + optional multi-AP.
        let stacked: MTLTexture
        if options.useTwoStageQuality {
            stacked = try await accumulateAlignedTwoStage(
                indices: kept,
                scores: scores,
                shifts: referenceShifts,
                apGrid: options.twoStageAPGrid,
                keepFractionPerAP: options.twoStageKeepFraction
                    ?? Double(options.keepPercent) / 100.0,
                progress: progress
            )
        } else if options.drizzleScale > 1 {
            stacked = try await accumulateAlignedDrizzled(
                indices: kept,
                scores: scores,
                shifts: referenceShifts,
                scale: options.drizzleScale,
                pixfrac: options.drizzlePixfrac,
                progress: progress
            )
        } else if let sigma = options.sigmaThreshold {
            stacked = try await accumulateAlignedSigmaClipped(
                indices: kept,
                scores: scores,
                shifts: referenceShifts,
                sigmaThreshold: sigma,
                progress: progress
            )
        } else {
            stacked = try await accumulateAligned(
                indices: kept,
                scores: scores,
                shifts: referenceShifts,
                referenceTex: referenceTex,
                progress: progress
            )
        }

        _ = referenceIndex
        _ = outputSize
        return stacked
    }

    // MARK: - Stage helpers

    private func gradeAllFrames(progress: @escaping (LuckyStackProgress) -> Void) async throws {
        let total = reader.header.frameCount
        var lastReported = -1

        // Streaming loop; one cmd buffer per frame, but we never wait between
        // frames except for staging slot availability.
        for frameIndex in 0..<total {
            stagingSemaphore.wait()
            let slot = frameIndex % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            // Copy SER bytes into the staging texture.
            reader.withFrameBytes(at: frameIndex) { ptr, len in
                let bytesPerRow = W * bytesPerPlane
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0,
                    withBytes: ptr,
                    bytesPerRow: bytesPerRow
                )
                _ = len
            }

            guard let cmd = queue.makeCommandBuffer() else { continue }

            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: frameTex)

            // Quality grade: frameTex → partials buffer.
            quality.encodeGrade(commandBuffer: cmd, frameTex: frameTex, frameIndex: frameIndex)

            // Luma extraction (256² downsample) for later alignment, cached
            // here so we don't re-read + re-unpack this frame in stage 2.
            let lumaBuf = device.makeBuffer(
                length: options.alignmentResolution * options.alignmentResolution * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            if let buf = lumaBuf, let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(lumaPSO)
                enc.setTexture(frameTex, index: 0)
                enc.setBuffer(buf, offset: 0, index: 0)
                var dstSize = SIMD2<UInt32>(UInt32(options.alignmentResolution), UInt32(options.alignmentResolution))
                enc.setBytes(&dstSize, length: 8, index: 1)
                let tgw = lumaPSO.threadExecutionWidth
                let tgh = lumaPSO.maxTotalThreadsPerThreadgroup / tgw
                let n = options.alignmentResolution
                enc.dispatchThreadgroups(
                    MTLSize(width: (n + tgw - 1) / tgw, height: (n + tgh - 1) / tgh, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tgw, height: tgh, depth: 1)
                )
                enc.endEncoding()
            }

            let captured = frameIndex
            cmd.addCompletedHandler { [weak self] _ in
                if let buf = lumaBuf, let self {
                    let n = self.options.alignmentResolution
                    let ptr = buf.contents().assumingMemoryBound(to: Float.self)
                    let array = Array(UnsafeBufferPointer(start: ptr, count: n * n))
                    self.cacheLuma(captured, array)
                }
                self?.stagingSemaphore.signal()
            }
            cmd.commit()

            if frameIndex - lastReported > 32 || frameIndex == total - 1 {
                lastReported = frameIndex
                let captured = frameIndex
                progress(.grading(done: captured + 1, total: total))
            }
        }

        // Wait for last frame to flush (so partials buffer is fully populated).
        // Replenish all staging slots before returning.
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }
    }

    private func loadAndUnpack(frameIndex: Int, into existing: MTLTexture?) async throws -> MTLTexture {
        let target = existing ?? Self.makeFrameTexture(device: device, w: W, h: H)
        let staging = Self.makeStaging(device: device, w: W, h: H, mono16: isMono16)

        reader.withFrameBytes(at: frameIndex) { ptr, _ in
            staging.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: W, height: H, depth: 1)),
                mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
            )
        }

        guard let cmd = queue.makeCommandBuffer() else {
            throw NSError(domain: "Lucky", code: 1)
        }
        encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: target)
        cmd.commit()
        cmd.waitUntilCompleted()
        return target
    }

    private func accumulateUnaligned(indices: [Int], progress: @escaping (LuckyStackProgress) -> Void) async throws -> MTLTexture {
        let accum = Self.makeAccumulator(device: device, w: W, h: H)
        progress(.buildingReference(done: 0, total: indices.count))

        for (i, idx) in indices.enumerated() {
            stagingSemaphore.wait()
            let slot = i % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            reader.withFrameBytes(at: idx) { ptr, _ in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
                )
            }

            guard let cmd = queue.makeCommandBuffer() else { continue }
            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: frameTex)
            // Accumulate (no shift, weight = 1)
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(accumPSO)
                enc.setTexture(frameTex, index: 0)
                enc.setTexture(accum, index: 1)
                var p = LuckyAccumParams(weight: 1.0, shift: SIMD2<Float>(0, 0))
                enc.setBytes(&p, length: MemoryLayout<LuckyAccumParams>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: accumPSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }
            cmd.addCompletedHandler { [weak self] _ in self?.stagingSemaphore.signal() }
            cmd.commit()

            if i % 16 == 0 {
                progress(.buildingReference(done: i + 1, total: indices.count))
            }
        }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }

        // Normalize.
        if let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(normalizePSO)
            enc.setTexture(accum, index: 0)
            var p = LuckyNormalizeParams(invTotalWeight: 1.0 / Float(indices.count))
            enc.setBytes(&p, length: MemoryLayout<LuckyNormalizeParams>.stride, index: 0)
            let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: normalizePSO)
            enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return accum
    }

    private func alignAgainstReference(referenceTex: MTLTexture, indices: [Int]) async throws -> [Int: SIMD2<Float>] {
        let n = options.alignmentResolution
        let refLuma = try await extractLuma(referenceTex, size: n)
        let scaleX = Float(W) / Float(n)
        let scaleY = Float(H) / Float(n)

        // Materialize all frame lumas up front (from cache where possible).
        var lumas: [(idx: Int, data: [Float])] = []
        lumas.reserveCapacity(indices.count)
        for idx in indices {
            if let cached = cachedLuma(idx) {
                lumas.append((idx, cached))
            } else {
                let frameTex = try await loadAndUnpack(frameIndex: idx, into: nil)
                let extracted = try await extractLuma(frameTex, size: n)
                lumas.append((idx, extracted))
            }
        }

        var result: [Int: SIMD2<Float>] = [:]
        var shifts = [SIMD2<Float>](repeating: .zero, count: lumas.count)

        if #available(macOS 14.0, *), let gpu = gpuCorrelator {
            // GPU path — feed each frame through the pre-built MPSGraph.
            // Serial calls into the same graph still benefit from cached
            // shader compile + Apple Silicon's deep command queue, so the
            // wall-clock is much lower than serial vDSP.
            for (i, item) in lumas.enumerated() {
                guard let peak = gpu.correlate(reference: refLuma, frame: item.data) else { continue }
                shifts[i] = decodeShift(peak: peak, n: n, scaleX: scaleX, scaleY: scaleY)
            }
        } else {
            // CPU fallback — parallelize across cores. Each iteration writes
            // to its own index, no contention. vDSP's FFTSetup is shared
            // (read-only after creation, thread-safe).
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
        }

        for (i, item) in lumas.enumerated() {
            result[item.idx] = shifts[i]
        }
        return result
    }

    private func decodeShift(peak: GPUPhaseCorrelator.Peak, n: Int, scaleX: Float, scaleY: Float) -> SIMD2<Float> {
        var dx = Float(peak.x) + peak.subX
        var dy = Float(peak.y) + peak.subY
        if dx > Float(n / 2) { dx -= Float(n) }
        if dy > Float(n / 2) { dy -= Float(n) }
        return SIMD2<Float>(dx * scaleX, dy * scaleY)
    }

    private func extractLuma(_ tex: MTLTexture, size n: Int) async throws -> [Float] {
        let buf = device.makeBuffer(length: n * n * MemoryLayout<Float>.size, options: .storageModeShared)!
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            throw NSError(domain: "Lucky", code: 2)
        }
        enc.setComputePipelineState(lumaPSO)
        enc.setTexture(tex, index: 0)
        enc.setBuffer(buf, offset: 0, index: 0)
        var dstSize = SIMD2<UInt32>(UInt32(n), UInt32(n))
        enc.setBytes(&dstSize, length: 8, index: 1)
        let tgw = lumaPSO.threadExecutionWidth
        let tgh = lumaPSO.maxTotalThreadsPerThreadgroup / tgw
        let tgSize = MTLSize(width: tgw, height: tgh, depth: 1)
        let tgCount = MTLSize(width: (n + tgw - 1) / tgw, height: (n + tgh - 1) / tgh, depth: 1)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let ptr = buf.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: n * n))
    }

    /// Build a reference stack from a subset of indices, applying per-frame
    /// shifts during accumulation. Used by Scientific mode to bootstrap a
    /// sharp reference before re-aligning the full keepers list.
    private func accumulateAlignedSubset(
        indices: [Int],
        shifts: [Int: SIMD2<Float>],
        progress: @escaping (LuckyStackProgress) -> Void
    ) async throws -> MTLTexture {
        let accum = Self.makeAccumulator(device: device, w: W, h: H)
        progress(.buildingReference(done: 0, total: indices.count))

        for (i, idx) in indices.enumerated() {
            stagingSemaphore.wait()
            let slot = i % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            reader.withFrameBytes(at: idx) { ptr, _ in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
                )
            }

            guard let cmd = queue.makeCommandBuffer() else { continue }
            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: frameTex)

            let shift = shifts[idx] ?? SIMD2<Float>(0, 0)
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(accumPSO)
                enc.setTexture(frameTex, index: 0)
                enc.setTexture(accum, index: 1)
                var p = LuckyAccumParams(weight: 1.0, shift: shift)
                enc.setBytes(&p, length: MemoryLayout<LuckyAccumParams>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: accumPSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }
            cmd.addCompletedHandler { [weak self] _ in self?.stagingSemaphore.signal() }
            cmd.commit()

            if i % 8 == 0 || i == indices.count - 1 {
                progress(.buildingReference(done: i + 1, total: indices.count))
            }
        }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }

        if let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(normalizePSO)
            enc.setTexture(accum, index: 0)
            var p = LuckyNormalizeParams(invTotalWeight: 1.0 / Float(indices.count))
            enc.setBytes(&p, length: MemoryLayout<LuckyNormalizeParams>.stride, index: 0)
            let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: normalizePSO)
            enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return accum
    }

    private func accumulateAligned(
        indices: [Int],
        scores: [Float],
        shifts: [Int: SIMD2<Float>],
        referenceTex: MTLTexture? = nil,
        progress: @escaping (LuckyStackProgress) -> Void
    ) async throws -> MTLTexture {
        let accum = Self.makeAccumulator(device: device, w: W, h: H)
        progress(.stacking(done: 0, total: indices.count))

        // Multi-AP shift map (one per pool slot — reused across frames).
        // Only allocated when scientific + multi-AP is on AND a reference is
        // available to compute against.
        let useMultiAP = options.useMultiAP && options.mode == .scientific && referenceTex != nil
        let gridSize = options.multiAPGrid
        var shiftMaps: [MTLTexture] = []
        if useMultiAP {
            for _ in 0..<options.stagingPoolSize {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rg32Float, width: gridSize, height: gridSize, mipmapped: false
                )
                desc.storageMode = .private
                desc.usage = [.shaderRead, .shaderWrite]
                shiftMaps.append(device.makeTexture(descriptor: desc)!)
            }
        }

        // Quality-weight curve: normalised score raised to gamma=2 then
        // mapped to [0.05 .. 1.5]. Best frames dominate sharply; the worst
        // kept frames contribute almost nothing instead of equally diluting
        // the stack. This was the main reason Scientific output looked too
        // soft — the previous 0.5..1.5 linear weighting only differentiated
        // best vs worst by 3×, so 1000 mediocre frames smeared the result.
        let keptScores = indices.map { scores[$0] }
        let lo = keptScores.min() ?? 0
        let hi = keptScores.max() ?? 1
        let span = max(1e-6, hi - lo)
        var totalWeight: Double = 0
        @inline(__always) func qualityWeight(_ score: Float) -> Float {
            let t = (score - lo) / span                  // 0..1, raw
            let shaped = t * t                           // gamma 2 — biases toward best
            return 0.05 + shaped * 1.45                  // 0.05..1.5
        }

        for (i, idx) in indices.enumerated() {
            stagingSemaphore.wait()
            let slot = i % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            reader.withFrameBytes(at: idx) { ptr, _ in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
                )
            }

            guard let cmd = queue.makeCommandBuffer() else { continue }
            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: frameTex)

            let weight = qualityWeight(scores[idx])
            let shift = shifts[idx] ?? SIMD2<Float>(0, 0)
            totalWeight += Double(weight)

            // Optional Multi-AP local shift refinement.
            if useMultiAP, let refTex = referenceTex {
                let mapTex = shiftMaps[slot]
                if let enc = cmd.makeComputeCommandEncoder() {
                    enc.setComputePipelineState(apShiftPSO)
                    enc.setTexture(refTex, index: 0)
                    enc.setTexture(frameTex, index: 1)
                    enc.setTexture(mapTex, index: 2)
                    var p = APSearchParamsCPU(
                        patchHalf: 8,
                        searchRadius: Int32(options.multiAPSearch),
                        gridSize: SIMD2<UInt32>(UInt32(gridSize), UInt32(gridSize)),
                        globalShift: shift
                    )
                    enc.setBytes(&p, length: MemoryLayout<APSearchParamsCPU>.stride, index: 0)
                    // One threadgroup per AP, threads = next-power-of-2 ≥ candidates.
                    let totalCand = (2 * options.multiAPSearch + 1) * (2 * options.multiAPSearch + 1)
                    let threadsPerGroup = max(64, nextPow2(totalCand))
                    enc.dispatchThreadgroups(
                        MTLSize(width: gridSize * gridSize, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
                    )
                    enc.endEncoding()
                }
                if let enc = cmd.makeComputeCommandEncoder() {
                    enc.setComputePipelineState(accumLocalPSO)
                    enc.setTexture(frameTex, index: 0)
                    enc.setTexture(accum, index: 1)
                    enc.setTexture(mapTex, index: 2)
                    var p = LuckyAccumLocalParamsCPU(weight: weight, globalShift: shift)
                    enc.setBytes(&p, length: MemoryLayout<LuckyAccumLocalParamsCPU>.stride, index: 0)
                    let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: accumLocalPSO)
                    enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                    enc.endEncoding()
                }
            } else if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(accumPSO)
                enc.setTexture(frameTex, index: 0)
                enc.setTexture(accum, index: 1)
                var p = LuckyAccumParams(weight: weight, shift: shift)
                enc.setBytes(&p, length: MemoryLayout<LuckyAccumParams>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: accumPSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }

            cmd.addCompletedHandler { [weak self] _ in self?.stagingSemaphore.signal() }
            cmd.commit()

            if i % 32 == 0 || i == indices.count - 1 {
                progress(.stacking(done: i + 1, total: indices.count))
            }
        }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }

        if let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(normalizePSO)
            enc.setTexture(accum, index: 0)
            var p = LuckyNormalizeParams(invTotalWeight: 1.0 / Float(totalWeight))
            enc.setBytes(&p, length: MemoryLayout<LuckyNormalizeParams>.stride, index: 0)
            let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: normalizePSO)
            enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        return accum
    }

    static func makeAccumulator(device: MTLDevice, w: Int, h: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: desc)!
    }

    /// Allocate a write-able floating-point texture matching the
    /// stack's frame dimensions. Used by the sigma-clipped path for
    /// the Welford state (rgba32Float for precision on the M2
    /// accumulator) and the clipped-pass weight accumulator.
    static func makeFloatBuffer(
        device: MTLDevice,
        w: Int, h: Int,
        format: MTLPixelFormat
    ) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: w, height: h, mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: desc)!
    }

    /// Two-stage quality accumulation (A.2).
    ///
    /// Pass 1 grades every kept frame on a per-AP-cell basis: each
    /// AP cell gets its own LAPD-variance score per frame, written
    /// to a flat buffer indexed `[frameIdx × apCount + apLinear]`.
    ///
    /// Between passes, on the CPU, we sort each AP's scores
    /// descending and pick the top `keepFractionPerAP × keptCount`
    /// frames per AP. The result is a `[apCount × frameCount]`
    /// keep-mask buffer (1 = keep, 0 = drop).
    ///
    /// Pass 2 runs the per-AP-keep accumulator on every kept frame.
    /// The kernel reads the mask at (apIndex(gid), currentFrame)
    /// and only contributes when the mask is 1; a per-pixel weight
    /// texture tracks how many frames each output pixel drew from.
    /// Final divide yields the per-AP locally-best stack.
    ///
    /// Hard-edge AP boundaries in v0; B.2 GPU feathered blending
    /// softens the transitions later. Multi-AP shifts are NOT
    /// engaged on this path for v0 (combining per-AP grading and
    /// per-AP local shifts is the C.3 "tiled" mode).
    private func accumulateAlignedTwoStage(
        indices: [Int],
        scores: [Float],
        shifts: [Int: SIMD2<Float>],
        apGrid: Int,
        keepFractionPerAP: Double,
        progress: @escaping (LuckyStackProgress) -> Void
    ) async throws -> MTLTexture {
        let safeGrid = max(1, apGrid)
        let apCount = safeGrid * safeGrid
        let frameCount = indices.count
        guard frameCount > 0 else {
            return Self.makeAccumulator(device: device, w: W, h: H)
        }

        // Pass 1: per-AP grading.
        // Buffer layout: [frameIdx × apCount + apLinear].
        let perAPBytes = MemoryLayout<Float>.stride * apCount * frameCount
        guard let perAPBuf = device.makeBuffer(length: perAPBytes, options: .storageModeShared) else {
            throw NSError(domain: "Lucky", code: 10)
        }
        // Zero-init.
        memset(perAPBuf.contents(), 0, perAPBytes)

        progress(.stacking(done: 0, total: frameCount * 2))
        for (i, idx) in indices.enumerated() {
            stagingSemaphore.wait()
            let slot = i % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            reader.withFrameBytes(at: idx) { ptr, _ in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
                )
            }
            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }
            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: frameTex)

            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(perAPGradePSO)
                enc.setTexture(frameTex, index: 0)
                enc.setBuffer(perAPBuf, offset: 0, index: 0)
                var p = PerAPQualityParamsCPU(
                    frameIndex: UInt32(i),
                    apGridSize: UInt32(safeGrid),
                    pad0: 0, pad1: 0
                )
                enc.setBytes(&p, length: MemoryLayout<PerAPQualityParamsCPU>.stride, index: 1)
                // 1D dispatch over `apCount` linear AP cells; the
                // shader decodes (x, y) internally. Metal requires
                // matching dimensionality between the threadgroup-
                // position and thread-index attributes.
                let tgSize = MTLSize(width: 256, height: 1, depth: 1)
                let tgCount = MTLSize(width: apCount, height: 1, depth: 1)
                enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
                enc.endEncoding()
            }
            cmd.addCompletedHandler { [weak self] _ in self?.stagingSemaphore.signal() }
            cmd.commit()

            if i % 32 == 0 || i == frameCount - 1 {
                progress(.stacking(done: i + 1, total: frameCount * 2))
            }
        }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }

        // CPU: per-AP CONTINUOUS quality weights.
        //
        // Earlier hard top-K per-AP selection (binary 0/1 mask) made
        // adjacent cells lock onto disjoint frame subsets, biasing
        // their accumulated brightness — visible as blob/tile
        // artifacts even after bilinear AP blending. The fix is to
        // weight EVERY globally-kept frame continuously per AP by a
        // rank-based sigmoid so neighbouring APs see the same frames
        // with smoothly-varying weights. Bilinear blending then sees
        // continuous gradients across cell boundaries, not on/off
        // steps.
        //
        // keepFractionPerAP keeps its meaning as the 50%-point of the
        // sigmoid centred at that rank: best-ranked frames pull
        // toward weight 1, frames well past the rank pull toward 0.
        // Transition width = 10% of frameCount so the taper is
        // selective but not abrupt — the per-AP "luckiness" survives
        // without the visual artifacts.
        let perAPRaw = perAPBuf.contents().assumingMemoryBound(to: Float.self)
        let perAPScores = Array(UnsafeBufferPointer(start: perAPRaw, count: apCount * frameCount))
        let perAPKeepCount = max(1, Int((Double(frameCount) * max(0.01, min(1.0, keepFractionPerAP))).rounded(.up)))
        let kSoft = Float(perAPKeepCount)
        let widthSoft = max(1.0, Float(frameCount) * 0.1)

        var keepMask = [Float](repeating: 0, count: apCount * frameCount)
        for ap in 0..<apCount {
            // Gather frame scores for this AP (frame-major buffer).
            var frameAndScore: [(frameIdx: Int, score: Float)] = []
            frameAndScore.reserveCapacity(frameCount)
            for f in 0..<frameCount {
                let bufIdx = f * apCount + ap
                frameAndScore.append((f, perAPScores[bufIdx]))
            }
            frameAndScore.sort { $0.score > $1.score }

            for r in 0..<frameCount {
                let f = frameAndScore[r].frameIdx
                // 1/(1+e^x): rank 0 → ~1, rank=kSoft → 0.5, rank≫kSoft → ~0.
                let arg = (Float(r) - kSoft) / widthSoft
                keepMask[ap * frameCount + f] = 1.0 / (1.0 + exp(arg))
            }
        }

        guard let keepBuf = device.makeBuffer(
            bytes: keepMask,
            length: MemoryLayout<Float>.stride * keepMask.count,
            options: .storageModeShared
        ) else {
            throw NSError(domain: "Lucky", code: 11)
        }

        // Pass 2: per-AP keep accumulator + per-pixel weight tracking.
        let accum = Self.makeAccumulator(device: device, w: W, h: H)
        let wtTex = Self.makeFloatBuffer(device: device, w: W, h: H, format: .rgba32Float)

        for (i, idx) in indices.enumerated() {
            stagingSemaphore.wait()
            let slot = i % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            reader.withFrameBytes(at: idx) { ptr, _ in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
                )
            }
            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }
            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: frameTex)

            let shift = shifts[idx] ?? SIMD2<Float>(0, 0)
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(perAPAccumPSO)
                enc.setTexture(frameTex, index: 0)
                enc.setTexture(accum, index: 1)
                enc.setTexture(wtTex, index: 2)
                enc.setBuffer(keepBuf, offset: 0, index: 0)
                var p = LuckyPerAPParamsCPU(
                    weight: 1.0,            // uniform within keep set; v1 adds per-AP quality weighting
                    apGridSize: UInt32(safeGrid),
                    frameIndex: UInt32(i),
                    frameCount: UInt32(frameCount),
                    shift: shift,
                    pad0: SIMD2<Float>(0, 0)
                )
                enc.setBytes(&p, length: MemoryLayout<LuckyPerAPParamsCPU>.stride, index: 1)
                let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: perAPAccumPSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }
            cmd.addCompletedHandler { [weak self] _ in self?.stagingSemaphore.signal() }
            cmd.commit()

            if i % 32 == 0 || i == frameCount - 1 {
                progress(.stacking(done: frameCount + i + 1, total: frameCount * 2))
            }
        }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }

        // Final per-pixel divide.
        if let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(perPixelNormPSO)
            enc.setTexture(accum, index: 0)
            enc.setTexture(wtTex, index: 1)
            var p = LuckyDivideParamsCPU(weightFloor: 1e-6)
            enc.setBytes(&p, length: MemoryLayout<LuckyDivideParamsCPU>.stride, index: 0)
            let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: perPixelNormPSO)
            enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        return accum
    }

    /// Drizzle accumulation (Fruchter & Hook 2002, B.6).
    ///
    /// Allocates an upsampled accumulator + per-pixel weight texture
    /// (`scale × W` × `scale × H`) and splats each kept frame's
    /// pixels onto the larger grid. The per-pixel weight tracks how
    /// much drop coverage every output pixel received; the final
    /// divide produces a clean output buffer at the upsampled
    /// dimensions.
    ///
    /// v0 is integer-scale only (2× / 3×). Sub-pixel shifts are
    /// honoured via the per-output reverse mapping in the splat
    /// kernel.
    private func accumulateAlignedDrizzled(
        indices: [Int],
        scores: [Float],
        shifts: [Int: SIMD2<Float>],
        scale: Int,
        pixfrac: Float,
        progress: @escaping (LuckyStackProgress) -> Void
    ) async throws -> MTLTexture {
        precondition(scale >= 1, "drizzle scale must be ≥ 1")

        let outW = W * scale
        let outH = H * scale
        let accum = Self.makeFloatBuffer(device: device, w: outW, h: outH, format: .rgba16Float)
        let wtTex = Self.makeFloatBuffer(device: device, w: outW, h: outH, format: .rgba32Float)

        // Quality weighting curve (mirrors accumulateAligned).
        let keptScores = indices.map { scores[$0] }
        let lo = keptScores.min() ?? 0
        let hi = keptScores.max() ?? 1
        let span = max(1e-6, hi - lo)
        @inline(__always) func qualityWeight(_ score: Float) -> Float {
            let t = (score - lo) / span
            let shaped = t * t
            return 0.05 + shaped * 1.45
        }

        progress(.stacking(done: 0, total: indices.count))
        for (i, idx) in indices.enumerated() {
            stagingSemaphore.wait()
            let slot = i % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            reader.withFrameBytes(at: idx) { ptr, _ in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
                )
            }
            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }
            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: frameTex)

            let shift = shifts[idx] ?? SIMD2<Float>(0, 0)
            let weight = qualityWeight(scores[idx])
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(drizzlePSO)
                enc.setTexture(frameTex, index: 0)
                enc.setTexture(accum, index: 1)
                enc.setTexture(wtTex, index: 2)
                var p = LuckyDrizzleParamsCPU(
                    weight: weight,
                    pixfrac: pixfrac,
                    scale: UInt32(scale),
                    pad0: 0,
                    shift: shift,
                    inputSize: SIMD2<UInt32>(UInt32(W), UInt32(H))
                )
                enc.setBytes(&p, length: MemoryLayout<LuckyDrizzleParamsCPU>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: drizzlePSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }
            cmd.addCompletedHandler { [weak self] _ in self?.stagingSemaphore.signal() }
            cmd.commit()

            if i % 32 == 0 || i == indices.count - 1 {
                progress(.stacking(done: i + 1, total: indices.count))
            }
        }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }

        // Per-pixel divide: out = accum / weight.
        if let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(perPixelNormPSO)
            enc.setTexture(accum, index: 0)
            enc.setTexture(wtTex, index: 1)
            var p = LuckyDivideParamsCPU(weightFloor: 1e-6)
            enc.setBytes(&p, length: MemoryLayout<LuckyDivideParamsCPU>.stride, index: 0)
            let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: perPixelNormPSO)
            enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        return accum
    }

    /// Two-pass sigma-clipped accumulation.
    ///
    /// Pass 1 builds a per-pixel running (mean, M2) via Welford. Pass
    /// 2 re-reads each kept frame, samples at the same shift, and
    /// only adds the sample to the output when its per-channel
    /// deviation is within `sigmaThreshold · σ` of the running mean.
    /// A per-pixel weight texture tracks how many frames actually
    /// contributed; the final pass divides accum by weight per pixel.
    ///
    /// Multi-AP refinement is OFF in this path for v0 — combining
    /// sigma-clip with per-AP local quality lands in a later block.
    /// Quality-weighted contributions are preserved (`qualityWeight`
    /// shaping mirrors the standard accumulator).
    private func accumulateAlignedSigmaClipped(
        indices: [Int],
        scores: [Float],
        shifts: [Int: SIMD2<Float>],
        sigmaThreshold: Float,
        progress: @escaping (LuckyStackProgress) -> Void
    ) async throws -> MTLTexture {
        // Allocate scratch buffers. mean / M2 stay in rgba32Float for
        // precision on the squared-deviation accumulator; the actual
        // accum + weightTex match the existing rgba16Float / rgba32Float
        // pipeline shape so the final divide writes back into the
        // same accum that callers expect to receive.
        let meanTex = Self.makeFloatBuffer(device: device, w: W, h: H, format: .rgba32Float)
        let m2Tex   = Self.makeFloatBuffer(device: device, w: W, h: H, format: .rgba32Float)
        let accum   = Self.makeAccumulator(device: device, w: W, h: H)
        let wtTex   = Self.makeFloatBuffer(device: device, w: W, h: H, format: .rgba32Float)

        // ---- Pass 1: Welford ----
        progress(.stacking(done: 0, total: indices.count * 2))
        for (i, idx) in indices.enumerated() {
            stagingSemaphore.wait()
            let slot = i % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            reader.withFrameBytes(at: idx) { ptr, _ in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
                )
            }
            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }
            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: frameTex)

            let shift = shifts[idx] ?? SIMD2<Float>(0, 0)
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(welfordPSO)
                enc.setTexture(frameTex, index: 0)
                enc.setTexture(meanTex, index: 1)
                enc.setTexture(m2Tex, index: 2)
                var p = LuckyWelfordParamsCPU(
                    frameNumber: UInt32(i + 1),
                    pad0: 0,
                    shift: shift
                )
                enc.setBytes(&p, length: MemoryLayout<LuckyWelfordParamsCPU>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: meanTex, pso: welfordPSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }
            cmd.addCompletedHandler { [weak self] _ in self?.stagingSemaphore.signal() }
            cmd.commit()

            if i % 32 == 0 || i == indices.count - 1 {
                progress(.stacking(done: i + 1, total: indices.count * 2))
            }
        }
        // Drain in-flight slots so the Welford state is fully realised.
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }

        // ---- Pass 2: Clipped accumulate ----
        let keptScores = indices.map { scores[$0] }
        let lo = keptScores.min() ?? 0
        let hi = keptScores.max() ?? 1
        let span = max(1e-6, hi - lo)
        @inline(__always) func qualityWeight(_ score: Float) -> Float {
            let t = (score - lo) / span
            let shaped = t * t
            return 0.05 + shaped * 1.45
        }

        let frameCount = UInt32(indices.count)
        for (i, idx) in indices.enumerated() {
            stagingSemaphore.wait()
            let slot = i % options.stagingPoolSize
            let staging = stagingTextures[slot]
            let frameTex = frameTextures[slot]

            reader.withFrameBytes(at: idx) { ptr, _ in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
                )
            }
            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }
            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: frameTex)

            let shift = shifts[idx] ?? SIMD2<Float>(0, 0)
            let weight = qualityWeight(scores[idx])
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(clippedAccumPSO)
                enc.setTexture(frameTex, index: 0)
                enc.setTexture(meanTex, index: 1)
                enc.setTexture(m2Tex, index: 2)
                enc.setTexture(accum, index: 3)
                enc.setTexture(wtTex, index: 4)
                var p = LuckyClipParamsCPU(
                    weight: weight,
                    sigmaThreshold: sigmaThreshold,
                    frameCount: frameCount,
                    pad0: 0,
                    shift: shift,
                    pad1: SIMD2<Float>(0, 0)
                )
                enc.setBytes(&p, length: MemoryLayout<LuckyClipParamsCPU>.stride, index: 0)
                let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: clippedAccumPSO)
                enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
                enc.endEncoding()
            }
            cmd.addCompletedHandler { [weak self] _ in self?.stagingSemaphore.signal() }
            cmd.commit()

            if i % 32 == 0 || i == indices.count - 1 {
                progress(.stacking(done: indices.count + i + 1, total: indices.count * 2))
            }
        }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.wait() }
        for _ in 0..<options.stagingPoolSize { stagingSemaphore.signal() }

        // ---- Pass 3: per-pixel divide ----
        if let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(perPixelNormPSO)
            enc.setTexture(accum, index: 0)
            enc.setTexture(wtTex, index: 1)
            var p = LuckyDivideParamsCPU(weightFloor: 1e-6)
            enc.setBytes(&p, length: MemoryLayout<LuckyDivideParamsCPU>.stride, index: 0)
            let (tgC, tgS) = dispatchThreadgroups(for: accum, pso: perPixelNormPSO)
            enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        return accum
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

// MARK: - Quality grading helper

private final class QualityGrader {
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
        let stride = MemoryLayout<QualityPartialResult>.stride
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
        let ptr = partialsBuffer.contents().assumingMemoryBound(to: QualityPartialResult.self)
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

// MARK: - Layout-mirror structs (must match Shaders.metal)

private struct QualityPartialResult {
    var sum: Float
    var sumSq: Float
    var count: UInt32
    var pad: UInt32
}

private struct LuckyAccumParams {
    var weight: Float
    var shift: SIMD2<Float>
}

private struct UnpackParamsCPU {
    var scale: Float
    var flip: UInt32
}
private struct BayerUnpackParamsCPU {
    var scale: Float
    var flip: UInt32
    var pattern: UInt32
}

/// Mirrors APSearchParams in Shaders.metal exactly.
private struct APSearchParamsCPU {
    var patchHalf: UInt32 = 8
    var searchRadius: Int32 = 8
    var gridSize: SIMD2<UInt32> = .init(8, 8)
    var globalShift: SIMD2<Float> = .zero

    init(patchHalf: UInt32 = 8, searchRadius: Int32 = 8, gridSize: SIMD2<UInt32>, globalShift: SIMD2<Float>) {
        self.patchHalf = patchHalf
        self.searchRadius = searchRadius
        self.gridSize = gridSize
        self.globalShift = globalShift
    }
}

private struct LuckyAccumLocalParamsCPU {
    var weight: Float
    var globalShift: SIMD2<Float>
}

private func nextPow2(_ n: Int) -> Int {
    var v = max(1, n)
    v -= 1
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16
    return min(1024, v + 1)
}

private struct LuckyNormalizeParams {
    var invTotalWeight: Float
}

// MARK: - Two-stage quality CPU param structs (A.2)

private struct PerAPQualityParamsCPU {
    var frameIndex: UInt32
    var apGridSize: UInt32
    var pad0: UInt32
    var pad1: UInt32
}

private struct LuckyPerAPParamsCPU {
    var weight: Float
    var apGridSize: UInt32
    var frameIndex: UInt32
    var frameCount: UInt32
    var shift: SIMD2<Float>
    var pad0: SIMD2<Float>
}

// MARK: - Drizzle CPU param struct (B.6)

private struct LuckyDrizzleParamsCPU {
    var weight: Float
    var pixfrac: Float
    var scale: UInt32
    var pad0: Float
    var shift: SIMD2<Float>
    var inputSize: SIMD2<UInt32>
}

// MARK: - Sigma-clipped CPU param structs (B.1)
//
// Exactly mirror the LuckyWelfordParams / LuckyClipParams /
// LuckyDivideParams structs in Shaders.metal. Keep field order, sizes,
// and pad slots identical so the GPU sees the same byte layout the
// CPU writes via setBytes().

private struct LuckyWelfordParamsCPU {
    var frameNumber: UInt32
    var pad0: Float
    var shift: SIMD2<Float>
}

private struct LuckyClipParamsCPU {
    var weight: Float
    var sigmaThreshold: Float
    var frameCount: UInt32
    var pad0: Float
    var shift: SIMD2<Float>
    var pad1: SIMD2<Float>
}

private struct LuckyDivideParamsCPU {
    var weightFloor: Float
}

// MARK: - Phase correlation (CPU FFT on small luma buffers)

struct PhaseShift { let dx: Float; let dy: Float }

/// Holds a pre-built FFTSetup for parallel use across alignment threads.
/// vDSP setups are thread-safe to share once created (read-only state), so
/// one instance covers all concurrent correlations at a given log2n.
final class SharedCPUFFT {
    let log2n: Int
    let setup: FFTSetup

    init(log2n: Int) {
        self.log2n = log2n
        self.setup = vDSP_create_fftsetup(vDSP_Length(log2n + 1), FFTRadix(kFFTRadix2))!
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func phaseCorrelate(ref: [Float], frame: [Float], n: Int) -> PhaseShift? {
        var refReal = ref
        var refImag = [Float](repeating: 0, count: n * n)
        var frmReal = frame
        var frmImag = [Float](repeating: 0, count: n * n)

        func fft2d(_ real: inout [Float], _ imag: inout [Float], inverse: Bool) {
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft2d_zip(setup, &split, 1, 0, vDSP_Length(log2n), vDSP_Length(log2n),
                                   inverse ? FFTDirection(FFT_INVERSE) : FFTDirection(FFT_FORWARD))
                }
            }
        }
        fft2d(&refReal, &refImag, inverse: false)
        fft2d(&frmReal, &frmImag, inverse: false)

        let count = n * n
        var cpReal = [Float](repeating: 0, count: count)
        var cpImag = [Float](repeating: 0, count: count)
        for k in 0..<count {
            let fr = refReal[k], fi = refImag[k]
            let gr = frmReal[k], gi = -frmImag[k]
            let re = fr * gr - fi * gi
            let im = fr * gi + fi * gr
            let mag = max(sqrtf(re * re + im * im), 1e-12)
            cpReal[k] = re / mag
            cpImag[k] = im / mag
        }
        fft2d(&cpReal, &cpImag, inverse: true)

        var peakVal: Float = -.infinity
        var peakIdx = 0
        for k in 0..<count where cpReal[k] > peakVal { peakVal = cpReal[k]; peakIdx = k }
        let py = peakIdx / n
        let px = peakIdx % n

        func sample(_ x: Int, _ y: Int) -> Float {
            let xi = (x + n) % n
            let yi = (y + n) % n
            return cpReal[yi * n + xi]
        }
        let cx = sample(px, py)
        let lx = sample(px - 1, py)
        let rx = sample(px + 1, py)
        let ly = sample(px, py - 1)
        let ry = sample(px, py + 1)
        func sub(_ l: Float, _ c: Float, _ r: Float) -> Float {
            let denom = l - 2 * c + r
            if abs(denom) < 1e-8 { return 0 }
            return max(-0.5, min(0.5, 0.5 * (l - r) / denom))
        }
        return PhaseShift(dx: Float(px) + sub(lx, cx, rx), dy: Float(py) + sub(ly, cx, ry))
    }
}

private func phaseCorrelate(ref: [Float], frame: [Float], n: Int) -> PhaseShift? {
    let log2n = Int(log2(Double(n)))
    guard 1 << log2n == n else { return nil }

    var refReal = ref
    var refImag = [Float](repeating: 0, count: n * n)
    var frmReal = frame
    var frmImag = [Float](repeating: 0, count: n * n)

    guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n + 1), FFTRadix(kFFTRadix2)) else { return nil }
    defer { vDSP_destroy_fftsetup(setup) }

    func fft2d(_ real: inout [Float], _ imag: inout [Float], inverse: Bool) {
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0, vDSP_Length(log2n), vDSP_Length(log2n), inverse ? FFTDirection(FFT_INVERSE) : FFTDirection(FFT_FORWARD))
            }
        }
    }
    fft2d(&refReal, &refImag, inverse: false)
    fft2d(&frmReal, &frmImag, inverse: false)

    let count = n * n
    var cpReal = [Float](repeating: 0, count: count)
    var cpImag = [Float](repeating: 0, count: count)
    for k in 0..<count {
        let fr = refReal[k], fi = refImag[k]
        let gr = frmReal[k], gi = -frmImag[k]
        let re = fr * gr - fi * gi
        let im = fr * gi + fi * gr
        let mag = max(sqrtf(re * re + im * im), 1e-12)
        cpReal[k] = re / mag
        cpImag[k] = im / mag
    }
    fft2d(&cpReal, &cpImag, inverse: true)

    var peakVal: Float = -.infinity
    var peakIdx = 0
    for k in 0..<count {
        let v = cpReal[k]
        if v > peakVal { peakVal = v; peakIdx = k }
    }
    let py = peakIdx / n
    let px = peakIdx % n

    func sample(_ x: Int, _ y: Int) -> Float {
        let xi = (x + n) % n
        let yi = (y + n) % n
        return cpReal[yi * n + xi]
    }
    let cx = sample(px, py)
    let lx = sample(px - 1, py)
    let rx = sample(px + 1, py)
    let ly = sample(px, py - 1)
    let ry = sample(px, py + 1)
    func sub(_ l: Float, _ c: Float, _ r: Float) -> Float {
        let denom = l - 2 * c + r
        if abs(denom) < 1e-8 { return 0 }
        return max(-0.5, min(0.5, 0.5 * (l - r) / denom))
    }

    var dx = Float(px) + sub(lx, cx, rx)
    var dy = Float(py) + sub(ly, cx, ry)
    if dx > Float(n / 2) { dx -= Float(n) }
    if dy > Float(n / 2) { dy -= Float(n) }
    return PhaseShift(dx: dx, dy: dy)
}

// MARK: - Misc

private extension Array where Element: Comparable {
    func argmax() -> Int {
        guard !isEmpty else { return 0 }
        var best = 0
        for i in 1..<count where self[i] > self[best] { best = i }
        return best
    }
}
