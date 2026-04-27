// Shared helpers for the astrosharper CLI: stderr writing, version
// metadata, and the usage block that several entry points print.
import Foundation

/// Write a line to stderr. Stdout stays clean for machine-readable
/// output (e.g. analyze --json), so error messages never pollute it.
func cliStderr(_ message: String) {
    let line = message.hasSuffix("\n") ? message : message + "\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

enum CLIInfo {
    /// Marketing version mirrors the AstroSharper app. Bumped together
    /// when v1.0 ships.
    static let version = "0.3.0"

    /// Build-time git description (set as a Swift compile flag in the
    /// future; for now a static placeholder).
    static let gitDescription = "feature/v1-foundation"
}

enum Usage {
    /// Print usage to stdout (or stderr when invoked from an error
    /// path) and exit with the supplied code. `destination` 1 = stdout,
    /// 2 = stderr.
    static func printAndExit(_ destination: Int, code: Int32) -> Never {
        let body = """
        astrosharper — headless CLI for the AstroSharper engine

        USAGE: astrosharper <subcommand> [options]

        SUBCOMMANDS:
          analyze <file.ser> [--json]
              Print SER metadata + sanity checks. Pure Foundation, no
              Metal device required. --json emits machine-readable
              output for the regression harness.

          stack <input> <output> [options]
              Run the lucky-stack pipeline headless. (Coming with the
              SourceReader-fed accumulator refactor.)

          validate <testimages-dir>
              Run the regression suite against a TESTIMAGES tree and
              print pass/fail metrics. (Coming with F3.)

          version
              Print build version.

          help
              Show this message.
        """
        if destination == 2 {
            cliStderr(body)
        } else {
            print(body)
        }
        exit(code)
    }
}
