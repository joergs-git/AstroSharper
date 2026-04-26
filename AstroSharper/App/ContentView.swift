// Root layout: Path-Bar | Toolbar | HSplit( SettingsPanel | VSplit(Preview, FileList) ) | StatusBar
// Mirrors the proven AstroBlinkV2 layout pattern.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PathBar()
            Divider()
            ToolbarView()
            Divider()
            mainArea
            Divider()
            StatusBar()
        }
        .background(Color(NSColor.windowBackgroundColor))
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
                .frame(minHeight: 160, idealHeight: 260)
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

private struct ToolbarView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 12) {
            PresetMenu()

            Divider().frame(height: 18)

            Toggle("Sharpen", isOn: $app.sharpen.enabled)
                .toggleStyle(.button)
            Toggle("Stabilize", isOn: $app.stabilize.enabled)
                .toggleStyle(.button)
            Toggle("Tone", isOn: $app.toneCurve.enabled)
                .toggleStyle(.button)

            Divider().frame(height: 18)

            Button {
                app.applyToSelection()
            } label: {
                Label("Apply to Selection", systemImage: "play.fill")
            }
            .disabled(!app.canApply)
            .help("Apply current settings to all selected files (⌘R)")

            Spacer()

            // Blink player — cycles previewFileID through the current
            // selection (or all rows if nothing selected) at configurable
            // rate. AstroTriage-style A/B blink for picking the best frame.
            HStack(spacing: 4) {
                Button {
                    app.toggleBlink()
                } label: {
                    Label(app.blinkActive ? "Stop Blink" : "Blink", systemImage: app.blinkActive ? "stop.fill" : "rays")
                }
                .help("Blink-cycle through the selected (or all) files. Useful for spotting the sharpest frame in a series.")
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("l", modifiers: [])

                if app.blinkActive {
                    Picker("", selection: Binding(
                        get: { app.blinkRate },
                        set: { app.setBlinkRate($0) }
                    )) {
                        ForEach([1.0, 2.0, 4.0, 8.0, 16.0], id: \.self) { v in
                            Text("\(Int(v))/s").tag(v)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 70)
                    .labelsHidden()
                }
            }

            Divider().frame(height: 18)

            // Before/After compare toggle (hold B or click).
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
