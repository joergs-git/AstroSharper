// Bottom-left translucent overlay on the preview. Shows file metadata,
// current/total frame, sharpness for the displayed frame and — for SERs —
// a sampled sharpness distribution plus a lucky-stack "keep top N%"
// recommendation derived from the spread of that distribution.
//
// Toggle visibility from AppModel.hudVisible (keyboard shortcut "i").
import SwiftUI

struct PreviewStatsHUD: View {
    let stats: PreviewStats
    /// Invoked when the user clicks "Calculate Video Quality". Optional —
    /// when nil, the button is hidden (e.g. for static-image previews).
    var onCalculateVideoQuality: (() -> Void)? = nil
    /// True while a scan is running — HUD shows a spinner instead of the
    /// button so the user gets immediate feedback that the click landed.
    var isScanning: Bool = false
    /// A.5 v1 — chronological per-frame XY shifts from the most recent
    /// stabilizer run. nil before any Stabilize has completed; the HUD
    /// hides the sparkline row in that case.
    var stabilizerShifts: [SIMD2<Float>]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // First line — filename + dims/depth.
            HStack(spacing: 6) {
                Image(systemName: stats.totalFrames > 1 ? "film" : "photo")
                    .foregroundColor(.secondary)
                Text(stats.fileName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            metaLine
            if stats.totalFrames > 1 {
                Text("Frame \(stats.currentFrame)/\(stats.totalFrames)")
                    .foregroundColor(.secondary)
            }
            if let s = stats.currentSharpness {
                HStack(spacing: 4) {
                    Image(systemName: "scope").foregroundColor(.secondary)
                    Text("Sharpness: \(formatSharpness(s))")
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .help("Variance of the Laplacian. Higher = more high-frequency detail (sharper). Compare values within the same target — absolute numbers depend on contrast and exposure.")
                }
            }
            // E.4 capture-validator warnings — non-modal yellow chips so
            // the user catches a suboptimal capture (long exposure, 8-bit
            // on lunar/solar, derotation needed, …) before they spend
            // 10 minutes stacking it.
            if !stats.captureWarnings.isEmpty {
                Divider().background(Color.white.opacity(0.15)).padding(.vertical, 2)
                ForEach(stats.captureWarnings, id: \.code) { w in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: w.severity == .warning
                              ? "exclamationmark.triangle.fill"
                              : "info.circle.fill")
                            .foregroundColor(w.severity == .warning ? .yellow : .blue)
                            .font(.system(size: 10))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.message)
                                .foregroundColor(w.severity == .warning ? .yellow : .white)
                                .fixedSize(horizontal: false, vertical: true)
                            if let s = w.suggestion {
                                Text(s)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                }
            }
            if let d = stats.distribution {
                Divider().background(Color.white.opacity(0.15)).padding(.vertical, 2)
                Text("Sampled \(d.sampleCount) frames")
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Text("p10:").foregroundColor(.secondary)
                    Text(formatSharpness(d.p10))
                    Text("med:").foregroundColor(.secondary)
                    Text(formatSharpness(d.median))
                    Text("p90:").foregroundColor(.secondary)
                    Text(formatSharpness(d.p90))
                }
                .font(.system(size: 10, design: .monospaced))
                if let j = d.jitterRMS {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.secondary)
                        Text("Jitter: \(String(format: "%.1f", j)) px RMS")
                            .help("Root-mean-square frame-to-frame shift (phase correlation between adjacent samples). Higher = more atmospheric motion to register.")
                    }
                }
                // A.5 — median half-flux radius across the sampled
                // frames. Lower = sharper (more concentrated PSF).
                // Same row style as Jitter for visual consistency.
                if let h = d.medianHFR {
                    HStack(spacing: 4) {
                        Image(systemName: "scope")
                            .foregroundColor(.secondary)
                        Text("HFR: \(String(format: "%.2f", h)) px")
                            .help("Median half-flux radius across sampled frames. The radius around the brightness centroid that contains 50% of the total flux. Lower = sharper / more concentrated PSF. Compare values within the same target — absolute numbers depend on subject brightness profile.")
                    }
                }
                Text("Recommend: keep top \(Int(d.recommendedKeepFraction * 100))% (\(d.recommendedKeepCount) of \(d.totalFrames))")
                    .fontWeight(.semibold)
                    .foregroundColor(.yellow)
                Text(d.recommendationText)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: 320, alignment: .leading)
            } else if stats.totalFrames > 1 {
                // Distribution not yet computed for this video. Offer an
                // explicit "Calculate Video Quality" button instead of
                // auto-scanning every SER the user clicks. While scanning,
                // swap to a spinner so the click obviously registered —
                // the scan takes 3-5 s and silent UI looked broken.
                Divider().background(Color.white.opacity(0.15)).padding(.vertical, 2)
                if isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.yellow)
                        Text("Scanning frames…")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Video quality not yet calculated.")
                        .foregroundColor(.secondary)
                    if let onCalc = onCalculateVideoQuality {
                        Button("Calculate Video Quality") { onCalc() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.yellow)
                            .help("Sample up to 64 frames, measure sharpness + jitter, and recommend a lucky-stack keep-percentage. Result is cached on disk so re-opens are instant.")
                    } else {
                        Text("Quality scan available for SER files only (AVI scan coming soon).")
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
            }
            // A.5 v1 — XY-shift sparkline. Renders the chronological
            // per-frame alignment magnitudes from the most recent
            // Stabilize run as a tiny line graph. Hidden until at
            // least one Stabilize has completed (or when only one
            // frame's worth of data is available — the sparkline
            // needs at least two points to draw a segment).
            if let shifts = stabilizerShifts, shifts.count >= 2 {
                Divider().background(Color.white.opacity(0.15)).padding(.vertical, 2)
                HStack(spacing: 6) {
                    Image(systemName: "scribble.variable")
                        .foregroundColor(.secondary)
                    Text("Drift")
                        .foregroundColor(.secondary)
                    XYShiftSparkline(shifts: shifts)
                        .frame(width: 100, height: 14)
                    Text(Self.formatPeakShift(shifts))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .help("Per-frame XY-shift magnitude (px) from the most recent Stabilize run. Sparkline shows chronological order across the kept frames; the trailing number is the peak. Higher peak = more atmospheric drift the registration had to absorb.")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(12)
    }

    private var metaLine: some View {
        let bits: [String] = {
            var out: [String] = []
            if let dim = stats.dimensions {
                out.append("\(dim.width)×\(dim.height)")
            }
            if let bd = stats.bitDepth { out.append("\(bd)-bit") }
            if let bayer = stats.bayerLabel { out.append(bayer) }
            out.append(formatBytes(stats.fileSizeBytes))
            if let date = stats.captureDate {
                out.append(Self.dateFormatter.string(from: date))
            }
            return out
        }()
        return Text(bits.joined(separator: " · "))
            .foregroundColor(.secondary)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    /// Show small sharpness numbers in scientific or fixed notation depending
    /// on magnitude. Variance-of-Laplacian on normalised float textures is
    /// typically in the 1e-5…1e-1 range.
    private func formatSharpness(_ v: Float) -> String {
        if !v.isFinite { return "—" }
        let av = abs(v)
        if av == 0 { return "0" }
        if av < 0.001 || av >= 1000 {
            return String(format: "%.2e", v)
        }
        return String(format: "%.4f", v)
    }

    /// Peak shift magnitude across the chronological shift sequence —
    /// renders alongside the sparkline so the user gets one number for
    /// "how bad was the worst frame" without reading the chart.
    fileprivate static func formatPeakShift(_ shifts: [SIMD2<Float>]) -> String {
        let peak = shifts.map { sqrtf($0.x * $0.x + $0.y * $0.y) }.max() ?? 0
        return String(format: "%.1f px", peak)
    }
}

// MARK: - XY-shift sparkline (A.5 v1)

/// Compact line plot of the shift magnitudes (sqrt(dx² + dy²)) across
/// the kept frames. Auto-scales y to the peak so the visual range is
/// always [0 … peak] regardless of capture quality. Drawn entirely in
/// Path math — no animation, no caching needed for the typical
/// 50…1000-point series.
struct XYShiftSparkline: View {
    let shifts: [SIMD2<Float>]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { path in
                    let mags = shifts.map { sqrtf($0.x * $0.x + $0.y * $0.y) }
                    let peak = max(mags.max() ?? 1, 0.5)   // floor avoids divide-by-tiny
                    let n = max(mags.count, 2)
                    let stepX = geo.size.width / CGFloat(n - 1)
                    for (i, m) in mags.enumerated() {
                        let x = stepX * CGFloat(i)
                        let y = geo.size.height * (1.0 - CGFloat(m / peak))
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.yellow.opacity(0.85), lineWidth: 1)
            }
        }
    }
}
