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
        var keepPercent = 25
        var metricsPath: String?
        var quiet = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--keep":
                guard i + 1 < args.count, let v = Int(args[i + 1]),
                      v >= 1, v <= 99
                else {
                    cliStderr("stack: --keep requires an integer in [1, 99]")
                    return 64
                }
                keepPercent = v
                i += 2
            case "--metrics":
                guard i + 1 < args.count else {
                    cliStderr("stack: --metrics requires a path argument")
                    return 64
                }
                metricsPath = args[i + 1]
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
            cliStderr("usage: astrosharper stack <input.ser> <output.tif> [--keep N] [--metrics file.json] [--quiet]")
            return 64
        }

        let inputURL  = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

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
        let outputDir = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true
        )

        var options = LuckyStackOptions()
        options.keepPercent = keepPercent

        let pipeline = Pipeline()

        let started = Date()
        do {
            let resultURL = try await LuckyStack.runAsync(
                sourceURL: inputURL,
                outputURL: outputURL,
                options: options,
                pipeline: pipeline
            ) { progress in
                if !quiet {
                    Self.printProgress(progress)
                }
            }
            let elapsed = Date().timeIntervalSince(started)

            if !quiet {
                print("stack: wrote \(resultURL.path) in \(String(format: "%.2f", elapsed)) s")
            }

            if let metricsPath {
                try writeMetricsJSON(
                    to: URL(fileURLWithPath: metricsPath),
                    inputURL: inputURL,
                    outputURL: resultURL,
                    keepPercent: keepPercent,
                    elapsedSeconds: elapsed
                )
            }
            return 0
        } catch {
            cliStderr("stack: \(error.localizedDescription)")
            return 1
        }
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

    private static func writeMetricsJSON(
        to url: URL,
        inputURL: URL,
        outputURL: URL,
        keepPercent: Int,
        elapsedSeconds: TimeInterval
    ) throws {
        let outputAttrs = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)) ?? [:]
        let outputBytes = (outputAttrs[.size] as? Int) ?? 0

        let metrics: [String: Any] = [
            "inputFile": inputURL.lastPathComponent,
            "outputFile": outputURL.lastPathComponent,
            "keepPercent": keepPercent,
            "elapsedSeconds": elapsedSeconds,
            "outputBytes": outputBytes
        ]
        let data = try JSONSerialization.data(
            withJSONObject: metrics,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
