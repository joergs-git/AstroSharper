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
    case ser = "SER"
    case gif = "Animated GIF"
    var id: String { rawValue }
}

struct SerExportPanel: View {
    @EnvironmentObject private var app: AppModel
    // Crop %s remain @State — they're a pure UI mirror of the source-
    // pixel `app.serCropRect` and get re-synced from it on appear.
    @State private var cropX: Double = 0
    @State private var cropY: Double = 0
    @State private var cropW: Double = 1.0
    @State private var cropH: Double = 1.0
    @State private var writing: Bool = false
    @State private var writeProgress: Double = 0
    @State private var lastResult: String? = nil
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
            LabeledSlider(label: "Width  %",  value: $cropW, range: 0.1...1.0, format: "%.2f")
                .onChange(of: cropW) { _, _ in updateCropRect() }
            LabeledSlider(label: "Height %",  value: $cropH, range: 0.1...1.0, format: "%.2f")
                .onChange(of: cropH) { _, _ in updateCropRect() }
            LabeledSlider(label: "Pos X  %",  value: $cropX, range: 0...1.0, format: "%.2f")
                .onChange(of: cropX) { _, _ in updateCropRect() }
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
            if app.serExportFormat == .gif {
                // FPS — discrete picker (1, 2, 5, 10, 15, 20, 24, 30, 60).
                // Continuous sliders for fps invite weird values like
                // "37 fps" that no playback target wants. Discrete picker
                // covers the common targets (1=time-lapse, 10=cinematic,
                // 24=film, 30=display, 60=smooth).
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
                }
                // Frames target — full range 2 ... trim length. User
                // had to live with 10...600 before; the GIF writer
                // already evenly sub-samples to whatever target lands
                // here.
                LabeledSlider(label: "Frames",
                              value: Binding(get: { Double(app.serExportTargetFrames) }, set: { app.serExportTargetFrames = Int($0) }),
                              range: 2 ... Double(max(2, trimFrameCount)),
                              format: "%.0f")
                Text(estimateGIFLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text(estimateSERLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            // Frame stride — applies to BOTH formats. Cheap way to
            // shrink output size when source has more frames than
            // necessary. Stride 2 = every other frame, etc.
            HStack {
                Text("Stride")
                    .font(.system(size: 11))
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: $app.serExportFrameStride) {
                    Text("1 (all)").tag(1)
                    Text("every 2nd").tag(2)
                    Text("every 3rd").tag(3)
                    Text("every 5th").tag(5)
                    Text("every 10th").tag(10)
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                if app.serExportFrameStride > 1 {
                    Text("\(strideEffectiveFrameCount) frames out")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .help("Subsample the trim range — write every Nth source frame. Reduces output file size by 1/N. Works for SER and GIF.")

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
                .disabled(app.serExportResizeDivisor > 1 || app.serExportRotationDegrees != 0)
                .help("Run every exported frame through the current Sharpen + Tone settings (what the live preview shows). Off = raw frame bytes. Auto-enabled at Export time when Resize or Rotate are non-default.")
            if effectiveBakeIn {
                Text(app.serExportFormat == .ser
                     ? "⚠︎ Output .ser will be 16-bit RGB and no longer scientifically linear. Use only for replay / showcase, NOT for re-stacking."
                     : "GIF will exactly match the live preview.")
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
        app.serExportRotationDegrees != 0
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
        let frames = strideEffectiveFrameCount
        let bytes = Int(w * h * bpp) * frames + 178
        let what = bakedOn ? "16-bit RGB baked" : "16-bit mono est."
        return "≈ \(formatBytes(bytes)) · \(frames) frames · \(Int(w))×\(Int(h)) · \(what)"
    }

    private var estimateGIFLabel: String {
        guard let dims = sourceDims else { return "" }
        let cropW = (app.serCropRect?.width).map(Double.init)  ?? dims.w
        let cropH = (app.serCropRect?.height).map(Double.init) ?? dims.h
        let div = max(1, Double(app.serExportResizeDivisor))
        let w = max(2.0, cropW / div)
        let h = max(2.0, cropH / div)
        // Animated GIF: ~0.5 B/px after LZW, conservative. Effective
        // frame count = min(targetFrames, strided frame count).
        let stridedCount = strideEffectiveFrameCount
        let frames = min(app.serExportTargetFrames, stridedCount)
        let bytes = Int(w * h * 0.5) * frames + 1024
        let secs = Double(frames) / Double(max(1, app.serExportFPS))
        return "≈ \(formatBytes(bytes)) · \(frames) frames · \(Int(w))×\(Int(h)) @ \(app.serExportFPS) fps = \(String(format: "%.1f", secs))s"
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
        switch app.serExportFormat {
        case .ser: runSerExport()
        case .gif: runGifExport()
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
        let fname = String(format: "%@_trim_%d-%d%@.ser", base, trimStart, trimEnd, suffix)
        let outURL = AppModel.uniqueOutputURL(outFolder.appendingPathComponent(fname))
        let bakeOpts: BakeInExporter.Options? = app.serExportBakeIn
            ? BakeInExporter.Options(
                sharpen: app.sharpen,
                toneCurve: app.toneCurve,
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
                    frameStride: app.serExportFrameStride,
                    progress: { f in DispatchQueue.main.async { writeProgress = f } }
                )
                DispatchQueue.main.async {
                    writing = false
                    lastResult = "Saved \(outURL.lastPathComponent)"
                    app.registerOutput(url: outURL, autoSwitch: true)
                    app.highlightLatestOutput(url: outURL)
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
        let fname = String(format: "%@_%d-%d_%dfps%@.gif", base, trimStart, trimEnd, app.serExportFPS, suffix)
        let outURL = AppModel.uniqueOutputURL(outFolder.appendingPathComponent(fname))
        let captureFPS = app.serExportFPS
        let captureTarget = app.serExportTargetFrames
        let bakeOpts: BakeInExporter.Options? = app.serExportBakeIn
            ? BakeInExporter.Options(
                sharpen: app.sharpen,
                toneCurve: app.toneCurve,
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
                    targetFrameCount: captureTarget,
                    fps: captureFPS,
                    crop: crop,
                    bakeIn: bakeOpts,
                    frameStride: app.serExportFrameStride,
                    progress: { f in DispatchQueue.main.async { writeProgress = f } }
                )
                DispatchQueue.main.async {
                    writing = false
                    lastResult = "Saved \(outURL.lastPathComponent)"
                    app.registerOutput(url: outURL, autoSwitch: true)
                    app.highlightLatestOutput(url: outURL)
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
