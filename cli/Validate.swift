// astrosharper validate — F3 regression harness.
//
// Walks a TESTIMAGES tree for `.ser` files, runs `analyze --json` and
// `stack --smart-auto --keep 25 --metrics` on each, and diffs the
// produced metrics against committed baselines under
// `Tests/Regression/baselines/`.
//
// Baseline naming: <parent-dir>__<filename>.json (analyze) and
// <parent-dir>__<filename>.stack.json (stack). The double underscore
// disambiguates files with similar names across subjects.
//
// Invokes itself as a subprocess for the analyze + stack runs so the
// regression harness exercises exactly the same code path users hit
// when running the CLI directly. If the in-process binary path is
// unknown we fall back to PATH lookup of `astrosharper`.
//
// Volatile fields stripped before comparing:
//   - elapsedSeconds (timing varies machine to machine)
//   - outputFile (absolute path or auto-generated tempname)
// Tolerated drift:
//   - outputBytes ±2 % (TIFF compression deterministic but build /
//     toolchain version can shift it slightly)
//
// Exit codes: 0 all green; 1 drift detected; 64 usage error.
import Foundation

enum Validate {
    static func run(args: [String]) async -> Int32 {
        var dirArg: String?
        var regenerate = false
        var quiet = false
        var filter: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--regenerate":
                regenerate = true
                i += 1
            case "--quiet":
                quiet = true
                i += 1
            case "--filter":
                guard i + 1 < args.count else {
                    cliStderr("validate: --filter requires a substring argument")
                    return 64
                }
                filter = args[i + 1]
                i += 2
            case "--help", "-h":
                printUsage()
                return 0
            default:
                if args[i].hasPrefix("-") {
                    cliStderr("validate: unknown option '\(args[i])'")
                    return 64
                }
                if dirArg != nil {
                    cliStderr("validate: only one TESTIMAGES directory accepted")
                    return 64
                }
                dirArg = args[i]
                i += 1
            }
        }

        guard let dirArg else {
            printUsage()
            return 64
        }
        let testimagesURL = URL(fileURLWithPath: dirArg).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: testimagesURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            cliStderr("validate: '\(testimagesURL.path)' is not a directory")
            return 64
        }

        // Locate baselines/ relative to the repo root. The CLI always
        // builds inside the same project, so its binary lives at
        // <DerivedData>/Build/Products/<config>/astrosharper, and the
        // SOURCE root is the test-data root. The binary path itself
        // is fragile — find baselines/ by walking up from the binary
        // until we find a `Tests/Regression/baselines` directory.
        guard let baselinesURL = findBaselinesDir() else {
            cliStderr("validate: could not locate Tests/Regression/baselines/ relative to the binary path. Is the CLI built inside the AstroSharper project tree?")
            return 64
        }

        // Enumerate .ser files. Stable sort by relative path so the
        // output is reproducible across runs.
        let serFiles = enumerateSER(under: testimagesURL, filter: filter).sorted {
            $0.path < $1.path
        }
        guard !serFiles.isEmpty else {
            cliStderr("validate: no .ser files found under \(testimagesURL.path)\(filter.map { " (filter: \($0))" } ?? "")")
            return 64
        }

        let cli = ownBinaryPath()
        var passes = 0
        var fails = 0
        var failedFiles: [String] = []

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astrosharper-validate-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for ser in serFiles {
            let baselineKey = baselineKey(for: ser, root: testimagesURL)
            if !quiet {
                print("→ \(baselineKey)")
            }

            let analyzeOK = runAnalyzeAndDiff(
                cli: cli, ser: ser, baselineKey: baselineKey,
                baselinesURL: baselinesURL, regenerate: regenerate, quiet: quiet
            )
            let stackOK = await runStackAndDiff(
                cli: cli, ser: ser, baselineKey: baselineKey,
                baselinesURL: baselinesURL, tmpDir: tmpDir,
                regenerate: regenerate, quiet: quiet
            )

            if analyzeOK && stackOK {
                passes += 1
            } else {
                fails += 1
                failedFiles.append(baselineKey)
            }
        }

        // Summary.
        print("")
        print("validate: \(passes) passed, \(fails) failed (out of \(serFiles.count))")
        if !failedFiles.isEmpty {
            print("failed:")
            for f in failedFiles { print("  - \(f)") }
        }
        if regenerate {
            print("(--regenerate: baselines rewritten; re-run without the flag to verify)")
        }
        return fails == 0 ? 0 : 1
    }

    // MARK: - Per-file runners

    private static func runAnalyzeAndDiff(
        cli: String, ser: URL, baselineKey: String,
        baselinesURL: URL, regenerate: Bool, quiet: Bool
    ) -> Bool {
        let baselinePath = baselinesURL.appendingPathComponent("\(baselineKey).json")
        let result = runProcess(executable: cli, args: ["analyze", "--json", ser.path])
        guard result.exitCode == 0,
              let produced = parseJSONObject(result.stdout) else {
            cliStderr("  ✗ \(baselineKey) analyze: process failed (exit \(result.exitCode))")
            return false
        }

        if regenerate {
            return writeJSON(produced, to: baselinePath, label: "\(baselineKey) analyze", quiet: quiet)
        }

        guard let baseline = readJSONObject(baselinePath) else {
            cliStderr("  ✗ \(baselineKey) analyze: missing baseline at \(baselinePath.path) — run with --regenerate to create")
            return false
        }
        let diff = diffJSON(produced, baseline, ignore: [], byteTolerantKeys: [])
        if diff.isEmpty {
            if !quiet { print("  ✓ analyze") }
            return true
        }
        cliStderr("  ✗ \(baselineKey) analyze drift:")
        for line in diff { cliStderr("    \(line)") }
        return false
    }

    private static func runStackAndDiff(
        cli: String, ser: URL, baselineKey: String,
        baselinesURL: URL, tmpDir: URL,
        regenerate: Bool, quiet: Bool
    ) async -> Bool {
        let baselinePath = baselinesURL.appendingPathComponent("\(baselineKey).stack.json")
        let outputTif = tmpDir.appendingPathComponent("\(baselineKey).tif")
        let metricsTmp = tmpDir.appendingPathComponent("\(baselineKey).stack.json")

        let stackArgs = [
            "stack", ser.path, outputTif.path,
            "--smart-auto", "--keep", "25",
            "--quiet", "--metrics", metricsTmp.path
        ]
        let result = runProcess(executable: cli, args: stackArgs)
        guard result.exitCode == 0 else {
            cliStderr("  ✗ \(baselineKey) stack: process failed (exit \(result.exitCode))\n\(result.stderr)")
            return false
        }
        guard let producedRaw = readJSONObject(metricsTmp) else {
            cliStderr("  ✗ \(baselineKey) stack: --metrics output unreadable")
            return false
        }
        let produced = sanitiseStackMetrics(producedRaw)

        if regenerate {
            return writeJSON(produced, to: baselinePath, label: "\(baselineKey) stack", quiet: quiet)
        }

        guard let baseline = readJSONObject(baselinePath) else {
            cliStderr("  ✗ \(baselineKey) stack: missing baseline at \(baselinePath.path) — run with --regenerate to create")
            return false
        }
        // outputBytes drifts ±2 % between builds (TIFF compression
        // version-quirks); outputSharpness drifts ±5 % (variance-of-
        // Laplacian on rgba16Float is sensitive to last-bit noise in
        // the stack output). Both tolerances are wired in
        // `sameLeaf(a:b:key:byteTolerantKeys:)` — F3 v1 used a single
        // ±2 % bucket; v1.1 splits per-key for the noisier sharpness.
        let diff = diffJSON(
            produced, baseline,
            ignore: ["elapsedSeconds", "outputFile"],
            byteTolerantKeys: ["outputBytes"],
            qualityTolerantKeys: ["outputSharpness"]
        )
        if diff.isEmpty {
            if !quiet { print("  ✓ stack") }
            return true
        }
        cliStderr("  ✗ \(baselineKey) stack drift:")
        for line in diff { cliStderr("    \(line)") }
        return false
    }

    // MARK: - Helpers

    /// Strip volatile fields (timestamps, absolute paths) from the
    /// stack metrics produced by `astrosharper stack --metrics`.
    /// outputFile is set to the basename only; elapsedSeconds removed.
    private static func sanitiseStackMetrics(_ raw: [String: Any]) -> [String: Any] {
        var out = raw
        out.removeValue(forKey: "elapsedSeconds")
        if var arr = out["keepPercents"] as? [[String: Any]] {
            for j in 0..<arr.count {
                if let f = arr[j]["outputFile"] as? String {
                    arr[j]["outputFile"] = (f as NSString).lastPathComponent
                }
            }
            out["keepPercents"] = arr
        }
        return out
    }

    /// Recursive JSON diff. Returns human-readable lines.
    ///
    /// - `ignore`: keys skipped at any depth.
    /// - `byteTolerantKeys`: compared with ±2 % tolerance (tight —
    ///   for output file-size drift across builds).
    /// - `qualityTolerantKeys`: compared with ±5 % tolerance (looser
    ///   — for variance-of-Laplacian style image-quality metrics
    ///   that ride last-bit noise in the rgba16Float stack output).
    private static func diffJSON(
        _ produced: [String: Any], _ baseline: [String: Any],
        ignore: Set<String>,
        byteTolerantKeys: Set<String>,
        qualityTolerantKeys: Set<String> = [],
        path: String = ""
    ) -> [String] {
        var lines: [String] = []
        let keys = Set(produced.keys).union(baseline.keys).subtracting(ignore)
        for k in keys.sorted() {
            let key = path.isEmpty ? k : "\(path).\(k)"
            let pVal = produced[k]
            let bVal = baseline[k]
            switch (pVal, bVal) {
            case (nil, _):
                lines.append("MISSING in produced: \(key)")
            case (_, nil):
                lines.append("UNEXPECTED in produced: \(key) = \(String(describing: pVal!))")
            case (let p as [String: Any], let b as [String: Any]):
                lines.append(contentsOf: diffJSON(
                    p, b, ignore: ignore,
                    byteTolerantKeys: byteTolerantKeys,
                    qualityTolerantKeys: qualityTolerantKeys,
                    path: key
                ))
            case (let p as [Any], let b as [Any]):
                if p.count != b.count {
                    lines.append("LENGTH \(key): produced=\(p.count) baseline=\(b.count)")
                } else {
                    for idx in 0..<p.count {
                        if let pd = p[idx] as? [String: Any], let bd = b[idx] as? [String: Any] {
                            lines.append(contentsOf: diffJSON(
                                pd, bd, ignore: ignore,
                                byteTolerantKeys: byteTolerantKeys,
                                qualityTolerantKeys: qualityTolerantKeys,
                                path: "\(key)[\(idx)]"
                            ))
                        } else if !sameLeaf(
                            p[idx], b[idx], key: k,
                            byteTolerantKeys: byteTolerantKeys,
                            qualityTolerantKeys: qualityTolerantKeys
                        ) {
                            lines.append("\(key)[\(idx)]: produced=\(p[idx]) baseline=\(b[idx])")
                        }
                    }
                }
            default:
                if !sameLeaf(
                    pVal!, bVal!, key: k,
                    byteTolerantKeys: byteTolerantKeys,
                    qualityTolerantKeys: qualityTolerantKeys
                ) {
                    lines.append("\(key): produced=\(pVal!) baseline=\(bVal!)")
                }
            }
        }
        return lines
    }

    /// Tolerant leaf comparison:
    /// - ±2 % for keys in `byteTolerantKeys` (file-size drift)
    /// - ±5 % for keys in `qualityTolerantKeys` (image-quality metrics)
    /// - exact match otherwise.
    private static func sameLeaf(
        _ a: Any, _ b: Any, key: String,
        byteTolerantKeys: Set<String>,
        qualityTolerantKeys: Set<String> = []
    ) -> Bool {
        if byteTolerantKeys.contains(key) || qualityTolerantKeys.contains(key) {
            guard let an = (a as? NSNumber)?.doubleValue,
                  let bn = (b as? NSNumber)?.doubleValue,
                  bn > 0
            else { return false }
            let tol = byteTolerantKeys.contains(key) ? 0.02 : 0.05
            return abs(an - bn) / bn <= tol
        }
        return String(describing: a) == String(describing: b)
    }

    private static func enumerateSER(under root: URL, filter: String?) -> [URL] {
        var out: [URL] = []
        guard let it = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return out
        }
        for case let u as URL in it {
            guard u.pathExtension.lowercased() == "ser" else { continue }
            if let f = filter, !u.path.contains(f) { continue }
            out.append(u)
        }
        return out
    }

    /// Build the baseline key from a SER's PARENT directory + filename,
    /// joined with `__`. Mirrors the existing committed baseline names.
    private static func baselineKey(for ser: URL, root: URL) -> String {
        let parent = ser.deletingLastPathComponent().lastPathComponent
        return "\(parent)__\(ser.lastPathComponent)"
    }

    private static func findBaselinesDir() -> URL? {
        // Start from the CWD and walk up looking for Tests/Regression/baselines.
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cur
                .appendingPathComponent("Tests")
                .appendingPathComponent("Regression")
                .appendingPathComponent("baselines")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    private static func ownBinaryPath() -> String {
        let arg0 = CommandLine.arguments.first ?? "astrosharper"
        // arg0 may be relative — resolve against CWD.
        if arg0.hasPrefix("/") { return arg0 }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(arg0).standardizedFileURL.path
    }

    // MARK: - I/O

    private static func runProcess(executable: String, args: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ("", "launch failed: \(error)", 1)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            p.terminationStatus
        )
    }

    private static func parseJSONObject(_ str: String) -> [String: Any]? {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func writeJSON(_ obj: [String: Any], to url: URL, label: String, quiet: Bool) -> Bool {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
            if !quiet { print("  ✓ \(label) (regenerated)") }
            return true
        } catch {
            cliStderr("  ✗ \(label): write failed: \(error)")
            return false
        }
    }

    private static func printUsage() {
        let body = """
        astrosharper validate <testimages-dir> [options]

        Walks a directory of .ser captures, runs analyze + stack on each,
        and diffs the resulting metrics against committed baselines under
        Tests/Regression/baselines/.

        OPTIONS:
          --regenerate   Rewrite baselines instead of diffing. Use after
                         intentional calibration changes.
          --filter <s>   Only run files whose path contains <s>.
          --quiet        Suppress per-file PASS lines; only print drift
                         and the summary.

        EXIT CODES:
          0  all baselines match
          1  drift detected
          64 usage error / missing input
        """
        print(body)
    }
}
