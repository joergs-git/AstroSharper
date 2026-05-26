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
    @State private var format: SerExportFormat = .ser
    @State private var fps: Int = 30
    @State private var targetFrames: Int = 60     // GIF only
    @State private var cropX: Double = 0
    @State private var cropY: Double = 0
    @State private var cropW: Double = 1.0
    @State private var cropH: Double = 1.0
    @State private var writing: Bool = false
    @State private var writeProgress: Double = 0
    @State private var lastResult: String? = nil
    /// When true, every exported frame is run through the current
    /// Sharpen + Tone chain before write. SER bake-in re-types the
    /// output as 16-bit RGB and breaks scientific linearity (use only
    /// for showcase/replay). GIF bake-in is WYSIWYG against the live
    /// preview.
    @State private var bakeInProcessing: Bool = false
    /// 1 = full-res, 2 = ½×½, 4, 8, 16. Shrinks output WxH by the
    /// divisor on the GPU during bake-in. Resize > 1 implicitly
    /// requires bake-in (the resize happens inside the GPU pipeline
    /// pass), so toggling it auto-enables `bakeInProcessing`.
    @State private var resizeDivisor: Int = 1
    /// 0 / 90 / 180 / 270 — clockwise rotation of every exported
    /// frame. Default 0 (no rotation). Non-zero forces bake-in
    /// (rotation happens after the GPU pipeline pass so we always
    /// have demosaiced RGB to rotate).
    @State private var rotationDegrees: Int = 0

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
            Picker("Format", selection: $format) {
                ForEach(SerExportFormat.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            if format == .gif {
                LabeledSlider(label: "FPS",
                              value: Binding(get: { Double(fps) }, set: { fps = Int($0) }),
                              range: 5...60, format: "%.0f")
                LabeledSlider(label: "Frames",
                              value: Binding(get: { Double(targetFrames) }, set: { targetFrames = Int($0) }),
                              range: 10...600, format: "%.0f")
                Text(estimateGIFLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text(estimateSERLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 2)
            HStack {
                Text("Resize")
                    .font(.system(size: 11))
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: $resizeDivisor) {
                    Text("1:1").tag(1)
                    Text("1:2").tag(2)
                    Text("1:4").tag(4)
                    Text("1:8").tag(8)
                    Text("1:16").tag(16)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .help("Downsample the output by this factor on the GPU after Sharpen + Tone. 1:2 = ½×½ (¼ the area). Requires Bake-in.")
                if resizeDivisor > 1 {
                    Text(resizedDimensionLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Rotate")
                    .font(.system(size: 11))
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: $rotationDegrees) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .help("Clockwise rotation applied to every exported frame. 90° / 270° swap width and height. Requires Bake-in.")
                if rotationDegrees != 0 {
                    Image(systemName: "rotate.right.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Toggle("Bake in Sharpen + Tone", isOn: $bakeInProcessing)
                .font(.system(size: 11))
                .disabled(resizeDivisor > 1 || rotationDegrees != 0)
                .onChange(of: resizeDivisor) { _, new in
                    if new > 1 { bakeInProcessing = true }
                }
                .onChange(of: rotationDegrees) { _, new in
                    if new != 0 { bakeInProcessing = true }
                }
                .help("Run every exported frame through the current Sharpen + Tone settings (what the live preview shows). Off = raw frame bytes. Auto-enabled when Resize or Rotate are non-default.")
            if bakeInProcessing {
                Text(format == .ser
                     ? "⚠︎ Output .ser will be 16-bit RGB and no longer scientifically linear. Use only for replay / showcase, NOT for re-stacking."
                     : "GIF will exactly match the live preview.")
                    .font(.system(size: 10))
                    .foregroundColor(format == .ser ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var resizedDimensionLabel: String {
        guard let dims = sourceDims else { return "" }
        let w = (app.serCropRect?.width).map(Double.init)  ?? dims.w
        let h = (app.serCropRect?.height).map(Double.init) ?? dims.h
        let dw = max(2, Int(w) / resizeDivisor)
        let dh = max(2, Int(h) / resizeDivisor)
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

    private var estimateSERLabel: String {
        guard let dims = sourceDims else { return "" }
        let w = (app.serCropRect?.width).map(Double.init)  ?? dims.w
        let h = (app.serCropRect?.height).map(Double.init) ?? dims.h
        // bit depth heuristic: SER source is 8 or 16-bit / channel.
        // Conservative estimate at 16-bit mono = 2 B/px; OSC bayer
        // 8-bit = 1 B/px. We use 16-bit to be safe on size estimate.
        let bytes = Int(w * h * 2.0) * trimFrameCount + 178
        return "≈ \(formatBytes(bytes)) (16-bit mono est.)"
    }

    private var estimateGIFLabel: String {
        guard let dims = sourceDims else { return "" }
        let w = (app.serCropRect?.width).map(Double.init)  ?? dims.w
        let h = (app.serCropRect?.height).map(Double.init) ?? dims.h
        // Animated GIF: ~0.5 B/px after LZW, conservative. Frame
        // count = min(targetFrames, trimFrameCount).
        let frames = min(targetFrames, trimFrameCount)
        let bytes = Int(w * h * 0.5) * frames + 1024
        return "≈ \(formatBytes(bytes)) · \(frames) frames @ \(fps) fps = \(String(format: "%.1f", Double(frames) / Double(fps)))s"
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
        switch format {
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
        let suffix = bakeInProcessing ? "_baked" : ""
        let fname = String(format: "%@_trim_%d-%d%@.ser", base, trimStart, trimEnd, suffix)
        let outURL = AppModel.uniqueOutputURL(outFolder.appendingPathComponent(fname))
        let bakeOpts: BakeInExporter.Options? = bakeInProcessing
            ? BakeInExporter.Options(
                sharpen: app.sharpen,
                toneCurve: app.toneCurve,
                outputBitDepth: 16,
                resizeDivisor: resizeDivisor,
                rotationDegrees: rotationDegrees
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
        let suffix = bakeInProcessing ? "_baked" : ""
        let fname = String(format: "%@_%d-%d_%dfps%@.gif", base, trimStart, trimEnd, fps, suffix)
        let outURL = AppModel.uniqueOutputURL(outFolder.appendingPathComponent(fname))
        let captureFPS = fps
        let captureTarget = targetFrames
        let bakeOpts: BakeInExporter.Options? = bakeInProcessing
            ? BakeInExporter.Options(
                sharpen: app.sharpen,
                toneCurve: app.toneCurve,
                outputBitDepth: 8,
                resizeDivisor: resizeDivisor,
                rotationDegrees: rotationDegrees
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
