// Multi-percentage keep-list parser.
//
// BiggSky's documented workflow lets the user enter several keep-%
// values in one field (e.g. "20, 40, 60, 80") so they can compare
// stack-quality vs. retention-rate side-by-side without re-running the
// whole pipeline four times manually. The parser turns that user
// string into a clean integer array; the UI / runner then iterates the
// existing LuckyStack.run() per percentage.
//
// v0 is the parser only. The single-pass accumulator (writing to N
// output buffers in one read pass) is the v1 optimisation — it saves
// real time on 5000-frame SERs but requires changes to the GPU
// accumulator kernel. Until then the AppModel loop runs the pipeline
// once per percentage; the savings come from the per-percentage outputs
// being side-by-side comparable rather than re-typed.
import Foundation

enum LuckyKeepPercents {

    /// Smallest accepted keep-%. 0 would mean "keep no frames" and is
    /// rejected; 1% is the academic lucky-imaging extreme.
    static let minPercent = 1

    /// Largest accepted keep-%. 99% means "almost the whole stack" —
    /// 100 would skip the lucky selection entirely so we cap at 99.
    static let maxPercent = 99

    /// Parse a comma- (or whitespace-) separated list of keep-percent
    /// values into a sorted, deduplicated, validated integer array.
    ///
    /// Whitespace, semicolons, and `%` symbols are tolerated. Tokens
    /// that don't parse to an integer in `[minPercent, maxPercent]`
    /// are silently dropped — the UI can re-render the cleaned list so
    /// the user sees what we accepted.
    ///
    /// Examples:
    ///
    ///   "20, 40, 60, 80"        → [20, 40, 60, 80]
    ///   "20,40, 60 , 80%"       → [20, 40, 60, 80]
    ///   "60, 20, 40"            → [20, 40, 60]   (sorted)
    ///   "20, 20, 40, 40"        → [20, 40]       (deduped)
    ///   "20, foo, 40, 200, 0"   → [20, 40]       (foo / 200 / 0 rejected)
    ///   ""                      → []
    static func parse(_ input: String) -> [Int] {
        // Permissive splitter: comma, semicolon, or whitespace runs.
        let separators: CharacterSet = .init(charactersIn: ",;").union(.whitespaces)
        let tokens = input
            .components(separatedBy: separators)
            .map { $0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var seen: Set<Int> = []
        var out: [Int] = []
        for tok in tokens {
            guard let n = Int(tok) else { continue }
            guard n >= minPercent && n <= maxPercent else { continue }
            if seen.insert(n).inserted {
                out.append(n)
            }
        }
        return out.sorted()
    }

    /// Render a clean canonical string of the percent list — the inverse
    /// operation of `parse`. Useful when echoing the parsed list back
    /// into the UI text field after the user blurs it.
    static func format(_ percents: [Int]) -> String {
        percents.map { String($0) }.joined(separator: ", ")
    }

    /// Filename suffix for a given percent — SharpCap-style: `_p25.tif`.
    /// Used by the UI loop when generating per-output filenames.
    static func filenameSuffix(percent: Int) -> String {
        "_p\(percent)"
    }
}
