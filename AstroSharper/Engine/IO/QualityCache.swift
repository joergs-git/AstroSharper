// On-disk cache for SER sharpness distributions and per-image sharpness
// scores. Avoids re-scanning the same file every time the user opens it
// — relevant for SERs where a 64-frame scan can take a couple of seconds.
//
// Cache key fingerprint: file size + mtime epoch. We deliberately avoid
// hashing the file contents (too slow for multi-GB SERs); size+mtime is
// the same heuristic Spotlight / git use and is good enough for a UI cache.
//
// Storage: ~/Library/Containers/<bundle>/Data/Library/Application Support/
// AstroSharper/quality-cache.json (sandbox-safe).
import Foundation

/// Per-file cached quality data. Either side may be nil — SER files only
/// fill `distribution`; static images only fill `sharpness`.
struct CachedQuality: Codable, Equatable {
    var fingerprint: String
    var sharpness: Float?
    var distribution: SharpnessDistribution?
}

@MainActor
final class QualityCache {
    static let shared = QualityCache()

    private var entries: [String: CachedQuality] = [:]
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
        self.storeURL = appDir.appendingPathComponent("quality-cache.json")
        load()
    }

    /// Build a deterministic fingerprint from filesystem metadata. Returns
    /// nil if we can't stat the file (e.g. permission denied).
    static func fingerprint(for url: URL) -> String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attrs else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(Int64(mtime * 1000))"
    }

    private func key(for url: URL) -> String { url.path }

    func lookup(url: URL) -> CachedQuality? {
        guard let fp = Self.fingerprint(for: url),
              let entry = entries[key(for: url)],
              entry.fingerprint == fp else { return nil }
        return entry
    }

    func store(url: URL, sharpness: Float? = nil, distribution: SharpnessDistribution? = nil) {
        guard let fp = Self.fingerprint(for: url) else { return }
        var entry = entries[key(for: url)] ?? CachedQuality(fingerprint: fp)
        // Replace fingerprint if it changed (file was edited).
        if entry.fingerprint != fp {
            entry = CachedQuality(fingerprint: fp)
        }
        if let s = sharpness { entry.sharpness = s }
        if let d = distribution { entry.distribution = d }
        entries[key(for: url)] = entry
        scheduleSave()
    }

    /// Drop everything — used by a "Recalculate Video Quality" menu item.
    func clear(url: URL) {
        entries[key(for: url)] = nil
        scheduleSave()
    }

    // MARK: - Persistence

    /// Coalesce rapid writes — many files added in quick succession would
    /// otherwise rewrite the JSON on every insert.
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
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([String: CachedQuality].self, from: data) {
            entries = decoded
        }
    }
}
