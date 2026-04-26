// Section toggle bar: Inputs ▶ Memory ▶ Outputs flow, with the mini-player
// (◀ ⏯ ▶ + fps + magic-wand auto-detect toggle) clustered at the right.
// The player is section-aware:
//   - Memory tab + frames in RAM → drives memory transport.
//   - Inputs / Outputs → blink-cycles the row selection (or all rows).
import AppKit
import SwiftUI

struct SectionToggleBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 4) {
            SectionToggleButton(
                section: .inputs, title: "Inputs", icon: "tray.full.fill",
                count: app.inputsFileCount, isActive: app.displayedSection == .inputs,
                tooltip: "Source files you opened (⌘O / drag-and-drop). The Lucky-Stack and Apply actions read from here."
            ) { app.switchToSection(.inputs) }

            FlowArrow()

            SectionToggleButton(
                section: .memory, title: "Memory", icon: "memorychip.fill",
                count: app.memoryFileCount, isActive: app.displayedSection == .memory,
                tooltip: "Aligned frames currently in RAM. Scrub with the player; click Save All when satisfied."
            ) { app.switchToSection(.memory) }

            FlowArrow()

            SectionToggleButton(
                section: .outputs, title: "Outputs", icon: "tray.and.arrow.down.fill",
                count: app.outputsFileCount, isActive: app.displayedSection == .outputs,
                tooltip: "Files this app has written. Marked / selected files here can be re-processed via Apply-to-Selection."
            ) { app.switchToSection(.outputs) }

            Spacer()

            // Memory tab actions.
            if app.displayedSection == .memory && app.memoryFileCount > 0 {
                Button { app.saveMemoryFramesToDisk() } label: {
                    Label("Save All to Disk", systemImage: "tray.and.arrow.down")
                }
                .controlSize(.small)
                .help("Write all in-memory aligned frames to <output>/<ops>/ and switch to OUTPUTS.")
            }

            // Mini player — tight ◀ ⏯ ▶ cluster.
            Divider().frame(height: 14)
            InlinePlayer()

            Divider().frame(height: 14)

            // Outputs reveal helpers, only relevant on OUTPUTS.
            if app.displayedSection == .outputs {
                Button {
                    refreshOutputs()
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("Re-scan the output folder.")

                if let url = app.outputsRootURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help("Reveal in Finder.")
                }
            }

            Toggle(isOn: $app.autoDetectPresetOnOpen) {
                Image(systemName: "wand.and.stars")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Smart preset auto-detection: opening a folder named e.g. 'Sun', 'Jupiter' or 'Moon' picks the matching built-in preset for you.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private func refreshOutputs() {
        guard let root = app.outputsRootURL else { return }
        app.catalog.load(from: root)
        app.previewFileID = app.catalog.files.first?.id
    }
}

// MARK: - Inline player (◀ ⏯ ▶ + fps)

private struct InlinePlayer: View {
    @EnvironmentObject private var app: AppModel

    private var isMemoryMode: Bool {
        app.displayedSection == .memory && app.playback.hasFrames
    }
    private var isPlaying: Bool { isMemoryMode ? app.playback.isPlaying : app.blinkActive }
    private var fps: Double { isMemoryMode ? app.playback.fps : app.blinkRate }
    private var positionLabel: String {
        if isMemoryMode {
            return "\(app.playback.currentIndex + 1)/\(app.playback.frames.count)"
        }
        let cands = candidates
        guard !cands.isEmpty else { return "—" }
        let cur = cands.firstIndex(of: app.previewFileID ?? .init()).map { $0 + 1 } ?? 1
        return "\(cur)/\(cands.count)"
    }
    private var candidates: [FileEntry.ID] {
        if !app.selectedFileIDs.isEmpty {
            return app.catalog.files.map(\.id).filter { app.selectedFileIDs.contains($0) }
        }
        return app.catalog.files.map(\.id)
    }

    var body: some View {
        HStack(spacing: 2) {
            Button { step(by: -1) } label: { Image(systemName: "backward.frame.fill") }
                .buttonStyle(.plain)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous frame (←)")

            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("p", modifiers: [])
            .help(isMemoryMode
                  ? "Play / Pause memory frames (P)"
                  : "Blink-cycle through selected files (P)")

            Button { step(by: 1) } label: { Image(systemName: "forward.frame.fill") }
                .buttonStyle(.plain)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next frame (→)")

            Text(positionLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 56, alignment: .leading)
                .padding(.leading, 4)

            Picker("", selection: Binding(
                get: { fps }, set: { setFPS($0) }
            )) {
                ForEach([1.0, 3.0, 6.0, 12.0, 18.0, 24.0, 30.0, 60.0], id: \.self) { v in
                    Text("\(Int(v)) fps").tag(v)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 80)
            .labelsHidden()
            .help("Cycle / playback rate. Also used for video / GIF export.")
        }
    }

    private func togglePlay() {
        if isMemoryMode { app.togglePlay() } else { app.toggleBlink() }
    }
    private func step(by delta: Int) {
        if isMemoryMode { app.stepFrame(by: delta); return }
        let cands = candidates
        guard !cands.isEmpty else { return }
        let cur = cands.firstIndex(of: app.previewFileID ?? .init()) ?? 0
        let next = ((cur + delta) % cands.count + cands.count) % cands.count
        app.previewFileID = cands[next]
    }
    private func setFPS(_ v: Double) {
        if isMemoryMode { app.setFPS(v) } else { app.setBlinkRate(v) }
    }
}

// MARK: - Section toggle button

private struct FlowArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(AppPalette.accent)
            .padding(.horizontal, 2)
    }
}

private struct SectionToggleButton: View {
    let section: CatalogSection
    let title: String
    let icon: String
    let count: Int
    let isActive: Bool
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                Text("(\(count))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isActive ? AppPalette.accent : Color.secondary.opacity(0.25),
                        lineWidth: isActive ? 2.0 : 0.5
                    )
            )
            .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
