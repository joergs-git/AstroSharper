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
                HStack(spacing: 6) {
                    ProgressView(value: Double(processed), total: Double(total))
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                    Text("\(processed)/\(total)")
                        .font(.system(size: 11, design: .monospaced))
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
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.underPageBackgroundColor))
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
