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
        a.distribution == b.distribution
    }
}

struct SharpnessDistribution: Equatable, Codable {
    let sampleCount: Int
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
    /// Human-readable recommendation rationale.
    let recommendationText: String
}

// MARK: - Sharpness probe

/// Variance of Laplacian — a scale-invariant, contrast-sensitive proxy for
/// image sharpness. Higher = sharper. Used by Computer Vision libraries as
/// a focus/blur metric for decades.
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
    private let laplacian: MPSImageLaplacian
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
        self.laplacian = MPSImageLaplacian(device: device)
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
        guard let cmd = commandQueue.makeCommandBuffer(), let e = entry else { return .nan }
        laplacian.encode(commandBuffer: cmd, sourceTexture: src, destinationTexture: e.lap)
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
            // we can finalise as RMS without an extra pass. Each pair is one
            // 1024² FFT-pair (~50 ms on M-series), so 64 samples ≈ 3 s.
            var shiftSqSum: Double = 0
            var shiftCount: Int = 0
            var prevTex: MTLTexture? = nil
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
                // Pairwise phase correlation against the previously loaded
                // sample. Magnitude in original-texture pixels.
                if let prev = prevTex,
                   let shift = Align.phaseCorrelate(reference: prev, frame: tex) {
                    let mag2 = Double(shift.dx * shift.dx + shift.dy * shift.dy)
                    if mag2.isFinite {
                        shiftSqSum += mag2
                        shiftCount += 1
                    }
                }
                prevTex = tex
            }
            if Task.isCancelled || scores.isEmpty { return }

            let jitter: Float? = shiftCount > 0
                ? Float((shiftSqSum / Double(shiftCount)).squareRoot())
                : nil
            let dist = Self.makeDistribution(scores: scores, jitterRMS: jitter)
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

    /// Translate the raw distribution into a "keep top N%" recommendation.
    /// The heuristic: a wide distribution means a few frames are dramatically
    /// sharper than the rest (turbulent seeing) → be picky. A tight
    /// distribution means most frames are similar → keep more, since the
    /// stack benefits more from SNR than from selectivity.
    nonisolated private static func makeDistribution(scores: [Float], jitterRMS: Float? = nil) -> SharpnessDistribution {
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

        // Spread = p90 / p10 (clamped to avoid divide-by-zero).
        let spread = Double(p90 / max(p10, 1e-6))
        var keep: Double
        var basis: String
        switch spread {
        case ..<1.4:
            keep = 0.75
            basis = "tight quality distribution — keep top 75% for SNR."
        case ..<2.0:
            keep = 0.50
            basis = "moderate variance — keep top 50% balances SNR and detail."
        case ..<4.0:
            keep = 0.25
            basis = "wide spread (seeing variable) — keep top 25%."
        default:
            keep = 0.10
            basis = "very wide spread (turbulent seeing) — keep only top 10%."
        }

        // Refine with jitter: very high frame-to-frame motion means even the
        // "sharp" frames are positionally inconsistent; tighten the keep band
        // by one notch so the lucky stack has less drift to register out.
        if let j = jitterRMS, j > 15 {
            switch keep {
            case 0.75: keep = 0.50
            case 0.50: keep = 0.25
            case 0.25: keep = 0.10
            default: break
            }
            basis += " High jitter (\(String(format: "%.1f", j)) px RMS) — tightened one band."
        } else if let j = jitterRMS, j > 6 {
            basis += " Moderate jitter (\(String(format: "%.1f", j)) px RMS)."
        }

        return SharpnessDistribution(
            sampleCount: sorted.count,
            median: p50, p10: p10, p90: p90, min: lo, max: hi,
            jitterRMS: jitterRMS,
            recommendedKeepFraction: keep,
            recommendationText: basis
        )
    }
}
