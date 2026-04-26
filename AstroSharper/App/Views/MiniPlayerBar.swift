// Always-visible row above the file list with play + fps. Acts on whatever
// the active section is:
//   - Memory: drives the in-memory transport (same source as TransportBar).
//   - Inputs / Outputs: cycles previewFileID through the row selection
//     (or every row if nothing's selected) — i.e. the AstroTriage-style
//     blink-compare for picking the sharpest frame in a series.
import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("p", modifiers: [])
            .help(playTooltip)

            Button {
                step(by: -1)
            } label: { Image(systemName: "backward.frame.fill") }
            .buttonStyle(.plain)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button {
                step(by: 1)
            } label: { Image(systemName: "forward.frame.fill") }
            .buttonStyle(.plain)
            .keyboardShortcut(.rightArrow, modifiers: [])

            Text(positionLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 80, alignment: .leading)

            Spacer()

            Picker("", selection: Binding(
                get: { fps },
                set: { setFPS($0) }
            )) {
                ForEach([1.0, 3.0, 6.0, 12.0, 18.0, 24.0, 30.0, 60.0], id: \.self) { v in
                    Text("\(Int(v)) fps").tag(v)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 90)
            .labelsHidden()
            .help("Cycle / playback rate (also used by video / GIF export).")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    // MARK: - Mode-aware accessors
    //
    // Three priorities for the play / step / fps controls:
    //   1. Memory mode wins when the in-memory transport has frames.
    //   2. SER in-file playback when the previewed file is a multi-frame
    //      SER — play the captured stream instead of cycling files.
    //   3. Otherwise blink-cycle through the file selection (AstroTriage).

    private var isMemoryMode: Bool {
        app.displayedSection == .memory && app.playback.hasFrames
    }
    private var isSerFileMode: Bool {
        !isMemoryMode && app.canPlaySerFrames
    }
    private var isPlaying: Bool {
        if isMemoryMode { return app.playback.isPlaying }
        if isSerFileMode { return app.serPlaybackActive }
        return app.blinkActive
    }
    private var fps: Double {
        isMemoryMode ? app.playback.fps : app.blinkRate
    }
    private var positionLabel: String {
        if isMemoryMode {
            return "\(app.playback.currentIndex + 1)/\(app.playback.frames.count)"
        }
        if isSerFileMode {
            return "\(app.previewSerFrameIndex + 1)/\(app.previewSerFrameCount)"
        }
        let total = candidates.count
        guard total > 0 else { return "—" }
        let cur = candidates.firstIndex(of: app.previewFileID ?? .init()).map { $0 + 1 } ?? 1
        return "\(cur)/\(total)"
    }
    private var playTooltip: String {
        if isMemoryMode { return "Play / Pause memory frames (P)" }
        if isSerFileMode { return "Play / Pause frames inside this SER (P)" }
        return "Blink-cycle through selected files (or all files if none selected) (P)"
    }
    private var candidates: [FileEntry.ID] {
        if !app.selectedFileIDs.isEmpty {
            return app.catalog.files.map(\.id).filter { app.selectedFileIDs.contains($0) }
        }
        return app.catalog.files.map(\.id)
    }

    private func togglePlay() {
        if isMemoryMode { app.togglePlay(); return }
        if isSerFileMode { app.toggleSerPlayback(); return }
        app.toggleBlink()
    }
    private func step(by delta: Int) {
        if isMemoryMode { app.stepFrame(by: delta); return }
        if isSerFileMode { app.stepSerFrame(by: delta); return }
        let cands = candidates
        guard cands.count >= 1 else { return }
        let cur = cands.firstIndex(of: app.previewFileID ?? .init()) ?? 0
        let next = ((cur + delta) % cands.count + cands.count) % cands.count
        app.previewFileID = cands[next]
    }
    private func setFPS(_ v: Double) {
        if isMemoryMode { app.setFPS(v) } else { app.setBlinkRate(v) }
    }
}
