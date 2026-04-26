// Single source of truth for UI state, wired into views via @EnvironmentObject.
// Keeps all cross-cutting state (open folder, selection, processing settings,
// active job) in one place so the layout code stays pure SwiftUI.
import AppKit
import Combine
import Foundation
import Metal
import UniformTypeIdentifiers

enum CatalogSection: String, Equatable, CaseIterable {
    case inputs = "Inputs"
    case memory = "Memory"
    case outputs = "Outputs"
}

/// Per-section state snapshot used by the swap-based section toggle.
struct CatalogSectionState {
    var catalog: FileCatalog = FileCatalog()
    var selected: Set<FileEntry.ID> = []
    var marked: Set<FileEntry.ID> = []
    var preview: FileEntry.ID?
}

@MainActor
final class AppModel: ObservableObject {
    // Live mirror — always reflects the currently displayed section. The
    // inactive section's state is parked in `stash`. switchToSection() swaps
    // them. This keeps the existing view bindings (`$app.catalog`, etc.)
    // working without per-view conditional logic.
    @Published var catalog = FileCatalog()
    @Published var selectedFileIDs: Set<FileEntry.ID> = []
    @Published var markedFileIDs: Set<FileEntry.ID> = []
    @Published var previewFileID: FileEntry.ID?
    @Published var displayedSection: CatalogSection = .inputs

    /// Stashed state for every inactive section. The currently-displayed
    /// section's state lives in the @Published mirrors above; switching
    /// swaps the mirror with the corresponding stash entry.
    private var stashedStates: [CatalogSection: CatalogSectionState] = [
        .inputs:  CatalogSectionState(),
        .memory:  CatalogSectionState(),
        .outputs: CatalogSectionState(),
    ]

    /// Outputs root URL — used to scan the folder for files written by the
    /// processing pipeline. Set when an output is first written.
    @Published var outputsRootURL: URL?

    // Per-section counts for the toggle bar so the user always sees at a
    // glance how many files live in each section, including the inactive
    // ones, without switching.
    func fileCount(for section: CatalogSection) -> Int {
        if section == .memory { return playback.frames.count }
        if section == displayedSection { return catalog.files.count }
        return stashedStates[section]?.catalog.files.count ?? 0
    }
    var inputsFileCount: Int { fileCount(for: .inputs) }
    var outputsFileCount: Int { fileCount(for: .outputs) }
    var memoryFileCount: Int { fileCount(for: .memory) }

    var inputsRootURL: URL? {
        if displayedSection == .inputs { return catalog.rootURL }
        return stashedStates[.inputs]?.catalog.rootURL
    }
    /// Force a SwiftUI re-render hook for the toggle — bumped each switch.
    @Published var sectionTick: Int = 0

    // Processing settings
    @Published var sharpen = SharpenSettings()
    @Published var stabilize = StabilizeSettings()
    @Published var toneCurve = ToneCurveSettings()

    // Before/After compare — toggle, not slider.
    @Published var showAfter: Bool = true

    // Job status for batch runs
    @Published var jobStatus: JobStatus = .idle

    // Output folder model — split into two so the auto-derived folder can
    // track the currently-opened root, while the user's explicit Choose stays
    // sticky across folder switches.
    //
    // - `pickedOutputFolder`: user picked via Choose (or sandbox-fallback);
    //    persists via security-scoped bookmark across launches.
    // - `autoOutputFolder`: <currentRoot>/_AstroSharper; refreshed on every
    //    folder open, **only used when no picked folder is set**.
    //
    // Effective folder (used by run actions) prefers picked, falls back to
    // auto. UI surfaces whichever is active so the user always sees where
    // outputs go.
    @Published var pickedOutputFolder: URL?
    @Published var autoOutputFolder: URL?

    /// The actual destination for any output write, always resolved fresh
    /// rather than cached so it reflects the latest state.
    var effectiveOutputFolder: URL? {
        pickedOutputFolder ?? autoOutputFolder
    }

    /// Backwards-compatible alias used by view code that hasn't been
    /// migrated to the split model yet.
    var customOutputFolder: URL? {
        get { pickedOutputFolder }
        set { pickedOutputFolder = newValue }
    }

    // 256-bucket luminance histogram of the current preview file (0..1 scale).
    // Recomputed when the preview file changes. Used by the tone-curve editor
    // for its overlay and by the Stretch button for auto-endpoint detection.
    @Published var previewHistogram: [UInt32] = []
    @Published var histogramLogScale: Bool = false

    // SER scrub state — frame index and frame count for the currently-shown
    // SER. Set by the preview coordinator after reading the SER header;
    // re-set to (0, 0) when the active file isn't SER.
    @Published var previewSerFrameIndex: Int = 0
    @Published var previewSerFrameCount: Int = 0

    // In-memory playback / sequence state. Populated by "Run Stabilize" so the
    // user can scrub, play and export the aligned frames before committing
    // anything to disk. Disk export becomes a separate explicit action.
    @Published var playback = PlaybackState()

    // Lucky-Stack settings + queue (separate from the regular file catalog
    // since SER files have no thumbnail and aren't run through the standard
    // sharpen pipeline at input time).
    @Published var luckyStack = LuckyStackUIState()

    // Blink-through player (AstroTriage style). Cycles `previewFileID`
    // through the active selection (or all files if nothing selected) at the
    // configured rate so the user can quickly compare similar frames.
    @Published var blinkActive: Bool = false
    @Published var blinkRate: Double = 4    // frames per second
    private var blinkTimer: Timer?

    /// When ON, a folder/file open auto-detects Sun/Moon/Jupiter/Saturn/Mars
    /// from filenames + folder names and applies the matching default preset.
    @Published var autoDetectPresetOnOpen: Bool = true

    let presets = PresetManager.shared

    // MARK: - Security-scoped access bookkeeping
    //
    // Every URL that can have its parent (or the file itself) written to —
    // root catalog folder, custom output folder, dragged-in folders — must
    // hold security-scoped access while the user is operating on it.
    // Otherwise sandbox writes inside subdirectories get "Operation not
    // permitted", especially on NAS / external volumes.
    //
    // We track every actively-scoped URL and release it when:
    //   - it's replaced by a new URL of the same role
    //   - the model deinits (app quit)
    private var heldScopes: Set<URL> = []

    private func grantSecurityScope(_ url: URL) {
        guard !heldScopes.contains(url) else { return }
        if url.startAccessingSecurityScopedResource() {
            heldScopes.insert(url)
        }
    }
    private func releaseSecurityScope(_ url: URL?) {
        guard let u = url, heldScopes.contains(u) else { return }
        u.stopAccessingSecurityScopedResource()
        heldScopes.remove(u)
    }
    deinit {
        for u in heldScopes { u.stopAccessingSecurityScopedResource() }
    }

    private static let outputBookmarkKey = "AstroSharper.customOutputBookmark.v1"

    /// Pin a user-chosen output folder. Stays sticky across folder switches
    /// (`autoOutputFolder` won't override it) and persists across launches
    /// via security-scoped bookmark. Pass nil to clear and revert to the
    /// auto-tracking behaviour.
    func setCustomOutputFolder(_ url: URL?) {
        if let prev = pickedOutputFolder, prev != url { releaseSecurityScope(prev) }
        if let url {
            grantSecurityScope(url)
            pickedOutputFolder = url
            if let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(bookmark, forKey: Self.outputBookmarkKey)
            }
        } else {
            pickedOutputFolder = nil
            UserDefaults.standard.removeObject(forKey: Self.outputBookmarkKey)
        }
    }

    /// Restore the persisted output-folder bookmark (if any) so a one-time
    /// "Choose a writable folder" prompt sticks across app launches. Called
    /// from init.
    private func restoreOutputFolderFromBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.outputBookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        guard !stale else { return }
        if url.startAccessingSecurityScopedResource() {
            heldScopes.insert(url)
            if canWriteAt(folder: url) {
                pickedOutputFolder = url
            } else {
                url.stopAccessingSecurityScopedResource()
                heldScopes.remove(url)
            }
        }
    }

    /// Last-resort writable location: the app's own Documents folder inside
    /// its sandbox container. Always writable for sandboxed apps, persists
    /// across launches, and is reachable via "Show in Finder" actions even
    /// though it's deep in `~/Library/Containers/`.
    private func sandboxDefaultOutputFolder() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = docs.appendingPathComponent("AstroSharper Outputs", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Probe-write a tiny file to verify we have actual write permission at
    /// `folder`. Catches sandbox / NAS / read-only filesystem cases where
    /// `createDirectory` succeeds but real writes fail later.
    private func canWriteAt(folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let probe = folder.appendingPathComponent(".astrosharper-probe-\(UUID().uuidString)")
            try Data([0]).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// Modal prompt asking the user to pick a writable output folder. Used as
    /// a fallback when the implicit `<root>/_luckystack/` location is blocked
    /// by sandbox / NAS permissions. Returns the picked URL on success.
    @discardableResult
    private func promptForWritableOutputFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Use as Output Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        setCustomOutputFolder(url)
        return url
    }

    /// Resolve a guaranteed-writable output folder. Tries in order:
    ///   1. User-configured `customOutputFolder` (persisted via bookmark).
    ///   2. `<input root>/_AstroSharper` (works on Documents/Desktop/SSDs).
    ///   3. Sandbox-default `~/Library/Containers/.../Documents/AstroSharper Outputs/`
    ///      — always writable for a sandboxed app.
    ///
    /// Never prompts; the sandbox default is the silent fallback when both
    /// of the user-facing locations refuse writes (e.g. read-only NAS).
    private func resolveWritableOutputFolder(implicit suggestion: URL?) -> URL? {
        // Picked > current auto > implicit suggestion > sandbox fallback.
        if let picked = pickedOutputFolder, canWriteAt(folder: picked) {
            return picked
        }
        if let auto = autoOutputFolder, canWriteAt(folder: auto) {
            return auto
        }
        if let suggested = suggestion, canWriteAt(folder: suggested) {
            return suggested
        }
        if let fallback = sandboxDefaultOutputFolder(), canWriteAt(folder: fallback) {
            autoOutputFolder = fallback
            return fallback
        }
        return nil
    }

    // Which file IDs are the actual batch target right now.
    var batchTargetIDs: Set<FileEntry.ID> {
        markedFileIDs.isEmpty ? selectedFileIDs : markedFileIDs
    }

    var canApply: Bool {
        !batchTargetIDs.isEmpty && jobStatus.isIdle
    }

    var selectionCount: Int { selectedFileIDs.count }
    var markedCount: Int { markedFileIDs.count }

    private var cancellables: Set<AnyCancellable> = []

    init() {
        Publishers.CombineLatest4($sharpen, $stabilize, $toneCurve, $markedFileIDs)
            .dropFirst()
            .sink { [weak self] _ in self?.clearStaleError() }
            .store(in: &cancellables)

        // When the Memory tab is active, sync the row selection back into
        // the playback index so the preview reflects whatever the user
        // clicked in the file list.
        $previewFileID
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self, self.displayedSection == .memory, let id else { return }
                if let idx = self.playback.frames.firstIndex(where: { $0.id == id }) {
                    self.playback.currentIndex = idx
                }
            }
            .store(in: &cancellables)

        // Restore the previously-chosen output folder (if any) so the user's
        // one-time pick sticks across launches.
        restoreOutputFolderFromBookmark()
    }

    // MARK: - Folder

    func promptOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        panel.prompt = "Open"
        if panel.runModal() == .OK {
            openMixed(urls: panel.urls)
        }
    }

    func openFolder(_ url: URL) {
        ensureInputsActive()
        // Drop the previous root scope, hold the new one for the session.
        if let prev = catalog.rootURL, prev != url { releaseSecurityScope(prev) }
        grantSecurityScope(url)

        catalog.load(from: url)
        selectedFileIDs.removeAll()
        markedFileIDs.removeAll()
        previewFileID = catalog.files.first?.id
        jobStatus = .idle
        loadThumbnailsAsync()
        autoApplyDefaultPreset(candidates: catalogCandidateStrings(rootURL: url))
        autoSetupOutputFolder(in: url)
    }

    /// Refresh the auto-derived output folder to track the current root.
    /// Always points at `<root>/_AstroSharper/` if writable (Documents,
    /// Desktop, externe SSDs). Falls back to the sandbox container's
    /// Documents folder when the input root is read-only (NAS).
    ///
    /// `pickedOutputFolder` (a deliberate user choice) overrides this in
    /// `effectiveOutputFolder`, so a one-time Choose still wins. Without a
    /// picked folder the output destination *follows* the inputs — opening
    /// a Jupiter folder writes to `Jupiter/_AstroSharper`, opening a Sun
    /// folder switches to `Sun/_AstroSharper` automatically.
    private func autoSetupOutputFolder(in root: URL) {
        let candidate = root.appendingPathComponent("_AstroSharper", isDirectory: true)
        if canWriteAt(folder: candidate) {
            autoOutputFolder = candidate
            grantSecurityScope(candidate)
            return
        }
        if let fallback = sandboxDefaultOutputFolder(), canWriteAt(folder: fallback) {
            autoOutputFolder = fallback
        }
    }

    /// Build the strings that the auto-detector scans (path components from
    /// every loaded file plus the folder name).
    private func catalogCandidateStrings(rootURL: URL?) -> [String] {
        var c: [String] = []
        if let r = rootURL { c.append(r.lastPathComponent) }
        // Include enough samples that an "outlier" filename doesn't dominate —
        // for typical SharpCap captures, the folder name is the strongest hint.
        c.append(contentsOf: catalog.files.prefix(20).map { $0.url.lastPathComponent })
        c.append(contentsOf: catalog.files.prefix(20).map { $0.url.deletingLastPathComponent().lastPathComponent })
        return c
    }

    /// If auto-detect is on, find the matching target and apply that target's
    /// best built-in preset (the first one). Leaves the active preset alone if
    /// no keyword matches so the user's current settings aren't clobbered.
    private func autoApplyDefaultPreset(candidates: [String]) {
        guard autoDetectPresetOnOpen else { return }
        guard let target = PresetAutoDetect.detect(in: candidates) else { return }
        guard let preset = presets.builtIn.first(where: { $0.target == target }) else { return }
        applyPreset(preset)
        // Also update WinJUPOS target if user later switches to that mode.
        luckyStack.winjuposTarget = preset.target.rawValue
    }

    /// Accepts a mix of file and folder URLs (AstroTriage-style). Folders are
    /// expanded; loose files are added directly. The result is one combined
    /// catalog so files from multiple sessions / days can sit side-by-side.
    func openMixed(urls: [URL]) {
        ensureInputsActive()
        let fm = FileManager.default
        var allURLs: [URL] = []
        var anyFolder: URL?
        // Hold scope on every picked URL — folders give us write access into
        // their subdirectories (where _luckystack lands), files give us read
        // access. We release the previous catalog root if it changed.
        if let prev = catalog.rootURL { releaseSecurityScope(prev) }
        for url in urls { grantSecurityScope(url) }

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                anyFolder = anyFolder ?? url
                if let contents = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                ) {
                    allURLs.append(contentsOf: contents.filter {
                        FileCatalog.supportedExtensions.contains($0.pathExtension.lowercased())
                    })
                }
            } else if FileCatalog.supportedExtensions.contains(url.pathExtension.lowercased()) {
                allURLs.append(url)
            }
        }
        let inferredRoot = anyFolder ?? urls.first?.deletingLastPathComponent()
        catalog.loadURLs(allURLs, root: inferredRoot)
        selectedFileIDs.removeAll()
        markedFileIDs.removeAll()
        previewFileID = catalog.files.first?.id
        jobStatus = .idle
        loadThumbnailsAsync()
        autoApplyDefaultPreset(candidates: catalogCandidateStrings(rootURL: inferredRoot ?? urls.first))
        if let root = inferredRoot { autoSetupOutputFolder(in: root) }
    }

    private func ensureInputsActive() {
        if displayedSection != .inputs { switchToSection(.inputs) }
    }

    // MARK: - Section switching

    func switchToSection(_ section: CatalogSection) {
        guard section != displayedSection else { return }

        // Stash the currently-active section's mirrored state.
        stashedStates[displayedSection] = CatalogSectionState(
            catalog: catalog,
            selected: selectedFileIDs,
            marked: markedFileIDs,
            preview: previewFileID
        )

        // Memory is a virtual section — its catalog is rebuilt fresh from
        // playback frames on each entry, ignoring any prior stash.
        let newState: CatalogSectionState
        if section == .memory {
            newState = CatalogSectionState(
                catalog: buildMemoryCatalog(),
                selected: [],
                marked: [],
                preview: stashedStates[.memory]?.preview
            )
        } else {
            newState = stashedStates[section] ?? CatalogSectionState()
        }

        catalog = newState.catalog
        selectedFileIDs = newState.selected
        markedFileIDs = newState.marked
        previewFileID = newState.preview ?? catalog.files.first?.id

        displayedSection = section
        sectionTick &+= 1

        // First-visit-to-outputs convenience: scan the output folder if we
        // haven't yet so the user sees existing files without a manual
        // refresh.
        if section == .outputs && catalog.files.isEmpty,
           let root = outputsRootURL {
            catalog.load(from: root)
            previewFileID = catalog.files.first?.id
            loadThumbnailsAsync()
        }
    }

    /// Build a virtual catalog from the in-memory aligned playback frames.
    /// Each frame is exposed as a `FileEntry` whose URL points back at the
    /// source SER; the row's status is `.done` to signal "ready, in
    /// memory". Selecting a row drives the playback index so the preview
    /// shows the corresponding aligned frame.
    private func buildMemoryCatalog() -> FileCatalog {
        var cat = FileCatalog()
        cat.rootURL = nil
        cat.files = playback.frames.enumerated().map { (index, frame) in
            var entry = FileCatalog.makeEntry(url: frame.sourceURL)
            // Distinguish in-memory rows visually: prefix "▶ N: " so the
            // user can tell them apart from on-disk inputs/outputs at a
            // glance.
            entry = FileEntry(
                id: frame.id,
                url: frame.sourceURL,
                name: String(format: "%03d  %@", index + 1, frame.sourceURL.lastPathComponent),
                sizeBytes: 0,
                creationDate: nil,
                status: .done
            )
            return entry
        }
        return cat
    }

    // MARK: - Output catalog

    /// Append a freshly-written output file to the OUTPUTS section. Auto-runs
    /// thumbnail generation so the row populates without a refresh.
    func registerOutput(url: URL, autoSwitch: Bool = false) {
        outputsRootURL = url.deletingLastPathComponent()
        var entry = FileCatalog.makeEntry(url: url)
        entry.status = .done
        appendOutputEntry(entry)
        // Generate thumbnail off-thread, write back into whichever store
        // (active mirror or stash) currently owns the row.
        let id = entry.id
        let url = url
        Task.detached(priority: .utility) { [weak self] in
            let img = ThumbnailLoader.load(url: url, maxDimension: 48)
            await MainActor.run {
                self?.attachOutputThumbnail(img, forID: id)
            }
        }
        if autoSwitch && displayedSection != .outputs {
            switchToSection(.outputs)
        }
    }

    private func appendOutputEntry(_ entry: FileEntry) {
        if displayedSection == .outputs {
            catalog.files.append(entry)
        } else {
            var stash = stashedStates[.outputs] ?? CatalogSectionState()
            stash.catalog.files.append(entry)
            if stash.catalog.rootURL == nil { stash.catalog.rootURL = outputsRootURL }
            stashedStates[.outputs] = stash
        }
    }

    private func attachOutputThumbnail(_ img: NSImage?, forID id: FileEntry.ID) {
        if displayedSection == .outputs, let idx = catalog.index(of: id) {
            catalog.files[idx].thumbnail = img
        } else if var stash = stashedStates[.outputs],
                  let idx = stash.catalog.index(of: id) {
            stash.catalog.files[idx].thumbnail = img
            stashedStates[.outputs] = stash
        }
    }

    // MARK: - Marking

    /// Toggle the meridian-flip flag on a file. Effects propagate via the
    /// preview coordinator (re-load) and through any subsequent processing.
    func toggleMeridianFlip(_ id: FileEntry.ID) {
        guard let idx = catalog.index(of: id) else { return }
        catalog.files[idx].meridianFlipped.toggle()
        // If the toggled file is the current preview, force a reload.
        if previewFileID == id {
            // SwiftUI doesn't observe nested struct updates without a parent
            // mutation, so bump a derived published to nudge the coordinator.
            let saved = previewFileID
            previewFileID = nil
            previewFileID = saved
        }
    }

    func toggleMark(_ id: FileEntry.ID) {
        if markedFileIDs.contains(id) { markedFileIDs.remove(id) }
        else { markedFileIDs.insert(id) }
        clearStaleError()
    }
    func markAll() { markedFileIDs = Set(catalog.files.map { $0.id }); clearStaleError() }
    func unmarkAll() { markedFileIDs.removeAll(); clearStaleError() }
    func invertMarks() {
        let all = Set(catalog.files.map { $0.id })
        markedFileIDs = all.subtracting(markedFileIDs)
        clearStaleError()
    }
    func markSelection() { markedFileIDs.formUnion(selectedFileIDs); clearStaleError() }

    // MARK: - Deletion from list (doesn't touch disk)

    func removeFromList(_ ids: Set<FileEntry.ID>) {
        guard !ids.isEmpty else { return }
        catalog.files.removeAll { ids.contains($0.id) }
        selectedFileIDs.subtract(ids)
        markedFileIDs.subtract(ids)
        if let preview = previewFileID, ids.contains(preview) {
            previewFileID = catalog.files.first?.id
        }
    }

    // Called from view layer when settings change — clears a "stuck" error so
    // the status bar isn't frozen on a prior validation message.
    func clearStaleError() {
        if case .error = jobStatus { jobStatus = .idle }
        if case .done = jobStatus { jobStatus = .idle }
    }

    // MARK: - In-memory stabilization (preview before exporting)

    private let stabilizerPipeline = Pipeline()
    private var playbackTimer: Timer?

    func runStabilizationInMemory() {
        let targets = batchTargetIDs
        guard targets.count >= 2 else {
            jobStatus = .error("Stabilize needs at least 2 files (mark or select them)")
            return
        }
        let urls: [(id: FileEntry.ID, url: URL, meridianFlipped: Bool)] = catalog.files
            .filter { targets.contains($0.id) }
            .map { ($0.id, $0.url, $0.meridianFlipped) }

        jobStatus = .running(processed: 0, total: urls.count)
        stopPlayback()

        Stabilizer.run(
            inputs: .init(urls: urls, cropMode: stabilize.cropMode),
            pipeline: stabilizerPipeline,
            onProgress: { [weak self] p in
                guard let self else { return }
                switch p {
                case .loadingReference:
                    self.jobStatus = .running(processed: 0, total: urls.count)
                case .computingShifts(let done, let total):
                    self.jobStatus = .running(processed: done, total: total * 2)
                case .applyingShifts(let done, let total):
                    self.jobStatus = .running(processed: total + done, total: total * 2)
                case .finished:
                    break
                }
            },
            completion: { [weak self] result in
                guard let self else { return }
                guard let result else {
                    self.jobStatus = .error("Stabilization cancelled or failed")
                    return
                }
                self.playback.frames = result.aligned.map {
                    PlaybackFrame(id: $0.id, sourceURL: $0.url, texture: $0.texture)
                }
                self.playback.currentIndex = 0
                self.playback.isPlaying = false
                // Land the user on MEMORY tab so they immediately see the
                // aligned frames as a list. They can scrub via the player
                // and, when satisfied, click "Save All" to write to OUTPUTS.
                self.switchToSection(.memory)
                self.jobStatus = .idle
            }
        )
    }

    /// Write all frames currently in `playback` to
    /// `<output>/stabilized/<sourceName>_aligned.tif`. Refreshes the OUTPUTS
    /// section so the user immediately sees the saved files.
    /// Persist all in-memory playback frames to the standard output folder.
    /// Called from the toolbar "Save All" button when the Memory tab is
    /// active. Writes to `<output>/stabilized/<source>_aligned.tif`,
    /// registers each result in the OUTPUTS catalog, then auto-switches
    /// there so the user sees their saved files.
    func saveMemoryFramesToDisk() {
        autoSaveStabilizedFrames()
    }

    private func autoSaveStabilizedFrames() {
        guard !playback.frames.isEmpty else { return }
        let outputRoot = effectiveOutputFolder ?? sandboxDefaultOutputFolder()
        guard let root = outputRoot else { return }
        let stabFolder = root.appendingPathComponent("stabilized", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stabFolder, withIntermediateDirectories: true)
        } catch {
            jobStatus = .error("Cannot create 'stabilized' folder: \(error.localizedDescription)")
            return
        }

        let frames = playback.frames
        Task.detached(priority: .userInitiated) { [weak self] in
            for frame in frames {
                let baseName = frame.sourceURL.deletingPathExtension().lastPathComponent
                let outURL = stabFolder.appendingPathComponent("\(baseName)_aligned.tif")
                try? ImageTexture.write(texture: frame.texture, to: outURL)
                await MainActor.run {
                    self?.registerOutput(url: outURL, autoSwitch: false)
                }
            }
            await MainActor.run {
                guard let self else { return }
                // Auto-switch to OUTPUTS so the user finds the result.
                if self.displayedSection != .outputs { self.switchToSection(.outputs) }
            }
        }
    }

    func clearPlayback() {
        stopPlayback()
        playback = PlaybackState()
    }

    // MARK: - Playback transport

    func togglePlay() {
        playback.isPlaying ? stopPlayback() : startPlayback()
    }
    func startPlayback() {
        guard !playback.frames.isEmpty else { return }
        playback.isPlaying = true
        let interval = 1.0 / max(1.0, playback.fps)
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceFrame() }
        }
    }
    func stopPlayback() {
        playback.isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    func setFPS(_ fps: Double) {
        playback.fps = max(1, min(60, fps))
        if playback.isPlaying { startPlayback() }  // restart with new interval
    }
    func stepFrame(by delta: Int) {
        guard !playback.frames.isEmpty else { return }
        let n = playback.frames.count
        playback.currentIndex = ((playback.currentIndex + delta) % n + n) % n
    }
    func seekTo(index: Int) {
        guard !playback.frames.isEmpty else { return }
        playback.currentIndex = max(0, min(playback.frames.count - 1, index))
    }
    // MARK: - Export from playback

    func exportPlayback(format: ExportFormat) {
        guard !playback.frames.isEmpty else {
            jobStatus = .error("Nothing to export — run Stabilize first.")
            return
        }
        let panel = NSSavePanel()
        if format.isSequence {
            // Save as folder (we'll fill it with N files).
            let dirPanel = NSOpenPanel()
            dirPanel.canChooseDirectories = true
            dirPanel.canChooseFiles = false
            dirPanel.canCreateDirectories = true
            dirPanel.allowsMultipleSelection = false
            dirPanel.prompt = "Export here"
            guard dirPanel.runModal() == .OK, let dir = dirPanel.url else { return }
            performExport(format: format, destination: dir)
            return
        }
        panel.nameFieldStringValue = "astrosharper_export.\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performExport(format: format, destination: url)
    }

    private func performExport(format: ExportFormat, destination: URL) {
        let lut: MTLTexture? = toneCurve.enabled
            ? ToneCurveLUT.build(points: toneCurve.controlPoints, device: MetalDevice.shared.device)
            : nil
        let opts = Exporter.Options(
            format: format,
            fps: playback.fps,
            sharpen: sharpen,
            toneCurve: toneCurve,
            toneCurveLUT: lut
        )
        jobStatus = .running(processed: 0, total: playback.frames.count)
        Exporter.export(
            frames: playback.frames,
            to: destination,
            options: opts,
            pipeline: stabilizerPipeline
        ) { [weak self] p in
            guard let self else { return }
            switch p {
            case .writing(let done, let total):
                self.jobStatus = .running(processed: done, total: total)
            case .finished:
                let revealURL = format.isSequence ? destination : destination.deletingLastPathComponent()
                self.jobStatus = .done(processed: self.playback.frames.count, outputDir: revealURL)
            case .error(let msg):
                self.jobStatus = .error(msg)
            }
        }
    }

    // MARK: - Lucky Stack

    /// Runs Lucky Stack on a single SER file (right-click "Lucky Stack This File").
    /// Useful for a quick test before committing settings to a multi-file batch.
    func runLuckyStackOnSingleFile(id: FileEntry.ID) {
        guard let entry = catalog.files.first(where: { $0.id == id }), entry.isSER else { return }
        let suggested = catalog.rootURL?.appendingPathComponent("_luckystack", isDirectory: true)
            ?? entry.url.deletingLastPathComponent().appendingPathComponent("_luckystack", isDirectory: true)
        guard let outputFolder = resolveWritableOutputFolder(implicit: suggested) else {
            jobStatus = .error("No writable output folder — run cancelled.")
            return
        }
        luckyStack.queue = [LuckyStackItem(url: entry.url, meridianFlipped: entry.meridianFlipped)]
        let opts = LuckyStackOptions(mode: luckyStack.mode, keepPercent: luckyStack.keepPercent)
        runNextLuckyStackItem(outputFolder: outputFolder, options: opts)
    }

    func runLuckyStackOnSelection() {
        let targets = batchTargetIDs
        let selectedSers = catalog.files.filter { targets.contains($0.id) && $0.isSER }
        guard !selectedSers.isEmpty else {
            jobStatus = .error("Mark or select at least one .ser file in the list.")
            return
        }

        let suggested = catalog.rootURL?.appendingPathComponent("_luckystack", isDirectory: true)
        guard let outputFolder = resolveWritableOutputFolder(implicit: suggested) else {
            jobStatus = .error("No writable output folder — run cancelled.")
            return
        }

        // Build the queue: per SER, one item per requested variant. The
        // default slider-based run uses an empty `variantLabel` (no subdir);
        // each non-zero entry in `variants` adds a labelled run that lands
        // in its own subdirectory of the output folder.
        var queue: [LuckyStackItem] = []
        for entry in selectedSers {
            queue.append(LuckyStackItem(
                url: entry.url,
                meridianFlipped: entry.meridianFlipped,
                variantLabel: "",
                absoluteCount: nil,
                keepPercent: luckyStack.keepPercent
            ))
            for n in luckyStack.variants.absoluteCounts where n > 0 {
                queue.append(LuckyStackItem(
                    url: entry.url,
                    meridianFlipped: entry.meridianFlipped,
                    variantLabel: "f\(n)",
                    absoluteCount: n,
                    keepPercent: luckyStack.keepPercent
                ))
            }
            for p in luckyStack.variants.percentages where p > 0 {
                queue.append(LuckyStackItem(
                    url: entry.url,
                    meridianFlipped: entry.meridianFlipped,
                    variantLabel: "p\(p)",
                    absoluteCount: nil,
                    keepPercent: p
                ))
            }
        }

        luckyStack.queue = queue
        let opts = LuckyStackOptions(mode: luckyStack.mode, keepPercent: luckyStack.keepPercent)
        runNextLuckyStackItem(outputFolder: outputFolder, options: opts)
    }

    func clearLuckyStackQueue() {
        luckyStack.queue.removeAll()
    }

    private func runNextLuckyStackItem(outputFolder: URL, options: LuckyStackOptions) {
        guard let nextIdx = luckyStack.queue.firstIndex(where: { $0.status == .pending || $0.status == .processing }) else {
            jobStatus = .done(processed: luckyStack.queue.count, outputDir: outputFolder)
            return
        }
        let item = luckyStack.queue[nextIdx]
        let header = (try? SerReader(url: item.url))?.header
        let outName = LuckyStackNaming.filename(
            for: item.url,
            header: header,
            mode: luckyStack.filenameMode,
            target: luckyStack.winjuposTarget
        )
        // Variant subdirectory ("f100", "p25", or empty for default).
        let variantDir = item.variantLabel.isEmpty
            ? outputFolder
            : outputFolder.appendingPathComponent(item.variantLabel, isDirectory: true)
        try? FileManager.default.createDirectory(at: variantDir, withIntermediateDirectories: true)
        let outURL = variantDir.appendingPathComponent(outName)
        luckyStack.queue[nextIdx].status = .processing
        luckyStack.queue[nextIdx].progress = 0.0

        var perItemOpts = options
        perItemOpts.meridianFlipped = item.meridianFlipped
        perItemOpts.keepPercent = item.keepPercent
        perItemOpts.keepCount = item.absoluteCount
        perItemOpts.useMultiAP = (luckyStack.mode == .scientific) && luckyStack.multiAP.enabled
        perItemOpts.multiAPGrid = luckyStack.multiAP.grid
        perItemOpts.multiAPSearch = max(4, min(16, luckyStack.multiAP.patchHalf))

        if luckyStack.bakeInProcessing {
            let lut: MTLTexture? = toneCurve.enabled
                ? ToneCurveLUT.build(points: toneCurve.controlPoints, device: MetalDevice.shared.device)
                : nil
            perItemOpts.bakeIn = LuckyStackBakeIn(
                sharpen: sharpen,
                toneCurve: toneCurve,
                toneCurveLUT: lut
            )
        }

        LuckyStack.run(
            sourceURL: item.url,
            outputURL: outURL,
            options: perItemOpts,
            pipeline: stabilizerPipeline
        ) { [weak self] p in
            guard let self else { return }
            switch p {
            case .opening:
                self.luckyStack.queue[nextIdx].statusText = "opening"
            case .grading(let done, let total):
                self.luckyStack.queue[nextIdx].progress = Double(done) / Double(max(total, 1)) * 0.5
                self.luckyStack.queue[nextIdx].statusText = "grading \(done)/\(total)"
                self.jobStatus = .running(processed: done, total: total)
            case .sorting:
                self.luckyStack.queue[nextIdx].statusText = "sorting"
            case .buildingReference(let done, let total):
                self.luckyStack.queue[nextIdx].progress = 0.5 + Double(done) / Double(max(total, 1)) * 0.15
                self.luckyStack.queue[nextIdx].statusText = "reference \(done)/\(total)"
            case .stacking(let done, let total):
                self.luckyStack.queue[nextIdx].progress = 0.65 + Double(done) / Double(max(total, 1)) * 0.3
                self.luckyStack.queue[nextIdx].statusText = "stacking \(done)/\(total)"
                self.jobStatus = .running(processed: done, total: total)
            case .writing:
                self.luckyStack.queue[nextIdx].statusText = "writing"
                self.luckyStack.queue[nextIdx].progress = 0.98
            case .finished(let url):
                self.luckyStack.queue[nextIdx].status = .done
                self.luckyStack.queue[nextIdx].progress = 1.0
                self.luckyStack.queue[nextIdx].outputURL = url
                self.luckyStack.queue[nextIdx].statusText = "done"
                // Surface the new output in the Outputs section. First output
                // of a run flips to OUTPUTS automatically so the user sees
                // their results without having to toggle.
                let isFirst = (self.outputsRootURL == nil)
                self.registerOutput(url: url, autoSwitch: isFirst)
                self.runNextLuckyStackItem(outputFolder: outputFolder, options: options)
            case .error(let msg):
                self.luckyStack.queue[nextIdx].status = .error
                self.luckyStack.queue[nextIdx].statusText = msg
                self.runNextLuckyStackItem(outputFolder: outputFolder, options: options)
            }
        }
    }

    // MARK: - Presets

    func applyPreset(_ preset: Preset) {
        sharpen = preset.sharpen
        stabilize = preset.stabilize
        toneCurve = preset.toneCurve
        luckyStack.mode = preset.luckyMode
        luckyStack.keepPercent = preset.luckyKeepPercent
        // Per-preset Multi-AP tuning. Grid==0 means the preset prefers the
        // single-AP global path; grid>0 turns Multi-AP on with the grid size.
        if preset.luckyMultiAPGrid > 0 && preset.luckyMode == .scientific {
            luckyStack.multiAP = .grid(preset.luckyMultiAPGrid, preset.luckyMultiAPPatchHalf)
        } else {
            luckyStack.multiAP = .off
        }
        luckyStack.variants = preset.luckyVariants
        presets.activeID = preset.id
    }

    /// Snapshot the current settings into a new user preset.
    func saveCurrentAsPreset(name: String, target: PresetTarget, notes: String = "") {
        let p = Preset(
            name: name,
            target: target,
            notes: notes,
            isBuiltIn: false,
            sharpen: sharpen,
            stabilize: stabilize,
            toneCurve: toneCurve,
            luckyMode: luckyStack.mode,
            luckyKeepPercent: luckyStack.keepPercent,
            luckyMultiAPGrid: luckyStack.multiAP.grid,
            luckyMultiAPPatchHalf: luckyStack.multiAP.patchHalf,
            luckyVariants: luckyStack.variants
        )
        presets.save(p)
    }

    /// Update the existing preset (must be a user preset) with current settings.
    func updateActivePreset() {
        guard let id = presets.activeID,
              let existing = presets.preset(withID: id),
              !existing.isBuiltIn else { return }
        var updated = existing
        updated.sharpen = sharpen
        updated.stabilize = stabilize
        updated.toneCurve = toneCurve
        updated.luckyMode = luckyStack.mode
        updated.luckyKeepPercent = luckyStack.keepPercent
        updated.luckyMultiAPGrid = luckyStack.multiAP.grid
        updated.luckyMultiAPPatchHalf = luckyStack.multiAP.patchHalf
        updated.luckyVariants = luckyStack.variants
        presets.save(updated)
    }

    // MARK: - Blink player

    /// Toggle the blink cycle on / off. When ON, the preview file rotates
    /// through the candidates list at `blinkRate` per second.
    func toggleBlink() {
        blinkActive ? stopBlink() : startBlink()
    }
    func startBlink() {
        let candidates = blinkCandidates()
        guard candidates.count >= 2 else { return }
        blinkActive = true
        blinkTimer?.invalidate()
        let interval = 1.0 / max(0.5, blinkRate)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceBlink() }
        }
    }
    func stopBlink() {
        blinkActive = false
        blinkTimer?.invalidate()
        blinkTimer = nil
    }
    func setBlinkRate(_ rate: Double) {
        blinkRate = max(0.5, min(30, rate))
        if blinkActive { startBlink() }   // reschedule with new interval
    }

    /// Returns the IDs the blink player rotates through. Prefers row-
    /// selection in the active section; if nothing selected, falls back to
    /// every file in the active section.
    private func blinkCandidates() -> [FileEntry.ID] {
        let inOrder = catalog.files.map { $0.id }
        if !selectedFileIDs.isEmpty {
            return inOrder.filter { selectedFileIDs.contains($0) }
        }
        return inOrder
    }

    private func advanceBlink() {
        let cands = blinkCandidates()
        guard cands.count >= 2 else { stopBlink(); return }
        let curIdx = cands.firstIndex(of: previewFileID ?? cands[0]) ?? -1
        previewFileID = cands[(curIdx + 1) % cands.count]
    }

    private func advanceFrame() {
        guard !playback.frames.isEmpty else { return }
        let next = playback.currentIndex + 1
        if next >= playback.frames.count {
            if playback.loop {
                playback.currentIndex = 0
            } else {
                stopPlayback()
            }
        } else {
            playback.currentIndex = next
        }
    }

    private func loadThumbnailsAsync() {
        for entry in catalog.files {
            let id = entry.id
            let url = entry.url
            Task.detached(priority: .utility) { [weak self] in
                let img = ThumbnailLoader.load(url: url, maxDimension: 48)
                await MainActor.run {
                    guard let self, let idx = self.catalog.index(of: id) else { return }
                    self.catalog.files[idx].thumbnail = img
                }
            }
        }
    }

    // MARK: - Batch

    private var activeJob: BatchJob?

    func applyToSelection() {
        let targets = batchTargetIDs
        guard !targets.isEmpty, case .idle = jobStatus else { return }

        // Stabilize needs ≥2 files.
        if stabilize.enabled && targets.count < 2 {
            jobStatus = .error("Stabilize needs at least 2 files (mark or select them first)")
            return
        }

        // Keep catalog order.
        let selectedInputs: [BatchJob.Input] = catalog.files
            .filter { targets.contains($0.id) }
            .map { BatchJob.Input(id: $0.id, url: $0.url, meridianFlipped: $0.meridianFlipped) }
        guard let root = catalog.rootURL else { return }
        let suggested = root.appendingPathComponent("_processed", isDirectory: true)
        guard let outDir = resolveWritableOutputFolder(implicit: suggested) else {
            jobStatus = .error("No writable output folder — run cancelled.")
            return
        }

        // Mark all queued.
        for id in targets {
            if let idx = catalog.index(of: id) { catalog.files[idx].status = .queued }
        }

        let job = BatchJob()
        activeJob = job
        jobStatus = .running(processed: 0, total: selectedInputs.count)

        job.run(
            inputs: selectedInputs,
            outputDir: outDir,
            config: .init(sharpen: sharpen, stabilize: stabilize, toneCurve: toneCurve)
        ) { [weak self] event in
            guard let self else { return }
            switch event {
            case .started(let total):
                self.jobStatus = .running(processed: 0, total: total)
            case .fileStarted(let id):
                if let idx = self.catalog.index(of: id) {
                    self.catalog.files[idx].status = .processing(progress: 0.5)
                }
            case .fileDone(let id):
                if let idx = self.catalog.index(of: id) {
                    self.catalog.files[idx].status = .done
                }
                if case .running(let p, let t) = self.jobStatus {
                    self.jobStatus = .running(processed: p + 1, total: t)
                }
            case .fileFailed(let id, let msg):
                if let idx = self.catalog.index(of: id) {
                    self.catalog.files[idx].status = .error(msg)
                }
                if case .running(let p, let t) = self.jobStatus {
                    self.jobStatus = .running(processed: p + 1, total: t)
                }
            case .finished(let processed):
                self.jobStatus = .done(processed: processed, outputDir: outDir)
                self.activeJob = nil
                // Re-scan the output folder once and add all written files
                // to the OUTPUTS section. Auto-switch on first output run.
                self.scanOutputFolder(outDir, autoSwitch: self.outputsRootURL == nil)
            case .cancelled:
                self.jobStatus = .idle
                self.activeJob = nil
            }
        }
    }

    /// Scan an output folder and add every supported file we find to the
    /// OUTPUTS section (replacing any prior contents from the same root).
    private func scanOutputFolder(_ folder: URL, autoSwitch: Bool) {
        outputsRootURL = folder
        var newCat = FileCatalog()
        newCat.load(from: folder)

        if displayedSection == .outputs {
            catalog = newCat
            previewFileID = newCat.files.first?.id
        } else {
            var stash = stashedStates[.outputs] ?? CatalogSectionState()
            stash.catalog = newCat
            stashedStates[.outputs] = stash
        }
        for entry in newCat.files {
            let id = entry.id
            let url = entry.url
            Task.detached(priority: .utility) { [weak self] in
                let img = ThumbnailLoader.load(url: url, maxDimension: 48)
                await MainActor.run {
                    self?.attachOutputThumbnail(img, forID: id)
                }
            }
        }
        if autoSwitch && displayedSection != .outputs {
            switchToSection(.outputs)
        }
    }
}

// MARK: - Settings

struct SharpenSettings: Equatable, Codable {
    var enabled: Bool = true

    // Classical Unsharp Mask.
    var unsharpEnabled: Bool = true
    var radius: Double = 1.5         // Gaussian sigma in pixels
    var amount: Double = 1.0         // Unsharp amount
    var adaptive: Bool = false

    // Lucy-Richardson deconvolution.
    var lrEnabled: Bool = false
    var lrIterations: Int = 30
    var lrSigma: Double = 1.3

    // Wiener deconvolution (synthetic Gaussian PSF).
    // Linear MSE-optimal inverse — sharper edges than L-R for known PSFs,
    // but ringing risk if SNR is mis-set. Best for crisp planetary frames
    // where the optical PSF is well-modelled by a Gaussian.
    var wienerEnabled: Bool = false
    var wienerSigma: Double = 1.4
    var wienerSNR: Double = 50

    // Wavelet sharpening (à-trous / starlet) — 4 dyadic scales, independently
    // boosted. Standard tool for solar/planetary sharpening (Registax-style).
    var waveletEnabled: Bool = false
    var waveletScales: [Double] = [1.8, 1.4, 1.0, 0.6]  // amounts for scales 1..4
}

struct StabilizeSettings: Equatable, Codable {
    var enabled: Bool = false
    var referenceMode: ReferenceMode = .firstSelected
    var cropMode: CropMode = .pad
    var stackAverage: Bool = false

    enum ReferenceMode: String, CaseIterable, Identifiable, Codable {
        case firstSelected = "First Selected"
        case brightest = "Brightest Frame"
        var id: String { rawValue }
    }

    enum CropMode: String, CaseIterable, Identifiable, Codable {
        case pad = "Pad to Bounding Box"       // output stays at input size, black borders
        case crop = "Crop to Intersection"     // output = overlap region of all frames
        var id: String { rawValue }
    }
}

struct ToneCurveSettings: Equatable, Codable {
    var enabled: Bool = false
    var controlPoints: [CGPoint] = [
        CGPoint(x: 0.0, y: 0.0),
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 1.0, y: 1.0),
    ]
}

// MARK: - Lucky Stack UI state

struct LuckyStackItem: Identifiable {
    enum Status { case pending, processing, done, error }
    let id = UUID()
    let url: URL
    var meridianFlipped: Bool = false
    /// Empty for the default "use the slider" run; otherwise "f100", "p25",
    /// etc. Becomes the subdirectory name in the output folder.
    var variantLabel: String = ""
    /// Either an explicit absolute frame count or the slider percent (when
    /// `absoluteCount` is nil).
    var absoluteCount: Int?
    var keepPercent: Int = 25
    var status: Status = .pending
    var progress: Double = 0
    var statusText: String = "pending"
    var outputURL: URL?
}

/// Multi-AP local alignment configuration. `grid` of 0 disables it; otherwise
/// the value is the edge length of the AP grid (e.g. 8 → 8×8 = 64 APs).
/// `patchHalf` is the radius of each correlation patch in pixels (so 8 →
/// 16×16 patch). Both numbers come from the active preset; UI exposes them
/// for power users in Scientific mode.
struct LuckyMultiAPConfig: Codable, Equatable {
    var grid: Int = 0
    var patchHalf: Int = 8
    var enabled: Bool { grid > 0 }

    static let off = LuckyMultiAPConfig(grid: 0, patchHalf: 8)
    static func grid(_ n: Int, _ patchHalf: Int = 8) -> LuckyMultiAPConfig {
        LuckyMultiAPConfig(grid: n, patchHalf: patchHalf)
    }

    var label: String {
        if !enabled { return "Off" }
        return "\(grid)×\(grid) (patch \(patchHalf * 2))"
    }
}

enum LuckyStackFilenameMode: String, CaseIterable, Identifiable, Equatable, Codable {
    case sharpcap = "SharpCap (preserve)"
    case winjupos = "WinJUPOS (timestamped)"
    var id: String { rawValue }
}

/// Optional extra stack outputs requested per .ser, on top of the default
/// "keep best N%" slider value. Each non-zero entry triggers a *separate*
/// stack run for that file, written to a subdirectory of the output folder
/// (e.g. `f100/`, `p25/`). Default values are all zero meaning "off".
struct LuckyStackVariants: Codable, Equatable {
    var absoluteCounts: [Int] = [0, 0, 0]   // f-slots
    var percentages: [Int] = [0, 0, 0]      // p-slots

    var isEmpty: Bool {
        absoluteCounts.allSatisfy { $0 == 0 } && percentages.allSatisfy { $0 == 0 }
    }
}

struct LuckyStackUIState {
    var mode: LuckyStackMode = .lightspeed
    var keepPercent: Int = 25
    var queue: [LuckyStackItem] = []
    var outputFolder: URL?
    var filenameMode: LuckyStackFilenameMode = .sharpcap
    var multiAP: LuckyMultiAPConfig = .off
    var variants: LuckyStackVariants = LuckyStackVariants()
    /// When ON, the stacked texture is run through the standard sharpen +
    /// tone pipeline before being written to disk. Default ON because users
    /// almost always expect the saved file to look like the live preview;
    /// turn OFF to keep raw stacks for separate downstream processing.
    var bakeInProcessing: Bool = true

    /// Optional target tag used to fill the WinJUPOS `<obj>` field. Defaults
    /// to whatever is in the active preset's target if any.
    var winjuposTarget: String = "Sun"
}

enum LuckyStackNaming {
    /// Build the output filename for one stacked file.
    /// - sharpcap: `<basename>_stack.tif`
    /// - winjupos: `YYYY-MM-DD-HHmm_s-<target>.tif`, falling back to the
    ///   SharpCap filename if the SER has no UTC timestamp embedded.
    static func filename(for url: URL, header: SerHeader?, mode: LuckyStackFilenameMode, target: String) -> String {
        let safeTarget = target.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "")
        switch mode {
        case .sharpcap:
            return url.deletingPathExtension().lastPathComponent + "_stack.tif"
        case .winjupos:
            if let date = header?.dateUTC {
                let fmt = DateFormatter()
                fmt.timeZone = TimeZone(identifier: "UTC")
                fmt.dateFormat = "yyyy-MM-dd-HHmm_ss"
                let stamp = fmt.string(from: date)
                return "\(stamp)-\(safeTarget).tif"
            }
            // Fallback: keep SharpCap base name + target.
            let base = url.deletingPathExtension().lastPathComponent
            return "\(base)-\(safeTarget).tif"
        }
    }
}

// MARK: - Playback (in-memory sequence)

struct PlaybackFrame: Identifiable {
    let id: UUID         // matches FileEntry.id of the source file
    let sourceURL: URL
    var texture: MTLTexture
}

struct PlaybackState {
    var frames: [PlaybackFrame] = []
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var fps: Double = 24
    var loop: Bool = true

    var hasFrames: Bool { !frames.isEmpty }
    var currentFrame: PlaybackFrame? {
        guard frames.indices.contains(currentIndex) else { return nil }
        return frames[currentIndex]
    }
}

// MARK: - Job status

enum JobStatus: Equatable {
    case idle
    case running(processed: Int, total: Int)
    case done(processed: Int, outputDir: URL)
    case error(String)

    var isIdle: Bool { if case .idle = self { return true } else { return false } }
}
