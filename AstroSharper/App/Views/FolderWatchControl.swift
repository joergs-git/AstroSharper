// Folder-watch + auto-stack control (LSW 5.2 "realtime" parity).
//
// A self-contained sub-view kept in its own file so the Lucky-Stack
// section's @ViewBuilder closure stays well under the type-inference
// budget (see tasks/lessons.md — adding siblings to that already-large
// body topples the resolver). The whole control reduces to ONE line at
// the call site.
//
// State lives on AppModel (`folderWatchActive`, `watchedFolderURL`,
// `folderWatchStatus`); this view is pure presentation + the folder
// picker. Watching is session-only — there is no "remember on launch"
// toggle here on purpose; the user explicitly arms it each session.
import AppKit
import SwiftUI

struct FolderWatchControl: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: app.folderWatchActive ? "eye.fill" : "eye")
                    .foregroundColor(app.folderWatchActive ? .green : .secondary)
                    .font(.system(size: 12))
                Text("Auto-stack folder watch")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if app.folderWatchActive {
                    Button(role: .destructive) {
                        app.stopFolderWatch()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.small)
                } else {
                    Button {
                        chooseFolderAndStart()
                    } label: {
                        Label("Watch folder…", systemImage: "play.fill")
                    }
                    .controlSize(.small)
                }
            }

            if app.folderWatchActive {
                Text(app.folderWatchStatus)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                Text("Watches a capture folder and auto-stacks each new .ser as it finishes writing. Existing files are left alone. Target is auto-detected from the filename, falling back to the active preset.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(app.folderWatchActive
                      ? Color.green.opacity(0.10)
                      : Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(app.folderWatchActive ? Color.green.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.18), value: app.folderWatchActive)
        .help("Realtime auto-stack: point this at your SharpCap / FireCapture output folder and AstroSharper stacks each new SER the moment its capture finishes — leave it running overnight and wake up to stacked TIFFs.")
    }

    private func chooseFolderAndStart() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Watch this folder"
        panel.message = "Choose the capture folder to watch for new SER files."
        if let def = app.watchPickerDefaultURL {
            panel.directoryURL = def
        }
        if panel.runModal() == .OK, let url = panel.url {
            app.startFolderWatch(url: url)
        }
    }
}
