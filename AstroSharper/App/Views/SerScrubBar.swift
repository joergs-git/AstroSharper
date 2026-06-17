// Frame scrub bar for SER files. Sits under the preview when the active
// catalog entry is an SER, hidden otherwise. The slider drives
// `previewSerFrameIndex`; PreviewCoordinator throttles the loads so dragging
// stays smooth across thousands of frames.
import SwiftUI

struct SerScrubBar: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow

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
            // Hit area 60 px (visual track + knob stay 4/13 px centred).
            // Doubled per user feedback — drag/click works anywhere in
            // the row band, no need to pixel-hunt the 13-px knob.
            .frame(height: 60)
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

            // Frame counter on top + a wall-clock playback time below.
            // Same 30-fps display convention as the trim-range label,
            // so both readouts agree: a 648-frame trim displayed as
            // "21.6 s" in the trim label maps to "0:21" here.
            VStack(alignment: .trailing, spacing: 1) {
                Text("Frame \(app.previewSerFrameIndex + 1)/\(app.previewSerFrameCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(playbackTimeLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.75))
            }
            .frame(width: 130, alignment: .trailing)

            // Trim controls: set start / end to the current scrub
            // position, reset both. The visual range overlay on the
            // ScrubTrack updates live. Compact buttons; the bigger
            // export panel (frame count, fps, file size, output
            // format) opens elsewhere in a follow-up step.
            Button {
                let n = app.previewSerFrameIndex
                // If end is already set lower than the new start, reset
                // end so we don't end up with an inverted range.
                if let e = app.serTrimEnd, e <= n { app.serTrimEnd = nil }
                app.serTrimStart = n
                persistTrim()
            } label: {
                Image(systemName: "arrowtriangle.right.square")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .disabled(!usable)
            .help("Trim — set range START to current frame.")
            Button {
                let n = app.previewSerFrameIndex
                if let s = app.serTrimStart, s >= n { app.serTrimStart = nil }
                app.serTrimEnd = n
                persistTrim()
            } label: {
                Image(systemName: "arrowtriangle.left.square")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .disabled(!usable)
            .help("Trim — set range END to current frame.")
            if app.serTrimStart != nil || app.serTrimEnd != nil {
                Button {
                    app.serTrimStart = nil
                    app.serTrimEnd = nil
                    persistTrim()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.purple)
                }
                .buttonStyle(.plain)
                .help("Clear the trim range.")
                Text(trimRangeLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.purple)
            }

            // Export panel — opens its own draggable NSWindow (not a
            // popover) so the user can park it off-screen-side and
            // still see the live crop overlay on the preview.
            Button {
                openWindow(id: "ser-export")
            } label: {
                Image(systemName: "square.on.square")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(!usable)
            .help("Open the Trim · Crop · Export window — save the selected range as a shorter .ser or animated GIF. The window is draggable so it won't cover the preview.")

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

            // Instant-scrub proxy (opt-in). Builds a cached low-res proxy
            // of the whole SER so scrubbing big (8-20 GB) files is instant
            // instead of laggy. READ-ONLY — never affects trim / export.
            if app.scrubProxyBuilding {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("\(Int(app.scrubProxyProgress * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(width: 64)
                .help("Building the scrub proxy… scrubbing will be instant once done. Cached for next time.")
            } else if app.scrubProxyAvailable {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.purple)
                    .help("Instant scrub active — a cached low-res proxy covers this SER. Scrubbing reads from it (no lag), full-res frame loads on release.")
            } else {
                Button {
                    app.buildScrubProxy()
                } label: {
                    Image(systemName: "bolt")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .disabled(!usable)
                .help("Build a cached low-res scrub proxy for this SER — makes scrubbing big files instant. Runs once in the background; reused on later opens. Doesn't touch trim markers or export.")
            }

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

    /// Current playback time vs total, formatted M:SS (or H:MM:SS
    /// for > 1 h captures). Uses the SER's REAL capture FPS when
    /// the timestamp trailer is present (FireCapture / SharpCap /
    /// ASIStudio all write it); falls back to 30 fps otherwise. The
    /// fps source is reflected with a "~" prefix on the estimated
    /// case so the user can tell which is which.
    private var playbackTimeLabel: String {
        let fps = displayFPS
        let cur = Double(app.previewSerFrameIndex) / fps
        let tot = Double(max(0, app.previewSerFrameCount - 1)) / fps
        let prefix = app.previewSerCapturedFPS == nil ? "~" : ""
        return "\(prefix)\(Self.formatTime(cur)) / \(Self.formatTime(tot))"
    }

    /// Single source of truth for the displayed frame rate. Captured
    /// FPS from the SER trailer wins; 30 fps is the conservative
    /// fallback. Used by both the playback time and the trim label.
    var displayFPS: Double {
        app.previewSerCapturedFPS ?? 30.0
    }

    /// Save the current trim pair into the per-URL memory so a
    /// round-trip through the export-preview window (or any other
    /// file switch) restores it on re-open of the same SER.
    private func persistTrim() {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }) else { return }
        app.rememberedSerTrimRanges[entry.url] = (app.serTrimStart, app.serTrimEnd)
    }

    static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Compact human label for the live trim range, e.g.
    /// "245-892 (648f, 21.6s @ 30 fps)". Surfaces frame count + run
    /// length at the current SER frame rate so the user sees how
    /// much they've selected for export.
    private var trimRangeLabel: String {
        let total = app.previewSerFrameCount
        guard total > 0 else { return "" }
        let s = app.serTrimStart ?? 0
        let e = app.serTrimEnd ?? max(0, total - 1)
        let n = max(0, e - s + 1)
        // Real capture FPS when available, else 30 fps fallback.
        let secs = Double(n) / displayFPS
        return String(format: "%d-%d (%df, %.1fs)", s, e, n, secs)
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
    @EnvironmentObject private var app: AppModel
    @Binding var frameIndex: Int
    let frameCount: Int

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let upper = max(1, frameCount - 1)
            let frac = Double(min(max(0, frameIndex), upper)) / Double(upper)
            let knobX = CGFloat(frac) * w

            // Trim marker positions (nil = no trim set on that side)
            let trimStartX: CGFloat? = app.serTrimStart.map {
                CGFloat(min(max(0, $0), upper)) / CGFloat(upper) * w
            }
            let trimEndX: CGFloat? = app.serTrimEnd.map {
                CGFloat(min(max(0, $0), upper)) / CGFloat(upper) * w
            }

            // EVERY visual child carries `.allowsHitTesting(false)` —
            // otherwise SwiftUI's per-child hit testing routes a click
            // landing on the white Circle (knob) to the Circle itself,
            // and because the Circle has no gesture the click is just
            // swallowed. Result before this fix: clicks JUST OUTSIDE
            // the knob worked, clicks DIRECTLY on the knob (the
            // obvious target!) did nothing. With the shapes opting
            // out of hit testing, the ZStack's contentShape rectangle
            // is the only thing the gesture sees — so the whole 60-px
            // row reacts identically whether you hit the knob or not.
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)
                    .allowsHitTesting(false)
                if let s = trimStartX, let e = trimEndX, e > s {
                    Capsule()
                        .fill(Color.purple.opacity(0.35))
                        .frame(width: e - s, height: 8)
                        .offset(x: s)
                        .allowsHitTesting(false)
                }
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: knobX, height: 4)
                    .allowsHitTesting(false)
                if let s = trimStartX {
                    Rectangle()
                        .fill(Color.purple)
                        .frame(width: 2, height: 18)
                        .offset(x: s - 1)
                        .allowsHitTesting(false)
                }
                if let e = trimEndX {
                    Rectangle()
                        .fill(Color.purple)
                        .frame(width: 2, height: 18)
                        .offset(x: e - 1)
                        .allowsHitTesting(false)
                }
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: knobX - 6.5)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Mark dragging on the first event so PreviewView's
                        // observer can switch to the cheap nearest-cached
                        // path instead of decoding every position.
                        if !app.isSerScrubbing { app.isSerScrubbing = true }
                        let f = min(max(0, value.location.x / w), 1)
                        let idx = Int((Double(f) * Double(upper)).rounded())
                        if idx != frameIndex { frameIndex = idx }
                    }
                    .onEnded { _ in
                        // Release: drop drag-state. The observer in
                        // PreviewView will then trigger a full-res
                        // decode of the landed frame so the final
                        // image is exact, not a snapped neighbour.
                        app.isSerScrubbing = false
                    }
            )
        }
    }
}
