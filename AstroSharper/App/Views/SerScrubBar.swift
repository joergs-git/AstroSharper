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

            // Custom drag-gesture scrubber instead of SwiftUI `Slider`.
            // A SwiftUI Slider wraps NSSlider, whose drag runs a modal
            // `-[NSSliderCell trackMouse:]` loop in NSEventTrackingRunLoop-
            // Mode. CoreAnimation does NOT commit / present the preview's
            // CAMetalLayer during that modal loop, so scrubbed frames
            // stayed frozen on screen until release — no amount of
            // synchronous redraw helped. A `DragGesture` runs through
            // SwiftUI's normal event path (no modal loop), so the
            // @Published index updates AND the Metal preview presents
            // live while dragging. (Bonus: also sidesteps the 5000-tick-
            // mark layout cost the old Slider had.)
            ScrubTrack(
                frameIndex: $app.previewSerFrameIndex,
                frameCount: frameCount
            )
            // Hit area 40 px (visual track + knob stay 4/13 px centred);
            // generous click forgiveness — user no longer has to pixel-
            // hunt the 13-px knob to start a drag, the entire row height
            // around the track is now active.
            .frame(height: 40)
            .disabled(!usable)
            .opacity(usable ? 1 : 0.4)

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

            // Export-current-frame → TIFF in outputs folder.
            // Pinned use case: solar Hα prominence captures where
            // stacking softens wisp morphology — scrub to the sharpest
            // single frame, click here to keep it.
            Button {
                app.exportCurrentSerFrame()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(!usable)
            .help("Save the currently-displayed frame as a 16-bit TIFF in the outputs folder. Use this when stacking softens a feature you want to preserve crisply — scrub to the sharpest single frame and click to keep it. Filename: <ser_basename>_frame_<NNNN>.tif (no-overwrite numbered).")

            // Playback speed picker — multiplies the base blink rate.
            // Live: changing while playing re-arms the timer at the new
            // interval, no need to stop / restart.
            Picker("", selection: $app.serPlaybackSpeedMultiplier) {
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("4×").tag(4.0)
                Text("8×").tag(8.0)
                Text("16×").tag(16.0)
            }
            .pickerStyle(.menu)
            .frame(width: 64)
            .controlSize(.small)
            .disabled(!usable)
            .help("Playback speed multiplier (1× = base blink rate). Picks the timer interval — decode/upload caps the effective speed around 125 fps.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.underPageBackgroundColor))
    }
}

/// Drag-gesture frame scrubber. Maps the cursor's x-position along the
/// track to a frame index and writes it to the binding continuously
/// during the drag. Uses `DragGesture(minimumDistance: 0)` so a single
/// click also seeks. Crucially this runs through SwiftUI's event path
/// rather than NSSlider's modal `trackMouse:` loop, so the Metal preview
/// presents new frames LIVE while dragging (the modal loop blocks
/// CoreAnimation commits, freezing the preview until release).
private struct ScrubTrack: View {
    @Binding var frameIndex: Int
    let frameCount: Int

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let upper = max(1, frameCount - 1)
            let frac = Double(min(max(0, frameIndex), upper)) / Double(upper)
            let knobX = CGFloat(frac) * w

            ZStack(alignment: .leading) {
                // Track groove.
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)
                // Filled portion up to the knob.
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: knobX, height: 4)
                // Knob.
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: knobX - 6.5)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let f = min(max(0, value.location.x / w), 1)
                        let idx = Int((Double(f) * Double(upper)).rounded())
                        if idx != frameIndex { frameIndex = idx }
                    }
            )
        }
    }
}
