// `astrosharper analyze <file.ser>` — print SER metadata + sanity stats.
//
// This is the smallest possible end-to-end exercise of the CLI: open a
// SER, parse the header, print a summary. Pure Foundation, no Metal
// device required, so it doubles as a build smoke test for the CLI
// target. Everything heavier (frame decode + Metal-backed metrics)
// lands when Block A's quality intelligence work is wired in.
import Foundation

enum Analyze {
    static func run(args: [String]) -> Int32 {
        // Single positional: input file path. Optional flag: --json.
        var path: String?
        var emitJSON = false

        for arg in args {
            switch arg {
            case "--json":
                emitJSON = true
            case let opt where opt.hasPrefix("--"):
                cliStderr("analyze: unknown option '\(opt)'")
                cliStderr("usage: astrosharper analyze <file.ser> [--json]")
                return 64
            default:
                if path != nil {
                    cliStderr("analyze: only one input file accepted (got '\(path!)' and '\(arg)')")
                    return 64
                }
                path = arg
            }
        }

        guard let inputPath = path else {
            cliStderr("analyze: missing input file path")
            cliStderr("usage: astrosharper analyze <file.ser> [--json]")
            return 64
        }

        let url = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            cliStderr("analyze: file not found: \(url.path)")
            return 1
        }

        do {
            let reader = try SerReader(url: url)
            if emitJSON {
                emit(json: reader)
            } else {
                emit(text: reader)
            }
            return 0
        } catch {
            cliStderr("analyze: failed to open '\(url.path)': \(error)")
            return 1
        }
    }

    // MARK: - Output

    private static func emit(text reader: SerReader) {
        let h = reader.header
        let totalBytes = h.frameCount * h.bytesPerFrame
        let totalGB = Double(totalBytes) / 1_000_000_000.0

        print("file        : \(reader.url.path)")
        print("dimensions  : \(h.imageWidth) × \(h.imageHeight)")
        print("frames      : \(h.frameCount)")
        print("bit depth   : \(h.pixelDepthPerPlane)")
        print("color       : \(h.colorID) (mono=\(h.colorID.isMono), bayer=\(h.colorID.isBayer), rgb=\(h.colorID.isRGB))")
        print("instrument  : \(emptyOrValue(h.instrument))")
        print("observer    : \(emptyOrValue(h.observer))")
        print("telescope   : \(emptyOrValue(h.telescope))")
        if let date = reader.captureDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            print("captured UT : \(formatter.string(from: date))")
        } else {
            print("captured UT : (unknown — header has no timestamp)")
        }
        print("frame bytes : \(h.bytesPerFrame.formatted())")
        print("total bytes : \(totalBytes.formatted()) (\(String(format: "%.2f", totalGB)) GB)")
    }

    private static func emit(json reader: SerReader) {
        let h = reader.header
        // Emit basename only (not absolute path) so the regression
        // harness's baselines are stable across machines and clones.
        // The full path is still in the input argument and the run log.
        var payload: [String: Any] = [
            "filename": reader.url.lastPathComponent,
            "imageWidth": h.imageWidth,
            "imageHeight": h.imageHeight,
            "frameCount": h.frameCount,
            "pixelDepth": h.pixelDepthPerPlane,
            "colorID": String(describing: h.colorID),
            "colorIsMono": h.colorID.isMono,
            "colorIsBayer": h.colorID.isBayer,
            "colorIsRGB": h.colorID.isRGB,
            "bytesPerFrame": h.bytesPerFrame,
            "totalBytes": h.frameCount * h.bytesPerFrame,
            "instrument": h.instrument,
            "observer": h.observer,
            "telescope": h.telescope
        ]
        if let date = reader.captureDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            payload["captureDateUTC"] = formatter.string(from: date)
        } else {
            payload["captureDateUTC"] = NSNull()
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            } else {
                cliStderr("analyze: JSON encoding produced no bytes")
            }
        } catch {
            cliStderr("analyze: JSON encode failed: \(error)")
        }
    }

    private static func emptyOrValue(_ s: String) -> String {
        s.isEmpty ? "(none)" : s
    }
}
