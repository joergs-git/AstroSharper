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
                Text("Recommend: keep top \(Int(d.recommendedKeepFraction * 100))%")
                    .fontWeight(.semibold)
                    .foregroundColor(.yellow)
                Text(d.recommendationText)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .leading)
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
}
