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
import CoreGraphics
import Foundation
import ImageIO

enum Validate {
    static func run(args: [String]) async -> Int32 {
        var dirArg: String?
        var regenerate = false
        var quiet = false
        var filter: String?
        // AutoAP sweep mode — for each fixture, runs stack twice
        // (multi-AP off vs multi-AP + AutoAP fast) and prints the
        // LAPD-sharpness ratio + wall-clock ratio. Pure measurement
        // tool: doesn't touch baselines, doesn't gate exit code on
        // quality (some fixtures benefit, some don't, the sweep just
        // surfaces the picture). Pass criteria from the plan:
        //   - auto LAPD ≥ baseline LAPD − 2% on every fixture
        //   - auto LAPD ≥ baseline LAPD + 5% on at least 4 / 7
        //   - auto wall-clock ≤ 1.3 × baseline
        var autoAPSweep = false

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
            case "--auto-ap-sweep":
                autoAPSweep = true
                i += 1
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

        if autoAPSweep {
            return await runAutoAPSweep(
                cli: cli, serFiles: serFiles, root: testimagesURL,
                tmpDir: tmpDir, quiet: quiet
            )
        }

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

    // MARK: - AutoAP sweep

    /// Runs each SER fixture through `stack --smart-auto --keep 25` in
    /// two configurations:
    ///   1. "baseline" — no multi-AP, current default behaviour
    ///   2. "auto"     — multi-AP on with AutoAP `.fast` (the new
    ///                   default-on path)
    /// Captures `outputSharpness` (variance-of-Laplacian) + wall-clock
    /// from each run and prints a per-fixture comparison + summary
    /// against the plan's pass criteria. Does NOT write or read
    /// baselines — this is a measurement tool, not a regression check.
    private static func runAutoAPSweep(
        cli: String, serFiles: [URL], root: URL,
        tmpDir: URL, quiet: Bool
    ) async -> Int32 {
        struct Row {
            let key: String
            let baselineLAPD: Double?      // multi-AP off
            let presetLAPD: Double?        // multi-AP on, prior preset geometry
            let autoLAPD: Double?          // multi-AP on, AutoAP fast
            let baselineWall: Double
            let autoWall: Double
        }
        var rows: [Row] = []

        for ser in serFiles {
            let key = baselineKey(for: ser, root: root)
            if !quiet { print("→ \(key)") }

            // Run 1: baseline (no multi-AP, AutoAP off)
            let outBaseline = tmpDir.appendingPathComponent("\(key).baseline.tif")
            let metricsBaseline = tmpDir.appendingPathComponent("\(key).baseline.json")
            let baselineStart = Date()
            _ = runProcess(executable: cli, args: [
                "stack", ser.path, outBaseline.path,
                "--smart-auto", "--keep", "25",
                "--auto-ap", "off",
                "--quiet", "--metrics", metricsBaseline.path
            ])
            let baselineWall = Date().timeIntervalSince(baselineStart)
            let baselineLAPD = readSharpness(metricsBaseline)

            // Run 2: multi-AP on with prior preset geometry (no AutoAP)
            // — pins multi-ap-grid to 10 (mid-range of historical
            // preset values) so we measure AutoAP's geometry win
            // separately from the multi-AP-itself effect.
            let outPreset = tmpDir.appendingPathComponent("\(key).preset.tif")
            let metricsPreset = tmpDir.appendingPathComponent("\(key).preset.json")
            _ = runProcess(executable: cli, args: [
                "stack", ser.path, outPreset.path,
                "--smart-auto", "--keep", "25",
                "--multi-ap", "--multi-ap-grid", "10",
                "--auto-ap", "off",
                "--quiet", "--metrics", metricsPreset.path
            ])
            let presetLAPD = readSharpness(metricsPreset)

            // Run 3: AutoAP fast + multi-AP on
            let outAuto = tmpDir.appendingPathComponent("\(key).auto.tif")
            let metricsAuto = tmpDir.appendingPathComponent("\(key).auto.json")
            let autoStart = Date()
            _ = runProcess(executable: cli, args: [
                "stack", ser.path, outAuto.path,
                "--smart-auto", "--keep", "25",
                "--multi-ap",
                "--auto-ap", "fast",
                "--quiet", "--metrics", metricsAuto.path
            ])
            let autoWall = Date().timeIntervalSince(autoStart)
            let autoLAPD = readSharpness(metricsAuto)

            rows.append(Row(
                key: key,
                baselineLAPD: baselineLAPD,
                presetLAPD: presetLAPD,
                autoLAPD: autoLAPD,
                baselineWall: baselineWall,
                autoWall: autoWall
            ))
        }

        // Print summary table.
        // String(format:) with %s on Swift String is undefined and
        // crashes; format numerics with String(format:) and pad the
        // strings via String repetition.
        print("")
        print("AutoAP sweep — three-way per fixture:")
        print("  base = multi-AP off ; preset = multi-AP on with grid 10×10 ; auto = multi-AP on with AutoAP")
        print("  " + padRight("fixture", 44) + " "
              + padLeft("base LAPD", 10) + " "
              + padLeft("preset", 10) + " "
              + padLeft("auto", 10) + " "
              + padLeft("Δvs base", 9) + " "
              + padLeft("Δvs preset", 11) + " "
              + padLeft("auto s", 7))
        var fixturesAutoBeatsPreset = 0
        var fixturesAutoBeatsBase = 0
        var totalBaselineWall: Double = 0
        var totalAutoWall: Double = 0
        for r in rows {
            let baseStr = r.baselineLAPD.map { String(format: "%.3e", $0) } ?? "—"
            let presetStr = r.presetLAPD.map { String(format: "%.3e", $0) } ?? "—"
            let autoStr = r.autoLAPD.map { String(format: "%.3e", $0) } ?? "—"
            let dBaseStr: String
            if let b = r.baselineLAPD, let a = r.autoLAPD, b > 0 {
                let d = (a - b) / b * 100
                dBaseStr = String(format: "%+6.1f%%", d)
                if d > 0 { fixturesAutoBeatsBase += 1 }
            } else {
                dBaseStr = "—"
            }
            let dPresetStr: String
            if let p = r.presetLAPD, let a = r.autoLAPD, p > 0 {
                let d = (a - p) / p * 100
                dPresetStr = String(format: "%+6.1f%%", d)
                if d > 0 { fixturesAutoBeatsPreset += 1 }
            } else {
                dPresetStr = "—"
            }
            totalBaselineWall += r.baselineWall
            totalAutoWall += r.autoWall
            let autoWallStr = String(format: "%6.2f", r.autoWall)
            print("  " + padRight(r.key, 44) + " "
                  + padLeft(baseStr, 10) + " "
                  + padLeft(presetStr, 10) + " "
                  + padLeft(autoStr, 10) + " "
                  + padLeft(dBaseStr, 9) + " "
                  + padLeft(dPresetStr, 11) + " "
                  + padLeft(autoWallStr, 7))
        }

        // Pass criteria — restated for the three-way sweep:
        //   (a) AutoAP geometry ≥ preset geometry on EVERY fixture
        //       (the user's "manual change should make it worse" bar:
        //        the hand-tuned preset 10×10 is the "manual" choice
        //        AutoAP must beat).
        //   (b) Multi-AP + AutoAP ≥ multi-AP off on at least half
        //       the fixtures (multi-AP itself only helps on data
        //       with measurable atmospheric shear; it's expected
        //       to lose on already-clean captures).
        //   (c) AutoAP wall-clock overhead ≤ 1.3× the no-multi-AP
        //       baseline.
        print("")
        print("Pass criteria:")
        let critA = fixturesAutoBeatsPreset == rows.count
        let critB = fixturesAutoBeatsBase * 2 >= rows.count
        let wallRatio = totalBaselineWall > 0 ? totalAutoWall / totalBaselineWall : 1.0
        let critC = wallRatio <= 1.3
        let critAStr = critA
            ? "✓ AutoAP beats preset on \(rows.count)/\(rows.count)"
            : "✗ AutoAP beats preset on \(fixturesAutoBeatsPreset)/\(rows.count)"
        let critBStr = critB
            ? "✓ multi-AP+auto helps on \(fixturesAutoBeatsBase)/\(rows.count)"
            : "✗ multi-AP+auto helps on \(fixturesAutoBeatsBase)/\(rows.count)"
        let wallRatioStr = String(format: "%.2fx", wallRatio)
        print("  (a) AutoAP geometry beats preset    : " + critAStr)
        print("  (b) multi-AP+auto helps ≥ ½ fixtures: " + critBStr)
        print("  (c) wall-clock ratio ≤ 1.3×          : " + (critC ? "✓" : "✗") + " (" + wallRatioStr + ")")

        let passed = critA && critB && critC
        print("")
        print("AutoAP sweep: \(passed ? "PASS" : "FAIL")")
        return passed ? 0 : 1
    }

    private static func padLeft(_ s: String, _ n: Int) -> String {
        let pad = max(0, n - s.count)
        return String(repeating: " ", count: pad) + s
    }
    private static func padRight(_ s: String, _ n: Int) -> String {
        let pad = max(0, n - s.count)
        return s + String(repeating: " ", count: pad)
    }

    private static func readSharpness(_ url: URL) -> Double? {
        guard let raw = readJSONObject(url) else { return nil }
        // Multi-keep metrics nest the sharpness value inside
        // `keepPercents[N].outputSharpness`; for single-keep there's
        // exactly one entry. Pull the first.
        if let arr = raw["keepPercents"] as? [[String: Any]],
           let first = arr.first,
           let s = (first["outputSharpness"] as? NSNumber)?.doubleValue {
            return s
        }
        return nil
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
        var produced = sanitiseStackMetrics(producedRaw)
        // F3 v1.3 — RMSE vs an optional sibling reference image. The
        // harness looks for `<basename>.reference.{png,tif,tiff}` next
        // to the SER; absent → metric silently omitted (~half of our
        // baselines have AS!3 references on disk today). When present,
        // each per-keep entry gets a `referenceRMSE` field that the
        // tolerance-bucket diff catches at ±5%.
        if let refURL = findReferenceImage(for: ser) {
            attachReferenceRMSE(
                to: &produced, producedTIF: outputTif, referenceURL: refURL
            )
        }

        if regenerate {
            return writeJSON(produced, to: baselinePath, label: "\(baselineKey) stack", quiet: quiet)
        }

        guard let baseline = readJSONObject(baselinePath) else {
            cliStderr("  ✗ \(baselineKey) stack: missing baseline at \(baselinePath.path) — run with --regenerate to create")
            return false
        }
        // outputBytes drifts ±2 % between builds (TIFF compression
        // version-quirks); the quality metrics ride last-bit noise in
        // the rgba16Float accumulator and need a looser ±5 %.
        // F3 v1 = outputBytes only; v1.1 added outputSharpness;
        // v1.2 added FFT mid + high band fractions. All three quality
        // axes share the same tolerance bucket — they're independent
        // measurements but the noise floor scales similarly.
        let diff = diffJSON(
            produced, baseline,
            ignore: ["elapsedSeconds", "outputFile"],
            byteTolerantKeys: ["outputBytes"],
            qualityTolerantKeys: [
                "outputSharpness",
                "outputFFTMidFraction",
                "outputFFTHighFraction",
                "referenceRMSE",
            ]
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
          --regenerate     Rewrite baselines instead of diffing. Use after
                           intentional calibration changes.
          --filter <s>     Only run files whose path contains <s>.
          --quiet          Suppress per-file PASS lines; only print drift
                           and the summary.
          --auto-ap-sweep  Run an A/B comparison: stack each fixture once
                           with multi-AP off, once with multi-AP + AutoAP
                           fast. Prints LAPD-sharpness delta + wall-clock
                           ratio per fixture. Pass criteria: every fixture
                           within −2% of baseline, ≥ +5% on ≥ 4/N, total
                           wall-clock ≤ 1.3× baseline.

        EXIT CODES:
          0  all baselines match
          1  drift detected
          64 usage error / missing input
        """
        print(body)
    }

    // MARK: - F3 v1.3 — RMSE vs reference image

    /// Look for a sibling reference image alongside the SER. Convention:
    /// `<basename>.reference.{png,tif,tiff}` — same dir as the SER, same
    /// basename minus extension, plus a `.reference` token. Returns nil
    /// if none of the candidate paths exist.
    private static func findReferenceImage(for serURL: URL) -> URL? {
        let dir = serURL.deletingLastPathComponent()
        let stem = serURL.deletingPathExtension().lastPathComponent
        for ext in ["png", "tif", "tiff", "PNG", "TIF", "TIFF"] {
            let candidate = dir
                .appendingPathComponent("\(stem).reference.\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Attach `referenceRMSE` to every keepPercents entry in `produced`.
    /// Both the produced TIF and the reference image are loaded as 8-bit
    /// luma, the reference is resampled to the produced dimensions if
    /// they differ, and the per-pixel RMSE is computed in [0, 1].
    /// Missing-on-disk / decode failures silently skip the field rather
    /// than raising — the metric is opportunistic, not required.
    private static func attachReferenceRMSE(
        to produced: inout [String: Any],
        producedTIF: URL,
        referenceURL: URL
    ) {
        guard let rmse = computeRMSE(produced: producedTIF, reference: referenceURL) else {
            return
        }
        if var arr = produced["keepPercents"] as? [[String: Any]] {
            for j in 0..<arr.count {
                arr[j]["referenceRMSE"] = rmse
            }
            produced["keepPercents"] = arr
        }
    }

    /// Per-pixel root-mean-square error between two images, computed on
    /// 8-bit luma. Values normalised to [0, 1]. Reference is resampled
    /// to the produced image's pixel dimensions when they differ —
    /// AS!3's pre-shipped outputs are sometimes cropped or scaled
    /// relative to ours and treating that as drift would just be
    /// noise. Returns nil on decode / readback failure.
    private static func computeRMSE(produced: URL, reference: URL) -> Double? {
        guard let p = loadLumaBitmap(produced),
              let dim = produced8Dimensions(produced)
        else { return nil }
        guard let r = loadLumaBitmap(reference, resizeTo: dim) else { return nil }
        guard p.count == r.count, !p.isEmpty else { return nil }
        var sumSq: Double = 0
        for i in 0..<p.count {
            let d = (Double(p[i]) - Double(r[i])) / 255.0
            sumSq += d * d
        }
        return (sumSq / Double(p.count)).squareRoot()
    }

    private static func produced8Dimensions(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// Decode `url` to an 8-bit luma byte buffer. Optional `resizeTo`
    /// resamples via CoreGraphics' default high-quality interpolation
    /// before flattening to luma — used when the reference image and
    /// the produced TIF differ in pixel dimensions.
    private static func loadLumaBitmap(_ url: URL, resizeTo: (Int, Int)? = nil) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let w: Int
        let h: Int
        if let target = resizeTo {
            w = target.0; h = target.1
        } else {
            w = cg.width; h = cg.height
        }
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixels
    }
}
