// Root layout: Path-Bar | Toolbar | HSplit( SettingsPanel | VSplit(Preview, FileList) ) | StatusBar
// Mirrors the proven AstroBlinkV2 layout pattern.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader()
            Divider()
            ToolbarView()
            Divider()
            mainArea
            Divider()
            StatusBar()
        }
        .background(Color(NSColor.windowBackgroundColor))
        .tint(AppPalette.accent)
        .onDrop(of: [.fileURL], delegate: FolderDropDelegate(app: app))
    }

    private var mainArea: some View {
        HSplitView {
            SettingsPanel()
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)

            VSplitView {
                VStack(spacing: 0) {
                    PreviewView()
                        .frame(minHeight: 240)
                    if app.previewSerFrameCount > 1 {
                        Divider()
                        SerScrubBar()
                    }
                    if app.playback.hasFrames {
                        Divider()
                        TransportBar()
                    }
                }
                VStack(spacing: 0) {
                    SectionToggleBar()
                    FileListView()
                }
                .frame(minHeight: 180, idealHeight: 280)
            }
            .frame(minWidth: 500)
        }
    }
}

// MARK: - Path bar

private struct PathBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if let url = app.catalog.rootURL {
                Text(url.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            } else {
                Text("No folder opened — drag a folder here or press ⌘O")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                app.promptOpenFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .help("Open folder (⌘O)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.underPageBackgroundColor))
    }
}

// MARK: - Toolbar
//
// Single row, no redundant section-enable toggles (those live in the
// settings panel section headers themselves) and no separate path bar
// (its content moved up into this row so the chrome shrinks by 24 pt).

private struct ToolbarView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            // "Apply ALL Stuff" — single hero entry point. Picks lucky-stack,
            // memory in-place, or file-batch depending on context (see
            // AppModel.applyAllStuff).
            Button { app.applyAllStuff() } label: {
                Label("Apply ALL Stuff", systemImage: "wand.and.stars")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(AppPalette.accent)
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!app.canApply)
            .help("Run every enabled operation on the current selection (⇧⌘A). Lucky Stack short-circuits the chain because it consumes whole SER files.")

            Divider().frame(height: 18)

            PresetMenu()

            Divider().frame(height: 18)

            // Folder context. Replaces the old grey path bar — the open
            // button is the leading icon, the path follows.
            Button { app.promptOpenFolder() } label: {
                Label("Open", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open folder or files (⌘O)")

            if app.catalog.rootURL == nil {
                Text("No folder opened — drag a folder here or press ⌘O")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button { openWindow(id: "howto") } label: {
                Label("Howto", systemImage: "questionmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open the workflow guide in a movable, non-blocking window — keep it on screen while you work.")

            // Before / After compare (B) — single, prominent.
            Toggle(isOn: $app.showAfter) {
                Label(app.showAfter ? "After" : "Before", systemImage: app.showAfter ? "eye.fill" : "eye.slash")
            }
            .toggleStyle(.button)
            .keyboardShortcut("b", modifiers: [])
            .help("Toggle Before / After (B)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Drop

private struct FolderDropDelegate: DropDelegate {
    let app: AppModel

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    app.openFolder(url)
                } else {
                    // Dropped a file — use its parent folder.
                    app.openFolder(url.deletingLastPathComponent())
                }
            }
        }
        return true
    }
}
