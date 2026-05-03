// Welcome / splash screen shown at app launch.
//
// Single-shot informational sheet — surfaces the brand identity, the
// version + tagline, links to AstroBin (real example output) and the
// repo, and a "don't show again" checkbox so power users can suppress
// it after the first run. Never blocking: the user sees and dismisses
// in <2 s.
//
// Pattern mirrors the AstroTriage / AstroBlink splash the user
// references in their CLAUDE.md preferences. Pure SwiftUI; no asset-
// catalog dependency.
import AppKit
import SwiftUI

struct SplashView: View {
    let onDismiss: () -> Void

    @StateObject private var launchTracker = LaunchTracker.shared
    @State private var dontShowAgain: Bool = false

    var body: some View {
        VStack(spacing: 18) {
            header
            Divider()
            featureList
            Divider()
            footer
            actionRow
            creditLine
        }
        .padding(28)
        .frame(width: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            BrandMark()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("AstroSharper")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppPalette.brandGradient)
                    Text(AppVersion.shortString)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text("Lucky imaging helper for macOS")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Stack, sharpen and tone-tune planetary, lunar and solar SER captures — natively, on Apple Silicon.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer()
        }
    }

    /// Three-bullet "what makes this different" list — keeps the
    /// splash informative without becoming a wall of text. Picked
    /// from the actual differentiators (AutoNuke + AutoAP, Mac-
    /// native Metal pipeline, no plate-scale guessing).
    private var featureList: some View {
        VStack(alignment: .leading, spacing: 8) {
            featureRow(icon: "wand.and.stars",
                       title: "AutoNuke",
                       body: "One toggle: auto-PSF, auto-keep-%, AP grid + multi-AP gate all picked per data. Beats hand-tuned presets on every fixture in our regression set.")
            featureRow(icon: "cpu",
                       title: "Native Metal pipeline",
                       body: "Built for Apple Silicon. Streaming SER reader, GPU stacking, FFT phase correlation — no Wine, no Boot Camp.")
            featureRow(icon: "scope",
                       title: "Knows your target",
                       body: "Filename keyword detection routes Sun / Moon / Jupiter / Saturn / Mars to the right preset. Switch any time via the chip row in the header.")
        }
    }

    private func featureRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppPalette.accent)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(body)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button {
                NSWorkspace.shared.open(AppLinks.astrobinProfile)
            } label: {
                Label("Example images on AstroBin", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)

            Button {
                NSWorkspace.shared.open(AppLinks.github)
            } label: {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)

            Spacer()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Toggle("Don't show this again", isOn: $dontShowAgain)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Re-open later from the Help menu.")
            Spacer()
            Button("Continue") {
                launchTracker.setSplashSuppressed(dontShowAgain)
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Author credit — small, bottom-aligned. Click opens AstroBin
    /// profile. Acts as both attribution and a route to the author's
    /// real imaging output.
    private var creditLine: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Created by")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Button {
                NSWorkspace.shared.open(AppLinks.astrobinProfile)
            } label: {
                Text("joergsflow")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppPalette.brandGradient)
            }
            .buttonStyle(.plain)
            .help("Opens joergsflow's AstroBin gallery.")
            Spacer()
        }
    }
}
