// Folder-watch + auto-stack control (LSW 5.2 "realtime" parity).
//
// Lives in the top toolbar next to Open rather than in the Lucky Stack
// section: the whole point of folder-watch is to arm it on an EMPTY
// capture folder before the session starts, and the Lucky Stack section
// is SER-gated (disabled when no files are present) — exactly the moment
// the user needs the control. So this is a compact toolbar button + a
// shared NSOpenPanel picker.
//
// State lives on AppModel (`folderWatchActive`, `watchedFolderURL`,
// `folderWatchStatus`). Watching is session-only — no "remember on
// launch" toggle on purpose; the user explicitly arms it each session.
import AppKit
import SwiftUI

// MARK: - Compact toolbar control

/// Compact watch control for the top toolbar (next to Open). Lives here
/// rather than in the Lucky Stack section because the whole point of
/// folder-watch is to arm it on an EMPTY capture folder — and the Lucky
/// Stack section disables itself when there are no SER files yet, which
/// is exactly the moment the user wants to start watching. Toolbar
/// placement keeps it reachable regardless of catalog state.
struct FolderWatchToolbarButton: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if app.folderWatchActive {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 11))
                Text(app.watchedFolderURL?.lastPathComponent ?? "watching")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120)
                if app.folderWatchStackedCount > 0 {
                    Text("\(app.folderWatchStackedCount)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.8)))
                }
                Button {
                    app.stopFolderWatch()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop watching")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.green.opacity(0.15)))
            .overlay(Capsule().stroke(Color.green.opacity(0.4), lineWidth: 1))
            .help(app.folderWatchStatus)
        } else {
            Button {
                FolderWatchPicker.chooseAndStart(app: app)
            } label: {
                Label("Watch", systemImage: "eye")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Auto-stack folder watch: point at a capture folder and AstroSharper stacks each new SER as it finishes writing. Works on an empty folder — arm it before the session starts.")
        }
    }
}

// MARK: - Shared picker

/// Folder picker shared by the section box + the toolbar button so the
/// NSOpenPanel config stays in one place.
enum FolderWatchPicker {
    @MainActor
    static func chooseAndStart(app: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Watch this folder"
        panel.message = "Choose the capture folder to watch for new SER files."
        if let def = app.watchPickerDefaultURL {
            panel.directoryURL = def
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // One-time community-share decision for the whole watch session,
        // so the per-stack prompt never interrupts the unattended flow.
        // Skipped entirely when the user has globally disabled community
        // share (bottom-bar toggle) — then it's simply off, no question.
        var autoShare = false
        if !CommunityShare.userDisabled {
            let alert = NSAlert()
            alert.messageText = "Auto-share during this watch session?"
            alert.informativeText = "Folder watch stacks unattended. Choose once whether each stacked thumbnail is uploaded to the community feed — you won't be asked per file."
            alert.addButton(withTitle: "Auto-share")   // .alertFirstButtonReturn
            alert.addButton(withTitle: "Don't share")   // .alertSecondButtonReturn
            autoShare = (alert.runModal() == .alertFirstButtonReturn)
        }
        app.startFolderWatch(url: url, autoShare: autoShare)
    }
}
