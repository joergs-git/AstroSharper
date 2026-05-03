// Quality / sharpness probing for preview HUD and lucky-stack recommendations.
//
// SharpnessProbe computes a single scalar (variance-of-Laplacian) per
// MTLTexture using two MPS passes — robust under exposure changes and
// trivially cheap (~1 ms on a 4 K frame).
//
// SerQualityScanner samples up to 64 evenly-spaced frames from a SER file,
// runs the probe on each, builds a distribution, and derives a recommended
// "keep top N%" lucky-stack threshold based on the spread of per-frame
// sharpness scores.
//
// Both are deliberately format-agnostic at the API level: the probe takes
// any RGBA texture (the existing pipeline's beforeTex / afterTex types).
import Foundation
import Metal
import MetalPerformanceShaders

// MARK: - Stats payload exposed to the UI

/// All the information the HUD shows for the active preview entry. Built
/// up incrementally as info becomes available: header info first, then the
/// current-frame sharpness, then the SER distribution + recommendation.
struct PreviewStats: Equatable {
    var fileName: String = ""
    var fileSizeBytes: Int64 = 0
    var dimensions: (width: Int, height: Int)? = nil
    var bitDepth: Int? = nil          // 8 or 16 for SER, nil otherwise
    var bayerLabel: String? = nil     // "RGGB" / "GRBG" / "Mono" / "RGB"
    var captureDate: Date? = nil      // SER header UTC, otherwise file mtime
    var totalFrames: Int = 1          // 1 for stills, N for SER
    var currentFrame: Int = 1         // 1-based for display
    var currentSharpness: Float? = nil

    // Distribution (SER only, populated by scanner).
    var distribution: SharpnessDistribution? = nil

    /// Non-blocking findings from `CaptureValidator.validate`. Populated
    /// when a SER (or AVI with header equivalents) is loaded; the HUD
    /// surfaces them as inline yellow chips so the user catches a
    /// suboptimal capture before they spend time stacking it. Not
    /// participating in `==` is intentional — warning-array order may
    /// shuffle harmlessly across loads.
    var captureWarnings: [CaptureWarning] = []

    // MARK: Equatable
    static func == (a: PreviewStats, b: PreviewStats) -> Bool {
        a.fileName == b.fileName &&
        a.fileSizeBytes == b.fileSizeBytes &&
        a.dimensions?.width == b.dimensions?.width &&
        a.dimensions?.height == b.dimensions?.height &&
        a.bitDepth == b.bitDepth &&
        a.bayerLabel == b.bayerLabel &&
        a.captureDate == b.captureDate &&
        a.totalFrames == b.totalFrames &&
        a.currentFrame == b.currentFrame &&
        a.currentSharpness == b.currentSharpness &&
        a.distribution == b.distribution &&
        a.captureWarnings == b.captureWarnings
    }
}

struct SharpnessDistribution: Equatable, Codable {
    let sampleCount: Int
    /// Total frames in the source SER. Used by the keep-% recommender to
    /// enforce the absolute / typical frame-count floors on the actual
    /// stack size, not the 64-sample probe scan.
    let totalFrames: Int
    let median: Float
    let p10: Float
    let p90: Float
    let min: Float
    let max: Float
    /// RMS frame-to-frame shift (pixels) measured by phase-correlating
    /// adjacent sampled frames. nil when fewer than two samples succeeded.
    /// Higher = more atmospheric jitter; informational signal that the
    /// lucky-stack registration step has more work to do.
    var jitterRMS: Float? = nil
    /// Recommended fraction (0…1) of best frames to keep when stacking.
    let recommendedKeepFraction: Double
    /// Recommended absolute frame count to keep — `recommendedKeepFraction
    /// × totalFrames`, lifted to the floor when the fraction would drop
    /// the count below ~100 frames. Always >= 50 even for tiny SERs.
    let recommendedKeepCount: Int
    /// Human-readable recommendation rationale, includes both the
    /// percentage and the absolute count so the user can sanity-check
    /// without doing arithmetic.
    let recommendationText: String
}

// MARK: - Sharpness probe

/// Variance of Diagonal Laplacian (LAPD) — a scale-invariant, contrast-
/// sensitive proxy for image sharpness. Higher = sharper.
///
/// LAPD uses an 8-neighbour kernel weighted by 1/distance² (cardinal
/// neighbours = 1.0, diagonal neighbours = 0.5, centre = -6). Versus
/// the classic 4-neighbour cross Laplacian, LAPD picks up edges at any
/// orientation rather than penalising diagonals — empirically better
/// in seeing-limited regimes per MDPI 2076-3417/13/4/2652. The probe
/// reduces the LAPD field to a single variance via
/// `MPSImageStatisticsMeanAndVariance` so the legacy "single Float per
/// frame" API is preserved.
///
/// Performance notes
/// -----------------
/// • **Shared instance**: callers should use `SharpnessProbe.shared` instead
///   of constructing one per file. The probe owns a Metal command queue and
///   a small texture cache; allocating both on every static-image import
///   wastes more time than the actual GPU work.
/// • **Texture cache**: the destination textures (Laplacian + stats) are
///   keyed by `(width, height, pixelFormat)` so repeat calls on a SER's
///   evenly-shaped frames reuse the same allocations. Per-call allocation
///   was the dominant cost in batch scans, not the GPU passes themselves.
/// • Calls are thread-safe — guarded by an internal lock — so the probe
///   can be shared across `Task.detached` workers (AppModel's thumbnail
///   loader does exactly this).
final class SharpnessProbe {
    /// Shared instance. Use this everywhere — `init(device:)` is kept for
    /// tests and one-off cases that need an isolated queue.
    static let shared = SharpnessProbe(device: MetalDevice.shared.device)

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let lapdPSO: MTLComputePipelineState
    private let stats: MPSImageStatisticsMeanAndVariance

    // Cache temp textures by (width, height, sourcePixelFormat). All probe
    // calls on the same-shaped input reuse the same destinations. Bounded
    // by the number of unique input shapes the user opens — in practice 1-3.
    private struct CacheKey: Hashable {
        let w: Int; let h: Int; let format: MTLPixelFormat
    }
    private struct CacheEntry { let lap: MTLTexture; let stats: MTLTexture }
    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheLock = NSLock()

    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        guard let lib = MetalDevice.shared.library,
              let fn = lib.makeFunction(name: "compute_lapd_field"),
              let pso = try? device.makeComputePipelineState(function: fn)
        else {
            fatalError("SharpnessProbe: missing compute_lapd_field kernel")
        }
        self.lapdPSO = pso
        self.stats = MPSImageStatisticsMeanAndVariance(device: device)
    }

    /// Synchronous compute. Returns NaN if anything fails — callers can
    /// treat that as "no data available".
    func compute(texture src: MTLTexture) -> Float {
        let key = CacheKey(w: src.width, h: src.height, format: src.pixelFormat)
        cacheLock.lock()
        var entry = cache[key]
        if entry == nil {
            guard let pair = makeEntry(for: src) else {
                cacheLock.unlock()
                return .nan
            }
            cache[key] = pair
            entry = pair
        }
        // Hold the lock through encode + wait so two threads probing
        // same-shaped textures don't trample each other on the cached
        // statsTex.getBytes. Probe runs ~1 ms so contention is negligible.
        defer { cacheLock.unlock() }
        guard
            let cmd = commandQueue.makeCommandBuffer(),
            let e = entry,
            let enc = cmd.makeComputeCommandEncoder()
        else { return .nan }

        // Pass 1: per-pixel LAPD field.
        enc.setComputePipelineState(lapdPSO)
        enc.setTexture(src, index: 0)
        enc.setTexture(e.lap, index: 1)
        let tgw = lapdPSO.threadExecutionWidth
        let tgh = lapdPSO.maxTotalThreadsPerThreadgroup / tgw
        let tgSize = MTLSize(width: tgw, height: tgh, depth: 1)
        let tgCount = MTLSize(
            width: (src.width  + tgw - 1) / tgw,
            height: (src.height + tgh - 1) / tgh,
            depth: 1
        )
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()

        // Pass 2: variance reduction over the LAPD field.
        stats.encode(commandBuffer: cmd, sourceTexture: e.lap, destinationTexture: e.stats)
        cmd.commit()
        cmd.waitUntilCompleted()

        // Variance pixel sits at (1,0). Average RGB so mono and Bayer
        // sources produce comparable numbers; alpha is ignored.
        var pix = [Float](repeating: 0, count: 4)
        e.stats.getBytes(&pix,
                         bytesPerRow: 4 * MemoryLayout<Float>.size,
                         from: MTLRegionMake2D(1, 0, 1, 1),
                         mipmapLevel: 0)
        let v = (pix[0] + pix[1] + pix[2]) / 3.0
        return v.isFinite ? v : 0
    }

    // MARK: - CPU reference (unit-testable, GPU-independent)

    /// CPU implementation of the LAPD operator that mirrors
    /// `compute_lapd_field` / `laplacian_at` in Shaders.metal byte-for-byte.
    /// Used by the test target to assert kernel correctness and by any
    /// host-tool that wants a sharpness number without booting Metal.
    ///
    /// `pixels` is a row-major luminance buffer of size `width * height`.
    /// Returns the variance of the LAPD field — the same scalar the GPU
    /// path produces (modulo float rounding), so the two can be diffed
    /// in regression tests on synthetic inputs.
    static func referenceVarianceOfLAPD(
        luma pixels: [Float],
        width: Int,
        height: Int
    ) -> Float {
        precondition(pixels.count == width * height, "buffer size mismatch")
        guard width >= 3, height >= 3 else { return 0 }

        // Pass 1: build the LAPD field (border pixels = 0).
        var lapd = [Float](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let c  = pixels[y * width + x]
                let l  = pixels[y * width + (x - 1)]
                let r  = pixels[y * width + (x + 1)]
                let t  = pixels[(y - 1) * width + x]
                let b  = pixels[(y + 1) * width + x]
                let tl = pixels[(y - 1) * width + (x - 1)]
                let tr = pixels[(y - 1) * width + (x + 1)]
                let bl = pixels[(y + 1) * width + (x - 1)]
                let br = pixels[(y + 1) * width + (x + 1)]
                lapd[y * width + x] =
                    (l + r + t + b) + 0.5 * (tl + tr + bl + br) - 6.0 * c
            }
        }

        // Pass 2: variance over the whole field (matches the GPU path's
        // MPSImageStatisticsMeanAndVariance reduction, which divides by N
        // including border zeros).
        let n = Float(pixels.count)
        var sum: Float = 0
        for v in lapd { sum += v }
        let mean = sum / n
        var sumSq: Float = 0
        for v in lapd { let d = v - mean; sumSq += d * d }
        return sumSq / n
    }

    private func makeEntry(for src: MTLTexture) -> CacheEntry? {
        let lapDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: src.pixelFormat,
            width: src.width,
            height: src.height,
            mipmapped: false
        )
        lapDesc.usage = [.shaderRead, .shaderWrite]
        lapDesc.storageMode = .private
        guard let lapTex = device.makeTexture(descriptor: lapDesc) else { return nil }

        // Stats destination is documented to require RGBA32Float, 2x1.
        let statsDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: 2, height: 1,
            mipmapped: false
        )
        statsDesc.usage = [.shaderRead, .shaderWrite]
        statsDesc.storageMode = .shared
        guard let statsTex = device.makeTexture(descriptor: statsDesc) else { return nil }
        return CacheEntry(lap: lapTex, stats: statsTex)
    }
}

// MARK: - SER quality scanner

/// Background scan of a SER file: samples frames, runs SharpnessProbe on
/// each, produces a SharpnessDistribution + recommendation. Cancellable.
@MainActor
final class SerQualityScanner {
    typealias ProgressHandler = (PreviewStats) -> Void

    private var task: Task<Void, Never>?

    /// Scan `url` (assumed to be a valid SER) and incrementally fill in the
    /// distribution side of `seedStats`. The handler is called on the main
    /// actor whenever new data is ready (initial header info, then once at
    /// the end with the full distribution).
    func scan(url: URL, seedStats: PreviewStats, handler: @escaping ProgressHandler) {
        cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            guard self != nil else { return }
            guard let reader = try? SerReader(url: url) else { return }
            let header = reader.header
            let total = header.frameCount
            // Sample up to 64 evenly spaced frames; for short SERs use all.
            let sampleCount = min(64, total)
            guard sampleCount > 0 else { return }
            // Use the shared probe so the texture cache is reused across
            // every sample in this scan (all SER frames are same-shaped, so
            // the cache hits 63 out of 64 calls).
            let probe = SharpnessProbe.shared

            var scores: [Float] = []
            scores.reserveCapacity(sampleCount)
            // Squared shift magnitudes between adjacent samples — squared so
            // we can finalise as RMS without an extra pass. Each pair only
            // costs one new FFT (the prior sample's FFT is reused as the
            // reference) plus the cross-power-spectrum + IFFT step, instead
            // of two FFTs per pair as in the naïve path.
            var shiftSqSum: Double = 0
            var shiftCount: Int = 0
            var prevFFT: Align.FrameFFT? = nil
            for i in 0..<sampleCount {
                if Task.isCancelled { return }
                // Even spacing: pick frame indices across the full range.
                let frac = (Double(i) + 0.5) / Double(sampleCount)
                let frameIdx = min(total - 1, Int(frac * Double(total)))
                guard let tex = try? SerFrameLoader.loadFrame(
                    url: url,
                    frameIndex: frameIdx,
                    device: MetalDevice.shared.device
                ) else { continue }
                let s = probe.compute(texture: tex)
                if s.isFinite { scores.append(s) }
                // Compute the FFT once per sample. It serves as the "frame"
                // FFT for this pair and the "reference" FFT for the next.
                let curFFT = Align.computeFFT(of: tex)
                if let prev = prevFFT, let cur = curFFT,
                   let shift = Align.phaseCorrelate(refFFT: prev, frameFFT: cur) {
                    let mag2 = Double(shift.dx * shift.dx + shift.dy * shift.dy)
                    if mag2.isFinite {
                        shiftSqSum += mag2
                        shiftCount += 1
                    }
                }
                prevFFT = curFFT
            }
            if Task.isCancelled || scores.isEmpty { return }

            let jitter: Float? = shiftCount > 0
                ? Float((shiftSqSum / Double(shiftCount)).squareRoot())
                : nil
            let dist = Self.makeDistribution(
                scores: scores,
                totalFrames: total,
                jitterRMS: jitter
            )
            await MainActor.run {
                var stats = seedStats
                stats.distribution = dist
                handler(stats)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Translate the raw sample distribution into a "keep top N% (M of T
    /// frames)" recommendation that's anchored in lucky-imaging norms,
    /// not the bare p90/p10 spread.
    ///
    /// Algorithm:
    ///
    ///   1. Knee detection — find the percentile `p` where sharpness
    ///      drops below `0.5 × p90`. The fraction of frames *above* the
    ///      knee is the natural "sharp tail" that lucky imaging targets.
    ///   2. Clamp to scientific norms: between 5% and 50% of frames.
    ///      The legacy 75% default was wrong — a "tight" distribution
    ///      typically means uniformly-mediocre seeing, not uniformly-
    ///      sharp; either way 50% of-the-frames-or-fewer is the right
    ///      anchor (BiggSky's documented default is 25%).
    ///   3. Frame-count floor: SNR ∝ √N. Recommend at least 100 frames
    ///      (when the SER has them) and never less than 50, regardless
    ///      of the percentage that implies.
    ///   4. Jitter tightening — RMS frame-to-frame shift > 15 px tightens
    ///      the band by 30% so registration has less drift to fight.
    ///   5. Display both percentage and count so the user can sanity-
    ///      check without arithmetic.
    nonisolated private static func makeDistribution(
        scores: [Float],
        totalFrames: Int,
        jitterRMS: Float? = nil
    ) -> SharpnessDistribution {
        let sorted = scores.sorted()
        func percentile(_ p: Double) -> Float {
            guard !sorted.isEmpty else { return 0 }
            let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
            return sorted[idx]
        }
        let p10 = percentile(0.10)
        let p50 = percentile(0.50)
        let p90 = percentile(0.90)
        let lo  = sorted.first ?? 0
        let hi  = sorted.last  ?? 0

        let rec = computeKeepRecommendation(
            sortedScores: sorted,
            totalFrames: totalFrames,
            p90: p90,
            jitterRMS: jitterRMS
        )

        return SharpnessDistribution(
            sampleCount: sorted.count,
            totalFrames: totalFrames,
            median: p50, p10: p10, p90: p90, min: lo, max: hi,
            jitterRMS: jitterRMS,
            recommendedKeepFraction: rec.fraction,
            recommendedKeepCount: rec.count,
            recommendationText: rec.text
        )
    }

    /// Pure, testable keep-% formula. Surfaced as `internal` (not
    /// private) so the unit tests in AstroSharperTests can validate
    /// it on synthetic distributions without booting Metal or building
    /// a SerReader.
    ///
    /// Empirical clamp range [0.20, 0.75] is anchored on the BiggSky
    /// reference dataset (2026-04-29):
    ///   - Saturn good seeing, 28 manual APs: 75% keep
    ///   - Jupiter f/14, 141 APs: 75% keep
    ///   - Mars opposition, 28 APs: 67% keep
    ///   - Jupiter (12" SCT), 31 auto APs: 65% keep
    ///   - Jupiter UL16 F/20, 146 APs: 20% keep (high frame count, cherry pick)
    /// The previous [0.05, 0.50] band saturated at 50% on every tight
    /// distribution and bottomed at 5% on very wide ones — both ends
    /// outside the empirically-verified BiggSky norm.
    ///
    /// Guarantees:
    ///   * Result fraction is in [0.20, 0.75] inclusive (excluding the
    ///     empty-sample fallback which uses 25%).
    ///   * Result count is at least `min(totalFrames, 50)`.
    ///   * When `totalFrames >= 100`, result count is at least 100
    ///     (typical SNR floor).
    ///   * When `sortedScores` is empty, returns the BiggSky default
    ///     25% fraction with the floor applied.
    nonisolated static func computeKeepRecommendation(
        sortedScores: [Float],
        totalFrames: Int,
        p90: Float,
        jitterRMS: Float?
    ) -> (fraction: Double, count: Int, text: String) {
        let absoluteFloor = 50
        let typicalFloor  = min(totalFrames, 100)
        let lowerBound = 0.20
        let upperBound = 0.75

        // Empty / degenerate input → BiggSky 25% default + floor.
        guard !sortedScores.isEmpty, totalFrames > 0 else {
            let count = max(absoluteFloor, min(totalFrames, max(typicalFloor, totalFrames / 4)))
            let frac  = totalFrames > 0 ? Double(count) / Double(totalFrames) : 0.25
            return (frac, count, "Keep top \(Int((frac * 100).rounded()))% (\(count) of \(totalFrames) frames) — default; no quality samples available.")
        }

        // Knee detection on the ASCENDING sorted scores.
        let kneeThreshold = 0.5 * p90
        let kneeIdx = sortedScores.firstIndex { $0 >= kneeThreshold } ?? sortedScores.count
        let aboveKneeCount = sortedScores.count - kneeIdx
        let kneeFraction = Double(aboveKneeCount) / Double(sortedScores.count)

        // Jitter tightening — applied to the raw kneeFraction BEFORE
        // the empirical clamp, so a high-jitter capture lands lower in
        // the [0.20, 0.75] band rather than getting masked by the floor.
        var rawFraction = kneeFraction
        var jitterNote = ""
        if let j = jitterRMS, j > 15 {
            let before = rawFraction
            rawFraction = rawFraction * 0.7
            jitterNote = " High jitter (\(String(format: "%.1f", j)) px RMS) — tightened from \(Int((before * 100).rounded()))% to \(Int((rawFraction * 100).rounded()))%."
        } else if let j = jitterRMS, j > 6 {
            jitterNote = " Moderate jitter (\(String(format: "%.1f", j)) px RMS)."
        }

        // Clamp to the BiggSky empirical band.
        let clampedFraction = max(lowerBound, min(upperBound, rawFraction))

        // Frame-count floor: lift the keep count up to whichever floor
        // applies, then re-derive the fraction so display is consistent.
        let idealCount = Int((clampedFraction * Double(totalFrames)).rounded(.up))
        let liftedCount = max(typicalFloor, max(absoluteFloor, idealCount))
        let keepCount = min(liftedCount, totalFrames)   // cannot keep more than we have
        let keepFraction = Double(keepCount) / Double(totalFrames)

        let pct = Int((keepFraction * 100).rounded())
        let kneePct = Int((kneeFraction * 100).rounded())
        var text: String
        if keepCount > idealCount {
            text = "Keep top \(pct)% (\(keepCount) of \(totalFrames) frames). Knee at \(kneePct)% suggests fewer; lifted to the SNR floor."
        } else if kneeFraction >= upperBound {
            text = "Keep top \(pct)% (\(keepCount) of \(totalFrames) frames). Tight distribution — capped at \(Int(upperBound * 100))% per BiggSky norms."
        } else if kneeFraction < lowerBound {
            text = "Keep top \(pct)% (\(keepCount) of \(totalFrames) frames). Wide distribution — lifted to \(Int(lowerBound * 100))% floor (BiggSky's lowest empirical keep rate)."
        } else {
            text = "Keep top \(pct)% (\(keepCount) of \(totalFrames) frames) — sharpness drops sharply below this point."
        }
        text += jitterNote
        return (keepFraction, keepCount, text)
    }
}
