// Left settings panel. Three collapsible sections, always present, each with
// its own Enabled toggle. All settings are bound directly to AppModel so the
// preview and batch engine read them from one source of truth.
import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Workflow order: capture → stack → align → sharpen → tone → save.
                LuckyStackSection()
                Divider()
                StabilizeSection()
                Divider()
                SharpeningSection()
                Divider()
                ToneCurveSection()
                Divider()
                OutputFolderSection()
                Spacer(minLength: 0)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Sharpening

struct SharpeningSection: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        SectionContainer(title: "Sharpening", icon: "wand.and.stars", isOn: $app.sharpen.enabled) {
            // Slider ranges bumped 1.5–2× the previous limits so the
            // strong sharpening typical for jupiter / saturn fits inside
            // the slider without forcing the user to type values manually.
            Toggle("Unsharp Mask", isOn: $app.sharpen.unsharpEnabled)
            LabeledSlider(label: "Radius (σ)", value: $app.sharpen.radius, range: 0.2...15, format: "%.2f px")
                .disabled(!app.sharpen.unsharpEnabled)
            LabeledSlider(label: "Amount", value: $app.sharpen.amount, range: 0...8, format: "%.2f")
                .disabled(!app.sharpen.unsharpEnabled)
            Toggle("Adaptive (dim areas less)", isOn: $app.sharpen.adaptive)
                .disabled(!app.sharpen.unsharpEnabled)

            Divider().padding(.vertical, 4)

            Toggle("Wavelet Sharpen (à-trous)", isOn: $app.sharpen.waveletEnabled)
            if app.sharpen.waveletEnabled {
                ForEach(0..<app.sharpen.waveletScales.count, id: \.self) { idx in
                    LabeledSlider(
                        label: "Scale \(idx + 1) (\(Int(pow(2.0, Double(idx)))) px)",
                        value: Binding(
                            // Bounds-checked — when the user shrinks the
                            // array via the minus button, in-flight ForEach
                            // closures captured the now-out-of-range idx
                            // and would crash on the next read. Guard
                            // returns 0 for stale bindings; the row gets
                            // discarded on the next layout pass.
                            get: {
                                idx < app.sharpen.waveletScales.count
                                    ? app.sharpen.waveletScales[idx]
                                    : 0
                            },
                            set: {
                                guard idx < app.sharpen.waveletScales.count else { return }
                                app.sharpen.waveletScales[idx] = $0
                            }
                        ),
                        range: 0...20, format: "%.2f×"
                    )
                }
                // Add / remove scales — engine supports up to 8 — plus a
                // reset that drops back to the 6-band Registax-style
                // default ([1.8, 1.4, 1.0, 0.6, 0.4, 0.3]).
                HStack {
                    Button("Reset to default") {
                        app.sharpen.waveletScales = [1.8, 1.4, 1.0, 0.6, 0.4, 0.3]
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("Restore the 6-band default amounts and band count.")
                    Spacer()
                    Button {
                        if app.sharpen.waveletScales.count > 1 {
                            app.sharpen.waveletScales.removeLast()
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(app.sharpen.waveletScales.count <= 1)
                    .help("Remove the largest-scale band.")
                    Text("\(app.sharpen.waveletScales.count) bands")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 56)
                    Button {
                        if app.sharpen.waveletScales.count < 8 {
                            app.sharpen.waveletScales.append(0.2)
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(app.sharpen.waveletScales.count >= 8)
                    .help("Add another band (covers 2× the previous scale's pixel size).")
                }
                LabeledSlider(
                    label: "Noise threshold",
                    value: $app.sharpen.waveletNoiseThreshold,
                    range: 0...0.05, format: "%.4f"
                )
                .help("Donoho-style soft-shrinkage applied per band BEFORE the boost. Zeroes out small noise coefficients, leaves edge coefficients alone — denoise without losing sharpness because thresholding happens inside the same à-trous decomposition that's about to amplify the layers. 0.005–0.015 is the sweet spot on planetary OSC; >0.02 starts visibly smoothing fine cloud detail. 0 = off.")
                Text("Registax-style multi-scale sharpening. Each band covers 2× the pixel size of the previous one (1, 2, 4, 8, 16, 32, 64, 128 px). Smaller scales = fine cloud / surface detail; larger scales = overall contrast / band structure. The noise threshold above shrinks small (= noise) coefficients to zero before the boost, scaled per band so the noisier fine scales get more denoising than the cleaner large scales.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 4)

            Toggle("Wiener Deconvolution", isOn: $app.sharpen.wienerEnabled)
            LabeledSlider(label: "Wiener PSF σ", value: $app.sharpen.wienerSigma, range: 0.3...6, format: "%.2f px")
                .disabled(!app.sharpen.wienerEnabled)
            LabeledSlider(label: "Wiener SNR", value: $app.sharpen.wienerSNR, range: 5...500, format: "%.0f")
                .disabled(!app.sharpen.wienerEnabled)
            Text("Linear MSE-optimal deconvolution. Best for theoretical-PSF (well-known optics). Lower SNR = more regularization, less ringing.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(app.sharpen.wienerEnabled ? 1 : 0.5)

            Divider().padding(.vertical, 4)

            Toggle("Lucy-Richardson Deconvolution", isOn: $app.sharpen.lrEnabled)
            LabeledSlider(
                label: "Iterations",
                value: Binding(
                    get: { Double(app.sharpen.lrIterations) },
                    set: { app.sharpen.lrIterations = Int($0) }
                ),
                range: 1...200, format: "%.0f"
            )
            .disabled(!app.sharpen.lrEnabled)
            LabeledSlider(label: "PSF σ", value: $app.sharpen.lrSigma, range: 0.3...8, format: "%.2f px")
                .disabled(!app.sharpen.lrEnabled)

            Divider().padding(.vertical, 4)

            // Noise reduction — final stage, applied AFTER all sharpening
            // and before the tone curve. Edge-preserving bilateral filter.
            Toggle("Noise Reduction (final stage)", isOn: $app.sharpen.nrEnabled)
            LabeledSlider(label: "Spatial σ", value: $app.sharpen.nrSpatial, range: 0.3...4, format: "%.2f px")
                .disabled(!app.sharpen.nrEnabled)
            LabeledSlider(label: "Edge tolerance", value: $app.sharpen.nrRange, range: 0.005...0.30, format: "%.3f")
                .disabled(!app.sharpen.nrEnabled)
            LabeledSlider(
                label: "Window radius",
                value: Binding(
                    get: { Double(app.sharpen.nrRadius) },
                    set: { app.sharpen.nrRadius = Int($0) }
                ),
                range: 1...6, format: "%.0f px"
            )
            .disabled(!app.sharpen.nrEnabled)
            Text("Bilateral filter — runs after all sharpening, before tone curve. Smooths the noise floor without crossing edges. Keep edge tolerance low (0.02–0.08) for hard band/limb preservation.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(app.sharpen.nrEnabled ? 1 : 0.5)

            Divider().padding(.vertical, 4)

            LuckyRunButton(
                disabled: false,
                title: "Apply Sharpening",
                subtitle: applyTargetSubtitle,
                icon: "wand.and.stars"
            ) {
                app.runSharpenOnActiveSection()
            }
            .help("Apply the current Sharpening settings to the active section: in Memory it edits frames in-place (ops accumulate), in Inputs/Outputs it writes a sharpened TIFF to the output folder.")
        }
    }

    private var applyTargetSubtitle: String {
        switch app.displayedSection {
        case .memory:  return "🧠  edit memory frames in-place"
        case .inputs:  return "📥  process selection → OUTPUTS"
        case .outputs: return "🔁  re-process outputs → OUTPUTS"
        }
    }
}

// MARK: - Stabilize

struct StabilizeSection: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        SectionContainer(title: "Stabilize / Align", icon: "scope", isOn: $app.stabilize.enabled) {
            Picker("Reference", selection: $app.stabilize.referenceMode) {
                ForEach(StabilizeSettings.ReferenceMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .help("Marked: use the row tagged with the gold star (press R on a row). First selected: use whatever's first in the selection. Best-quality: auto-pick the sharpest frame as reference.")

            // Reference-marker status. Three states:
            //   • marked & in current section → show name in green
            //   • marked but not in this section → orange hint
            //   • not marked → red call-to-action
            referenceStatusBanner

            Picker("Alignment", selection: $app.stabilize.alignmentMode) {
                ForEach(StabilizeSettings.AlignmentMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.menu)
            .help("""
                  Full Frame: phase-correlation on the whole image (general use).
                  Disc Centroid: locks onto the bright disc's centre of mass — ideal for full-disc Sun / Moon, robust against thin clouds and seeing wobble.
                  Reference ROI: phase-correlate only inside a user-defined rect on the reference. Pin alignment to a specific feature like a sunspot group, prominence, or crater.
                  """)

            // ROI controls — only visible when ROI mode is active.
            if app.stabilize.alignmentMode == .referenceROI {
                roiControls
            }

            Picker("Boundary", selection: $app.stabilize.cropMode) {
                ForEach(StabilizeSettings.CropMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.menu)
            .help("Pad: output stays at source size with black borders where content shifted out. Crop: output is reduced to the overlap region shared by all frames.")

            Toggle("Stack average after align", isOn: $app.stabilize.stackAverage)

            Divider().padding(.vertical, 4)

            LuckyRunButton(
                disabled: false,
                title: "Run Stabilize",
                subtitle: "🛰️  align frames in memory → Memory tab",
                icon: "scope"
            ) {
                app.runStabilizationInMemory()
            }
            .help("Loads all marked / selected frames, computes shifts, applies them in memory. Switches to the Memory tab automatically. Save All from there to write them to OUTPUTS.")

            if app.playback.hasFrames {
                Label("\(app.playback.frames.count) aligned frames in memory", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
            }

            Text("Needs ≥ 2 files marked or selected.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var referenceStatusBanner: some View {
        if let id = app.referenceFileID,
           let entry = app.catalog.files.first(where: { $0.id == id }) {
            Label("Reference: \(entry.name)", systemImage: "star.fill")
                .font(.caption2)
                .foregroundColor(.yellow)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if app.stabilize.referenceMode == .marked {
            Label("No reference pinned — press R on a row to pick one", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var roiControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    // Capture the current preview viewport rect as the
                    // ROI. The user zooms / pans to frame the feature
                    // they want pinned, then locks it in. Stored as a
                    // normalised rect so it survives zoom changes.
                    NotificationCenter.default.post(name: .stabilizeCaptureROI, object: nil)
                } label: {
                    Label("Lock current view as ROI", systemImage: "rectangle.dashed.badge.record")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Use the area currently visible in the preview as the alignment region. Zoom into the sunspot / prominence / feature you want, then click here.")

                if app.stabilize.roi != nil {
                    Button("Clear") { app.stabilize.roi = nil }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundColor(.secondary)
                }
            }
            if let r = app.stabilize.roi {
                Text(String(format: "ROI %.0f×%.0f%% at (%.0f%%, %.0f%%)",
                            r.w * 100, r.h * 100, r.x * 100, r.y * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("No ROI set — defaults to centre 50 %")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
    }
}

extension Notification.Name {
    /// Posted by the Stabilize section's "Lock current view as ROI"
    /// button — the preview coordinator listens, snapshots its current
    /// viewport rect into normalised reference-frame coordinates, and
    /// writes back into AppModel.stabilize.roi.
    static let stabilizeCaptureROI = Notification.Name("AstroSharper.stabilizeCaptureROI")
}

// MARK: - Tone Curve

struct ToneCurveSection: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        SectionContainer(title: "Tone Curve", icon: "waveform.path.ecg", isOn: $app.toneCurve.enabled) {
            // Auto white balance — independent of the Tone Curve toggle.
            // Runs as the FIRST step of the post-stack pipeline (before
            // any sharpening) so saturation / unsharp don't amplify a
            // green cast that's invisible at neutral colour.
            Toggle("Auto White Balance (gray-world)", isOn: $app.toneCurve.autoWB)
                .help("Computes a per-channel offset+scale on the input so the three channels share a neutral mean. Critical for OSC stacks — Bayer green is naturally amplified by 2× photosite count, so post-stack OSC images otherwise look greenish once saturation > 1. Mono / pre-balanced sources are unaffected.")
            Toggle("Atmospheric Chromatic Dispersion Correction", isOn: $app.toneCurve.chromaticAlignment)
                .help("Phase-correlates R and B against G on the post-stack output and applies sub-pixel shifts so the three channels re-align (G stays anchored). Atmospheric refraction shifts blue more than red, so OSC planets at low altitude show coloured limb fringes; ACDC removes them. No-op on mono / pre-aligned sources because the offsets come out near zero.")
            Toggle("Auto Stretch (histogram normalisation)", isOn: $app.toneCurve.autoStretch)
                .help("Maps the dim camera-native pixel range to fill the display range. Finds the 0.5%-percentile dark floor and 99.5%-percentile bright tail, scales linearly so the bright tail lands at ~95%. This is the default behaviour of every external export tool (BiggSky, Registax) — without it the stacked output looks washed out and low-contrast even though the underlying detail is the same. Closes most of the visible gap to reference exports in one step.")
            Divider().padding(.vertical, 4)
            ToneCurveEditor(
                points: $app.toneCurve.controlPoints,
                histogram: app.previewHistogram,
                logHistogram: $app.histogramLogScale
            )
            Divider().padding(.vertical, 4)
            // Brightness — additive offset, ±0.3 typical. Identity = 0.
            HStack {
                Text("Brightness")
                    .font(.system(size: 11))
                    .frame(width: 80, alignment: .leading)
                Slider(value: $app.toneCurve.brightness, in: -0.3...0.3, step: 0.005)
                Text(String(format: "%+.2f", app.toneCurve.brightness))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
                    .foregroundColor(.secondary)
                Button("Reset") { app.toneCurve.brightness = 0.0 }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(abs(app.toneCurve.brightness) < 1e-4)
            }
            .help("Additive lightness offset, applied after the tone curve. Identity = 0.")
            // Contrast — multiplicative around 0.5. Identity = 1.0.
            HStack {
                Text("Contrast")
                    .font(.system(size: 11))
                    .frame(width: 80, alignment: .leading)
                Slider(value: $app.toneCurve.contrast, in: 0.5...2.0, step: 0.02)
                Text(String(format: "%.2f", app.toneCurve.contrast))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
                    .foregroundColor(.secondary)
                Button("Reset") { app.toneCurve.contrast = 1.0 }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(abs(app.toneCurve.contrast - 1.0) < 1e-4)
            }
            .help("Contrast multiplier around 0.5 mid-point. >1 expands, <1 compresses.")
            // Saturation — applied around per-pixel Rec.709 luma. 1.0 is
            // identity. Stacking averages noisy frames toward grey, so a
            // small boost (1.2–1.5) typically restores planetary colour
            // without touching luminance.
            HStack {
                Text("Saturation")
                    .font(.system(size: 11))
                    .frame(width: 80, alignment: .leading)
                Slider(value: $app.toneCurve.saturation, in: 0...3, step: 0.05)
                Text(String(format: "%.2f", app.toneCurve.saturation))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
                    .foregroundColor(.secondary)
                Button("Reset") { app.toneCurve.saturation = 1.0 }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(abs(app.toneCurve.saturation - 1.0) < 1e-4)
            }
            .help("0 = grayscale, 1 = unchanged, 2 = double saturation. Applied after the tone curve.")
            Divider().padding(.vertical, 4)
            LuckyRunButton(
                disabled: false,
                title: "Apply Tone Curve",
                subtitle: toneApplySubtitle,
                icon: "waveform.path"
            ) {
                app.runToneOnActiveSection()
            }
            .help("Apply the current tone curve to the active section: Memory edits in-place (ops accumulate), Inputs/Outputs writes a toned TIFF to the output folder.")
        }
    }

    private var toneApplySubtitle: String {
        switch app.displayedSection {
        case .memory:  return "🧠  edit memory frames in-place"
        case .inputs:  return "📥  process selection → OUTPUTS"
        case .outputs: return "🔁  re-process outputs → OUTPUTS"
        }
    }
}

// MARK: - Output folder

struct OutputFolderSection: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .foregroundColor(.accentColor)
                Text("Output Folder")
                    .font(.system(size: 13, weight: .semibold))
            }

            HStack(spacing: 4) {
                if app.pickedOutputFolder != nil {
                    Image(systemName: "pin.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 9))
                        .help("Pinned: this folder stays even when you switch input folders. Click Reset to follow inputs again.")
                }
                Text(activePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }

            HStack {
                Button("Choose…") { chooseFolder() }
                    .controlSize(.small)
                if app.pickedOutputFolder != nil {
                    Button("Reset") { app.setCustomOutputFolder(nil) }
                        .controlSize(.small)
                        .help("Clear the pinned folder and resume tracking the currently-opened input folder (<input>/_AstroSharper).")
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var activePath: String {
        app.effectiveOutputFolder?.path ?? "<input>/_AstroSharper"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            app.setCustomOutputFolder(url)
        }
    }
}

// MARK: - Shared section container

private struct SectionContainer<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    @ViewBuilder let content: () -> Content
    /// All sections start collapsed at launch for a clean panel; the user
    /// expands what they need. A toggle-on later auto-expands the section,
    /// and a toggle-off resets so the next on-click feels predictable.
    @State private var userExpanded: Bool? = false

    private var expanded: Bool {
        userExpanded ?? isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // Whole title row toggles collapse — feels more discoverable
                // than only the small chevron being clickable.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        userExpanded = !expanded
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 12)
                        Image(systemName: icon)
                            .foregroundColor(.accentColor)
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse section" : "Expand section")

                Spacer()
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    content()
                }
                .disabled(!isOn)
                .opacity(isOn ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: isOn) { _, _ in
            // Reset user override so toggle on/off restores the default
            // expand/collapse behaviour (no surprise sticky state).
            userExpanded = nil
        }
    }
}

// MARK: - Labeled slider

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}
