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

    /// Per-channel stacking (Path B). When true, OSC Bayer sources are
    /// split into R / G / B mono streams BEFORE alignment, each
    /// channel is aligned and stacked independently against its own
    /// reference, then the three results are recombined into the
    /// final RGB. The documented BiggSky differentiator:
    ///   - catches per-frame atmospheric chromatic dispersion
    ///     (each channel shifts differently),
    ///   - skips the bilinear/Malvar interpolation step entirely so
    ///     the stack accumulator sees TRUE measured pixels per
    ///     channel rather than reconstructed neighbour averages,
    ///   - aligns each channel using same-channel features so
    ///     sub-pixel precision survives across the keep set.
    ///
    /// Empirically: averaging always smears detail unless every frame
    /// is sub-pixel-perfectly aligned. RGB-after-demosaic hides the
    /// per-channel sub-pixel offsets so our shared-shift accumulator
    /// can't compensate. Per-channel stacking re-exposes those
    /// offsets and aligns them out.
    ///
    /// Mono SER captures ignore this flag.
    var perChannelStacking: Bool = false

    /// Auto-PSF post-pass (Block C.1 v0). After the stack writes, the
    /// engine estimates Gaussian PSF sigma from the planetary limb's
    /// line-spread function and runs Wiener deconvolution with the
    /// estimated sigma. Applies AFTER the bake-in (so unsharp +
    /// wavelet inside bake-in run first, then the deconv pass on the
    /// already-cooked output). Set `autoPSFSNR` to control Wiener
    /// regularisation (50 = balanced, 30 = aggressive, 100 = soft).
    ///
    /// Mutually exclusive with `bakeIn.sharpen.wienerEnabled` /
    /// `bakeIn.sharpen.lrEnabled` — the auto-PSF path provides its
    /// own deconv with the auto-estimated sigma, so passing manual
    /// sigmas in bake-in alongside this flag would deconvolve twice.
    /// `LuckyStack.run` enforces this by running auto-PSF only when
    /// `useAutoPSF == true`.
    var useAutoPSF: Bool = false
    var autoPSFSNR: Double = 50

    /// Capture-gamma compensation around the auto-PSF + Wiener post-pass
    /// (Block C.6). 1.0 = no correction (data assumed linear). Typical
    /// SharpCap / FireCapture defaults apply gamma 2.0 by default; pre-
    /// linearising the input restores the linear forward-model assumption
    /// the Wiener inverse filter relies on, killing planetary edge ringing.
    /// Re-encoded with `1/captureGamma` after the deconv so downstream
    /// blend / denoise / tone curves see the same encoding throughout.
    var captureGamma: Double = 1.0

    /// Run the AutoPSF Wiener post-pass on luminance only (Block C.7).
    /// Computes Y = 0.299 R + 0.587 G + 0.114 B, deconvolves Y, then
    /// adds the deconv Δ to every channel. ~3× faster than per-channel
    /// FFT and avoids per-channel ringing artefacts on OSC bayer sources
    /// where R/G/B noise floors differ. Default ON because the failure
    /// mode (independent per-channel ringing) is more objectionable
    /// than the loss of per-channel adaptivity. Mono sources produce
    /// numerically identical output regardless of this flag.
    var processLuminanceOnly: Bool = true

    /// Border crop applied to the saved view file (Block C.8). Default
    /// 32 px matches BiggSky's `SaveView_BorderCrop` and hides the FFT
    /// wrap-around / Wiener edge ring frequency-domain deconv leaves on
    /// each side. Set to 0 to disable. Cropping is no-op when the value
    /// would leave a non-positive output dimension.
    var borderCropPixels: Int = BorderCrop.defaultViewBorderCropPixels

    /// White-cap override for `Pipeline.applyOutputRemap`. nil = use the
    /// pipeline's built-in default (0.92). Lower values dim the saved
    /// file more — useful when Wiener overshoot on bright features still
    /// pushes them too close to pure white at the default. Range
    /// [0.5, 1.0]; below 0.5 the output looks unnaturally muted on most
    /// subjects.
    var outputWhiteCap: Double? = nil

    /// Disable the subject-aware stack-end tone adjust.
    ///
    /// Default FALSE (2026-05-01) — replaced the destructive whiteCap
    /// clamp with a subject-aware gamma curve user-validated via
    /// brightness bracket: lunar / wide-range subjects pass through
    /// unchanged, planetary / dark-dominated subjects get gamma 1.3
    /// (pure midtone compression, no clamping → no detail loss).
    /// Setting this true skips the adjust entirely (= bare accumulator
    /// for all subjects, which the user verified looks correct on
    /// lunar but slightly bright on planetary).
    var disableOutputRemap: Bool = false

    /// Dual-stage denoise around the auto-PSF + Wiener path (Block C.5).
    /// Pre-denoise (default 0 = off) wraps the input BEFORE PSF
    /// estimation + deconvolution — suppresses noise so the limb
    /// LSF measurement is cleaner and the deconv inverse filter
    /// doesn't amplify noise. Post-denoise (default 0 = off) cleans
    /// up residual ringing AFTER the Wiener restore.
    ///
    /// Both are wavelet soft-threshold (perfect-reconstruction
    /// pyramid with per-band thresholding). 0..100 maps linearly
    /// to wavelet noise threshold ∈ [0, 0.025] — same scale as
    /// the existing manual wavelet denoise. Typical values:
    ///   75 / 75  : strong dual-stage (BiggSky default)
    ///    0 /  1  : low-noise SER (clean dataset)
    ///   50 / 30  : balanced
    /// Only fires when `useAutoPSF == true`.
    var denoisePrePercent: Int = 0
    var denoisePostPercent: Int = 0

    /// Auto-derive `keepPercent` from the per-frame quality grading
    /// instead of using whatever value the user passed (Block A.4).
    /// When ON, the runner runs its full quality pass first, then
    /// hands the sorted scores to `SerQualityScanner.computeKeepRecommendation`
    /// to pick the keep fraction. The chosen percentage is logged via
    /// NSLog so the GUI / CLI can surface it.
    ///
    /// Reuses the lucky-stack runner's own grading output — no
    /// duplicate scan, no extra cost. Skipped if `keepCount` (the
    /// absolute frame-count override) is set.
    var useAutoKeepPercent: Bool = false

    /// Tiled deconvolution with green / yellow / red mask (Block C.3 v0).
    /// Classifies each cell of an `apGrid × apGrid` AP grid by content:
    ///   - GREEN (high LAPD + bright luma) — surface, full deconv
    ///   - YELLOW (bright luma but lower LAPD) — limb, gentle deconv
    ///   - RED (dim luma) — background, deconv skipped
    /// The classification feeds a soft mask that bilinear-blends the
    /// pre-deconv (background) with the post-Wiener (foreground)
    /// output. The main BiggSky-documented benefit: no noise
    /// amplification in dark background regions, since the inverse
    /// filter doesn't fire there. v0 uses a single global PSF (the
    /// AutoPSF estimate) — per-tile PSF refinement is C.3 v1+.
    /// Only fires when `useAutoPSF == true`.
    var useTiledDeconv: Bool = false
    /// Edge length of the tile grid. 8 = 8×8 = 64 cells (matches the
    /// default multi-AP grid). Smaller = more aggressive
    /// classification on small details; larger = smoother boundaries.
    /// Range [4, 16] in practice.
    var tiledDeconvAPGrid: Int = 8
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

    /// Wavelet-based denoise wrapper used by the dual-stage path
    /// around the auto-PSF + Wiener pipeline (Block C.5). Calls
    /// `Wavelet.sharpen` with amounts = [1, 1, 1, 1, 1, 1] (perfect
    /// reconstruction — no actual sharpening) and a per-band
    /// soft-threshold scaled from the user's 0..100 percent. The
    /// existing wavelet engine already implements per-band
    /// thresholding that decays with band index (finest scales =
    /// most denoised), so this wrapper is just a convenient
    /// "denoise only" entry point.
    ///
    /// Threshold mapping: percent / 100 × 0.025 — same upper end
    /// as the manual `sharpen.waveletNoiseThreshold` slider in the
    /// SettingsPanel, so 100% here is "as strong as the user can
    /// already dial in by hand".
    /// Radial deconv-fade — kills Gibbs ringing at the disc limb on
    /// high-contrast small-disc subjects (Mars-class). AutoPSF
    /// provides the disc centre + radius; we mix(pre, deconv, mask)
    /// where the mask fades from 1 (full deconv) at the disc centre
    /// to 0 (pre / bare) just past the limb. The user accepted the
    /// trade-off: outer ring of the disc less sharp than the inner
    /// core, but the dark ring artifact disappears.
    ///
    /// Defaults: inner = 0.65 × discRadius, outer = 1.05 × discRadius.
    /// The slight extension past the limb (×1.05) keeps a touch of
    /// deconv on the very edge bright detail without amplifying the
    /// discontinuity that would re-introduce ringing.
    static func radialDeconvBlend(
        pre: MTLTexture,
        deconv: MTLTexture,
        center: SIMD2<Float>,
        discRadius: Float,
        innerFraction: Float = 0.65,
        outerFraction: Float = 1.05,
        device: MTLDevice
    ) -> MTLTexture? {
        guard let lib = MetalDevice.shared.library,
              let fn = lib.makeFunction(name: "lucky_radial_deconv_blend"),
              let pso = try? device.makeComputePipelineState(function: fn) else {
            return nil
        }
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pre.pixelFormat,
            width: pre.width, height: pre.height,
            mipmapped: false
        )
        outDesc.storageMode = .private
        outDesc.usage = [.shaderRead, .shaderWrite]
        guard let output = device.makeTexture(descriptor: outDesc) else { return nil }
        let queue = MetalDevice.shared.commandQueue
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pso)
        enc.setTexture(pre,    index: 0)
        enc.setTexture(deconv, index: 1)
        enc.setTexture(output, index: 2)
        var p = LuckyRadialMaskParamsCPU(
            center: center,
            innerRadius: max(1, innerFraction * discRadius),
            outerRadius: max(2, outerFraction * discRadius)
        )
        enc.setBytes(&p, length: MemoryLayout<LuckyRadialMaskParamsCPU>.stride, index: 0)
        let (tgC, tgS) = dispatchThreadgroups(for: output, pso: pso)
        enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return output
    }

    /// Build the green/yellow/red tile classification + run the GPU
    /// mask-blend that combines the pre-deconv (background) with the
    /// post-Wiener (foreground). Returns nil on any error so the
    /// caller can fall back to plain deconv.
    ///
    /// Classification rules (Block C.3 v0):
    ///   1. APPlanner.plan(...) labels each cell with a LAPD score +
    ///      kept/dropped flag (drops dim background outright).
    ///   2. Cells dropped by APPlanner → mask 0 (RED, no deconv).
    ///   3. Surviving cells split at the median APPlanner score:
    ///        top half  → mask 1 (GREEN, full deconv)
    ///        bottom    → mask 0.5 (YELLOW, half-strength deconv)
    ///   4. Mask uploaded as r32Float (apGrid × apGrid); GPU shader
    ///      bilinear-samples it for smooth tile boundaries.
    static func tiledDeconvBlend(
        pre: MTLTexture,
        deconv: MTLTexture,
        apGrid: Int,
        pipeline: Pipeline,
        device: MTLDevice
    ) -> MTLTexture? {
        let safeGrid = max(2, min(16, apGrid))
        guard let (luma, W, H) = AutoPSF.readLuminance(texture: pre, device: device) else {
            return nil
        }

        let plan = APPlanner.plan(
            luma: luma, width: W, height: H, apGrid: safeGrid
        )
        guard !plan.scores.isEmpty else { return nil }

        // Score-based green/yellow split among the surviving cells.
        let surviving = plan.mask.enumerated().compactMap { $1 ? $0 : nil }
        var mask = [Float](repeating: 0, count: safeGrid * safeGrid) // RED default
        if !surviving.isEmpty {
            let scoresOfSurviving = surviving.map { plan.scores[$0] }.sorted()
            let medianScore = scoresOfSurviving[scoresOfSurviving.count / 2]
            for cellIdx in surviving {
                mask[cellIdx] = plan.scores[cellIdx] >= medianScore ? 1.0 : 0.5
            }
        }

        // Upload mask as r32Float texture.
        let maskDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: safeGrid, height: safeGrid,
            mipmapped: false
        )
        maskDesc.storageMode = .shared
        maskDesc.usage = [.shaderRead]
        guard let maskTex = device.makeTexture(descriptor: maskDesc) else { return nil }
        mask.withUnsafeBufferPointer { buf in
            maskTex.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: safeGrid, height: safeGrid, depth: 1)
                ),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: safeGrid * MemoryLayout<Float>.size
            )
        }

        // Build the blend kernel PSO on demand. Cached by the static
        // closure: cheap to call repeatedly even though we go through
        // the library lookup each time (the pipeline state itself is
        // cached by Metal once compiled).
        guard let lib = MetalDevice.shared.library,
              let fn = lib.makeFunction(name: "lucky_mask_blend"),
              let pso = try? device.makeComputePipelineState(function: fn) else {
            return nil
        }

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pre.pixelFormat,
            width: pre.width, height: pre.height,
            mipmapped: false
        )
        outDesc.storageMode = .private
        outDesc.usage = [.shaderRead, .shaderWrite]
        guard let output = device.makeTexture(descriptor: outDesc) else { return nil }

        let queue = MetalDevice.shared.commandQueue
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pso)
        enc.setTexture(pre,    index: 0)
        enc.setTexture(deconv, index: 1)
        enc.setTexture(maskTex, index: 2)
        enc.setTexture(output,  index: 3)
        var p = LuckyMaskBlendParamsCPU(apGrid: UInt32(safeGrid))
        enc.setBytes(&p, length: MemoryLayout<LuckyMaskBlendParamsCPU>.stride, index: 0)
        let (tgC, tgS) = dispatchThreadgroups(for: output, pso: pso)
        enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        return output
    }

    /// Border crop for the saved view (Block C.8). Frequency-domain
    /// deconvolution leaves an FFT wrap-around / Wiener edge ring on
    /// each side of the output. Cropping `borderPixels` from each
    /// side hides that ring before the file is written.
    ///
    /// Allocates a smaller private-storage texture and blit-copies the
    /// interior region. Returns `input` unchanged when borderPixels ≤ 0
    /// or when the crop would leave a non-positive dimension. Pixel
    /// format is preserved so downstream `ImageTexture.write` doesn't
    /// have to branch on bit depth.
    static func cropBorder(
        input: MTLTexture,
        borderPixels: Int,
        device: MTLDevice
    ) -> MTLTexture {
        guard let rect = BorderCrop.cropRect(
            width: input.width,
            height: input.height,
            borderPixels: borderPixels
        ) else {
            return input  // crop disabled or impossible — pass through
        }
        let newW = Int(rect.width)
        let newH = Int(rect.height)
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: input.pixelFormat,
            width: newW, height: newH,
            mipmapped: false
        )
        outDesc.storageMode = .private
        outDesc.usage = [.shaderRead, .shaderWrite]
        guard let output = device.makeTexture(descriptor: outDesc) else {
            return input
        }
        let queue = MetalDevice.shared.commandQueue
        guard let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else {
            return input
        }
        blit.copy(
            from: input,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: Int(rect.minX), y: Int(rect.minY), z: 0),
            sourceSize: MTLSize(width: newW, height: newH, depth: 1),
            to: output,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return output
    }

    static func denoiseTexture(
        input: MTLTexture,
        percent: Int,
        pipeline: Pipeline,
        device: MTLDevice
    ) -> MTLTexture? {
        guard percent > 0 else { return input }
        let queue = MetalDevice.shared.commandQueue
        guard let cmd = queue.makeCommandBuffer() else { return nil }
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: input.pixelFormat,
            width: input.width, height: input.height,
            mipmapped: false
        )
        outDesc.storageMode = .private
        outDesc.usage = [.shaderRead, .shaderWrite]
        guard let output = device.makeTexture(descriptor: outDesc) else { return nil }
        var borrowed: [MTLTexture] = []
        let strength: Float = Float(min(100, max(0, percent))) / 100.0
        Wavelet.sharpen(
            input: input, output: output,
            amounts: [1, 1, 1, 1, 1, 1],   // perfect reconstruction
            baseSigma: 1.0,
            noiseThreshold: strength * 0.025,
            pipeline: pipeline,
            commandBuffer: cmd,
            borrowed: &borrowed
        )
        cmd.commit()
        cmd.waitUntilCompleted()
        return output
    }

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

            // Mono 8/16, the four Bayer patterns, and packed 8-bit RGB / BGR
            // are all supported. 16-bit RGB SERs (.rgb / .bgr with
            // pixelDepth=16) are rejected here — the unpack_rgb8 kernel
            // assumes 1 byte per channel. SerReader will mark the colour
            // ID correctly; this guard catches the RGB48 case the v0
            // kernel can't handle.
            let cid = reader.header.colorID
            if cid.isRGB && reader.header.bytesPerPlane != 1 {
                await onProgress(.error("16-bit RGB SER not yet supported — re-export as 8-bit RGB or as Bayer."))
                return
            }
            guard cid.isMono || cid.isBayer || cid.isRGB else {
                await onProgress(.error("Unsupported SER colour layout (got \(cid))."))
                return
            }

            // Path B per-channel stacking (commit 8e2a023 wired the flag,
            // LuckyStackPerChannel.swift implements the runner). Engaged
            // only on Bayer captures: mono SERs already extract a single
            // measured plane and don't have the per-channel atmospheric
            // dispersion problem the path is designed to fix.
            let usePerChannel = options.perChannelStacking
                && reader.header.colorID.isBayer

            do {
                let stacked: MTLTexture
                if usePerChannel {
                    stacked = try await LuckyStackPerChannel.run(
                        reader: reader,
                        pipeline: pipeline,
                        options: options,
                        progress: { p in
                            Task { @MainActor in onProgress(p) }
                        }
                    )
                } else {
                    let runner = LuckyRunner(reader: reader, pipeline: pipeline, options: options)
                    stacked = try await runner.run(progress: { p in
                        Task { @MainActor in onProgress(p) }
                    })
                }
                await onProgress(.writing)

                // Optional bake-in: route the stacked texture through the
                // user's current sharpen + tone pipeline before writing so
                // the saved file matches the live preview.
                var final: MTLTexture
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

                // Auto-PSF post-pass (Block C.1 v0): estimate σ from the
                // limb LSF and apply Wiener deconv, wrapped by dual-
                // stage denoise (Block C.5). The whole post-pass gates
                // on a successful AutoPSF result — when the estimator
                // bails (lunar / textured / cropped subjects with no
                // clean planetary limb) we want to preserve the bare
                // stack, not run the dual-denoise without the deconv
                // it's supposed to wrap (which would soften the output
                // for no benefit). Single code path for GUI + CLI;
                // both just set the options.
                if options.useAutoPSF {
                    let device = MetalDevice.shared.device

                    // Pre-flight PSF estimate on the bare stack — if
                    // this fails we skip the entire post-pass and
                    // write the stack as-is.
                    let psfPreflight = AutoPSF.estimate(texture: final, device: device)

                    if let psf = psfPreflight {
                        NSLog("AutoPSF: σ=%.2f conf=%.2f r=%.0f at (%.0f, %.0f)",
                              psf.sigma, psf.confidence, psf.discRadius,
                              psf.discCenter.x, psf.discCenter.y)

                        // Stage 1: pre-denoise (Block C.5 first half).
                        if options.denoisePrePercent > 0 {
                            if let denoised = Self.denoiseTexture(
                                input: final,
                                percent: options.denoisePrePercent,
                                pipeline: pipeline,
                                device: device
                            ) {
                                final = denoised
                            }
                        }

                        // Stage 2: Wiener deconvolution with the
                        // pre-flight σ (still valid — pre-denoise
                        // shouldn't shift the PSF estimate by much,
                        // and re-running estimate is wasted work).
                        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: final.pixelFormat,
                            width: final.width, height: final.height,
                            mipmapped: false
                        )
                        outDesc.storageMode = .private
                        outDesc.usage = [.shaderRead, .shaderWrite]
                        if let deconvTex = device.makeTexture(descriptor: outDesc) {
                            // Capture-gamma (C.6). Defensive: 0 / NaN fall
                            // back to 1.0 so a malformed setting can't
                            // divide-by-zero in the inverse re-encode.
                            let safeGamma: Float = (options.captureGamma > 0 && options.captureGamma.isFinite)
                                ? Float(options.captureGamma) : 1.0
                            Wiener.deconvolve(
                                input: final,
                                output: deconvTex,
                                sigma: psf.sigma,
                                snr: Float(options.autoPSFSNR),
                                device: device,
                                captureGamma: safeGamma,
                                processLuminanceOnly: options.processLuminanceOnly
                            )

                            // Radial fade is the FIRST blend choice
                            // when AutoPSF gave us a clean disc — it
                            // kills Wiener's Gibbs ringing at the limb
                            // without the chunky tile boundaries the
                            // tiled blend can produce on small discs.
                            // Tiled deconv stays available as a manual
                            // option for subjects where the radial
                            // assumption doesn't fit (multi-feature
                            // solar surface, future use cases).
                            if let radial = Self.radialDeconvBlend(
                                pre: final,
                                deconv: deconvTex,
                                center: psf.discCenter,
                                discRadius: psf.discRadius,
                                device: device
                            ) {
                                final = radial
                            } else if options.useTiledDeconv {
                                if let blended = Self.tiledDeconvBlend(
                                    pre: final,
                                    deconv: deconvTex,
                                    apGrid: options.tiledDeconvAPGrid,
                                    pipeline: pipeline,
                                    device: device
                                ) {
                                    final = blended
                                } else {
                                    final = deconvTex
                                }
                            } else {
                                final = deconvTex
                            }
                        }

                        // Stage 3: post-denoise (Block C.5 second half).
                        if options.denoisePostPercent > 0 {
                            if let denoised = Self.denoiseTexture(
                                input: final,
                                percent: options.denoisePostPercent,
                                pipeline: pipeline,
                                device: device
                            ) {
                                final = denoised
                            }
                        }
                    } else {
                        NSLog("AutoPSF: estimation skipped (no clean disc — likely lunar / textured subject); bare stack written, dual-stage denoise also skipped since it wraps the deconv it has nothing to do without")
                    }
                }

                // Stack-end auto-recovery (always-on). Mean-stacking lifts
                // the dark sky and flattens the bright peaks, leaving the
                // saved TIF visibly washed-out (full histogram squished
                // into the middle ~50% of the range). The recovery pass
                // linearly remaps the 1%/99% luma window into [0, 0.97]
                // — no gamma, no contrast amp — just undoes the dynamic-
                // range compression. Replaces the user-facing autoStretch
                // toggle (removed 2026-04-29 after the percentile + 0.85
                // scale + 0.8 gamma combination produced an
                // "unnatural super-high-contrast" look on lunar / planetary
                // captures). Runs on every output regardless of mode /
                // bake-in / AutoPSF success.
                final = pipeline.applyOutputRemap(
                    input: final,
                    whiteCap: options.outputWhiteCap.map { Float($0) },
                    enabled: !options.disableOutputRemap
                )

                // Border crop (Block C.8). Hides the deconv edge ring
                // before writing. Pass-through when borderCropPixels is 0
                // or when the crop would over-shoot the image dimensions.
                if options.borderCropPixels > 0 {
                    final = Self.cropBorder(
                        input: final,
                        borderPixels: options.borderCropPixels,
                        device: MetalDevice.shared.device
                    )
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
    let rgb8PSO: MTLComputePipelineState     // packed-RGB SER (3 bytes/pixel, 8-bit)
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
    let isRGB: Bool                  // .rgb / .bgr SER (3 bytes per pixel, 8-bit only)
    let rgbSwapRB: Bool              // true for .bgr — kernel swaps R/B
    let bayerPattern: UInt32

    // Staging pool for SER → GPU upload. For mono / Bayer we use textures
    // (1 or 2 bytes per pixel land cleanly in r8Unorm / r16Uint formats).
    // For RGB SERs (3 bytes per pixel) Metal has no rgb8Unorm format, so
    // we use a parallel pool of MTLBuffers — the unpack_rgb8 kernel reads
    // 3 raw bytes per output pixel directly from the buffer.
    let stagingTextures: [MTLTexture]
    let rgbBuffers: [MTLBuffer]      // empty when !isRGB
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
        self.rgb8PSO     = Self.makePSO(library: lib, device: device, fn: "unpack_rgb8_to_rgba")
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
        self.isMono16 = bytesPerPlane == 2 && !reader.header.colorID.isRGB
        self.isBayer = reader.header.colorID.isBayer
        self.isRGB = reader.header.colorID.isRGB
        self.rgbSwapRB = reader.header.colorID == .bgr
        self.bayerPattern = reader.header.colorID.bayerPatternIndex

        let dev = self.device
        // RGB and mono/Bayer pools are disjoint — only one is populated
        // per run. Allocating both would waste GPU memory on multi-GB
        // captures; the empty array path is the lightweight default.
        let isRGBLocal = reader.header.colorID.isRGB
        if isRGBLocal {
            self.stagingTextures = []
            let rgbFrameBytes = W * H * 3
            self.rgbBuffers = (0..<options.stagingPoolSize).map { _ in
                dev.makeBuffer(length: rgbFrameBytes, options: [.storageModeShared])!
            }
        } else {
            self.stagingTextures = (0..<options.stagingPoolSize).map { _ in
                Self.makeStaging(device: dev, w: W, h: H, mono16: bytesPerPlane == 2)
            }
            self.rgbBuffers = []
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

    /// RGB / BGR variant of `encodeUnpack` — reads from an MTLBuffer
    /// (3 bytes per pixel, 8-bit) and writes to the rgba16Float frame
    /// texture. `swapRB` is set per .rgb / .bgr at runner-init time.
    func encodeUnpackRGB(
        commandBuffer cmd: MTLCommandBuffer,
        buffer src: MTLBuffer,
        frameTex: MTLTexture
    ) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(rgb8PSO)
        var p = RgbUnpackParamsCPU(
            scale: 1.0 / 255.0,
            flip: options.meridianFlipped ? 1 : 0,
            swapRB: rgbSwapRB ? 1 : 0,
            width: UInt32(W)
        )
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setTexture(frameTex, index: 0)
        enc.setBytes(&p, length: MemoryLayout<RgbUnpackParamsCPU>.stride, index: 1)
        let (tgC, tgS) = dispatchThreadgroups(for: frameTex, pso: rgb8PSO)
        enc.dispatchThreadgroups(tgC, threadsPerThreadgroup: tgS)
        enc.endEncoding()
    }

    /// Single entry point that uploads frame `frameIndex` from disk into
    /// the runner's pool slot `slot` and decodes it into `frameTex`.
    /// Branches internally on colorID: mono / Bayer use the staging-
    /// texture path, RGB / BGR use the MTLBuffer path. Keeps the 11
    /// hot-loop sites uniform — they don't have to know the colour
    /// layout. The command buffer is shared with downstream passes
    /// (accumulate, quality, etc.) so no extra GPU sync is introduced.
    func decodeFrame(
        commandBuffer cmd: MTLCommandBuffer,
        frameIndex: Int,
        slot: Int,
        frameTex: MTLTexture
    ) {
        if isRGB {
            let buf = rgbBuffers[slot]
            reader.withFrameBytes(at: frameIndex) { ptr, len in
                memcpy(buf.contents(), ptr, len)
            }
            encodeUnpackRGB(commandBuffer: cmd, buffer: buf, frameTex: frameTex)
        } else {
            let staging = stagingTextures[slot]
            reader.withFrameBytes(at: frameIndex) { ptr, _ in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                      size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
                )
            }
            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: frameTex)
        }
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

        // Auto-keep (Block A.4): when set, derive the keep fraction
        // from the quality distribution instead of using the user's
        // configured value. Reuses the runner's grading output —
        // no duplicate scan. Skipped if `keepCount` is set (the
        // absolute frame-count override stays explicit).
        var resolvedKeepPercent = options.keepPercent
        if options.useAutoKeepPercent, options.keepCount == nil, !scores.isEmpty {
            let sorted = scores.sorted()
            let p90Idx = Int((Double(sorted.count - 1) * 0.9).rounded())
            let p90 = sorted[max(0, min(sorted.count - 1, p90Idx))]
            let rec = SerQualityScanner.computeKeepRecommendation(
                sortedScores: sorted,
                totalFrames: scores.count,
                p90: p90,
                jitterRMS: nil
            )
            resolvedKeepPercent = max(1, min(99, Int((rec.fraction * 100).rounded())))
            NSLog("Auto-keep: %d%% (%d of %d frames) — %@",
                  resolvedKeepPercent, rec.count, scores.count, rec.text)
        }

        // `keepCount` (absolute frame count) overrides `keepPercent` so the
        // user can request fixed-N stacks (e.g. "best 100 frames") for
        // direct comparison across SERs of different lengths.
        let kept: [Int]
        if let count = options.keepCount, count > 0 {
            kept = topNIndices(scores: scores, count: count)
        } else {
            kept = topNIndices(scores: scores, percent: resolvedKeepPercent)
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
            let frameTex = frameTextures[slot]

            guard let cmd = queue.makeCommandBuffer() else { continue }

            decodeFrame(commandBuffer: cmd, frameIndex: frameIndex, slot: slot, frameTex: frameTex)

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

        guard let cmd = queue.makeCommandBuffer() else {
            throw NSError(domain: "Lucky", code: 1)
        }

        // Slot-less path (used for the reference frame load in scientific
        // mode): allocate fresh staging on every call. RGB / BGR uses a
        // freshly-allocated MTLBuffer; mono / Bayer uses a freshly-
        // allocated staging texture. Both paths flow through the runner's
        // existing encode helpers so the kernel selection logic stays in
        // one place.
        if isRGB {
            let frameBytes = W * H * 3
            guard let buf = device.makeBuffer(length: frameBytes, options: [.storageModeShared]) else {
                throw NSError(domain: "Lucky", code: 2)
            }
            reader.withFrameBytes(at: frameIndex) { ptr, len in
                memcpy(buf.contents(), ptr, len)
            }
            encodeUnpackRGB(commandBuffer: cmd, buffer: buf, frameTex: target)
        } else {
            let staging = Self.makeStaging(device: device, w: W, h: H, mono16: isMono16)
            reader.withFrameBytes(at: frameIndex) { ptr, _ in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: W, height: H, depth: 1)),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: W * bytesPerPlane
                )
            }
            encodeUnpack(commandBuffer: cmd, staging: staging, frameTex: target)
        }
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
            let frameTex = frameTextures[slot]

            guard let cmd = queue.makeCommandBuffer() else { continue }
            decodeFrame(commandBuffer: cmd, frameIndex: idx, slot: slot, frameTex: frameTex)
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
            let frameTex = frameTextures[slot]

            guard let cmd = queue.makeCommandBuffer() else { continue }
            decodeFrame(commandBuffer: cmd, frameIndex: idx, slot: slot, frameTex: frameTex)

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
            let frameTex = frameTextures[slot]

            guard let cmd = queue.makeCommandBuffer() else { continue }
            decodeFrame(commandBuffer: cmd, frameIndex: idx, slot: slot, frameTex: frameTex)

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
        // rgba32Float (single-precision) — half-precision (rgba16Float)
        // gives ~10 bits of mantissa in the mid-range, which after
        // hundreds of weighted-sum updates and a final sharpen pass
        // surfaced as visible colour banding on smooth Jupiter cloud
        // bands. Single-precision burns 2x the texture memory but
        // gives 23 bits of mantissa — quantisation drops below the
        // 16-bit-int output range so the on-disk TIFF is clean.
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
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
            let frameTex = frameTextures[slot]

            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }
            decodeFrame(commandBuffer: cmd, frameIndex: idx, slot: slot, frameTex: frameTex)

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
            let frameTex = frameTextures[slot]

            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }
            decodeFrame(commandBuffer: cmd, frameIndex: idx, slot: slot, frameTex: frameTex)

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
        // rgba32Float for both accumulator and weight texture — same
        // rationale as makeAccumulator: half-precision was banding the
        // smooth-gradient output after sharpening.
        let accum = Self.makeFloatBuffer(device: device, w: outW, h: outH, format: .rgba32Float)
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
            let frameTex = frameTextures[slot]

            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }
            decodeFrame(commandBuffer: cmd, frameIndex: idx, slot: slot, frameTex: frameTex)

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
            let frameTex = frameTextures[slot]

            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }
            decodeFrame(commandBuffer: cmd, frameIndex: idx, slot: slot, frameTex: frameTex)

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
            let frameTex = frameTextures[slot]

            guard let cmd = queue.makeCommandBuffer() else {
                stagingSemaphore.signal()
                continue
            }
            decodeFrame(commandBuffer: cmd, frameIndex: idx, slot: slot, frameTex: frameTex)

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
/// Mirrors RgbUnpackParams in Shaders.metal exactly.
private struct RgbUnpackParamsCPU {
    var scale: Float
    var flip: UInt32
    var swapRB: UInt32
    var width: UInt32
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

// MARK: - C.3 mask-blend CPU param struct

private struct LuckyMaskBlendParamsCPU {
    var apGrid: UInt32
}

private struct LuckyRadialMaskParamsCPU {
    var center: SIMD2<Float>
    var innerRadius: Float
    var outerRadius: Float
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
