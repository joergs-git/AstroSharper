// Multi-column file list with checkbox-based marking, keyboard shortcuts,
// thumbnails, processing status and a context menu for bulk mark/remove
// operations.
//
// Selection (⌘-click / Shift-click) drives the preview target. Marking
// (checkbox / context menu) drives batch processing. Apply-to-Selection uses
// marks if any, otherwise current selection.
import AppKit
import SwiftUI

struct FileListView: View {
    @EnvironmentObject private var app: AppModel
    /// Sort state — clicking any column header toggles ascending/descending
    /// order on that key, AstroTriage style. Persists per session.
    @State private var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\.name, order: .forward)
    ]

    private var sortedFiles: [FileEntry] {
        app.catalog.files.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedFiles, selection: $app.selectedFileIDs, sortOrder: $sortOrder) {
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

/// Compact button for the meridian-flip toggle column.
private struct FlipCheckbox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                .foregroundColor(isOn ? .orange : .secondary)
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .help("Mark this file as 180°-flipped (post-meridian). Rotated in memory before all processing.")
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
