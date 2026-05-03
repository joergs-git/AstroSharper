// Bottom status bar: selection counter, job progress, ready/error message,
// plus the active folder path on the right at slightly larger type — moved
// down here from the toolbar so the top chrome stays compact.
import SwiftUI

struct StatusBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(countsLabel)
                .font(.system(size: 11, design: .monospaced))

            Divider().frame(height: 14)

            // Active section's folder path. Larger than the rest of the
            // status bar so it's actually readable when paths get long.
            if let pathText = activePathText {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(AppPalette.accent)
                Text(pathText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(pathText)
                Divider().frame(height: 14)
            }

            switch app.jobStatus {
            case .idle:
                Text(readyMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            case .running(let processed, let total):
                // Wider + bolder progress bar so it actually reads at
                // a glance during a stacking run. Tinted with the app
                // accent so it pops against the underPageBackground.
                // `max(total, 1)` is the SwiftUI/AppKit-ProgressView
                // safety guard — passing total=0 triggers the
                // "PlatformViewHost ... AppKitProgressView ... maximum
                // length doesn't satisfy min <= max" runtime assertion
                // when the engine briefly emits .running(0, 0) at
                // stage transitions. Same guard the PreviewView job
                // overlay uses.
                HStack(spacing: 8) {
                    ProgressView(
                        value: Double(processed),
                        total: Double(max(total, 1))
                    )
                    .progressViewStyle(.linear)
                    .frame(width: 260, height: 6)
                    .tint(AppPalette.accent)
                    Text("\(processed)/\(total)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(AppPalette.accent)
                }
            case .done(let n, let dir):
                HStack(spacing: 6) {
                    Label("\(n) processed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    .controlSize(.mini)
                }
            case .error(let msg):
                HStack(spacing: 6) {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    Button("Dismiss") { app.clearStaleError() }
                        .controlSize(.mini)
                }
            }

            Spacer()

            if app.sharpen.enabled || app.stabilize.enabled || app.toneCurve.enabled {
                Text(activeOps)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Divider().frame(height: 14)
            }

            // Bottom-bar opt-out icons (AstroBlink pattern). iCloud
            // sync is informational only (preset sync via PresetManager
            // happens automatically). Telemetry + community share are
            // user-toggleable: green when active, grey when off.
            iCloudIcon
            telemetryIcon
            communityIcon
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    /// iCloud preset sync — informational. Always-on by design (no
    /// toggle); icon dims when there's no iCloud account on the
    /// machine. macOS surfaces the no-account state via
    /// `FileManager.ubiquityIdentityToken == nil`.
    private var iCloudIcon: some View {
        let active = FileManager.default.ubiquityIdentityToken != nil
        return Image(systemName: active ? "icloud.fill" : "icloud.slash")
            .font(.system(size: 12))
            .foregroundColor(active ? .green : .secondary)
            .opacity(active ? 1.0 : 0.5)
            .help(active
                  ? "iCloud sync active — your saved presets sync between Macs."
                  : "iCloud unavailable — presets stay local on this Mac.")
    }

    /// Anonymous telemetry toggle. Default ON. Click to flip.
    /// Sends only the random machine UUID + AutoAP / AutoPSF stats
    /// per stack — no personal data, no filenames, no hostnames.
    private var telemetryIcon: some View {
        Button {
            app.setTelemetryEnabled(!app.telemetryEnabled)
        } label: {
            Image(systemName: app.telemetryEnabled
                  ? "chart.bar.doc.horizontal.fill"
                  : "chart.bar.doc.horizontal")
                .font(.system(size: 12))
                .foregroundColor(app.telemetryEnabled ? .green : .secondary)
                .opacity(app.telemetryEnabled ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .help(app.telemetryEnabled
              ? "Anonymous telemetry: ON. Each stack sends a random per-machine UUID + AutoAP / AutoPSF parameters so the engine's defaults can converge on what works empirically across the user fleet. No filenames, no hostnames, no personal data. Click to disable."
              : "Anonymous telemetry: OFF. Click to enable — helps tune AutoAP defaults across the user fleet.")
    }

    /// Community thumbnail share toggle. Default ON. Click to flip.
    /// When ON, after each successful stack the user is asked once
    /// whether to upload a downscaled JPEG thumbnail + minimal
    /// metadata to the community feed.
    private var communityIcon: some View {
        Button {
            app.setCommunityShareEnabled(!app.communityShareEnabled)
        } label: {
            Image(systemName: app.communityShareEnabled
                  ? "person.2.fill"
                  : "person.2.slash")
                .font(.system(size: 12))
                .foregroundColor(app.communityShareEnabled ? .green : .secondary)
                .opacity(app.communityShareEnabled ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .help(app.communityShareEnabled
              ? "Community share: ON. After each successful stack you'll be asked whether to upload a thumbnail + minimal metadata (target / frame count / random per-machine UUID) to the community feed. Per-stack opt-in stays granular. Click to disable globally."
              : "Community share: OFF. Click to enable — your stacks can appear in the public community feed of recent captures.")
    }

    private var activePathText: String? {
        if app.displayedSection == .outputs, let url = app.outputsRootURL {
            return url.path
        }
        if let url = app.catalog.rootURL { return url.path }
        return nil
    }

    private var countsLabel: String {
        let total = app.catalog.files.count
        if app.markedCount > 0 { return "\(app.markedCount) marked · \(total) files" }
        return "\(app.selectionCount)/\(total) selected"
    }

    private var readyMessage: String {
        if app.catalog.files.isEmpty { return "Open a folder to begin" }
        if app.batchTargetIDs.isEmpty { return "Select or mark files, press ⌘R" }
        return "Ready — ⌘R to apply"
    }

    private var activeOps: String {
        var parts: [String] = []
        if app.sharpen.enabled { parts.append("Sharpen") }
        if app.stabilize.enabled { parts.append("Stabilize") }
        if app.toneCurve.enabled { parts.append("Tone") }
        return parts.joined(separator: " · ")
    }
}
