// Preset storage and iCloud sync.
//
// Each user-saved preset is JSON-encoded and stored under a key
// "preset.<uuid>" in NSUbiquitousKeyValueStore (when iCloud is available)
// AND mirrored into UserDefaults for offline / no-iCloud-account use. This
// gives:
//   - Automatic, free sync across the user's Macs (KVS quota = 1 MB)
//   - Local fallback when iCloud is disabled or unavailable
//   - Conflict resolution by `modifiedAt` (last-write wins)
//
// Built-in presets are not stored — they're regenerated from code on every
// launch, so updating the app updates the built-ins.
import Combine
import Foundation

@MainActor
final class PresetManager: ObservableObject {
    static let shared = PresetManager()

    @Published private(set) var builtIn: [Preset] = BuiltInPresets.all()
    @Published private(set) var user: [Preset] = []

    /// Last preset the user applied or saved. `nil` for "Custom (no preset)".
    @Published var activeID: Preset.ID?

    private let userDefaultsKey = "AstroSharper.userPresets.v1"
    private let kvKeyPrefix = "preset."

    private var cancellables: Set<AnyCancellable> = []
    private var ignoreNextKVSChange = false

    private init() {
        loadFromLocal()
        attachKVSObserver()
        // Pull any iCloud presets that might already be there.
        syncFromKVS()
    }

    // MARK: - Public API

    var allPresets: [Preset] { builtIn + user }

    func preset(withID id: Preset.ID) -> Preset? {
        allPresets.first { $0.id == id }
    }

    func preset(matchingTarget t: PresetTarget) -> [Preset] {
        allPresets.filter { $0.target == t }
    }

    /// Saves a new user preset OR updates an existing one (matched by id).
    func save(_ preset: Preset) {
        var p = preset
        p.isBuiltIn = false
        p.modifiedAt = Date()

        if let idx = user.firstIndex(where: { $0.id == p.id }) {
            user[idx] = p
        } else {
            user.append(p)
        }
        persistLocal()
        pushToKVS(p)
        activeID = p.id
    }

    func delete(id: Preset.ID) {
        user.removeAll { $0.id == id }
        persistLocal()
        deleteFromKVS(id: id)
        if activeID == id { activeID = nil }
    }

    /// Forces a re-pull from iCloud KVS. Call after manual "Sync Now" tap.
    func forceSync() {
        NSUbiquitousKeyValueStore.default.synchronize()
        syncFromKVS()
    }

    // MARK: - Local persistence

    private func loadFromLocal() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        do {
            user = try JSONDecoder().decode([Preset].self, from: data)
        } catch {
            // If the local cache is corrupt, drop it but keep going — iCloud
            // will repopulate.
            user = []
        }
    }

    private func persistLocal() {
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    // MARK: - iCloud KVS

    private var kvs: NSUbiquitousKeyValueStore { .default }

    private func attachKVSObserver() {
        NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        .sink { [weak self] _ in
            guard let self else { return }
            if self.ignoreNextKVSChange { self.ignoreNextKVSChange = false; return }
            Task { @MainActor in self.syncFromKVS() }
        }
        .store(in: &cancellables)
    }

    private func pushToKVS(_ preset: Preset) {
        guard let data = try? JSONEncoder().encode(preset) else { return }
        ignoreNextKVSChange = true
        kvs.set(data, forKey: kvKeyPrefix + preset.id.uuidString)
        kvs.synchronize()
    }

    private func deleteFromKVS(id: Preset.ID) {
        ignoreNextKVSChange = true
        kvs.removeObject(forKey: kvKeyPrefix + id.uuidString)
        kvs.synchronize()
    }

    /// Reconcile remote KVS state with the local user list. Last-write-wins
    /// based on `modifiedAt`; remote-only presets are imported, local-only
    /// presets are pushed up.
    private func syncFromKVS() {
        let dict = kvs.dictionaryRepresentation
        var remote: [UUID: Preset] = [:]
        for (key, value) in dict {
            guard key.hasPrefix(kvKeyPrefix), let data = value as? Data else { continue }
            if let p = try? JSONDecoder().decode(Preset.self, from: data) {
                remote[p.id] = p
            }
        }

        var localByID: [UUID: Preset] = Dictionary(uniqueKeysWithValues: user.map { ($0.id, $0) })

        // Merge: remote wins if newer; local wins if newer or remote missing.
        for (id, rp) in remote {
            if let lp = localByID[id] {
                if rp.modifiedAt > lp.modifiedAt { localByID[id] = rp }
            } else {
                localByID[id] = rp
            }
        }

        // Push local-only presets up (they exist locally but not in remote).
        for (id, lp) in localByID where remote[id] == nil {
            pushToKVS(lp)
        }

        let merged = Array(localByID.values).sorted { $0.modifiedAt > $1.modifiedAt }
        if merged != user {
            user = merged
            persistLocal()
        }
    }
}
