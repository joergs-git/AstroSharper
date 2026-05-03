// Workflow guide shown via the toolbar "Howto" button. Floating sheet, no
// dependencies on app state — pure documentation.
import SwiftUI

struct HowToView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                BrandMark().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("How AstroSharper works")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppPalette.brandGradient)
                    Text("A four-step workflow from raw capture to a finished frame")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StepCard(
                        number: 1,
                        title: "Open your captures",
                        detail: "Press ⌘O or drag a folder onto the window. SharpCap / FireCapture .ser files plus 16-bit TIFF / PNG / JPEG are supported. The target picker chips at the top of the window light up for the auto-detected target (Sun / Moon / Jupiter / Saturn / Mars) — click any chip to override if the keyword detect missed."
                    )
                    StepCard(
                        number: 2,
                        title: "Flip AutoNuke ON, hit Run",
                        detail: "Open the Lucky Stack section, toggle AutoNuke. The engine then picks AP grid + patchHalf + multi-AP yes/no + auto-PSF σ + keep-% per data — all manual sliders grey out so there are no conflicting settings. Bake-in and Auto-tone stay independent (output-style choices). The Saved-file pipeline summary line under the toggles tells you exactly which paths will modify the saved TIFF."
                    )
                    StepCard(
                        number: 3,
                        title: "Sharpen + tone (in this order)",
                        detail: "The stacked TIFF lands in OUTPUTS automatically. Two labelled steps shape it from there: STEP 1: SHARPEN — pick ONE Deconvolution method (Wiener / Lucy-Richardson) AND/OR ONE Boost method (Unsharp / Wavelet à-trous). The picker prevents Wiener+LR or Unsharp+Wavelet (same-category stacking compounds artifacts). STEP 2: TONE CURVE & COLOUR — Auto White Balance + Atmospheric Chromatic Dispersion Correction for OSC, plus the histogram editor with click-to-add control points + B/C / saturation / shadows / highlights. (Colour & Levels was a separate STEP 2 until 2026-05-03; merged into Tone Curve since it had nothing else.)"
                    )
                    StepCard(
                        number: 4,
                        title: "Stabilize / Align sequences (optional)",
                        detail: "For multi-frame timelapses or comparing post-stack frames, use Run Stabilize / Align. The aligned frames live in MEMORY for fast scrubbing + blink-comparison; click Save All to push them to OUTPUTS. From there you can export TIFF / PNG / JPEG sequences, MP4 H.264, MOV ProRes 4444, or animated GIF."
                    )

                    Divider().padding(.vertical, 4)

                    Text("Why it's cool")
                        .font(.system(size: 14, weight: .heavy))

                    BulletRow(icon: "wand.and.stars", color: .orange,
                              text: "AutoNuke + AutoAP — content-aware AP geometry resolver beats hand-tuned presets on 6/6 BiggSky regression fixtures (Jupiter +9 / +18 / +26%, Moon +31%, Saturn +4%, Mars +1%).")
                    BulletRow(icon: "bolt.fill", color: .yellow,
                              text: "Native Metal pipeline — every shader runs on the GPU, every FFT on shared-FFTSetup vDSP across all cores. 4K Sun frame through unsharp mask in <10 ms on M2.")
                    BulletRow(icon: "scope", color: .purple,
                              text: "AutoPSF + Radial Fade Filter — measures Gaussian PSF σ from the planetary limb's LSF, then deconvolves aggressively without the dark Gibbs ring at the disc edge. As far as we know, original to AstroSharper.")
                    BulletRow(icon: "icloud.fill", color: .blue,
                              text: "iCloud-synced presets — every Lucky Stack setting (AutoNuke, denoise, drizzle, RFF, sigma-clip, bake-in, …) round-trips. Pick a preset on the laptop, apply it on the observatory iMac.")
                    BulletRow(icon: "square.stack.3d.up.fill", color: .pink,
                              text: "Lucky imaging done right: GPU-graded Laplacian variance + aligned reference build + gamma-shaped quality weighting + Multi-AP refinement + per-channel Bayer stacking for atmospheric chromatic dispersion.")
                    BulletRow(icon: "sparkles", color: .cyan,
                              text: "No dialog ping-pong: AutoNuke takes care of every parameter, output lands in the right folder, OUTPUTS section auto-flips so you can blink-compare against the source instantly.")

                    Divider().padding(.vertical, 4)

                    Text("Sharpening — what stacks well, what doesn't")
                        .font(.system(size: 14, weight: .heavy))
                    Text("Two distinct families of \"sharpening\". Stack one from each, never two of the same kind:")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    BulletRow(icon: "arrow.uturn.backward", color: .blue,
                              text: "DECONVOLUTION (Wiener / Lucy-Richardson) — inverts the blur using a PSF model. Recovers detail actually lost to atmosphere/optics.")
                    BulletRow(icon: "speaker.wave.3.fill", color: .purple,
                              text: "BOOST (Unsharp Mask / Wavelet à-trous) — amplifies existing high-frequency content. No PSF model; just contrast at a chosen scale.")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Combinations the picker enforces:")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.top, 4)
                        BulletRow(icon: "checkmark.circle.fill", color: .green,
                                  text: "Deconv + Boost (e.g. Wiener + Wavelet) — classic PixInsight / RegiStax pro pipeline. Different operations, different frequencies.")
                        BulletRow(icon: "checkmark.circle.fill", color: .green,
                                  text: "Just Boost (e.g. Off + Wavelet) — typical post-stack flow when Lucky Stack already baked deconv via --smart-auto.")
                        BulletRow(icon: "xmark.octagon.fill", color: .red,
                                  text: "Wiener + Lucy-Richardson — two deconvolutions stacked → severe ringing.")
                        BulletRow(icon: "xmark.octagon.fill", color: .red,
                                  text: "Unsharp Mask + Wavelet — two boosts stacked → compounded halos for the same gain you'd get tuning ONE harder.")
                    }
                    Text("Pre-gamma (linearisation) appears under the Deconvolution picker when a method is selected — match the gamma your capture program applied. Same role as WaveSharp's PreGamma loader knob.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)

                    Divider().padding(.vertical, 4)

                    Text("Preview navigation — standard macOS")
                        .font(.system(size: 14, weight: .heavy))
                    BulletRow(icon: "hand.draw", color: .blue,
                              text: "Drag = pan (closed-hand cursor). Pinch trackpad = zoom anchored to cursor. ⌥ + scroll wheel = zoom anchored to cursor.")
                    BulletRow(icon: "arrow.up.left.and.arrow.down.right", color: .green,
                              text: "Double-click = reset to fit + center.")
                    BulletRow(icon: "command", color: .purple,
                              text: "⌘+ zoom in 25% · ⌘- zoom out 25% · ⌘0 fit · ⌘1 1:1 · ⌘2 1:2 · ⌘3 1:4 · ⌘4 1:8.")
                    BulletRow(icon: "rectangle.split.2x1", color: .cyan,
                              text: "B = toggle Compare side panel. Top thumbnail = the current displayed file (no manipulations); bottom = the source SER's first frame (populated when Lucky Stack runs). Default 2× zoom, linked pinch + drag, double-click any thumb to reset.")

                    Divider().padding(.vertical, 4)

                    Text("Resetting & comparing")
                        .font(.system(size: 14, weight: .heavy))
                    BulletRow(icon: "arrow.counterclockwise.circle", color: .orange,
                              text: "Step 1 + Step 2 each have a 'Reset to defaults' button at the bottom of the section. Restores every control to factory and turns the section OFF — for when experimental tweaks drifted beyond recovery.")
                    BulletRow(icon: "scribble.variable", color: .yellow,
                              text: "After Stabilize, the HUD shows a Drift sparkline + peak shift in pixels — quick read on how much atmospheric motion the registration absorbed.")
                    BulletRow(icon: "scope", color: .pink,
                              text: "Median HFR (half-flux radius) joins the Jitter row in the HUD after a Calculate Video Quality scan. Lower = sharper / more concentrated PSF.")

                    Divider().padding(.vertical, 4)

                    Text("Privacy + community")
                        .font(.system(size: 14, weight: .heavy))
                    BulletRow(icon: "chart.bar.doc.horizontal.fill", color: .green,
                              text: "Anonymous telemetry sends a random per-machine UUID + AutoAP / AutoPSF parameters per stack so the engine's defaults can converge on the user fleet. No filenames, no hostnames, no personal data. Bottom-bar status icon toggles it off in one click.")
                    BulletRow(icon: "person.2.fill", color: .green,
                              text: "Community share asks once per stack whether to upload a small JPEG thumbnail + minimal metadata to the public feed. Per-stack opt-in stays granular; bottom-bar icon disables globally.")

                    Divider().padding(.vertical, 4)

                    Button {
                        NSWorkspace.shared.open(AppLinks.github.appendingPathComponent("wiki"))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "book.closed.fill")
                            Text("More info on my GitHub repo wiki — click here")
                                .underline()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                        .font(.system(size: 12))
                        .foregroundColor(AppPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .help(AppLinks.github.appendingPathComponent("wiki").absoluteString)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 640, height: 820)
    }
}

// MARK: - Step / bullet primitives

private struct StepCard: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(AppPalette.brandGradient)
                Text("\(number)")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct BulletRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
