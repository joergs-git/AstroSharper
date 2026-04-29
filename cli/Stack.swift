// `astrosharper stack <input.ser> <output.tif>` — headless lucky-stack.
//
// Opens the SER, runs the existing LuckyStack pipeline with sensible
// defaults, writes the 16-bit float TIFF output, and (optionally)
// emits a metrics JSON the F3 regression harness can diff against a
// committed baseline. This unblocks end-to-end regression testing of
// the actual stack output — without it, every GPU change is verified
// by hand in the running app.
//
// AVI lucky-stack is gated on the E.1 SourceReader refactor: until
// that lands the subcommand checks the input extension and rejects
// AVI with a clear error.
import Foundation
import Metal

enum Stack {

    static func run(args: [String]) async -> Int32 {
        // Parse CLI args.
        var inputPath: String?
        var outputPath: String?
        var keepPercents: [Int] = [25]
        var metricsPath: String?
        var quiet = false
        var sigmaThreshold: Float?
        var drizzleScale = 1
        var drizzlePixfrac: Float = 0.7
        var useTwoStage = false
        var twoStageGrid = 8
        var mode: LuckyStackMode = .lightspeed
        var useMultiAP = false
        var multiAPGrid = 8
        // `--sharpen` enables the unsharp + wavelet bundle. Deconv flags
        // are independent: --wiener-sigma / --lr-sigma can fire on their
        // own without unsharp / wavelet getting enabled.
        var doUnsharpWavelet = false
        var sharpenAmount: Double = 1.0
        var wienerSigma: Double? = nil
        var wienerSNR: Double = 50
        var lrSigma: Double? = nil
        var lrIterations: Int = 30
        var keepCountAbsolute: Int? = nil
        var usePerChannelStacking = false
        var useAutoPSF = false
        var autoPSFSNR: Double = 50
        var useAutoKeep = false
        var keepWasExplicit = false
        var denoisePrePercent: Int = 0
        var denoisePostPercent: Int = 0
        var useTiledDeconv = false
        var tiledDeconvAPGrid = 8
        // C.6 capture-gamma compensation. 1.0 = no correction (data
        // assumed linear). Camera UI sliders (50, 100, 200) convert via
        // `CaptureGamma.gamma(fromCameraSliderValue:)`. Wired into the
        // AutoPSF Wiener post-pass through `options.captureGamma`.
        var captureGamma: Double = 1.0
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--keep":
                // Accept "25" (single) or "20,40,60,80" (multi-%).
                guard i + 1 < args.count else {
                    cliStderr("stack: --keep requires an integer or comma-separated list in [1, 99]")
                    return 64
                }
                let raw = args[i + 1]
                let parsed = LuckyKeepPercents.parse(raw)
                guard !parsed.isEmpty else {
                    cliStderr("stack: --keep value '\(raw)' didn't parse to any valid percentage in [\(LuckyKeepPercents.minPercent), \(LuckyKeepPercents.maxPercent)]")
                    return 64
                }
                keepPercents = parsed
                keepWasExplicit = true
                i += 2
            case "--metrics":
                guard i + 1 < args.count else {
                    cliStderr("stack: --metrics requires a path argument")
                    return 64
                }
                metricsPath = args[i + 1]
                i += 2
            case "--sigma":
                guard i + 1 < args.count, let v = Float(args[i + 1]),
                      v.isFinite, v > 0
                else {
                    cliStderr("stack: --sigma requires a positive number (e.g. 2.5 for AS!4 default)")
                    return 64
                }
                sigmaThreshold = v
                i += 2
            case "--drizzle":
                guard i + 1 < args.count, let v = Int(args[i + 1]),
                      v >= 1, v <= 3
                else {
                    cliStderr("stack: --drizzle requires an integer in {1, 2, 3} (1 = off)")
                    return 64
                }
                drizzleScale = v
                i += 2
            case "--pixfrac":
                guard i + 1 < args.count, let v = Float(args[i + 1]),
                      v.isFinite, v > 0, v <= 1
                else {
                    cliStderr("stack: --pixfrac requires a number in (0, 1] (BiggSky default 0.7)")
                    return 64
                }
                drizzlePixfrac = v
                i += 2
            case "--two-stage":
                useTwoStage = true
                i += 1
            case "--two-stage-grid":
                guard i + 1 < args.count, let v = Int(args[i + 1]),
                      v >= 2, v <= 32
                else {
                    cliStderr("stack: --two-stage-grid requires an integer in [2, 32] (default 8)")
                    return 64
                }
                twoStageGrid = v
                useTwoStage = true
                i += 2
            case "--mode":
                // .lightspeed (default) — single-frame reference + global phase corr.
                // .scientific — 2-stage clean-reference build (top 5% aligned to
                //               single best, accumulated, then ALL keepers aligned
                //               to that cleaner reference). Sharper alignment on
                //               smooth subjects (Jupiter / Saturn / Sun); slower.
                guard i + 1 < args.count else {
                    cliStderr("stack: --mode requires lightspeed | scientific")
                    return 64
                }
                switch args[i + 1].lowercased() {
                case "lightspeed", "fast":
                    mode = .lightspeed
                case "scientific", "sci":
                    mode = .scientific
                default:
                    cliStderr("stack: --mode '\(args[i + 1])' not recognised (use lightspeed | scientific)")
                    return 64
                }
                i += 2
            case "--multi-ap":
                // Multi-AP local shift refinement — bilinear-sampled per-pixel
                // shift map from an 8×8 (or larger) grid of SAD searches against
                // the cleaner reference. Engages only in scientific mode and
                // only with the standard accumulator path (not two-stage /
                // drizzle / sigma).
                useMultiAP = true
                if mode == .lightspeed { mode = .scientific }   // implies scientific
                i += 1
            case "--multi-ap-grid":
                guard i + 1 < args.count, let v = Int(args[i + 1]),
                      v >= 4, v <= 16
                else {
                    cliStderr("stack: --multi-ap-grid requires an integer in [4, 16] (default 8)")
                    return 64
                }
                multiAPGrid = v
                useMultiAP = true
                if mode == .lightspeed { mode = .scientific }
                i += 2
            case "--sharpen":
                // Enable post-stack sharpen baked into the output TIFF.
                // Engages unsharp (radius=1.5, amount=1.0 by default) +
                // 4-scale à-trous wavelet ([1.8, 1.4, 1.0, 0.6]). Without
                // this flag the CLI writes the raw stacked accumulator,
                // which by design looks soft — the GUI applies the same
                // pipeline live before display, so the saved file then
                // doesn't match what the user sees on screen.
                doUnsharpWavelet = true
                i += 1
            case "--sharpen-amount":
                guard i + 1 < args.count, let v = Double(args[i + 1]),
                      v.isFinite, v >= 0, v <= 5
                else {
                    cliStderr("stack: --sharpen-amount requires a number in [0, 5] (default 1.0)")
                    return 64
                }
                sharpenAmount = v
                doUnsharpWavelet = true
                i += 2
            case "--wiener-sigma":
                guard i + 1 < args.count, let v = Double(args[i + 1]),
                      v.isFinite, v > 0, v <= 10
                else {
                    cliStderr("stack: --wiener-sigma requires a positive number in (0, 10] — typical 1.0..2.0 px")
                    return 64
                }
                wienerSigma = v
                i += 2
            case "--wiener-snr":
                guard i + 1 < args.count, let v = Double(args[i + 1]),
                      v.isFinite, v > 0
                else {
                    cliStderr("stack: --wiener-snr requires a positive number — typical 30..200 (lower = more regularisation)")
                    return 64
                }
                wienerSNR = v
                i += 2
            case "--lr-sigma":
                guard i + 1 < args.count, let v = Double(args[i + 1]),
                      v.isFinite, v > 0, v <= 10
                else {
                    cliStderr("stack: --lr-sigma requires a positive number in (0, 10] — typical 1.0..2.0 px")
                    return 64
                }
                lrSigma = v
                i += 2
            case "--per-channel":
                // Path B: per-channel (R / G / B) stacking for OSC Bayer
                // sources. Implementation lands across the next sessions;
                // the flag wires through to LuckyStackOptions today so
                // we can A/B against the existing RGB-after-demosaic path
                // as soon as the runner branch is ready.
                usePerChannelStacking = true
                i += 1
            case "--smart-auto":
                // Convenience preset — sets sensible Block C defaults:
                //   auto-PSF ON, SNR=200 (aggressive Wiener — user
                //                empirically picked SNR=200 over
                //                gentler values; auto-bails on
                //                textured subjects so lunar still
                //                gets bare-quality output)
                //
                // The radial deconv-fade always runs after AutoPSF
                // succeeds (no opt-in needed — it just uses the
                // disc geometry AutoPSF already measured) and it
                // kills the Gibbs ringing that aggressive Wiener
                // would otherwise produce at the disc limb on
                // small high-contrast subjects (Mars).
                //
                // Tiled deconv + dual-stage denoise are NOT in the
                // preset: the radial fade already handles the
                // background-protection job tiled deconv was
                // designed for, and denoise softens detail more
                // than it cleans up artifacts on the SNR=200 path.
                // Both stay available as manual flags.
                //
                // Per-channel deliberately NOT set: its half-res
                // extract + upsample softens output (~1 px blur);
                // the chromatic-dispersion correction it offers
                // matters only at low altitudes. Users who need
                // it can pass --per-channel explicitly.
                //
                // Individual flags after `--smart-auto` still
                // override (e.g. `--smart-auto --auto-psf-snr 100`
                // dials Wiener back from the preset's 200).
                useAutoPSF = true
                autoPSFSNR = 200
                // Auto-derive keep-% from the quality distribution UNLESS
                // the user passed --keep explicitly. Keep-% then becomes
                // self-tuning across SERs of different lengths / quality
                // profiles without the user thinking about it.
                if !keepWasExplicit { useAutoKeep = true }
                i += 1
            case "--auto-keep":
                // Standalone flag — auto-derive keep-% even outside
                // --smart-auto. Honored unless `--keep` was explicit.
                useAutoKeep = true
                i += 1
            case "--auto-psf":
                // Block C.1 v0: estimate Gaussian PSF sigma from the
                // stacked image's limb LSF, then apply Wiener
                // deconvolution with the estimated sigma. Mutually
                // exclusive with --wiener-sigma / --lr-sigma since
                // those override what we'd auto-estimate.
                useAutoPSF = true
                i += 1
            case "--auto-psf-snr":
                guard i + 1 < args.count, let v = Double(args[i + 1]),
                      v.isFinite, v > 0
                else {
                    cliStderr("stack: --auto-psf-snr requires a positive number — typical 30..200 (lower = more regularisation)")
                    return 64
                }
                autoPSFSNR = v
                i += 2
            case "--capture-gamma":
                // C.6 capture-gamma compensation around the auto-PSF +
                // Wiener post-pass. Accepts either an actual gamma
                // exponent (1, 1.5, 2, 2.2) or a camera-UI slider value
                // (>4.5 → treated as a SharpCap/ZWO 0..200 slider where
                // 50 ≈ linear). Identity at 1.0 (default).
                guard i + 1 < args.count, let v = Double(args[i + 1]),
                      v.isFinite, v > 0
                else {
                    cliStderr("stack: --capture-gamma requires a positive number (gamma exponent or camera slider 50..200)")
                    return 64
                }
                captureGamma = CaptureGamma.looksLikeCameraSlider(v)
                    ? CaptureGamma.gamma(fromCameraSliderValue: v)
                    : v
                i += 2
            case "--denoise-pre":
                // C.5 dual-stage denoise — strength [0, 100] applied
                // BEFORE the auto-PSF estimate + Wiener deconv.
                guard i + 1 < args.count, let v = Int(args[i + 1]),
                      v >= 0, v <= 100
                else {
                    cliStderr("stack: --denoise-pre requires an integer in [0, 100] (BiggSky default 75)")
                    return 64
                }
                denoisePrePercent = v
                i += 2
            case "--tiled-deconv":
                // Block C.3 v0: green/yellow/red mask blend around the
                // auto-PSF + Wiener output. Skips deconv on background
                // tiles (no noise amplification), full strength on
                // bright surface tiles, half strength on limb / dim
                // surface tiles. Requires --auto-psf.
                useTiledDeconv = true
                i += 1
            case "--tiled-grid":
                guard i + 1 < args.count, let v = Int(args[i + 1]),
                      v >= 4, v <= 16
                else {
                    cliStderr("stack: --tiled-grid requires an integer in [4, 16] (default 8)")
                    return 64
                }
                tiledDeconvAPGrid = v
                i += 2
            case "--denoise-post":
                // C.5 dual-stage denoise — strength [0, 100] applied
                // AFTER the Wiener restore (cleans up amplified noise).
                guard i + 1 < args.count, let v = Int(args[i + 1]),
                      v >= 0, v <= 100
                else {
                    cliStderr("stack: --denoise-post requires an integer in [0, 100] (BiggSky default 75)")
                    return 64
                }
                denoisePostPercent = v
                i += 2
            case "--keep-count":
                // Absolute frame count override (e.g. --keep-count 1 to
                // stack the single best-quality frame, no averaging).
                // Beats --keep when both are passed.
                guard i + 1 < args.count, let v = Int(args[i + 1]),
                      v >= 1
                else {
                    cliStderr("stack: --keep-count requires a positive integer (e.g. 1 = single best frame)")
                    return 64
                }
                keepCountAbsolute = v
                i += 2
            case "--lr-iter":
                guard i + 1 < args.count, let v = Int(args[i + 1]),
                      v >= 1, v <= 200
                else {
                    cliStderr("stack: --lr-iter requires an integer in [1, 200] — typical 20..50")
                    return 64
                }
                lrIterations = v
                i += 2
            case "--quiet", "-q":
                quiet = true
                i += 1
            case let opt where opt.hasPrefix("--"):
                cliStderr("stack: unknown option '\(opt)'")
                return 64
            default:
                if inputPath == nil {
                    inputPath = arg
                } else if outputPath == nil {
                    outputPath = arg
                } else {
                    cliStderr("stack: too many positional arguments (got '\(arg)')")
                    return 64
                }
                i += 1
            }
        }

        guard let input = inputPath, let output = outputPath else {
            cliStderr("stack: missing input or output path")
            cliStderr("usage: astrosharper stack <input.ser> <output.tif> [--keep N|N,N,...] [--mode lightspeed|scientific] [--multi-ap [--multi-ap-grid N]] [--two-stage [--two-stage-grid N]] [--sigma N] [--drizzle N [--pixfrac X]] [--sharpen [--sharpen-amount X]] [--auto-psf [--auto-psf-snr N] [--capture-gamma N]] [--metrics file.json] [--quiet]")
            return 64
        }

        // --auto-psf is mutually exclusive with manual --wiener-sigma /
        // --lr-sigma — if the user wants auto, they get auto; if they
        // want a specific sigma they pass it directly.
        if useAutoPSF, wienerSigma != nil || lrSigma != nil {
            cliStderr("stack: --auto-psf is mutually exclusive with --wiener-sigma / --lr-sigma (auto overrides; pick one)")
            return 64
        }

        let inputURL  = URL(fileURLWithPath: input)
        let outputURLBase = URL(fileURLWithPath: output)

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            cliStderr("stack: input file not found: \(inputURL.path)")
            return 1
        }

        // AVI gating — pending E.1 SourceReader-driven LuckyRunner.
        let ext = inputURL.pathExtension.lowercased()
        guard ext == "ser" else {
            cliStderr("stack: only SER lucky-stack is supported in v0 (got .\(ext)). AVI lucky-stack lands with the SourceReader refactor (E.1).")
            return 2
        }

        // Make sure the output directory exists.
        let outputDir = outputURLBase.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true
        )

        let pipeline = Pipeline()

        // For a single percentage, write to the user's chosen path
        // unchanged. For multi-% runs, derive N output paths by
        // appending the SharpCap-style "_p<n>" suffix before the
        // extension. This matches BiggSky's documented multi-%
        // workflow: one input → multiple stacked outputs side-by-side.
        let outputPlan: [(percent: Int, url: URL)] = keepPercents.map { pct in
            if keepPercents.count == 1 {
                return (pct, outputURLBase)
            }
            let dir = outputURLBase.deletingLastPathComponent()
            let base = outputURLBase.deletingPathExtension().lastPathComponent
            let suffix = LuckyKeepPercents.filenameSuffix(percent: pct)
            let ext = outputURLBase.pathExtension
            let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            return (pct, dir.appendingPathComponent(name))
        }

        var perPercentMetrics: [[String: Any]] = []
        let runStart = Date()
        for plan in outputPlan {
            var options = LuckyStackOptions()
            options.keepPercent = plan.percent
            // --keep-count overrides the percentage: stack exactly N
            // best-quality frames. Use 1 to extract the single best
            // frame (no averaging) and isolate 'lucky imaging' from
            // 'stacking averages'.
            if let kc = keepCountAbsolute { options.keepCount = kc }
            options.perChannelStacking = usePerChannelStacking
            options.useAutoPSF = useAutoPSF
            options.autoPSFSNR = autoPSFSNR
            options.captureGamma = captureGamma
            options.useAutoKeepPercent = useAutoKeep && !keepWasExplicit
            options.denoisePrePercent = denoisePrePercent
            options.denoisePostPercent = denoisePostPercent
            options.useTiledDeconv = useTiledDeconv
            options.tiledDeconvAPGrid = tiledDeconvAPGrid
            options.sigmaThreshold = sigmaThreshold
            options.drizzleScale = drizzleScale
            options.drizzlePixfrac = drizzlePixfrac
            options.useTwoStageQuality = useTwoStage
            options.twoStageAPGrid = twoStageGrid
            options.mode = mode
            options.useMultiAP = useMultiAP
            options.multiAPGrid = multiAPGrid
            // Bake-in fires when ANY post-stack sharpening flag was passed:
            // --sharpen (unsharp + wavelet bundle), --wiener-sigma (Wiener
            // deconv on its own), or --lr-sigma (Lucy-Richardson on its
            // own). Each flag enables only its specific stage so users can
            // empirically test 'pure' deconvolution against the reference
            // without unsharp halos getting in the way.
            // Bake-in fires only when the user explicitly asked for
            // sharpen / Wiener / LR. --smart-auto + --auto-psf flow
            // produces a stack + RFF-deconv saved file directly —
            // no Pipeline.process pass. The 2026-04-29 attempt to
            // route smart-auto through bake-in (for auto-stretch)
            // was reverted: the stretch + auto-PSF + RFF chain was
            // worse than the bare RFF output on lunar.
            let needsBakeIn = doUnsharpWavelet || wienerSigma != nil || lrSigma != nil
            if needsBakeIn {
                var sharpen = SharpenSettings()
                sharpen.enabled = true
                sharpen.unsharpEnabled = doUnsharpWavelet
                sharpen.amount = sharpenAmount
                sharpen.waveletEnabled = doUnsharpWavelet
                if let s = wienerSigma {
                    sharpen.wienerEnabled = true
                    sharpen.wienerSigma = s
                    sharpen.wienerSNR = wienerSNR
                }
                if let s = lrSigma {
                    sharpen.lrEnabled = true
                    sharpen.lrSigma = s
                    sharpen.lrIterations = lrIterations
                }
                options.bakeIn = LuckyStackBakeIn(
                    sharpen: sharpen,
                    toneCurve: ToneCurveSettings(),
                    toneCurveLUT: nil
                )
            }

            let started = Date()
            if !quiet, keepPercents.count > 1 {
                print("stack: starting keep=\(plan.percent)% → \(plan.url.lastPathComponent)")
            }
            do {
                let resultURL = try await LuckyStack.runAsync(
                    sourceURL: inputURL,
                    outputURL: plan.url,
                    options: options,
                    pipeline: pipeline
                ) { progress in
                    if !quiet {
                        Self.printProgress(progress)
                    }
                }
                let elapsed = Date().timeIntervalSince(started)
                let outputBytes = (
                    (try? FileManager.default.attributesOfItem(atPath: resultURL.path))?[.size] as? Int
                ) ?? 0
                perPercentMetrics.append([
                    "keepPercent": plan.percent,
                    "outputFile": resultURL.lastPathComponent,
                    "outputBytes": outputBytes,
                    "elapsedSeconds": elapsed
                ])
                if !quiet {
                    // `plan.percent` is the configured request; under
                    // --auto-keep the resolved keep% comes from the
                    // quality scan (logged via NSLog "Auto-keep: ...").
                    let modeNote = options.useAutoKeepPercent ? " (auto-keep)" : ""
                    print("stack: wrote \(resultURL.path) (keep=\(plan.percent)%\(modeNote)) in \(String(format: "%.2f", elapsed)) s")
                }
            } catch {
                cliStderr("stack: keep=\(plan.percent)%: \(error.localizedDescription)")
                return 1
            }
        }
        let totalElapsed = Date().timeIntervalSince(runStart)

        if let metricsPath {
            try? writeMultiMetricsJSON(
                to: URL(fileURLWithPath: metricsPath),
                inputURL: inputURL,
                perPercent: perPercentMetrics,
                totalElapsedSeconds: totalElapsed
            )
        }
        return 0
    }

    // MARK: - Helpers

    private static func printProgress(_ progress: LuckyStackProgress) {
        switch progress {
        case .opening(let url):
            cliStderr("[stack] opening \(url.lastPathComponent)")
        case .grading(let done, let total):
            // Throttle: only every ~10% of frames.
            if done == total || (total > 0 && done % max(1, total / 10) == 0) {
                cliStderr("[stack] grading \(done)/\(total)")
            }
        case .sorting:
            cliStderr("[stack] sorting")
        case .buildingReference(let done, let total):
            if total > 0 && done == total {
                cliStderr("[stack] reference built (\(done)/\(total))")
            }
        case .stacking(let done, let total):
            if done == total || (total > 0 && done % max(1, total / 10) == 0) {
                cliStderr("[stack] stacking \(done)/\(total)")
            }
        case .writing:
            cliStderr("[stack] writing output")
        case .finished:
            break  // top-level reports the URL + elapsed
        case .error(let message):
            cliStderr("[stack] ERROR: \(message)")
        }
    }

    /// Single- or multi-percentage metrics. For single-% runs the
    /// shape is the same as before plus the percentage list (length
    /// 1). For multi-% the per-percent details land in
    /// `keepPercents` so the regression harness can diff each output
    /// independently while the total wall-clock stays at the top
    /// level.
    private static func writeMultiMetricsJSON(
        to url: URL,
        inputURL: URL,
        perPercent: [[String: Any]],
        totalElapsedSeconds: TimeInterval
    ) throws {
        // Sort entries by keepPercent for stable JSON ordering.
        let sortedPerPercent = perPercent.sorted { lhs, rhs in
            ((lhs["keepPercent"] as? Int) ?? 0) < ((rhs["keepPercent"] as? Int) ?? 0)
        }
        let metrics: [String: Any] = [
            "inputFile": inputURL.lastPathComponent,
            "elapsedSeconds": totalElapsedSeconds,
            "keepPercents": sortedPerPercent
        ]
        let data = try JSONSerialization.data(
            withJSONObject: metrics,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
