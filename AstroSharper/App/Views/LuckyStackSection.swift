// Lucky-Stack panel section. Operates on whatever SER files are marked /
// selected in the main file list — no separate file picker, single source of
// truth. Output goes to the same `customOutputFolder` (or `<root>/_processed`
// fallback) used by the normal sharpen pipeline.
import SwiftUI

struct LuckyStackSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var expanded = false   // start collapsed for a clean panel

    private var serTargets: [FileEntry] {
        let ids = app.batchTargetIDs
        return app.catalog.files.filter { ids.contains($0.id) && $0.isSER }
    }
    private var serCount: Int { serTargets.count }
    private var allSerInCatalog: Int { app.catalog.files.filter { $0.isSER }.count }
    /// Lucky Stack is meaningless without SER input. We disable both the
    /// header chevron and the run button so the section can't accidentally
    /// be expanded on an empty / TIFF-only folder.
    private var disabled: Bool { allSerInCatalog == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    if !disabled {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(disabled)

                Image(systemName: "sparkles.tv.fill")
                    .foregroundColor(disabled ? .secondary : .accentColor)
                Text("Lucky Stack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(disabled ? .secondary : .primary)
                if disabled {
                    Text("· no .ser files")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(targetCountLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .opacity(disabled ? 0.55 : 1.0)
            .help(disabled ? "Lucky Stack runs on .ser video files. Open a folder containing SharpCap / FireCapture .ser captures to enable." : "")

            if expanded && !disabled {
                Picker("Mode", selection: $app.luckyStack.mode) {
                    ForEach(LuckyStackMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(app.luckyStack.mode.description)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Keep best").font(.caption)
                        Spacer()
                        Text("\(app.luckyStack.keepPercent) %")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(app.luckyStack.keepPercent) },
                            set: { app.luckyStack.keepPercent = max(1, min(100, Int($0))) }
                        ),
                        in: 5...75
                    )
                    .controlSize(.small)
                }

                // Extra-variants table — generates side-by-side stacks at
                // different keep-counts/percentages, each in its own subdir.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Extra stacks (subfolders f# / p#)")
                            .font(.caption)
                        Spacer()
                        if !app.luckyStack.variants.isEmpty {
                            Button("Clear") {
                                app.luckyStack.variants = LuckyStackVariants()
                            }
                            .controlSize(.mini)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("f")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 14, alignment: .leading)
                        ForEach(0..<3, id: \.self) { i in
                            VariantField(
                                value: Binding(
                                    get: { app.luckyStack.variants.absoluteCounts[i] },
                                    set: { app.luckyStack.variants.absoluteCounts[i] = max(0, $0) }
                                ),
                                placeholder: "frames"
                            )
                        }
                    }
                    HStack(spacing: 4) {
                        Text("p")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 14, alignment: .leading)
                        ForEach(0..<3, id: \.self) { i in
                            VariantField(
                                value: Binding(
                                    get: { app.luckyStack.variants.percentages[i] },
                                    set: { app.luckyStack.variants.percentages[i] = max(0, min(100, $0)) }
                                ),
                                placeholder: "%"
                            )
                        }
                    }
                    Text("Each non-zero entry runs an extra stack and writes to e.g. ‘f100/’ or ‘p25/’ in the output folder. 0 = off.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if app.luckyStack.mode == .scientific {
                    HStack(spacing: 4) {
                        Toggle("Multi-AP", isOn: Binding(
                            get: { app.luckyStack.multiAP.enabled },
                            set: { newOn in
                                if newOn {
                                    if app.luckyStack.multiAP.grid == 0 {
                                        app.luckyStack.multiAP = .grid(8, 16)
                                    }
                                } else {
                                    app.luckyStack.multiAP = .off
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        Text(app.luckyStack.multiAP.label)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .help("Local alignment-point grid for non-uniform seeing. Grid + patch size pull from the active preset; user presets remember your tuning.")

                    if app.luckyStack.multiAP.enabled {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("AP grid").font(.caption)
                                Spacer()
                                Text("\(app.luckyStack.multiAP.grid)×\(app.luckyStack.multiAP.grid)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(app.luckyStack.multiAP.grid) },
                                    set: { app.luckyStack.multiAP.grid = max(2, min(20, Int($0))) }
                                ),
                                in: 2...20, step: 1
                            )
                            .controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Patch size").font(.caption)
                                Spacer()
                                Text("\(app.luckyStack.multiAP.patchHalf * 2) px")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(app.luckyStack.multiAP.patchHalf) },
                                    set: { app.luckyStack.multiAP.patchHalf = max(4, min(48, Int($0))) }
                                ),
                                in: 4...48, step: 1
                            )
                            .controlSize(.small)
                        }
                    }
                }

                // Per-channel stacking (Path B). Bayer-only — mono SER
                // captures ignore the flag and use the standard runner.
                HStack(spacing: 4) {
                    Toggle("Per-channel (Path B)", isOn: $app.luckyStack.perChannelStacking)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .help("Path B: split Bayer SER into R/G/B planes, align + stack each independently, recombine. Catches per-frame chromatic dispersion. Bayer captures only — mono SER ignored. ~3× runtime cost.")

                // Auto-PSF post-pass (Block C.1 v0).
                HStack(spacing: 4) {
                    Toggle("Auto-PSF + Wiener", isOn: $app.luckyStack.autoPSF)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    if app.luckyStack.autoPSF {
                        Spacer()
                        Text("SNR")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("\(Int(app.luckyStack.autoPSFSNR))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .help("Estimates Gaussian PSF sigma from the planetary limb and applies Wiener deconvolution. Skipped silently if no clear disc edge is present in the stacked output. Use lower SNR (~30) for aggressive sharpening, higher (~100) for soft results on noisy data.")

                if app.luckyStack.autoPSF {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Wiener SNR").font(.caption)
                            Spacer()
                            Text("\(Int(app.luckyStack.autoPSFSNR))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: $app.luckyStack.autoPSFSNR,
                            in: 20...200, step: 10
                        )
                        .controlSize(.small)
                    }

                    // Block C.5 dual-stage denoise — visible only when
                    // auto-PSF is on, since the engine ignores these
                    // values otherwise.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Denoise (PSF estimate)").font(.caption)
                            Spacer()
                            Text("\(app.luckyStack.denoisePrePercent)%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(app.luckyStack.denoisePrePercent) },
                                set: { app.luckyStack.denoisePrePercent = Int($0) }
                            ),
                            in: 0...100, step: 5
                        )
                        .controlSize(.small)
                    }
                    .help("Wavelet soft-threshold applied before the PSF estimate + Wiener deconv. Cleans up the LSF measurement and prevents the inverse filter from amplifying noise. BiggSky-typical 75. Set to 0 for clean low-noise SERs.")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Denoise (After restore)").font(.caption)
                            Spacer()
                            Text("\(app.luckyStack.denoisePostPercent)%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(app.luckyStack.denoisePostPercent) },
                                set: { app.luckyStack.denoisePostPercent = Int($0) }
                            ),
                            in: 0...100, step: 5
                        )
                        .controlSize(.small)
                    }
                    .help("Wavelet soft-threshold applied after the Wiener restore. Suppresses residual ringing and amplified noise from the deconvolution. BiggSky-typical 75. Set to 1 for low-noise sources.")
                }

                Picker("Filename", selection: $app.luckyStack.filenameMode) {
                    ForEach(LuckyStackFilenameMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .help("SharpCap: keep original name + _stack. WinJUPOS: YYYY-MM-DD-HHmm_ss-<target>.tif from the SER UTC timestamp.")

                if app.luckyStack.filenameMode == .winjupos {
                    HStack(spacing: 4) {
                        Text("Target").font(.caption)
                        TextField("", text: $app.luckyStack.winjuposTarget)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(maxWidth: 100)
                    }
                }

                Divider()

                Toggle("Bake current Sharpen + Tone into output", isOn: $app.luckyStack.bakeInProcessing)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("ON (default): the saved TIFF is the stacked frame run through the active Sharpen + Tone Curve settings — matches what you see in the live preview. OFF: write the raw stacked mean and apply Sharpen later via 'Apply to Selection' on the OUTPUTS tab.")

                LuckyRunButton(disabled: serCount == 0) {
                    app.runLuckyStackOnSelection()
                }
                .help("Stacks every marked or selected .ser file. Output goes to the configured Output Folder.")

                Text(hintLine)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Status rows for any in-flight or completed lucky-stack queue items.
                if !app.luckyStack.queue.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(app.luckyStack.queue) { item in
                            QueueRow(item: item)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var targetCountLabel: String {
        if allSerInCatalog == 0 { return "no SER" }
        return "\(serCount)/\(allSerInCatalog) SER"
    }

    private var hintLine: String {
        if allSerInCatalog == 0 {
            return "No .ser files in the open folder. Open a folder with SharpCap captures (⌘O) to begin."
        }
        if serCount == 0 {
            return "Mark or select the .ser files you want to stack in the file list."
        }
        return "Will write \(serCount) stacked TIFF\(serCount == 1 ? "" : "s") to the output folder."
    }
}

/// Compact integer text field for the variants table. Stores 0 as "off"
/// (rendered as empty placeholder).
private struct VariantField: View {
    @Binding var value: Int
    let placeholder: String
    @State private var text: String = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 64)
            .multilineTextAlignment(.center)
            .onAppear { text = value == 0 ? "" : String(value) }
            .onChange(of: value) { _, new in
                let want = new == 0 ? "" : String(new)
                if text != want { text = want }
            }
            .onChange(of: text) { _, new in
                let n = Int(new.trimmingCharacters(in: .whitespaces)) ?? 0
                if value != n { value = n }
            }
    }
}

/// Generic hero "run" button — used by both Lucky Stack and Run Stabilize.
/// A layered SF-Symbol icon + sparkles overlay + purple→pink gradient.
struct LuckyRunButton: View {
    let disabled: Bool
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
    @State private var hover = false

    init(
        disabled: Bool,
        title: String = "Run Lucky Stack",
        subtitle: String = "✨  best frames → one stacked TIFF",
        icon: String = "square.3.layers.3d.top.filled",
        action: @escaping () -> Void
    ) {
        self.disabled = disabled
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(.white)
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.yellow)
                        .offset(x: 12, y: -8)
                }
                .frame(width: 28, height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: disabled
                        ? [Color.gray.opacity(0.5), Color.gray.opacity(0.3)]
                        : [Color(red: 0.45, green: 0.15, blue: 0.95),
                           Color(red: 0.95, green: 0.30, blue: 0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(hover ? 0.30 : 0.10), lineWidth: 1)
            )
            .shadow(color: disabled ? .clear : Color.purple.opacity(0.35), radius: hover ? 6 : 3, x: 0, y: 1)
            .scaleEffect(hover && !disabled ? 1.015 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .onHover { hover = $0 }
    }
}

private struct QueueRow: View {
    let item: LuckyStackItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                statusIcon
                Text(item.url.lastPathComponent)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(item.statusText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if item.status == .processing {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "circle").foregroundColor(.secondary)
        case .processing:
            Image(systemName: "circle.dotted").foregroundColor(.accentColor)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
        }
    }
}
