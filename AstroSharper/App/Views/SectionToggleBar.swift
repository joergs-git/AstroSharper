// Inputs / Outputs section toggle that sits directly above the file list.
// Two clearly-labelled toggle buttons with file counts so the user always
// sees at a glance which side they're on and what each section contains.
import AppKit
import SwiftUI

struct SectionToggleBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 6) {
            SectionToggleButton(
                section: .inputs,
                title: "Inputs",
                icon: "tray.full.fill",
                count: app.inputsFileCount,
                isActive: app.displayedSection == .inputs,
                tooltip: "Source files you opened (⌘O / drag-and-drop). The Lucky-Stack and Apply-to-Selection actions read from here."
            ) {
                app.switchToSection(.inputs)
            }

            SectionToggleButton(
                section: .memory,
                title: "Memory",
                icon: "memorychip.fill",
                count: app.memoryFileCount,
                isActive: app.displayedSection == .memory,
                tooltip: "Aligned frames currently held in RAM (e.g. from Run Stabilize). Scrub through them with the player; click Save All when satisfied to commit them to OUTPUTS."
            ) {
                app.switchToSection(.memory)
            }

            SectionToggleButton(
                section: .outputs,
                title: "Outputs",
                icon: "tray.and.arrow.down.fill",
                count: app.outputsFileCount,
                isActive: app.displayedSection == .outputs,
                tooltip: "Files this app has written (stacked TIFFs, processed exports). Marked / selected files here can be re-processed via Apply-to-Selection."
            ) {
                app.switchToSection(.outputs)
            }

            Divider().frame(height: 14).padding(.horizontal, 4)

            // Active section's path readout — confirms what you're looking at.
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(activePathLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(app.catalog.rootURL?.path ?? "no folder")
            }

            Spacer()

            // Memory-tab actions: save all to disk.
            if app.displayedSection == .memory && app.memoryFileCount > 0 {
                Button {
                    app.saveMemoryFramesToDisk()
                } label: {
                    Label("Save All to Disk", systemImage: "tray.and.arrow.down")
                }
                .controlSize(.small)
                .help("Write all in-memory aligned frames to <output>/stabilized/ and switch to OUTPUTS.")
            }

            // Right-side action icons (only relevant when on Outputs).
            if app.displayedSection == .outputs {
                Button {
                    refreshOutputs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("Re-scan the output folder for new files (e.g. created by another app).")

                if let url = app.outputsRootURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help("Reveal the output folder in Finder.")
                }
            }

            Toggle(isOn: $app.autoDetectPresetOnOpen) {
                Image(systemName: "wand.and.stars")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Smart preset auto-detection: when ON, opening a folder named e.g. 'Sun', 'Jupiter' or 'Moon' picks the matching built-in preset for you.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private var activePathLabel: String {
        if let url = app.catalog.rootURL { return url.path }
        return app.displayedSection == .inputs ? "no folder opened — ⌘O" : "no outputs yet"
    }

    private func refreshOutputs() {
        guard let root = app.outputsRootURL else { return }
        app.catalog.load(from: root)
        app.previewFileID = app.catalog.files.first?.id
    }
}

// MARK: - Single toggle pill

private struct SectionToggleButton: View {
    let section: CatalogSection
    let title: String
    let icon: String
    let count: Int
    let isActive: Bool
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                Text("(\(count))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.20) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isActive ? 1.5 : 0.5)
            )
            .foregroundColor(isActive ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
