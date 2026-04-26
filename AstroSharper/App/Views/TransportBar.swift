// Playback transport for in-memory aligned sequences.
// Sits below the preview when there are loaded frames.
import SwiftUI

struct TransportBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                app.stepFrame(by: -1)
            } label: { Image(systemName: "backward.frame.fill") }
            .buttonStyle(.plain)
            .help("Previous frame (←)")
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button {
                app.togglePlay()
            } label: {
                Image(systemName: app.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("p", modifiers: [])
            .help("Play / Pause (P)")

            Button {
                app.stepFrame(by: 1)
            } label: { Image(systemName: "forward.frame.fill") }
            .buttonStyle(.plain)
            .help("Next frame (→)")
            .keyboardShortcut(.rightArrow, modifiers: [])

            Slider(
                value: Binding(
                    get: {
                        let upper = max(1.0, Double(max(0, app.playback.frames.count - 1)))
                        return min(max(0, Double(app.playback.currentIndex)), upper)
                    },
                    set: { app.seekTo(index: Int($0)) }
                ),
                in: 0...max(1.0, Double(max(0, app.playback.frames.count - 1)))
            )
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .disabled(app.playback.frames.count < 2)

            Text("\(app.playback.currentIndex + 1)/\(app.playback.frames.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)

            Picker("", selection: Binding(
                get: { app.playback.fps },
                set: { app.setFPS($0) }
            )) {
                ForEach([1.0, 3.0, 6.0, 12.0, 18.0, 24.0, 30.0, 60.0], id: \.self) { v in
                    Text("\(Int(v)) fps").tag(v)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 80)
            .labelsHidden()

            Toggle("Loop", isOn: $app.playback.loop)
                .toggleStyle(.button)
                .controlSize(.small)

            Divider().frame(height: 14)

            Menu {
                ForEach(ExportFormat.allCases) { fmt in
                    Button(fmt.rawValue) { app.exportPlayback(format: fmt) }
                }
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .frame(width: 110)

            Button {
                app.clearPlayback()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .help("Clear playback (drops in-memory aligned frames)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.underPageBackgroundColor))
    }
}
