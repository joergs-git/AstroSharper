// async wrapper around the existing fire-and-forget `LuckyStack.run`.
//
// Headless tooling (CLI `stack` subcommand, regression harness, future
// scriptable workflows) needs to await the pipeline to completion to
// pick up the output URL and any error. The existing public API
// dispatches via `Task.detached` and reports through a @MainActor
// progress callback — perfect for the live SwiftUI app, awkward for
// a CLI process.
//
// `runAsync` hides the callback marshalling: the result is the
// finished output URL or a thrown error matching the
// `LuckyStackProgress.error` payload.
import Foundation

extension LuckyStack {

    /// Run the lucky-stack pipeline and await its completion.
    ///
    /// - Parameters:
    ///   - sourceURL: input SER file. AVI lucky-stack is gated on the
    ///     E.1 SourceReader integration; for v0 the CLI rejects AVI
    ///     upstream of this call.
    ///   - outputURL: destination TIFF file.
    ///   - options: stacking options. Bake-in / mode / multi-AP /
    ///     keep-percent all preserved as-is from the synchronous API.
    ///   - pipeline: shared per-frame pipeline (sharpen / tone) the
    ///     bake-in step uses when enabled.
    ///   - progressHandler: optional async progress sink. Each
    ///     `LuckyStackProgress` event passes through verbatim, so the
    ///     CLI can print stage updates if it wants.
    /// - Returns: the finished output URL.
    /// - Throws: an error wrapping the `error(message)` payload when
    ///   the underlying run reports a failure.
    static func runAsync(
        sourceURL: URL,
        outputURL: URL,
        options: LuckyStackOptions,
        pipeline: Pipeline,
        progressHandler: (@Sendable (LuckyStackProgress) -> Void)? = nil
    ) async throws -> URL {
        // The fire-and-forget API can call `progress` many times
        // (opening → grading → sorting → stacking → writing → finished).
        // CheckedContinuation enforces single-resume, so we gate on a
        // mutable box to ignore everything past the terminal event.
        final class ResumeGate: @unchecked Sendable {
            private var resumed = false
            private let lock = NSLock()
            func tryResume(_ block: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                block()
            }
        }
        let gate = ResumeGate()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            LuckyStack.run(
                sourceURL: sourceURL,
                outputURL: outputURL,
                options: options,
                pipeline: pipeline
            ) { progress in
                // Pass through to the optional progress sink first so
                // streaming UI / CLI output gets every event.
                progressHandler?(progress)
                switch progress {
                case .finished(let url):
                    gate.tryResume {
                        cont.resume(returning: url)
                    }
                case .error(let message):
                    gate.tryResume {
                        cont.resume(throwing: NSError(
                            domain: "AstroSharper.LuckyStack",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        ))
                    }
                default:
                    break
                }
            }
        }
    }
}
