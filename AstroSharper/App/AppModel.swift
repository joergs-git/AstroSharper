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
    /// User-pinned reference frame for stabilization. Single-valued — only
    /// one frame in the catalog can hold this marker at any time. Press R
    /// in the file list (or use the toolbar) to set / clear it. The
    /// Stabilize "Reference" picker defaults to this; if the user runs
    /// Stabilize without one set we fall back to the first selected frame
    /// and surface a one-time warning.
    @Published var referenceFileID: FileEntry.ID?
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
    @Published var blinkRate: Double = 18    // frames per second
    private var blinkTimer: Timer?

    // SER in-file playback. When the user has a multi-frame SER selected,
    // the play button advances `previewSerFrameIndex` (instead of cycling
    // between files) so they can preview the captured stream.
    @Published var serPlaybackActive: Bool = false
    private var serPlaybackTimer: Timer?

    /// Display-only auto-range stretch (AS!4-style "Auto Range 16-bit").
    /// Default ON: bright SER captures (solar Ha, lunar at low gain) land
    /// in the upper half of the 16-bit range with peaks near 1.0, so the
    /// raw display reads as washed-out white. Auto-range linearly remaps
    /// [p1, p99] → [0, 1] in the FRAGMENT SHADER ONLY — the underlying
    /// texture and saved files are unchanged. Toggle OFF to see the bare
    /// pixel values.
    @Published var displayAutoRange: Bool = true

    // Preview HUD — translucent stats overlay shown on top of the preview.
    // `previewStats` is filled by PreviewCoordinator as data becomes
    // available (header → current frame → distribution).
    @Published var previewStats: PreviewStats = PreviewStats()
    @Published var hudVisible: Bool = true

    /// Visible viewport in normalised image coordinates (0…1, top-left
    /// origin). Mini-map overlay was disabled — kept on the model so the
    /// helper code can be revived without churn.
    @Published var previewViewport: CGRect? = nil

    /// True while a Calculate-Video-Quality scan is running for the active
    /// file. The HUD swaps the button for a spinner when set.
    @Published var isCalculatingVideoQuality: Bool = false

    /// True while the live-preview pipeline is processing the most recent
    /// slider / setting change. Drives the top-right ProgressView overlay
    /// on PreviewView so the user knows their change is being applied —
    /// the preview was already async (background processingQueue), but
    /// the user had no signal that work was happening.
    @Published var processingInFlight: Bool = false

    /// True while a freshly-clicked file is being read into a preview
    /// texture. Critical for NAS-mounted SERs where the first frame's
    /// page-fault read can take 1-3 seconds — without this signal the
    /// user sees a black canvas and assumes the app is broken.
    @Published var isLoadingPreview: Bool = false

    /// Filename + size shown in the loading overlay so the user knows
    /// WHICH file is being read (vs guessing because they just clicked
    /// fast through several rows). Cleared when isLoadingPreview goes
    /// false.
    @Published var loadingPreviewLabel: String? = nil

    /// User-facing error from the most recent preview load. nil means
    /// the load succeeded or there's no current file. PreviewView shows
    /// this as an inline overlay so SER format / decode failures
    /// (unsupported ColorID, corrupt header, RGB-not-yet-supported,
    /// readerOpenFailed on a bad NAS share) don't silently leave the
    /// user with a black canvas.
    @Published var previewError: String? = nil

    /// Which high-level pipeline stage is currently executing in the
    /// live preview. nil = idle. Drives the colored highlight on the
    /// SettingsPanel section headers so the user can see which step
    /// of the pipeline is running. Pipeline.process emits transitions
    /// via a callback that PreviewCoordinator forwards to this property.
    @Published var activePreviewStage: PreviewStage? = nil

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

    /// Stabilize / Align operates on a *sequence of single-frame files*
    /// (one TIFF per timestamp / per session). It is NOT meaningful on
    /// .ser / .avi inputs — those are video containers where the
    /// equivalent stabilization happens inside the Lucky Stack pipeline
    /// per-frame. The button gate also requires ≥ 2 targets and a
    /// reference frame marker — without an explicit reference, the
    /// alignment uses the first frame which is rarely the sharpest.
    /// Idle gate keeps clicks from queuing while a run is already in
    /// flight.
    var canStabilize: Bool {
        guard jobStatus.isIdle else { return false }
        let targets = batchTargetIDs
        guard targets.count >= 2 else { return false }
        // Reject if ANY target is a SER / AVI sequence container.
        let videoExts: Set<String> = ["ser", "avi", "mov", "mp4", "m4v"]
        for id in targets {
            guard let f = catalog.files.first(where: { $0.id == id }) else { continue }
            if videoExts.contains(f.url.pathExtension.lowercased()) { return false }
        }
        // Reference marker must be set AND must point at one of the
        // current targets (otherwise the marker is on a row the user
        // didn't actually include in this batch).
        guard let ref = referenceFileID, targets.contains(ref) else { return false }
        return true
    }

    /// Reason the Stabilize button is disabled — surfaced as a tooltip
    /// in the GUI so the user knows what's missing instead of staring
    /// at a greyed button. Returns nil when the button is enabled.
    var stabilizeDisabledReason: String? {
        if !jobStatus.isIdle { return "Job already running" }
        let targets = batchTargetIDs
        if targets.count < 2 { return "Mark or select ≥ 2 image files" }
        let videoExts: Set<String> = ["ser", "avi", "mov", "mp4", "m4v"]
        for id in targets {
            guard let f = catalog.files.first(where: { $0.id == id }) else { continue }
            if videoExts.contains(f.url.pathExtension.lowercased()) {
                return "Stabilize doesn't apply to SER / AVI sequences"
            }
        }
        if referenceFileID == nil || !targets.contains(referenceFileID!) {
            return "Press R on a row to set a reference frame"
        }
        return nil
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
                guard let self else { return }
                // Switching the previewed file invalidates any running SER
                // in-file playback; the new file may not even be a SER.
                if self.serPlaybackActive { self.stopSerPlayback() }
                guard self.displayedSection == .memory, let id else { return }
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
        // Auto-select the first file so the user doesn't have to click a row
        // before running Apply / Lucky Stack. Matches AstroTriage's behaviour
        // and removes a redundant click from the open-→-process path.
        let firstID = catalog.files.first?.id
        selectedFileIDs = firstID.map { Set([$0]) } ?? []
        markedFileIDs.removeAll()
        previewFileID = firstID
        jobStatus = .idle
        loadThumbnailsAsync()
        autoApplyDefaultPreset(candidates: catalogCandidateStrings(rootURL: url))
        autoApplyOscDefaults()
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

    /// Block D.3: turn on auto white balance when the just-loaded files
    /// contain at least one OSC (Bayer SER / RGB SER / AVI) source. The
    /// detection peeks at the first file's SER header — sub-millisecond
    /// on Apple Silicon. Idempotent (no-op when autoWB is already on or
    /// the source is mono) so re-opening a folder doesn't toggle the
    /// flag back and forth.
    private func autoApplyOscDefaults() {
        guard let firstURL = catalog.files.first?.url else { return }
        if OscDefaults.applyDefaults(to: &toneCurve, for: firstURL) {
            NSLog("OscDefaults: enabled autoWB for OSC source %@", firstURL.lastPathComponent)
        }
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
        // Auto-select the first file so the user doesn't have to click a row
        // before running Apply / Lucky Stack. Matches AstroTriage's behaviour
        // and removes a redundant click from the open-→-process path.
        let firstID = catalog.files.first?.id
        selectedFileIDs = firstID.map { Set([$0]) } ?? []
        markedFileIDs.removeAll()
        previewFileID = firstID
        jobStatus = .idle
        loadThumbnailsAsync()
        autoApplyDefaultPreset(candidates: catalogCandidateStrings(rootURL: inferredRoot ?? urls.first))
        autoApplyOscDefaults()
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

    /// Select + preview the just-registered output file so the user sees
    /// it highlighted in the file list AND loaded in the preview pane.
    /// Looks up the entry by URL because `registerOutput` appended via
    /// the active-or-stashed path; either way the URL is unique. No-op if
    /// the row isn't in the active catalog yet (deferred entries land
    /// after switchToSection).
    func highlightLatestOutput(url: URL) {
        guard let id = catalog.files.first(where: { $0.url == url })?.id else { return }
        selectedFileIDs = Set([id])
        markedFileIDs.removeAll()
        previewFileID = id
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

    /// Pin a single frame as the stabilization reference. Pressing R when a
    /// frame is already the reference clears the marker, so R behaves as
    /// a sticky toggle on a single row.
    func toggleReference(_ id: FileEntry.ID) {
        if referenceFileID == id {
            referenceFileID = nil
        } else {
            referenceFileID = id
        }
        clearStaleError()
    }

    /// Remove any reference marker — used when the marked file is removed
    /// from the list or its section gets stashed.
    func clearReferenceMarker() {
        referenceFileID = nil
    }

    // MARK: - Deletion from list (doesn't touch disk)

    func removeFromList(_ ids: Set<FileEntry.ID>) {
        guard !ids.isEmpty else { return }
        catalog.files.removeAll { ids.contains($0.id) }
        selectedFileIDs.subtract(ids)
        markedFileIDs.subtract(ids)
        if let refID = referenceFileID, ids.contains(refID) { referenceFileID = nil }

        // Memory section: keep playback frames in sync with the list. Without
        // this the player's `currentIndex` points at a hole or an unrelated
        // frame, causing the texture-mix-up artefacts at the border the user
        // saw when scrubbing or deleting.
        if displayedSection == .memory {
            playback.frames.removeAll { ids.contains($0.id) }
            if playback.frames.isEmpty {
                playback.currentIndex = 0
                playback.isPlaying = false
            } else {
                playback.currentIndex = min(playback.currentIndex, playback.frames.count - 1)
            }
        }

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

        // Pick the reference frame ID per the user's choice. `.marked`
        // requires an explicit R-marker; if none is set we fall back to
        // first-selected and surface a helpful warning so the user knows
        // alignment may drift.
        let orderedTargetIDs: [FileEntry.ID] = catalog.files
            .filter { targets.contains($0.id) }
            .map { $0.id }

        var referenceID: FileEntry.ID = orderedTargetIDs.first!
        var referenceWarning: String?
        switch stabilize.referenceMode {
        case .marked:
            if let r = referenceFileID, orderedTargetIDs.contains(r) {
                referenceID = r
            } else {
                referenceWarning = "No reference marked — using first selected. Press R on a row to pin one."
            }
        case .firstSelected:
            referenceID = orderedTargetIDs.first!
        case .brightestQuality:
            // Best-quality frame is picked inside the Stabilizer (it has
            // the texture handles). We pass `nil` to signal that; here we
            // just leave the placeholder — Stabilizer will overwrite.
            referenceID = orderedTargetIDs.first!
        }

        // (b) Pre-flight warning when running from Memory and prior in-
        // memory edits exist. With (a) we *preserve* those edits — but the
        // user should still know that re-aligning means "stabilizing on
        // top of already-edited frames", which can re-introduce frame-to-
        // frame alignment drift if the prior edits were spatial. Fast,
        // synchronous confirm via NSAlert keeps the flow simple.
        if displayedSection == .memory {
            let dirty = playback.frames.contains { f in
                let nontrivial = f.appliedOps.filter { $0 != "aligned" }
                return !nontrivial.isEmpty
            }
            if dirty {
                let alert = NSAlert()
                alert.messageText = "Stabilize over edited frames?"
                alert.informativeText = "Memory contains frames with already-applied operations (sharpen / tone). Stabilize will compute fresh shifts on the current — possibly edited — pixels and replace each frame's texture. The op trail is preserved."
                alert.addButton(withTitle: "Stabilize")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn {
                    return
                }
            }
        }

        // Build inputs. In Memory tab we hand over the *current* memory
        // textures (preserving any in-place sharpen/tone edits) instead of
        // forcing a re-load from disk. In Inputs tab we just pass URLs and
        // Stabilizer loads them itself.
        let preloaded: [UUID: MTLTexture]
        let priorOps: [UUID: [String]]
        if displayedSection == .memory {
            var px: [UUID: MTLTexture] = [:]
            var ops: [UUID: [String]] = [:]
            for frame in playback.frames where targets.contains(frame.id) {
                px[frame.id] = frame.texture
                ops[frame.id] = frame.appliedOps
            }
            preloaded = px
            priorOps = ops
        } else {
            preloaded = [:]
            priorOps = [:]
        }

        let urls: [(id: FileEntry.ID, url: URL, meridianFlipped: Bool)] = catalog.files
            .filter { targets.contains($0.id) }
            .map { ($0.id, $0.url, $0.meridianFlipped) }

        if let warn = referenceWarning {
            // Non-fatal — surface as a status message. Cleared automatically
            // when a job starts.
            print("[stabilize] \(warn)")
        }

        jobStatus = .running(processed: 0, total: urls.count)
        stopPlayback()

        Stabilizer.run(
            inputs: .init(urls: urls,
                          cropMode: stabilize.cropMode,
                          alignmentMode: stabilize.alignmentMode,
                          referenceID: referenceID,
                          pickBestReference: stabilize.referenceMode == .brightestQuality,
                          roi: stabilize.roi?.asCGRect,
                          preloadedTextures: preloaded),
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
                // Preserve prior op trails — append "aligned" so the user
                // can see the full processing history (e.g. ["sharp",
                // "aligned"] when they sharpened first then re-stabilized).
                self.playback.frames = result.aligned.map { res in
                    let trail = (priorOps[res.id] ?? []) + ["aligned"]
                    return PlaybackFrame(id: res.id, sourceURL: res.url,
                                         texture: res.texture, appliedOps: trail)
                }
                self.playback.currentIndex = 0
                self.playback.isPlaying = false
                // Land the user on MEMORY tab so they immediately see the
                // aligned frames as a list. They can scrub via the player
                // and, when satisfied, click "Save All" to write to OUTPUTS.
                self.switchToSection(.memory)
                if let warn = referenceWarning {
                    self.jobStatus = .error(warn)   // friendly post-run hint
                } else {
                    self.jobStatus = .idle
                }
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

        // Smart subfolder pick: when the entire memory has the same op trail
        // we drop everything into one named folder. Mixed trails go into the
        // generic `processed/` subfolder; the suffix on each filename still
        // disambiguates which ops ran on which frame.
        let allOps = Set(playback.frames.map { $0.appliedOps.joined(separator: "_") })
        let folderName = (allOps.count == 1 ? allOps.first! : "processed")
            .replacingOccurrences(of: " ", with: "")
        let outFolder = root.appendingPathComponent(folderName.isEmpty ? "raw" : folderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        } catch {
            jobStatus = .error("Cannot create output subfolder: \(error.localizedDescription)")
            return
        }

        let frames = playback.frames
        Task.detached(priority: .userInitiated) { [weak self] in
            for frame in frames {
                let baseName = frame.sourceURL.deletingPathExtension().lastPathComponent
                let suffix = frame.appliedOps.isEmpty ? "" : "_" + frame.appliedOps.joined(separator: "_")
                let outURL = outFolder.appendingPathComponent("\(baseName)\(suffix).tif")
                try? ImageTexture.write(texture: frame.texture, to: outURL)
                await MainActor.run {
                    self?.registerOutput(url: outURL, autoSwitch: false)
                }
            }
            await MainActor.run {
                guard let self else { return }
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
        let selectedAvi  = catalog.files.filter { targets.contains($0.id) && $0.isAVI }
        guard !selectedSers.isEmpty else {
            if !selectedAvi.isEmpty {
                // AVI files are recognised in the catalog but the lucky-stack
                // engine still expects a SER reader; full AVI demuxing is on
                // the roadmap. Surface the limitation explicitly instead of
                // silently no-oping.
                jobStatus = .error("AVI lucky-stack support is coming — please convert to SER for now.")
            } else {
                jobStatus = .error("Mark or select at least one .ser file in the list.")
            }
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
        perItemOpts.perChannelStacking = luckyStack.perChannelStacking
        perItemOpts.useAutoPSF = luckyStack.autoPSF
        perItemOpts.autoPSFSNR = luckyStack.autoPSFSNR
        perItemOpts.denoisePrePercent = luckyStack.denoisePrePercent
        perItemOpts.denoisePostPercent = luckyStack.denoisePostPercent
        perItemOpts.useTiledDeconv = luckyStack.tiledDeconv
        perItemOpts.tiledDeconvAPGrid = luckyStack.tiledDeconvAPGrid
        perItemOpts.useAutoKeepPercent = luckyStack.autoKeepPercent
        // Stack-end remap: GUI toggle drives the engine flag. Default OFF
        // in luckyStack.autoRecoverDynamicRange — bare accumulator
        // preserves highlight detail, which the bracket on 2026-04-30
        // showed users prefer over the percentile stretch.
        perItemOpts.disableOutputRemap = !luckyStack.autoRecoverDynamicRange
        // Sigma-clip accumulator (B.1) — Scientific mode only. The
        // engine's `accumulateAlignedSigmaClipped` path triggers when
        // `options.sigmaThreshold` is non-nil, so we leave it nil
        // unless the GUI checkbox is on AND we're in scientific mode.
        perItemOpts.sigmaThreshold = (luckyStack.mode == .scientific && luckyStack.sigmaClipEnabled)
            ? Float(luckyStack.sigmaClipThreshold)
            : nil

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
                // ALWAYS flip to Outputs after a stack lands so the user
                // sees their result without manual navigation. registerOutput
                // appends the file to the catalog (active or stashed); we
                // then select+preview it so the row is highlighted and the
                // texture is loaded into the preview pane.
                self.registerOutput(url: url, autoSwitch: true)
                self.highlightLatestOutput(url: url)
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

    // MARK: - Per-section apply actions
    //
    // Hero buttons under Sharpening / Tone Curve route to these. Behaviour
    // depends on which catalog section is active:
    //   - Memory: process every in-memory frame in-place (or every marked
    //     subset). Stays in memory; ops accumulate in PlaybackFrame.appliedOps
    //     so the eventual Save All builds smart filenames.
    //   - Inputs / Outputs: same as Apply-to-Selection — load → process →
    //     write to a corresponding `_<op>` subfolder of the output root.

    func runSharpenOnActiveSection() {
        runMixedAction(name: "sharp", suffix: "_sharp",
                       includeSharpen: true, includeTone: false)
    }

    func runToneOnActiveSection() {
        runMixedAction(name: "tone", suffix: "_tone",
                       includeSharpen: false, includeTone: true)
    }

    /// "Apply ALL Stuff" — single-button pipeline that picks the right path
    /// based on the active section and which sections are enabled. Lucky
    /// Stack inherently breaks the chain (it consumes a whole SER and
    /// produces a single stacked frame), so if it's enabled and SER files
    /// are present in the selection we run *only* lucky-stack — its bake-in
    /// option already pulls sharpen / tone-curve into the stacked output.
    /// Otherwise:
    ///   - In Memory: apply sharpen + tone in-place to memory frames.
    ///   - In Inputs: run the regular file batch (stabilize → sharpen →
    ///     tone) which writes straight to the outputs folder.
    func applyAllStuff() {
        guard case .idle = jobStatus else { return }
        let targets = batchTargetIDs
        let serSelected = catalog.files.contains { targets.contains($0.id) && $0.isSER }

        // Lucky Stack route — auto-engages whenever SER files are present in
        // the selection. SER is the lucky-imaging input format, so this is
        // what the user expects; non-SER input falls through to the regular
        // file pipeline (stabilize / sharpen / tone).
        if serSelected {
            runLuckyStackOnSelection()
            return
        }

        if displayedSection == .memory {
            // Run both sharpen and tone in-place on memory frames. If
            // neither is enabled there's nothing to do — surface a helpful
            // status message instead of silently no-oping.
            if !sharpen.enabled && !toneCurve.enabled {
                jobStatus = .error("Nothing to apply — enable Sharpening or Tone Curve first.")
                return
            }
            applyToMemoryFrames(opName: "all",
                                includeSharpen: sharpen.enabled,
                                includeTone: toneCurve.enabled)
            return
        }

        // Inputs / Outputs section — the file-level pipeline. applyToSelection
        // already honours each section's `enabled` flag so we can hand it the
        // current settings unchanged.
        applyToSelection()
    }

    private func runMixedAction(
        name: String,
        suffix: String,
        includeSharpen: Bool,
        includeTone: Bool
    ) {
        if displayedSection == .memory {
            applyToMemoryFrames(opName: name,
                                includeSharpen: includeSharpen,
                                includeTone: includeTone)
        } else {
            applyToFileSelection(suffix: suffix,
                                 includeSharpen: includeSharpen,
                                 includeTone: includeTone)
        }
    }

    private func applyToMemoryFrames(opName: String, includeSharpen: Bool, includeTone: Bool) {
        guard !playback.frames.isEmpty else {
            jobStatus = .error("Memory is empty — run Stabilize / Lucky-Stack first.")
            return
        }
        // If the user marked specific memory rows we honour that; else apply
        // to every in-memory frame.
        let target: Set<UUID> = batchTargetIDs.isEmpty ? Set(playback.frames.map(\.id)) : batchTargetIDs

        // Build a "no-op" sharpen settings struct rather than fight the
        // memberwise init signature — clearer and resilient to field reorders.
        var emptySharpen = SharpenSettings()
        emptySharpen.enabled = false
        let s = includeSharpen ? sharpen : emptySharpen
        let t = includeTone ? toneCurve : ToneCurveSettings()
        let lut: MTLTexture? = includeTone && toneCurve.enabled
            ? ToneCurveLUT.build(points: toneCurve.controlPoints, device: MetalDevice.shared.device)
            : nil

        let device = MetalDevice.shared.device
        let pipeline = self.stabilizerPipeline
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for (i, frame) in await self.playback.frames.enumerated() where target.contains(frame.id) {
                let processed = pipeline.process(input: frame.texture, sharpen: s,
                                                  toneCurve: t, toneCurveLUT: lut)
                await MainActor.run {
                    self.playback.frames[i].texture = processed
                    self.playback.frames[i].appliedOps.append(opName)
                }
            }
            _ = device
        }
    }

    private func applyToFileSelection(suffix: String, includeSharpen: Bool, includeTone: Bool) {
        let targets = batchTargetIDs
        guard !targets.isEmpty else {
            jobStatus = .error("Select or mark files first.")
            return
        }
        // Use the existing batch pipeline but override per-section settings.
        let savedSharpen = sharpen
        let savedTone = toneCurve
        if !includeSharpen { sharpen.enabled = false }
        if !includeTone   { toneCurve.enabled = false }
        applyToSelection()
        // Restore — applyToSelection captures current values into the job at
        // start, so this restore doesn't cancel anything in flight.
        sharpen = savedSharpen
        toneCurve = savedTone
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
        blinkRate = max(0.5, min(60, rate))
        if blinkActive { startBlink() }   // reschedule with new interval
        if serPlaybackActive { startSerPlayback() }
    }

    // MARK: - SER in-file player

    /// True when the currently-previewed file is a frame-sequence (SER or
    /// AVI) with more than one frame. Drives whether the play button
    /// auto-advances frames in the file or blinks across files.
    var canPlaySerFrames: Bool {
        guard let id = previewFileID,
              let entry = catalog.files.first(where: { $0.id == id }),
              entry.isFrameSequence else { return false }
        return previewSerFrameCount > 1
    }

    func toggleSerPlayback() {
        serPlaybackActive ? stopSerPlayback() : startSerPlayback()
    }
    func startSerPlayback() {
        guard canPlaySerFrames else { return }
        serPlaybackActive = true
        serPlaybackTimer?.invalidate()
        let interval = 1.0 / max(0.5, blinkRate)
        serPlaybackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceSerFrame() }
        }
    }
    func stopSerPlayback() {
        serPlaybackActive = false
        serPlaybackTimer?.invalidate()
        serPlaybackTimer = nil
    }
    private func advanceSerFrame() {
        guard previewSerFrameCount > 0 else { stopSerPlayback(); return }
        previewSerFrameIndex = (previewSerFrameIndex + 1) % previewSerFrameCount
    }
    func stepSerFrame(by delta: Int) {
        guard previewSerFrameCount > 0 else { return }
        let n = previewSerFrameCount
        previewSerFrameIndex = ((previewSerFrameIndex + delta) % n + n) % n
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
            let isFrameSeq = entry.isFrameSequence
            Task.detached(priority: .utility) { [weak self] in
                let img = ThumbnailLoader.load(url: url, maxDimension: 48)
                await MainActor.run {
                    guard let self, let idx = self.catalog.index(of: id) else { return }
                    self.catalog.files[idx].thumbnail = img
                }
                // Static-image sharpness — populated from cache only. The
                // earlier auto-compute path ran SharpnessProbe on every new
                // static image at section-switch time, which scaled with
                // the OUTPUTS folder size: 20 freshly-stacked TIFFs ≈
                // 20 GPU passes + 20 main-thread writes ≈ 1–3 s before the
                // table felt responsive again. Match the pattern already
                // established for SER quality scans: cache hits populate
                // automatically, cache misses leave the column blank until
                // the user explicitly opts in via the
                // "Calculate Video Quality" button (or a future static-
                // image equivalent).
                guard !isFrameSeq else { return }
                if let cached = await QualityCache.shared.lookup(url: url),
                   let s = cached.sharpness {
                    await MainActor.run {
                        guard let self, let idx = self.catalog.index(of: id) else { return }
                        self.catalog.files[idx].sharpness = s
                    }
                }
            }
        }
    }

    // MARK: - On-demand video quality scan

    /// Scanner instance shared by the on-demand "Calculate Video Quality"
    /// flow. Persists between calls so the previous scan can be cancelled
    /// before a new one starts.
    private let videoQualityScanner = SerQualityScanner()

    /// Trigger a SER quality scan for the currently-previewed file. Result
    /// lands on `previewStats.distribution` and is persisted to disk so the
    /// next visit to the same file is instant.
    func calculateVideoQualityForCurrentFile() {
        guard let id = previewFileID,
              let entry = catalog.files.first(where: { $0.id == id }),
              entry.isSER else { return }
        let url = entry.url
        let seed = previewStats
        // Flip the scanning flag immediately so the HUD swaps the button
        // for a spinner; the user otherwise sees nothing change for the
        // 3-5 s the scan takes and assumes the click was lost.
        isCalculatingVideoQuality = true
        videoQualityScanner.scan(url: url, seedStats: seed) { [weak self] updated in
            guard let self else { return }
            self.isCalculatingVideoQuality = false
            guard self.previewFileID == id else { return }
            var merged = self.previewStats
            merged.distribution = updated.distribution
            self.previewStats = merged
            if let dist = updated.distribution {
                QualityCache.shared.store(url: url, distribution: dist)
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
//
// `SharpenSettings`, `StabilizeSettings`, `NormalisedRect`, and
// `ToneCurveSettings` moved to `Engine/PipelineSettings.swift` so the
// headless CLI and test targets can consume them without dragging in
// SwiftUI / @MainActor / AppModel itself. Their definitions and
// defaults are unchanged — preset JSON on disk keeps loading.

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

// `LuckyStackVariants` moved to Engine/Pipeline/LuckyStack.swift in v1.0
// foundation work — Preset.swift consumes it, so it must be in Engine
// for the headless CLI build.

struct LuckyStackUIState {
    var mode: LuckyStackMode = .lightspeed
    var keepPercent: Int = 25
    var queue: [LuckyStackItem] = []
    var outputFolder: URL?
    var filenameMode: LuckyStackFilenameMode = .sharpcap
    var multiAP: LuckyMultiAPConfig = .off
    var variants: LuckyStackVariants = LuckyStackVariants()
    /// When ON, the stacked texture is run through the standard sharpen +
    /// tone pipeline before being written to disk. Default OFF: a freshly
    /// stacked image should land "raw" so the user can decide which post-
    /// processing to apply. Turning this ON folds the current Sharpen + Tone
    /// settings into the saved TIF, which can be unintended on the first
    /// stack of a session.
    var bakeInProcessing: Bool = false

    /// Stack-end subject-aware tone adjust. Default ON (2026-05-01)
    /// after the gamma bracket: lunar / wide-range subjects pass
    /// through unchanged, planetary / dark-dominated subjects get a
    /// pure midtone-compression gamma 1.3 (no clamping → no detail
    /// loss). User can flip OFF for bare accumulator output across
    /// all subjects.
    var autoRecoverDynamicRange: Bool = true

    /// Optional target tag used to fill the WinJUPOS `<obj>` field. Defaults
    /// to whatever is in the active preset's target if any.
    var winjuposTarget: String = "Sun"

    /// Per-channel stacking (Path B). On Bayer captures, splits the
    /// SER into independent R/G/B channel planes, aligns + stacks
    /// each one separately against a shared reference, then
    /// recombines via a Bayer-pattern-aware bilinear upsample.
    /// Mono SER captures ignore this flag. ~3× runtime cost.
    var perChannelStacking: Bool = false

    /// Auto-PSF post-pass (Block C.1 v0). When ON, after the bake-in
    /// runs, the engine estimates Gaussian PSF sigma from the
    /// planetary limb's line-spread function and applies Wiener
    /// deconvolution with the estimated sigma. Works on planetary
    /// captures (lunar/solar/Jupiter/Saturn/Mars/Venus); skipped
    /// silently if no clear limb is found in the stacked output.
    var autoPSF: Bool = false
    /// Wiener SNR for the auto-PSF post-pass. 50 = balanced default,
    /// 30 = aggressive (rings on bright planets), 100 = soft (gentle
    /// on noisy data).
    var autoPSFSNR: Double = 50

    /// Dual-stage denoise around the auto-PSF + Wiener path (Block C.5).
    /// 0..100. Pre-denoise wraps the input before PSF estimation +
    /// deconv (cleaner LSF, less noise amplification). Post-denoise
    /// runs after Wiener restore (suppresses residual ringing). Both
    /// only fire when `autoPSF == true`.
    var denoisePrePercent: Int = 0
    var denoisePostPercent: Int = 0

    /// Tiled deconvolution with green/yellow/red mask (Block C.3 v0).
    /// Classifies each AP cell by content: surface (full deconv),
    /// limb (half deconv), background (skip). Soft mask blend
    /// suppresses noise amplification in dark regions. Only fires
    /// when `autoPSF == true`.
    var tiledDeconv: Bool = false
    var tiledDeconvAPGrid: Int = 8

    /// Auto-keep-% (Block A.4). When ON, the runner uses the per-frame
    /// quality distribution (free output of the runner's own grading
    /// pass) to derive a keep fraction via
    /// `SerQualityScanner.computeKeepRecommendation` instead of the
    /// `keepPercent` slider value. Smart auto turns this on; the
    /// user can always override by setting `keepPercent` manually.
    var autoKeepPercent: Bool = false

    /// Sigma-clipped stacking (Block B.1). When ON in Scientific mode,
    /// the accumulator does a Welford pass to compute per-pixel mean +
    /// variance, then a second pass that re-means only samples within
    /// `sigmaClipThreshold × σ` of the per-pixel mean — outlier frames
    /// (cosmic rays, satellite trails, single-frame seeing spikes) get
    /// clipped per-pixel rather than rejected wholesale. Default OFF
    /// because the two-pass cost is ~2× the unclipped accumulator;
    /// users opt in when they have visible outlier contamination.
    /// AS!4 / RegiStax default σ=2.5; we mirror that.
    var sigmaClipEnabled: Bool = false
    var sigmaClipThreshold: Double = 2.5
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
//
// `PlaybackFrame` and `PlaybackState` moved to Engine/PlaybackState.swift
// in v1.0 foundation work so Engine/Exporter.swift and the headless CLI
// can reference them without dragging in SwiftUI.

// MARK: - Job status

enum JobStatus: Equatable {
    case idle
    case running(processed: Int, total: Int)
    case done(processed: Int, outputDir: URL)
    case error(String)

    var isIdle: Bool { if case .idle = self { return true } else { return false } }
}
