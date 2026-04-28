// Multi-column file list with checkbox-based marking, keyboard shortcuts,
// thumbnails, processing status and a context menu for bulk mark/remove
// operations.
//
// Selection (⌘-click / Shift-click) drives the preview target. Marking
// (checkbox / context menu) drives batch processing. Apply-to-Selection uses
// marks if any, otherwise current selection.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @EnvironmentObject private var app: AppModel
    /// Sort state — clicking any column header toggles ascending/descending
    /// order on that key, AstroTriage style. Persists per session.
    @State private var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\.name, order: .forward)
    ]

    /// Live filename search. Empty string = no filter. The toggle next to
    /// the field flips the match into an EXCLUDE filter (hide rows that
    /// contain the query) — useful for stripping intermediate "_conv" /
    /// "_aligned" outputs while leaving the originals visible.
    @State private var searchText: String = ""
    @State private var negateSearch: Bool = false

    private var filteredFiles: [FileEntry] {
        let sorted = app.catalog.files.sorted(using: sortOrder)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sorted }
        return sorted.filter { file in
            let hit = file.name.range(of: q, options: .caseInsensitive) != nil
            return negateSearch ? !hit : hit
        }
    }

    /// Map a context-menu selection (Set is unordered) into URLs in the same
    /// order the file list currently displays — so multi-row Reveal in Finder
    /// and Copy-to-Clipboard come out in the visible order rather than a
    /// random hash order. Skips IDs whose entries no longer exist (e.g. just
    /// removed from the catalog).
    private func urlsForIDs(_ ids: Set<FileEntry.ID>) -> [URL] {
        filteredFiles.filter { ids.contains($0.id) }.map(\.url)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            table
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 11))
            TextField("Filter filenames…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
            // Include / Exclude toggle. Eye = show matches; eye-slash = hide
            // matches. Tinted red when negated so the user can't miss that
            // rows are being hidden.
            Button {
                negateSearch.toggle()
            } label: {
                Image(systemName: negateSearch ? "eye.slash.fill" : "eye.fill")
                    .foregroundColor(negateSearch ? .red : .accentColor)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(negateSearch
                  ? "Excluding rows whose name contains the query — click to switch to INCLUDE."
                  : "Showing rows whose name contains the query — click to switch to EXCLUDE.")
            // Subtle status — visible row count vs total when filter is on.
            if !searchText.isEmpty {
                Text("\(filteredFiles.count)/\(app.catalog.files.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private var table: some View {
        Table(filteredFiles, selection: $app.selectedFileIDs, sortOrder: $sortOrder) {
            TableColumn("") { (file: FileEntry) in
                MarkCheckbox(isOn: app.markedFileIDs.contains(file.id)) {
                    app.toggleMark(file.id)
                }
            }
            .width(26)

            // Reference-frame star (R-key toggle). Single-valued: only one
            // row shows a filled gold star at a time. Tooltip explains the
            // shortcut so users discover it without reading docs.
            TableColumn("") { (file: FileEntry) in
                ReferenceStar(isReference: app.referenceFileID == file.id) {
                    app.toggleReference(file.id)
                }
            }
            .width(24)

            TableColumn("") { (file: FileEntry) in
                if let thumb = file.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .cornerRadius(2)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 32, height: 32)
                }
            }
            .width(40)

            TableColumn("Name", value: \.name) { (file: FileEntry) in
                Text(file.name).font(.system(size: 12))
            }

            // Sortable extension column — clicking groups SER together and
            // raster images together when the user opened a mixed folder.
            // Type + pixel dimensions combined into one column. Two
            // columns would push the table over SwiftUI's TupleView
            // limit (~10), so we render type / dims stacked here.
            TableColumn("Format", value: \.typeKey) { (file: FileEntry) in
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.typeKey.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    if let w = file.pixelWidth, let h = file.pixelHeight {
                        Text("\(w)×\(h)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .help("File type + pixel dimensions (read from header at import).")
            }
            .width(80)

            // Static-image sharpness (variance of Laplacian — higher = sharper).
            // SER / AVI rows show "—" since they use a distribution scan
            // exposed via the preview HUD instead.
            TableColumn("Sharpness", value: \.sharpnessSortKey) { (file: FileEntry) in
                if let s = file.sharpness {
                    Text(Self.sharpnessString(s))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .help("Variance of Laplacian — higher = sharper image (more high-frequency detail).")
                } else {
                    Text(file.isFrameSequence ? "video" : "—")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .width(80)

            TableColumn("Created", value: \.creationSortKey) { (file: FileEntry) in
                Text(Self.dateString(file.creationDate))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(115)

            TableColumn("Size", value: \.sizeBytes) { (file: FileEntry) in
                Text(Self.sizeString(file.sizeBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(80)

            // Flip column: show the icon only when the flag is on. Off-state
            // is an empty placeholder so layout stays stable; toggling for
            // an off-row goes through the context menu ("Toggle Meridian Flip").
            TableColumn("Flip") { (file: FileEntry) in
                FlipCheckbox(isOn: file.meridianFlipped) {
                    app.toggleMeridianFlip(file.id)
                }
            }
            .width(36)

            TableColumn("Status") { (file: FileEntry) in
                statusLabel(file.status)
            }
            .width(120)
        }
        .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
            if ids.count == 1, let id = ids.first,
               let entry = app.catalog.files.first(where: { $0.id == id }),
               entry.isSER {
                Button("Lucky Stack This File") {
                    app.runLuckyStackOnSingleFile(id: id)
                }
                Divider()
            }
            // File-system actions on the right-clicked rows. Multi-select
            // is supported: reveal selects all picked files in Finder, copy
            // joins paths with newlines, "Open in other App…" opens every
            // selected file in the chosen app.
            Button("Open Folder in Finder") {
                let urls = urlsForIDs(ids)
                guard !urls.isEmpty else { return }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            .disabled(ids.isEmpty)
            Button("Copy Path+Filename to Clipboard") {
                let paths = urlsForIDs(ids).map(\.path).joined(separator: "\n")
                guard !paths.isEmpty else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(paths, forType: .string)
            }
            .disabled(ids.isEmpty)
            Button("Open in Other App…") {
                let urls = urlsForIDs(ids)
                guard !urls.isEmpty else { return }
                let panel = NSOpenPanel()
                panel.title = "Choose Application"
                panel.prompt = "Open"
                panel.allowedContentTypes = [.application]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                if panel.runModal() == .OK, let appURL = panel.url {
                    let cfg = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                            configuration: cfg, completionHandler: nil)
                }
            }
            .disabled(ids.isEmpty)
            Divider()
            Button("Mark Selection") { app.markedFileIDs.formUnion(ids) }
                .disabled(ids.isEmpty)
            Button("Unmark Selection") { app.markedFileIDs.subtract(ids) }
                .disabled(ids.isEmpty)
            Divider()
            Button("Mark All") { app.markAll() }
            Button("Unmark All") { app.unmarkAll() }
            Button("Invert Marks") { app.invertMarks() }
            if ids.count == 1, let id = ids.first {
                Divider()
                Button(app.referenceFileID == id ? "Clear Reference Marker" : "Set as Reference Frame (R)") {
                    app.toggleReference(id)
                }
            }
            Divider()
            Button("Toggle Meridian Flip") {
                for id in ids { app.toggleMeridianFlip(id) }
            }
            .disabled(ids.isEmpty)
            Divider()
            Button("Remove from List") { app.removeFromList(ids) }
                .disabled(ids.isEmpty)
        }
        .onChange(of: app.selectedFileIDs) { _, newSel in
            if let last = newSel.first, app.previewFileID != last {
                app.previewFileID = last
            }
            if newSel.isEmpty { app.previewFileID = app.catalog.files.first?.id }
        }
        .background(KeyboardCatcher { key in
            switch key {
            case .delete:
                // Backspace removes the current selection from the list.
                app.removeFromList(app.selectedFileIDs)
                return true
            case .space:
                // Toggle mark on current selection.
                for id in app.selectedFileIDs { app.toggleMark(id) }
                return true
            case .markReference:
                // R-key: pin this row as the stabilization reference. Only
                // the first selected ID is used since it's a single-valued
                // marker.
                if let first = app.selectedFileIDs.first {
                    app.toggleReference(first)
                    return true
                }
                return false
            }
        })
    }

    @ViewBuilder
    private func statusLabel(_ status: FileEntry.Status) -> some View {
        switch status {
        case .idle:
            Text("—").foregroundColor(.secondary)
        case .queued:
            Label("queued", systemImage: "circle.dashed").foregroundColor(.secondary)
        case .processing(let p):
            HStack(spacing: 4) {
                ProgressView(value: p).progressViewStyle(.linear).frame(width: 60)
                Text("\(Int(p * 100))%").font(.caption2).foregroundColor(.secondary)
            }
        case .done:
            Label("done", systemImage: "checkmark.circle.fill").foregroundColor(.green)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red)
        }
    }

    private static func sizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func sharpnessString(_ v: Float) -> String {
        if !v.isFinite { return "—" }
        let av = abs(v)
        if av < 0.001 || av >= 1000 { return String(format: "%.2e", v) }
        return String(format: "%.4f", v)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    private static func dateString(_ date: Date?) -> String {
        guard let d = date else { return "—" }
        return dateFormatter.string(from: d)
    }
}

// MARK: - Mark checkbox

private struct MarkCheckbox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .foregroundColor(isOn ? .accentColor : .secondary)
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
    }
}

/// Gold-star toggle marking the stabilization reference frame.
/// Only one frame in the catalog can hold this at a time — the toggle
/// flips the marker on / off via AppModel.toggleReference.
private struct ReferenceStar: View {
    let isReference: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isReference ? "star.fill" : "star")
                .foregroundColor(isReference ? .yellow : .secondary.opacity(0.4))
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .help("Pin as Stabilize reference frame (R). Only one row can be the reference at a time.")
    }
}

/// Compact button for the meridian-flip toggle column. Renders nothing
/// visible when off — most files aren't post-meridian-flip and a row of
/// grey icons just adds noise. Off-state cells stay clickable so users
/// who know the column can still toggle on; the context menu remains the
/// primary way to enable flip on a non-flipped row.
private struct FlipCheckbox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isOn {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
            } else {
                // Invisible hit-target preserves row height + click-to-toggle.
                Color.clear.frame(width: 14, height: 14)
            }
        }
        .buttonStyle(.plain)
        .help(isOn
              ? "Marked as 180°-flipped (post-meridian). Click to clear."
              : "Click to mark this file as 180°-flipped (post-meridian).")
    }
}

// MARK: - Keyboard shortcuts catcher

enum ListKey { case delete, space, markReference }

struct KeyboardCatcher: NSViewRepresentable {
    let onKey: (ListKey) -> Bool

    func makeNSView(context: Context) -> KeyEventView {
        let view = KeyEventView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyEventView, context: Context) {
        nsView.onKey = onKey
    }
}

final class KeyEventView: NSView {
    var onKey: ((ListKey) -> Bool)?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let onKey = self.onKey else { return event }
                // Only consume if our window is key and the user isn't typing in a text field.
                guard self.window?.isKeyWindow == true else { return event }
                if NSApp.keyWindow?.firstResponder is NSTextView { return event }
                switch event.keyCode {
                case 51, 117:  // delete, forward-delete
                    return onKey(.delete) ? nil : event
                case 49:       // space
                    return onKey(.space) ? nil : event
                case 15:       // R — pin reference frame (no modifiers)
                    if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                        return onKey(.markReference) ? nil : event
                    }
                    return event
                default:
                    return event
                }
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
