// `astrosharper transit <file.ser>` — detect + measure an ISS / aircraft
// transit in a SharpCap capture. Thin CLI wrapper over the shared
// `TransitDetector` engine so the acceptance suite can diff its JSON against
// the validated Python reference `ser_transit.py`.
//
//   astrosharper transit <file.ser> [--json] [--bin N] [--proof out.png]
//                                    [--focal-length-mm X] [--pixel-size-um Y]
//                                    [--no-dual-polarity]
import Foundation

enum Transit {
    static func run(args: [String]) -> Int32 {
        var path: String?
        var emitJSON = false
        var config = TransitConfig()

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--json":
                emitJSON = true; i += 1
            case "--bin":
                guard i + 1 < args.count, let v = Int(args[i+1]), v >= 1 else {
                    cliStderr("transit: --bin requires an integer ≥ 1"); return 64
                }
                config.bin = v; i += 2
            case "--proof":
                guard i + 1 < args.count else { cliStderr("transit: --proof requires an output path"); return 64 }
                config.proofImageURL = URL(fileURLWithPath: args[i+1]); i += 2
            case "--focal-length-mm":
                guard i + 1 < args.count, let v = Double(args[i+1]), v > 0 else {
                    cliStderr("transit: --focal-length-mm requires a positive number"); return 64
                }
                config.focalLengthMM = v; i += 2
            case "--pixel-size-um":
                guard i + 1 < args.count, let v = Double(args[i+1]), v > 0 else {
                    cliStderr("transit: --pixel-size-um requires a positive number"); return 64
                }
                config.pixelSizeUM = v; i += 2
            case "--no-dual-polarity":
                config.dualPolarity = false; i += 1
            case "--debug":
                config.debug = true; i += 1
            case let opt where opt.hasPrefix("--"):
                cliStderr("transit: unknown option '\(opt)'")
                cliStderr(usage); return 64
            default:
                if path != nil { cliStderr("transit: only one input file accepted"); return 64 }
                path = arg; i += 1
            }
        }

        guard let inputPath = path else {
            cliStderr("transit: missing input file path"); cliStderr(usage); return 64
        }
        let url = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            cliStderr("transit: file not found: \(url.path)"); return 1
        }

        let clock = Date()
        do {
            let result = try TransitDetector.detect(url: url, config: config)
            if emitJSON {
                print(result.jsonString())
            } else {
                emitText(result, file: url, elapsed: Date().timeIntervalSince(clock))
            }
            // Exit 0 when detected, 3 when clean (nothing crossed) — lets a
            // batch script branch without parsing JSON.
            return result.detected ? 0 : 3
        } catch {
            cliStderr("transit: detection failed for '\(url.path)': \(error)")
            return 1
        }
    }

    private static let usage =
        "usage: astrosharper transit <file.ser> [--json] [--bin N] [--proof out.png] " +
        "[--focal-length-mm X] [--pixel-size-um Y] [--no-dual-polarity]"

    private static func emitText(_ r: TransitResult, file url: URL, elapsed: TimeInterval) {
        print("file        : \(url.lastPathComponent)")
        print("mode        : \(r.mode.rawValue)")
        print("frames      : \(r.frames)")
        print("detected    : \(r.detected)")
        if let s = r.plateScaleArcsecPx {
            let src = r.plateScaleSource.map { " (\($0.rawValue))" } ?? ""
            print("plate scale : \(s) arcsec/px\(src)  disc-reliable=\(r.discReliable.map(String.init) ?? "n/a")")
        }
        for (n, e) in r.transits.enumerated() {
            print("--- transit \(n + 1)\(r.transits.count > 1 ? " of \(r.transits.count)" : "") ---")
            let where_ = e.onDisc.map { $0 ? " [on disc]" : " [off disc]" } ?? ""
            if e.moving {
                print("  moving    : yes\(where_)  frames \(e.activeFrames.first ?? 0)→\(e.activeFrames.last ?? 0) (\(e.nActive) pts)")
                if let en = e.entryPx, let ex = e.exitPx { print("  entry→exit: (\(en[0]),\(en[1])) → (\(ex[0]),\(ex[1])) px") }
                if let sp = e.speedPxPerFrame { print("  speed     : \(sp) px/frame  dir \(e.directionDeg ?? 0)°  R²=\(e.straightnessR2 ?? 0)") }
                if let tl = e.trackLenPx { print("  track len : \(tl) px") }
            } else {
                print("  moving    : no\(where_)  single blob at frame \(e.activeFrames.first ?? 0), peak z=\(e.peakZAtObject ?? 0)")
                if let en = e.entryPx { print("  position  : (\(en[0]),\(en[1])) px") }
            }
            print("  separation: \(e.separationPx) px" + (e.separationDeg.map { "  (\($0)°)" } ?? ""))
        }
        print("elapsed     : \(String(format: "%.1f", elapsed)) s")
    }
}
