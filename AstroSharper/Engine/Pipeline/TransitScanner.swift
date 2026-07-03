// SerTransitScanner — background wrapper around TransitDetector for the GUI.
// A detection reads the whole (multi-GB) SER, so it must run off the main
// thread; the result comes back on the main actor. Mirrors SerQualityScanner's
// shape (opt-in, cancellable, cache-backed) so the two feel identical to use.
import Foundation

@MainActor
final class SerTransitScanner {
    private var task: Task<Void, Never>?

    /// Detect a transit in `url` on a utility-priority background task, then
    /// deliver the verdict on the main actor. `nil` means the detector threw
    /// (unreadable file) or the scan was cancelled before it produced a result.
    func scan(url: URL, config: TransitConfig = .init(),
              completion: @escaping (TransitResult?) -> Void) {
        cancel()
        task = Task.detached(priority: .utility) {
            let result = try? TransitDetector.detect(url: url, config: config)
            if Task.isCancelled { return }
            await MainActor.run { completion(result) }
        }
    }

    func cancel() { task?.cancel(); task = nil }
}
