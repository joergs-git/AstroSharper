// Left settings panel. Three collapsible sections, always present, each with
// its own Enabled toggle. All settings are bound directly to AppModel so the
// preview and batch engine read them from one source of truth.
import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LuckyStackSection()
                Divider()
                SharpeningSection()
                Divider()
                StabilizeSection()
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
            Toggle("Unsharp Mask", isOn: $app.sharpen.unsharpEnabled)
            LabeledSlider(label: "Radius (σ)", value: $app.sharpen.radius, range: 0.2...10, format: "%.2f px")
                .disabled(!app.sharpen.unsharpEnabled)
            LabeledSlider(label: "Amount", value: $app.sharpen.amount, range: 0...5, format: "%.2f")
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
                            get: { app.sharpen.waveletScales[idx] },
                            set: { app.sharpen.waveletScales[idx] = $0 }
                        ),
                        range: 0...4, format: "%.2f×"
                    )
                }
                Text("Registax-style multi-scale sharpening. Try smaller scales for fine solar granulation, larger for overall contrast.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 4)

            Toggle("Wiener Deconvolution", isOn: $app.sharpen.wienerEnabled)
            LabeledSlider(label: "Wiener PSF σ", value: $app.sharpen.wienerSigma, range: 0.3...4, format: "%.2f px")
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
            LabeledSlider(label: "PSF σ", value: $app.sharpen.lrSigma, range: 0.3...5, format: "%.2f px")
                .disabled(!app.sharpen.lrEnabled)
        }
    }
}

// MARK: - Stabilize

struct StabilizeSection: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        SectionContainer(title: "Stabilize", icon: "scope", isOn: $app.stabilize.enabled) {
            Picker("Reference", selection: $app.stabilize.referenceMode) {
                ForEach(StabilizeSettings.ReferenceMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Picker("Boundary", selection: $app.stabilize.cropMode) {
                ForEach(StabilizeSettings.CropMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.menu)
            .help("Pad: output stays at source size with black borders where content shifted out. Crop: output is reduced to the overlap region shared by all frames.")

            Toggle("Stack average after align", isOn: $app.stabilize.stackAverage)

            Divider().padding(.vertical, 4)

            Button {
                app.runStabilizationInMemory()
            } label: {
                Label("Run Stabilize (in memory)", systemImage: "memorychip")
            }
            .controlSize(.small)
            .help("Loads all marked / selected frames, computes shifts, applies them in memory. Use the player to scrub. Export when satisfied.")

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
}

// MARK: - Tone Curve

struct ToneCurveSection: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        SectionContainer(title: "Tone Curve", icon: "waveform.path.ecg", isOn: $app.toneCurve.enabled) {
            ToneCurveEditor(
                points: $app.toneCurve.controlPoints,
                histogram: app.previewHistogram,
                logHistogram: $app.histogramLogScale
            )
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
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
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
