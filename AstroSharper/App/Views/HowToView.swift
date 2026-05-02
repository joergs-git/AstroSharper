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
                        detail: "Press ⌘O or drag a folder onto the window. SharpCap / FireCapture .ser files plus 16-bit TIFF / PNG / JPEG are supported. AstroSharper auto-detects Sun, Moon, Jupiter, Saturn or Mars from filenames and applies the matching built-in preset."
                    )
                    StepCard(
                        number: 2,
                        title: "Lucky-Stack the best frames",
                        detail: "Mark or select the .ser files you want, set Keep best (15–25% is the sweet spot for sharp planetary, 30–50% for noisy solar full-disk), and hit Run Lucky Stack. Scientific mode plus Multi-AP gives the best detail for wide-field; Lightspeed mode is for quick previews and Apple-Silicon-fast results."
                    )
                    StepCard(
                        number: 3,
                        title: "Sharpen + tone (in this order)",
                        detail: "The output TIFF lands in OUTPUTS automatically, then three labelled steps shape it: STEP 1: SHARPEN — pick ONE Deconvolution method (Wiener / Lucy-Richardson) AND/OR ONE Boost method (Unsharp / Wavelet à-trous). Pro pipeline pairs one deconv + one boost; the picker prevents Wiener+LR or Unsharp+Wavelet (same-category stacking compounds artifacts). STEP 2: COLOUR & LEVELS — Auto White Balance + Atmospheric Chromatic Dispersion Correction for OSC. STEP 3: TONE CURVE — histogram editor with click-to-add control points + B/C / saturation / shadows / highlights."
                    )
                    StepCard(
                        number: 4,
                        title: "Stabilize / Align sequences",
                        detail: "For multi-frame timelapses or comparing post-stack frames, use Run Stabilize / Align. The aligned frames live in MEMORY for fast scrubbing + blink-comparison; click Save All to push them to OUTPUTS. From there you can export TIFF / PNG / JPEG sequences, MP4 H.264, MOV ProRes 4444, or animated GIF."
                    )

                    Divider().padding(.vertical, 4)

                    Text("Why it's cool")
                        .font(.system(size: 14, weight: .heavy))

                    BulletRow(icon: "bolt.fill", color: .orange,
                              text: "Native Metal pipeline — every shader runs on the GPU, every FFT on shared-FFTSetup vDSP across all cores.")
                    BulletRow(icon: "wand.and.stars", color: .purple,
                              text: "Object-aware presets tuned per peer-reviewed solar-imaging quality literature (Pertuz, Denker/Deng).")
                    BulletRow(icon: "icloud.fill", color: .blue,
                              text: "Your tuned presets auto-sync across Macs via iCloud — pick a preset on your laptop, apply it on the observatory iMac.")
                    BulletRow(icon: "square.stack.3d.up.fill", color: .pink,
                              text: "Lucky imaging done right: GPU-graded Laplacian variance + aligned reference build + gamma-shaped quality weighting + Multi-AP refinement.")
                    BulletRow(icon: "sparkles", color: .cyan,
                              text: "No dialog ping-pong: Lucky Stack outputs sharpening + tone baked in by default, in the right folder — no manual export step.")

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
