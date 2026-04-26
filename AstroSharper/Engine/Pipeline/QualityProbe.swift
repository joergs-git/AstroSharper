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
    /// Recommended fraction (0…1) of best frames to keep when stacking.
    let recommendedKeepFraction: Double
    /// Human-readable recommendation rationale.
    let recommendationText: String
}

// MARK: - Sharpness probe

/// Variance of Laplacian — a scale-invariant, contrast-sensitive proxy for
/// image sharpness. Higher = sharper. Used by Computer Vision libraries as
/// a focus/blur metric for decades.
final class SharpnessProbe {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let laplacian: MPSImageLaplacian
    private let stats: MPSImageStatisticsMeanAndVariance

    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.laplacian = MPSImageLaplacian(device: device)
        self.stats = MPSImageStatisticsMeanAndVariance(device: device)
    }

    /// Synchronous compute. Returns NaN if anything fails — callers can
    /// treat that as "no data available".
    func compute(texture src: MTLTexture) -> Float {
        // Laplacian destination must match source format.
        let lapDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: src.pixelFormat,
            width: src.width,
            height: src.height,
            mipmapped: false
        )
        lapDesc.usage = [.shaderRead, .shaderWrite]
        lapDesc.storageMode = .private
        guard let lapTex = device.makeTexture(descriptor: lapDesc) else { return .nan }

        // Stats destination is documented to require RGBA32Float, 2x1.
        let statsDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: 2, height: 1,
            mipmapped: false
        )
        statsDesc.usage = [.shaderRead, .shaderWrite]
        statsDesc.storageMode = .shared
        guard let statsTex = device.makeTexture(descriptor: statsDesc) else { return .nan }

        guard let cmd = commandQueue.makeCommandBuffer() else { return .nan }
        laplacian.encode(commandBuffer: cmd, sourceTexture: src, destinationTexture: lapTex)
        stats.encode(commandBuffer: cmd, sourceTexture: lapTex, destinationTexture: statsTex)
        cmd.commit()
        cmd.waitUntilCompleted()

        // Variance pixel sits at (1,0). Average RGB so mono and Bayer
        // sources produce comparable numbers; alpha is ignored.
        var pix = [Float](repeating: 0, count: 4)
        statsTex.getBytes(&pix,
                          bytesPerRow: 4 * MemoryLayout<Float>.size,
                          from: MTLRegionMake2D(1, 0, 1, 1),
                          mipmapLevel: 0)
        let v = (pix[0] + pix[1] + pix[2]) / 3.0
        return v.isFinite ? v : 0
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
            let probe = SharpnessProbe(device: MetalDevice.shared.device)

            var scores: [Float] = []
            scores.reserveCapacity(sampleCount)
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
            }
            if Task.isCancelled || scores.isEmpty { return }

            let dist = Self.makeDistribution(scores: scores)
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
    nonisolated private static func makeDistribution(scores: [Float]) -> SharpnessDistribution {
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
        let keep: Double
        let basis: String
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

        return SharpnessDistribution(
            sampleCount: sorted.count,
            median: p50, p10: p10, p90: p90, min: lo, max: hi,
            recommendedKeepFraction: keep,
            recommendationText: basis
        )
    }
}
