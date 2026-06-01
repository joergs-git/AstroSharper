// Trim + Crop + Export controls for SER files.
// User opens this via the "Export…" button in the SerScrubBar.
// Defines:
//   - SerCropAspect: locked aspect-ratio presets for the crop rect
//                    (both landscape and portrait — Free / 1:1 /
//                    4:3 / 16:9 / 3:2 / 9:16 / 3:4 / 2:3).
//   - SerExportFormat: SER (truncated, same bit depth + Bayer layout)
//                      or animated GIF (8-bit sRGB).
//   - SerExportPanel:  the SwiftUI popover view shown when the user
//                      clicks "Export…" in the scrub bar.
// Writes are dispatched off-main; result lands in OUTPUTS automatically.
import AppKit
import SwiftUI

enum SerCropAspect: String, CaseIterable, Identifiable, Codable {
    case free  = "Free"
    case s1_1  = "1:1"
    case s4_3  = "4:3"
    case s3_2  = "3:2"
    case s16_9 = "16:9"
    case s9_16 = "9:16"   // portrait
    case s3_4  = "3:4"    // portrait
    case s2_3  = "2:3"    // portrait
    var id: String { rawValue }

    /// width / height. nil = free (no constraint).
    var ratio: CGFloat? {
        switch self {
        case .free:  return nil
        case .s1_1:  return 1.0
        case .s4_3:  return 4.0 / 3.0
        case .s3_2:  return 3.0 / 2.0
        case .s16_9: return 16.0 / 9.0
        case .s9_16: return 9.0 / 16.0
        case .s3_4:  return 3.0 / 4.0
        case .s2_3:  return 2.0 / 3.0
        }
    }
}

enum SerExportFormat: String, CaseIterable, Identifiable {
    case ser  = "SER"
    case mp4  = "MP4"
    case apng = "APNG"
    case gif  = "GIF"
    var id: String { rawValue }

    /// "Animated still image" formats — `<img>`-embeddable, no video
    /// player required. APNG and GIF share the same fps + target-
    /// frames UI controls (and the same preview-window plumbing).
    var isAnimatedStill: Bool { self == .apng || self == .gif }
}

struct SerExportPanel: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    // Crop %s remain @State — they're a pure UI mirror of the source-
    // pixel `app.serCropRect` and get re-synced from it on appear.
    @State private var cropX: Double = 0
    @State private var cropY: Double = 0
    @State private var cropW: Double = 1.0
    @State private var cropH: Double = 1.0
    @State private var writing: Bool = false
    @State private var writeProgress: Double = 0
    @State private var lastResult: String? = nil
    /// Auto-detected source SER capture fps from the optional timestamp
    /// trailer. nil = source has no trailer (or it was invalid). Used
    /// by the "Match source duration" button and the source-fps
    /// override field; no other math depends on it.
    @State private var detectedSourceFPS: Double? = nil
    // NOTE: format / fps / targetFrames / bakeInProcessing /
    // resizeDivisor / rotationDegrees now live on AppModel (prefix
    // `serExport…`) so they survive closing + re-opening this Window.
    // Read via `app.serExport…`, bind via `$app.serExport…`.

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.system(size: 14, weight: .heavy))

            trimSection
            cropSection
            outputSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { syncFromState() }
        // Trim is set from the scrub bar OUTSIDE this view. Track its
        // changes so the Duration slider keeps mirroring the trim's
        // real-time length until the user manually picks a different
        // duration.
        .onChange(of: app.serTrimStart) { _, _ in syncDurationToTrim() }
        .onChange(of: app.serTrimEnd)   { _, _ in syncDurationToTrim() }
        .onChange(of: app.serExportSourceFPSOverride) { _, _ in syncDurationToTrim() }
        .onDisappear { app.serExportPanelOpen = false }
    }

    // MARK: - Sections

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trim range").font(.system(size: 11, weight: .semibold))
            HStack {
                Text(trimSummary).font(.system(size: 11, design: .monospaced))
                Spacer()
                Button("Clear") {
                    app.serTrimStart = nil
                    app.serTrimEnd = nil
                }
                .font(.system(size: 11))
                .disabled(app.serTrimStart == nil && app.serTrimEnd == nil)
            }
            Text("Use the ▶︎▢ / ◀︎▢ buttons on the scrub bar to set start/end at the current frame.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Crop").font(.system(size: 11, weight: .semibold))
            HStack {
                Picker("Aspect", selection: $app.serCropAspect) {
                    ForEach(SerCropAspect.allCases) { a in
                        Text(a.rawValue).tag(a)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                .onChange(of: app.serCropAspect) { _, _ in snapToAspect() }
                Spacer()
                Button("Reset") {
                    app.serCropRect = nil
                    cropX = 0; cropY = 0; cropW = 1.0; cropH = 1.0
                }
                .disabled(app.serCropRect == nil)
                .font(.system(size: 11))
            }
            // Slider order pairs each dimension with its position:
            // Width with Pos X (horizontal extent), then Height with
            // Pos Y (vertical extent). Mirrors how users mentally
            // describe a crop rectangle ("400 wide starting at x=200").
            LabeledSlider(label: "Width  %",  value: $cropW, range: 0.1...1.0, format: "%.2f")
                .onChange(of: cropW) { _, _ in updateCropRect() }
            LabeledSlider(label: "Pos X  %",  value: $cropX, range: 0...1.0, format: "%.2f")
                .onChange(of: cropX) { _, _ in updateCropRect() }
            LabeledSlider(label: "Height %",  value: $cropH, range: 0.1...1.0, format: "%.2f")
                .onChange(of: cropH) { _, _ in updateCropRect() }
            LabeledSlider(label: "Pos Y  %",  value: $cropY, range: 0...1.0, format: "%.2f")
                .onChange(of: cropY) { _, _ in updateCropRect() }
            if let r = app.serCropRect {
                Text(String(format: "→ %d×%d px @ (%d, %d)",
                            Int(r.width), Int(r.height), Int(r.origin.x), Int(r.origin.y)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output").font(.system(size: 11, weight: .semibold))
            Picker("Format", selection: $app.serExportFormat) {
                ForEach(SerExportFormat.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            // Duration — what the user actually wants. Output plays
            // for this many seconds; the frame count needed is derived
            // (= duration × fps), picked evenly from the trim range.
            // Slider range 0.5–60s covers Insta-Reels-style showcases
            // (max 60s) without becoming unmanageable.
            LabeledSlider(label: "Duration s",
                          value: $app.serExportDurationSeconds,
                          range: 0.5...60.0,
                          format: "%.1f")

            // Match source — single-shot button. Sets duration to the
            // source SER's real-time duration so playback is 1:1 to
            // the original capture. Disabled when source fps is just
            // the 30-fps fallback (no trailer, no override).
            HStack {
                Spacer().frame(width: 70)
                Button {
                    let srcDur = sourceDurationSeconds
                    app.serExportDurationSeconds = max(0.5, min(60.0, srcDur))
                } label: {
                    Text("Match source · \(String(format: "%.1f", sourceDurationSeconds))s")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sourceDurationSeconds <= 0)
                .help("Set Duration to the source SER's real-time capture duration so output plays at 1:1 speed.")
                Spacer()
            }

            // FPS — discrete picker (1, 2, 5, 10, 15, 20, 24, 30, 60).
            // Smoothness knob. Lower fps = smaller file, choppier;
            // higher fps = smoother, larger file. Applies to all formats:
            //   .gif/.apng → frame delay = 1/fps
            //   .ser       → per-frame timestamp trailer at 1/fps spacing
            //   .mp4       → CMTime frame duration = 1/fps
            HStack {
                Text("FPS")
                    .font(.system(size: 11))
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: $app.serExportFPS) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("15").tag(15)
                    Text("20").tag(20)
                    Text("24").tag(24)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                Text("(smoothness)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Format-specific estimate line.
            Text(currentEstimateLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            // Source-FPS override — compact, only needed when the SER
            // has no timestamp trailer or auto-detection is wrong.
            // Affects nothing except the Match-source-duration button.
            HStack {
                Text("Source FPS")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                TextField("", value: Binding(
                    get: { effectiveSourceFPS },
                    set: { app.serExportSourceFPSOverride = $0 }
                ), formatter: Self.fpsFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.system(size: 10, design: .monospaced))
                if let detected = detectedSourceFPS {
                    Text("(detected \(String(format: "%.1f", detected)))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Text("(no trailer)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if app.serExportSourceFPSOverride != nil {
                    Button("⟲") {
                        app.serExportSourceFPSOverride = nil
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to auto-detected value")
                }
            }
            .help("Source SER capture fps. Only used by the \u{201C}Match source\u{201D} button; edit if detection is wrong or absent.")

            // Frame-budget warning when target frames > available
            // candidates. Surfaces the "I asked for 5s @ 60fps but my
            // trim only has 100 frames" case explicitly.
            if let warn = frameBudgetWarning {
                Text(warn)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)
            HStack {
                Text("Resize")
                    .font(.system(size: 11))
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: $app.serExportResizeDivisor) {
                    Text("1:1").tag(1)
                    Text("1:2").tag(2)
                    Text("1:4").tag(4)
                    Text("1:8").tag(8)
                    Text("1:16").tag(16)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .help("Downsample the output by this factor on the GPU after Sharpen + Tone. 1:2 = ½×½ (¼ the area). Requires Bake-in.")
                if app.serExportResizeDivisor > 1 {
                    Text(resizedDimensionLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Rotate")
                    .font(.system(size: 11))
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: $app.serExportRotationDegrees) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .help("Clockwise rotation applied to every exported frame. 90° / 270° swap width and height. Requires Bake-in.")
                if app.serExportRotationDegrees != 0 {
                    Image(systemName: "rotate.right.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Toggle("Bake in Sharpen + Tone", isOn: $app.serExportBakeIn)
                .font(.system(size: 11))
                .disabled(app.serExportResizeDivisor > 1 || app.serExportRotationDegrees != 0 || app.serExportFormat == .mp4)
                .help("Run every exported frame through the current Sharpen + Tone settings (what the live preview shows). Off = raw frame bytes. Auto-enabled at Export time when Resize / Rotate are non-default, and always on for MP4.")
            if effectiveBakeIn {
                Text(bakeInWarning)
                    .font(.system(size: 10))
                    .foregroundColor(app.serExportFormat == .ser ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// True when bake-in is either user-selected OR forced by a
    /// non-default Resize / Rotate. Single source of truth — the UI
    /// shows the warning based on this, and runExport flips
    /// `serExportBakeIn` to match before dispatching the write so the
    /// chosen bake state is also persisted for next time.
    private var effectiveBakeIn: Bool {
        app.serExportBakeIn ||
        app.serExportResizeDivisor > 1 ||
        app.serExportRotationDegrees != 0 ||
        app.serExportFormat == .mp4
    }

    private var bakeInWarning: String {
        switch app.serExportFormat {
        case .ser:
            return "⚠︎ Output .ser will be 16-bit RGB and no longer scientifically linear. Use only for replay / showcase, NOT for re-stacking."
        case .mp4:
            return "MP4 always bakes Sharpen + Tone — internet-ready H.264 video matching the live preview."
        case .apng:
            return "APNG = lossless 24-bit \u{2018}better GIF\u{2019} — every modern browser & forum renders it as a plain image."
        case .gif:
            return "GIF will exactly match the live preview."
        }
    }

    private var resizedDimensionLabel: String {
        guard let dims = sourceDims else { return "" }
        let w = (app.serCropRect?.width).map(Double.init)  ?? dims.w
        let h = (app.serCropRect?.height).map(Double.init) ?? dims.h
        let dw = max(2, Int(w) / app.serExportResizeDivisor)
        let dh = max(2, Int(h) / app.serExportResizeDivisor)
        return "→ \(dw)×\(dh) px"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let last = lastResult {
                Text(last)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if writing {
                ProgressView(value: writeProgress)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)
                Button(writing ? "Writing…" : "Export") {
                    runExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(writing || app.previewSerFrameCount == 0)
            }
        }
    }

    // MARK: - Helpers

    private func syncFromState() {
        if let r = app.serCropRect, let dims = sourceDims {
            cropX = Double(r.origin.x) / dims.w
            cropY = Double(r.origin.y) / dims.h
            cropW = Double(r.width)    / dims.w
            cropH = Double(r.height)   / dims.h
        } else {
            cropX = 0; cropY = 0; cropW = 1.0; cropH = 1.0
        }
        // Detect source capture fps from the SER's optional timestamp
        // trailer. Done lazily here (only when the panel opens) rather
        // than on every file selection — avoids a SerReader open on
        // unrelated UI events.
        detectedSourceFPS = detectSourceFPS()
        // Default Duration = the trim's real-time length. The user
        // already picked what they want by setting the trim range; the
        // default export duration should mirror that intent. They can
        // still drag the slider for a sped-up / slowed-down output.
        // Also called on trim-change so the default tracks live trim
        // edits made via the scrub bar's start/end buttons.
        syncDurationToTrim()
    }

    /// Set the Duration slider to the trim's real-time length, clamped
    /// to the slider's [0.5, 60] s range. Safe to call repeatedly.
    private func syncDurationToTrim() {
        let trimRealSec = sourceDurationSeconds
        guard trimRealSec > 0 else { return }
        app.serExportDurationSeconds = max(0.5, min(60.0, trimRealSec))
    }

    private func detectSourceFPS() -> Double? {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }),
              entry.isSER else { return nil }
        return (try? SerReader(url: entry.url))?.capturedFPS
    }

    // MARK: - Realtime fps derivation (Issue A fix)

    /// Numeric formatter for the Source FPS text field — 1 decimal,
    /// clamped to a sane astrophotography rate range so a typo doesn't
    /// poison the derived fps.
    private static let fpsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimum = 0.5
        f.maximum = 1000
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()

    /// The source capture fps that drives Keep-realtime: user override
    /// wins → auto-detection from the SER trailer → 30.0 fallback.
    private var effectiveSourceFPS: Double {
        if let override_ = app.serExportSourceFPSOverride, override_ > 0 {
            return override_
        }
        if let detected = detectedSourceFPS, detected > 0 {
            return detected
        }
        return 30.0
    }

    /// Output frame count derived from user inputs: duration × fps,
    /// capped at the trim's frame count (can't pick more frames than
    /// the source has). This is the single source of truth for
    /// "how many frames the writer will produce".
    private var effectiveTargetFrameCount: Int {
        let requested = Int((app.serExportDurationSeconds * Double(app.serExportFPS)).rounded())
        return max(1, min(requested, trimFrameCount))
    }

    /// Source SER's real-time duration in seconds. Drives the "Match
    /// source" button label and value. Returns 0 if it can't be
    /// computed (no source or zero-frame trim).
    private var sourceDurationSeconds: Double {
        let src = effectiveSourceFPS
        guard src > 0, trimFrameCount > 0 else { return 0 }
        return Double(trimFrameCount) / src
    }

    /// Concrete-action warning when the user's duration × fps exceeds
    /// what the trim range can deliver. The writer will silently cap;
    /// the user deserves to know their requested duration won't be
    /// achieved at the chosen fps.
    private var frameBudgetWarning: String? {
        let requested = Int((app.serExportDurationSeconds * Double(app.serExportFPS)).rounded())
        guard requested > trimFrameCount, trimFrameCount > 0 else { return nil }
        let achievable = Double(trimFrameCount) / Double(app.serExportFPS)
        return "⚠︎ Trim has only \(trimFrameCount) frames · at \(app.serExportFPS) fps that's \(String(format: "%.1f", achievable))s max. Shorten Duration to \(String(format: "%.1f", achievable))s or lower FPS."
    }

    /// Picks the right estimate label for the current format. All
    /// estimates now lead with effective frame count (= duration ×
    /// fps capped to trim).
    private var currentEstimateLabel: String {
        switch app.serExportFormat {
        case .ser:  return estimateSERLabel
        case .mp4:  return estimateMP4Label
        case .apng: return estimateAPNGLabel
        case .gif:  return estimateGIFLabel
        }
    }

    private var sourceDims: (w: Double, h: Double)? {
        guard let dim = app.previewStats.dimensions,
              dim.width > 0, dim.height > 0 else { return nil }
        return (Double(dim.width), Double(dim.height))
    }

    private var trimSummary: String {
        let n = trimFrameCount
        if app.serTrimStart == nil && app.serTrimEnd == nil {
            return "Full SER · \(n) frames"
        }
        let s = app.serTrimStart ?? 0
        let e = app.serTrimEnd ?? max(0, app.previewSerFrameCount - 1)
        return "\(s)-\(e) · \(n) frames"
    }

    private var trimFrameCount: Int {
        let total = app.previewSerFrameCount
        let s = app.serTrimStart ?? 0
        let e = app.serTrimEnd ?? max(0, total - 1)
        return max(0, min(total, e - s + 1))
    }

    /// Effective frame count after applying the stride. Stride 1 →
    /// trimFrameCount; stride 5 → ceil(trimFrameCount / 5).
    private var strideEffectiveFrameCount: Int {
        let stride = max(1, app.serExportFrameStride)
        let n = trimFrameCount
        return max(1, (n + stride - 1) / stride)
    }

    private var estimateSERLabel: String {
        guard let dims = sourceDims else { return "" }
        let cropW = (app.serCropRect?.width).map(Double.init)  ?? dims.w
        let cropH = (app.serCropRect?.height).map(Double.init) ?? dims.h
        // Resize divides both axes, swallowing 1/div² of the pixels.
        let div = max(1, Double(app.serExportResizeDivisor))
        let w = max(2.0, cropW / div)
        let h = max(2.0, cropH / div)
        // Bake-in writes 16-bit RGB (6 B/px); raw bayer/mono SER is
        // 1 or 2 B/px. Use 6 B/px when bake-in is ON (or implicitly
        // forced by resize/rotation), else 2 B/px conservative.
        let bakedOn = app.serExportBakeIn || app.serExportResizeDivisor > 1 || app.serExportRotationDegrees != 0
        let bpp = bakedOn ? 6.0 : 2.0
        let frames = effectiveTargetFrameCount
        let bytes = Int(w * h * bpp) * frames + 178
        let what = bakedOn ? "16-bit RGB baked" : "16-bit mono est."
        let secs = Double(frames) / Double(max(1, app.serExportFPS))
        return "≈ \(formatBytes(bytes)) · \(frames) frames · \(Int(w))×\(Int(h)) @ \(app.serExportFPS) fps · \(String(format: "%.1f", secs))s · \(what)"
    }

    /// Conservative APNG size estimate. 24-bit RGBA at ~1.5 B/px after
    /// DEFLATE on noisy planetary content (PNG filter type "None", no
    /// adaptive). Typically ~3× a GIF of the same dimensions but with
    /// full colour fidelity — that's the headline trade vs. GIF.
    private var estimateAPNGLabel: String {
        guard let dims = sourceDims else { return "" }
        let cropW = (app.serCropRect?.width).map(Double.init)  ?? dims.w
        let cropH = (app.serCropRect?.height).map(Double.init) ?? dims.h
        let div = max(1, Double(app.serExportResizeDivisor))
        let w = max(2.0, cropW / div)
        let h = max(2.0, cropH / div)
        let frames = effectiveTargetFrameCount
        let bytes = Int(w * h * 1.5) * frames + 4096
        let secs = Double(frames) / Double(max(1, app.serExportFPS))
        return "≈ \(formatBytes(bytes)) · \(frames) frames · \(Int(w))×\(Int(h)) @ \(app.serExportFPS) fps · \(String(format: "%.1f", secs))s · 24-bit lossless"
    }

    /// Coarse byte estimate for H.264 MP4 at our default bitrate
    /// heuristic (~8 bpp baseline, floor 2 Mbps; see Mp4Writer).
    private var estimateMP4Label: String {
        guard let dims = sourceDims else { return "" }
        let cropW = (app.serCropRect?.width).map(Double.init)  ?? dims.w
        let cropH = (app.serCropRect?.height).map(Double.init) ?? dims.h
        let div = max(1, Double(app.serExportResizeDivisor))
        let w = max(2.0, cropW / div)
        let h = max(2.0, cropH / div)
        let frames = effectiveTargetFrameCount
        let secs = Double(frames) / Double(max(1, app.serExportFPS))
        // Bits-per-second; same heuristic as Mp4Writer.
        let bps = Double(max(2_000_000, Int(w * h) * 8))
        let bytes = Int(bps * secs / 8.0) + 4096
        return "≈ \(formatBytes(bytes)) · \(frames) frames · \(Int(w))×\(Int(h)) @ \(app.serExportFPS) fps · \(String(format: "%.1f", secs))s · H.264"
    }

    private var estimateGIFLabel: String {
        guard let dims = sourceDims else { return "" }
        let cropW = (app.serCropRect?.width).map(Double.init)  ?? dims.w
        let cropH = (app.serCropRect?.height).map(Double.init) ?? dims.h
        let div = max(1, Double(app.serExportResizeDivisor))
        let w = max(2.0, cropW / div)
        let h = max(2.0, cropH / div)
        // Animated GIF: ~0.5 B/px after LZW, conservative.
        let frames = effectiveTargetFrameCount
        let bytes = Int(w * h * 0.5) * frames + 1024
        let secs = Double(frames) / Double(max(1, app.serExportFPS))
        return "≈ \(formatBytes(bytes)) · \(frames) frames · \(Int(w))×\(Int(h)) @ \(app.serExportFPS) fps · \(String(format: "%.1f", secs))s"
    }

    private func formatBytes(_ b: Int) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024.0) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(b) / (1024.0 * 1024.0)) }
        return String(format: "%.2f GB", Double(b) / (1024.0 * 1024.0 * 1024.0))
    }

    private func updateCropRect() {
        guard let dims = sourceDims else { return }
        let x = max(0, cropX * dims.w)
        let y = max(0, cropY * dims.h)
        var w = cropW * dims.w
        var h = cropH * dims.h
        // Aspect snap
        if let ratio = app.serCropAspect.ratio {
            // Prefer keeping the larger of width/height changes; lock
            // the OTHER to match the ratio. Snap to height if a portrait
            // ratio (ratio < 1), else snap to width.
            if ratio < 1 { w = h * ratio } else { h = w / ratio }
        }
        // Clamp to source bounds, preserving the chosen size as much
        // as possible.
        let maxW = dims.w - x
        let maxH = dims.h - y
        w = min(w, maxW)
        h = min(h, maxH)
        if w < 8 || h < 8 {
            app.serCropRect = nil
        } else {
            app.serCropRect = CGRect(x: x, y: y, width: w, height: h)
        }
    }

    private func snapToAspect() {
        // Adjust cropW/H to the new aspect, then re-emit rect.
        guard let ratio = app.serCropAspect.ratio, let dims = sourceDims else {
            return
        }
        // Keep the smaller side fixed; pick the other from the ratio.
        let curW = cropW * dims.w
        let curH = cropH * dims.h
        if ratio >= 1 {
            // landscape: H drives W
            let newW = curH * ratio
            cropW = min(1.0, newW / dims.w)
        } else {
            // portrait: W drives H
            let newH = curW / ratio
            cropH = min(1.0, newH / dims.h)
        }
        updateCropRect()
    }

    // MARK: - Run

    private func runExport() {
        // Belt-and-suspenders: Resize > 1 / Rotation != 0 BOTH require
        // the bake-in path (the GPU pipeline does the scale + rotate).
        // The toggle is auto-flipped by .onChange handlers in the
        // panel, but if SwiftUI ever fails to deliver the change (e.g.
        // observed-value update racing with a button tap), the export
        // would silently lose the rotation. Forcing the flag here at
        // dispatch time makes it bulletproof and also persists the
        // chosen bake state for the next window-open.
        if app.serExportResizeDivisor > 1 || app.serExportRotationDegrees != 0 {
            app.serExportBakeIn = true
        }
        // MP4 is always processed-look (demosaic + tone). Force the
        // bake-in flag so the user doesn't have to enable it manually
        // — and so the preview / writer state agrees.
        if app.serExportFormat == .mp4 {
            app.serExportBakeIn = true
        }
        switch app.serExportFormat {
        case .ser:  runSerExport()
        case .mp4:  runMp4Export()
        case .apng: runApngExport()
        case .gif:  runGifExport()
        }
    }

    private func runSerExport() {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }), entry.isSER else { return }
        let trimStart = app.serTrimStart ?? 0
        let trimEnd = app.serTrimEnd ?? max(0, app.previewSerFrameCount - 1)
        let crop = app.serCropRect
        let sourceURL = entry.url
        let suggested = sourceURL.deletingLastPathComponent().appendingPathComponent("_luckystack", isDirectory: true)
        guard let outFolder = app.resolveWritableOutputFolderPublic(implicit: suggested) else {
            lastResult = "Export failed: no writable output folder."
            return
        }
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let suffix = app.serExportBakeIn ? "_baked" : ""
        // Include fps in the filename so successive exports with
        // different fps settings stay easily distinguishable in the
        // outputs folder — matches the .gif / .mp4 / .png naming.
        let outFPS = app.serExportFPS
        let outTarget = effectiveTargetFrameCount
        let fname = String(format: "%@_trim_%d-%d_%dfps%@.ser", base, trimStart, trimEnd, outFPS, suffix)
        let outURL = AppModel.uniqueOutputURL(outFolder.appendingPathComponent(fname))
        let bakeOpts: BakeInExporter.Options? = app.serExportBakeIn
            ? BakeInExporter.Options(
                sharpen: app.sharpen,
                toneCurve: app.toneCurve,
                coloring: app.coloring,
                outputBitDepth: 16,
                resizeDivisor: app.serExportResizeDivisor,
                rotationDegrees: app.serExportRotationDegrees
              )
            : nil
        writing = true; writeProgress = 0; lastResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SerWriter.write(
                    source: sourceURL,
                    output: outURL,
                    frameRange: trimStart...trimEnd,
                    crop: crop,
                    bakeIn: bakeOpts,
                    frameStride: 1,
                    targetFrameCount: outTarget,
                    fps: outFPS,
                    progress: { f in DispatchQueue.main.async { writeProgress = f } }
                )
                DispatchQueue.main.async {
                    writing = false
                    lastResult = "Written: \(outURL.lastPathComponent) — review in preview window"
                    // Open the Export Preview window so the user can
                    // inspect the result at 1:1 and decide Keep vs
                    // Discard. DO NOT auto-register or auto-switch
                    // here — keeping the main preview on the source
                    // SER means the trim / crop / resize / rotation
                    // settings stay live for an immediate re-export
                    // with adjusted parameters.
                    app.exportPreviewURL = outURL
                    openWindow(id: "export-preview")
                }
            } catch {
                DispatchQueue.main.async {
                    writing = false
                    lastResult = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func runMp4Export() {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }), entry.isSER else { return }
        let trimStart = app.serTrimStart ?? 0
        let trimEnd = app.serTrimEnd ?? max(0, app.previewSerFrameCount - 1)
        let crop = app.serCropRect
        let sourceURL = entry.url
        let suggested = sourceURL.deletingLastPathComponent().appendingPathComponent("_luckystack", isDirectory: true)
        guard let outFolder = app.resolveWritableOutputFolderPublic(implicit: suggested) else {
            lastResult = "Export failed: no writable output folder."
            return
        }
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let captureFPS = app.serExportFPS
        let captureTargetFrames = effectiveTargetFrameCount
        let fname = String(format: "%@_%d-%d_%dfps.mp4", base, trimStart, trimEnd, captureFPS)
        let outURL = AppModel.uniqueOutputURL(outFolder.appendingPathComponent(fname))
        // MP4 path is bake-in-only (see Mp4Writer comment); always
        // build the Options even if the user didn't tick the toggle.
        let bakeOpts = BakeInExporter.Options(
            sharpen: app.sharpen,
            toneCurve: app.toneCurve,
            coloring: app.coloring,
            outputBitDepth: 8,
            resizeDivisor: app.serExportResizeDivisor,
            rotationDegrees: app.serExportRotationDegrees
        )
        writing = true; writeProgress = 0; lastResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Mp4Writer.write(
                    source: sourceURL,
                    output: outURL,
                    frameRange: trimStart...trimEnd,
                    fps: captureFPS,
                    crop: crop,
                    bakeIn: bakeOpts,
                    frameStride: 1,
                    targetFrameCount: captureTargetFrames,
                    progress: { f in DispatchQueue.main.async { writeProgress = f } }
                )
                DispatchQueue.main.async {
                    writing = false
                    lastResult = "Written: \(outURL.lastPathComponent) — review in preview window"
                    app.exportPreviewURL = outURL
                    openWindow(id: "export-preview")
                }
            } catch {
                DispatchQueue.main.async {
                    writing = false
                    lastResult = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func runApngExport() {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }), entry.isSER else { return }
        let trimStart = app.serTrimStart ?? 0
        let trimEnd = app.serTrimEnd ?? max(0, app.previewSerFrameCount - 1)
        let crop = app.serCropRect
        let sourceURL = entry.url
        let suggested = sourceURL.deletingLastPathComponent().appendingPathComponent("_luckystack", isDirectory: true)
        guard let outFolder = app.resolveWritableOutputFolderPublic(implicit: suggested) else {
            lastResult = "Export failed: no writable output folder."
            return
        }
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let suffix = app.serExportBakeIn ? "_baked" : ""
        let captureFPS = app.serExportFPS
        let captureTargetFrames = effectiveTargetFrameCount
        let fname = String(format: "%@_%d-%d_%dfps%@.png", base, trimStart, trimEnd, captureFPS, suffix)
        let outURL = AppModel.uniqueOutputURL(outFolder.appendingPathComponent(fname))
        // APNG mirrors GIF's behaviour — bake-in is optional. Without
        // bake-in, the raw demosaic in ApngWriter.fillRGBA produces
        // the same 8-bit output the GIF path does.
        let bakeOpts: BakeInExporter.Options? = app.serExportBakeIn
            ? BakeInExporter.Options(
                sharpen: app.sharpen,
                toneCurve: app.toneCurve,
                coloring: app.coloring,
                outputBitDepth: 8,
                resizeDivisor: app.serExportResizeDivisor,
                rotationDegrees: app.serExportRotationDegrees
              )
            : nil
        writing = true; writeProgress = 0; lastResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ApngWriter.write(
                    source: sourceURL,
                    output: outURL,
                    frameRange: trimStart...trimEnd,
                    targetFrameCount: captureTargetFrames,
                    fps: captureFPS,
                    crop: crop,
                    bakeIn: bakeOpts,
                    frameStride: 1,
                    progress: { f in DispatchQueue.main.async { writeProgress = f } }
                )
                DispatchQueue.main.async {
                    writing = false
                    lastResult = "Written: \(outURL.lastPathComponent) — review in preview window"
                    app.exportPreviewURL = outURL
                    openWindow(id: "export-preview")
                }
            } catch {
                DispatchQueue.main.async {
                    writing = false
                    lastResult = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func runGifExport() {
        guard let id = app.previewFileID,
              let entry = app.catalog.files.first(where: { $0.id == id }), entry.isSER else { return }
        let trimStart = app.serTrimStart ?? 0
        let trimEnd = app.serTrimEnd ?? max(0, app.previewSerFrameCount - 1)
        let crop = app.serCropRect
        let sourceURL = entry.url
        let suggested = sourceURL.deletingLastPathComponent().appendingPathComponent("_luckystack", isDirectory: true)
        guard let outFolder = app.resolveWritableOutputFolderPublic(implicit: suggested) else {
            lastResult = "Export failed: no writable output folder."
            return
        }
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let suffix = app.serExportBakeIn ? "_baked" : ""
        let captureFPS = app.serExportFPS
        let captureTargetFrames = effectiveTargetFrameCount
        let fname = String(format: "%@_%d-%d_%dfps%@.gif", base, trimStart, trimEnd, captureFPS, suffix)
        let outURL = AppModel.uniqueOutputURL(outFolder.appendingPathComponent(fname))
        let bakeOpts: BakeInExporter.Options? = app.serExportBakeIn
            ? BakeInExporter.Options(
                sharpen: app.sharpen,
                toneCurve: app.toneCurve,
                coloring: app.coloring,
                outputBitDepth: 8,
                resizeDivisor: app.serExportResizeDivisor,
                rotationDegrees: app.serExportRotationDegrees
              )
            : nil
        writing = true; writeProgress = 0; lastResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try GifWriter.write(
                    source: sourceURL,
                    output: outURL,
                    frameRange: trimStart...trimEnd,
                    targetFrameCount: captureTargetFrames,
                    fps: captureFPS,
                    crop: crop,
                    bakeIn: bakeOpts,
                    frameStride: 1,
                    progress: { f in DispatchQueue.main.async { writeProgress = f } }
                )
                DispatchQueue.main.async {
                    writing = false
                    lastResult = "Written: \(outURL.lastPathComponent) — review in preview window"
                    // Same as SER export: open the Export Preview
                    // window for Keep / Discard, don't auto-switch
                    // the main preview off the source.
                    app.exportPreviewURL = outURL
                    openWindow(id: "export-preview")
                }
            } catch {
                DispatchQueue.main.async {
                    writing = false
                    lastResult = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
