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
        var doSharpen = false
        var sharpenAmount: Double = 1.0  // applied only when --sharpen is set
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
                doSharpen = true
                i += 1
            case "--sharpen-amount":
                guard i + 1 < args.count, let v = Double(args[i + 1]),
                      v.isFinite, v >= 0, v <= 5
                else {
                    cliStderr("stack: --sharpen-amount requires a number in [0, 5] (default 1.0)")
                    return 64
                }
                sharpenAmount = v
                doSharpen = true
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
            cliStderr("usage: astrosharper stack <input.ser> <output.tif> [--keep N|N,N,...] [--mode lightspeed|scientific] [--multi-ap [--multi-ap-grid N]] [--two-stage [--two-stage-grid N]] [--sigma N] [--drizzle N [--pixfrac X]] [--sharpen [--sharpen-amount X]] [--metrics file.json] [--quiet]")
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
            options.sigmaThreshold = sigmaThreshold
            options.drizzleScale = drizzleScale
            options.drizzlePixfrac = drizzlePixfrac
            options.useTwoStageQuality = useTwoStage
            options.twoStageAPGrid = twoStageGrid
            options.mode = mode
            options.useMultiAP = useMultiAP
            options.multiAPGrid = multiAPGrid
            if doSharpen {
                // Engine defaults: unsharp on, wavelet OFF. Flip wavelet on
                // and override `amount` so a single --sharpen flag delivers
                // the BiggSky / Registax-style "sharpened final" look.
                var sharpen = SharpenSettings()
                sharpen.enabled = true
                sharpen.unsharpEnabled = true
                sharpen.amount = sharpenAmount
                sharpen.waveletEnabled = true
                options.bakeIn = LuckyStackBakeIn(
                    sharpen: sharpen,
                    toneCurve: ToneCurveSettings(),  // disabled by default — keep the float TIFF linear
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
                    print("stack: wrote \(resultURL.path) (keep=\(plan.percent)%) in \(String(format: "%.2f", elapsed)) s")
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
