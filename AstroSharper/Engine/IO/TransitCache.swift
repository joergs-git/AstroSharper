// On-disk cache for transit-detector results. A detection scan reads the whole
// (multi-GB) SER, so re-running it every time the user re-opens a folder would
// be painful — cache the verdict keyed by file size+mtime, exactly like
// QualityCache does for sharpness.
//
// Storage: ~/Library/Containers/<bundle>/Data/Library/Application Support/
// AstroSharper/transit-cache.json (sandbox-safe).
import Foundation

/// Per-file cached transit verdict, wrapped with the fingerprint that validates
/// it against the current file on disk.
struct CachedTransit: Codable, Equatable {
    var fingerprint: String
    var result: TransitResult
}

@MainActor
final class TransitCache {
    static let shared = TransitCache()

    private var entries: [String: CachedTransit] = [:]
    private let storeURL: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let fm = FileManager.default
        let supportDir = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)) ?? fm.temporaryDirectory
        let appDir = supportDir.appendingPathComponent("AstroSharper", isDirectory: true)
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.storeURL = appDir.appendingPathComponent("transit-cache.json")
        load()
    }

    /// Same size|mtime fingerprint scheme as QualityCache, so both caches agree
    /// on when a file has changed.
    static func fingerprint(for url: URL) -> String? { QualityCache.fingerprint(for: url) }

    private func key(for url: URL) -> String { url.path }

    func lookup(url: URL) -> TransitResult? {
        guard let fp = Self.fingerprint(for: url),
              let entry = entries[key(for: url)],
              entry.fingerprint == fp else { return nil }
        return entry.result
    }

    func store(url: URL, result: TransitResult) {
        guard let fp = Self.fingerprint(for: url) else { return }
        entries[key(for: url)] = CachedTransit(fingerprint: fp, result: result)
        scheduleSave()
    }

    func clear(url: URL) {
        entries[key(for: url)] = nil
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s debounce
            await self?.persistNow()
        }
    }

    private func persistNow() async {
        let snapshot = entries
        let url = storeURL
        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }.value
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: CachedTransit].self, from: data) {
            entries = decoded
        }
    }
}
