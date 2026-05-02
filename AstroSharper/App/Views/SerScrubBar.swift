// Frame scrub bar for SER files. Sits under the preview when the active
// catalog entry is an SER, hidden otherwise. The slider drives
// `previewSerFrameIndex`; PreviewCoordinator throttles the loads so dragging
// stays smooth across thousands of frames.
import SwiftUI

struct SerScrubBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        // Guard against degenerate ranges: SwiftUI's Slider requires a
        // non-empty interval and a stride that fits in it. A 0…0 range with
        // step 1 throws an internal precondition. We render a disabled
        // single-step slider when the frame count isn't usable yet, and the
        // real one otherwise. The container in ContentView already gates on
        // `frameCount > 1`, but races during file-switch can briefly violate
        // that, so be defensive here too.
        let frameCount = max(1, app.previewSerFrameCount)
        let upper = Double(frameCount - 1)
        let safeUpper = max(1.0, upper)
        let usable = upper >= 1.0

        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundColor(.secondary)
                .font(.system(size: 11))

            // Play / pause auto-advances `previewSerFrameIndex` at the
            // configured rate, so the user can preview the captured stream
            // without manually scrubbing.
            Button {
                app.toggleSerPlayback()
            } label: {
                Image(systemName: app.serPlaybackActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .disabled(!usable)
            .keyboardShortcut("p", modifiers: [])
            .help("Play / Pause frames inside this SER (P)")

            Button {
                app.previewSerFrameIndex = max(0, app.previewSerFrameIndex - 1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(.plain)
            .disabled(!usable || app.previewSerFrameIndex <= 0)
            .keyboardShortcut(.leftArrow, modifiers: [])

            // PERFORMANCE: do NOT pass `step:` here. SwiftUI maps a
            // discrete-step Slider to NSSlider with numberOfTickMarks
            // == range/step + 1, and AppKit then renders every tick on
            // every layout pass via -[NSSliderTickMarks drawRect:].
            // For a 5000-frame SER that's 5000 tick marks redrawing on
            // every window resize tick — confirmed via `sample` profile
            // 2026-05-02 (resize was 161/4058 main-thread samples in
            // tick-mark draw alone). The Int conversion in `set:` is
            // sufficient to snap the value to whole frames; no visual
            // ticks are needed.
            Slider(
                value: Binding(
                    get: {
                        let v = Double(app.previewSerFrameIndex)
                        return min(max(0, v), safeUpper)
                    },
                    set: { app.previewSerFrameIndex = Int($0) }
                ),
                in: 0...safeUpper
            )
            .controlSize(.small)
            .disabled(!usable)

            Button {
                let last = max(0, app.previewSerFrameCount - 1)
                app.previewSerFrameIndex = min(last, app.previewSerFrameIndex + 1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(.plain)
            .disabled(!usable || app.previewSerFrameIndex >= app.previewSerFrameCount - 1)
            .keyboardShortcut(.rightArrow, modifiers: [])

            Text("Frame \(app.previewSerFrameIndex + 1)/\(app.previewSerFrameCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.underPageBackgroundColor))
    }
}
