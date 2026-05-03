// astrosharper — headless CLI for the AstroSharper engine.
//
// Foundation work (F1): every algorithm landed in v1.0 is verifiable
// without launching the SwiftUI app. The CLI shares the Engine/ source
// tree with the GUI target so behaviour cannot drift between the two.
//
// The binary takes a subcommand as the first positional argument:
//
//   astrosharper analyze   <file.ser> [--json]
//   astrosharper stack     <input> <output> [options]      (TODO)
//   astrosharper validate  <testimages-dir>                (TODO)
//   astrosharper version
//   astrosharper help
//
// Stack/validate are stubbed in this initial pass — they print "not
// implemented" and exit non-zero so calling scripts fail fast. They
// land alongside the algorithms they wrap (Block A onwards). Analyze
// is fully wired today and pure-Foundation, so the test suite can use
// it to assert SER header parsing without standing up the Metal stack.
import Foundation

let args = CommandLine.arguments

// Drop the binary name itself; what's left is "<subcommand> [args...]".
guard args.count >= 2 else {
    Usage.printAndExit(2, code: 64)
    fatalError("unreachable")
}

let subcommand = args[1]
let subargs = Array(args.dropFirst(2))

let exitCode: Int32
switch subcommand {
case "analyze":
    exitCode = Analyze.run(args: subargs)

case "stack":
    exitCode = await Stack.run(args: subargs)

case "validate":
    exitCode = await Validate.run(args: subargs)

case "version", "--version", "-v":
    print("astrosharper \(CLIInfo.version) — \(CLIInfo.gitDescription)")
    exitCode = 0

case "help", "--help", "-h":
    Usage.printAndExit(1, code: 0)
    fatalError("unreachable")

default:
    cliStderr("astrosharper: unknown subcommand '\(subcommand)'")
    Usage.printAndExit(2, code: 64)
    fatalError("unreachable")
}

exit(exitCode)
