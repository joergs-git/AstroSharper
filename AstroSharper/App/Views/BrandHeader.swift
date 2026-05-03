// Top-of-window brand strip: logo mark + product name + tagline + target
// picker. The picker auto-highlights the target detected (by filename
// keywords) for the currently-previewed SER, syncing live as the user
// scrolls files. Clicking any target applies that target's first
// built-in preset — useful when the auto-detect missed.
import SwiftUI

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            // Brand identity (left) — compact: small mark + single-
            // line title (the "Lucky imaging helper for macOS"
            // tagline lives on the splash screen and was eating
            // bar height for no real value).
            HStack(spacing: 8) {
                BrandMark()
                    .frame(width: 22, height: 22)
                Text("AstroSharper")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppPalette.brandGradient)
                Text(AppVersion.shortString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .frame(width: 260, height: 44, alignment: .leading)

            Spacer(minLength: 12)

            // Target picker — geometrically centered. The two flanking
            // Spacers + the fixed-width brand block on the left make
            // the picker land in the middle of the window regardless
            // of window width.
            TargetPickerRow()

            Spacer(minLength: 12)

            // Right-side balancer matches the brand block's width so
            // the picker stays visually centered. Two violet pills
            // sit trailing-aligned within it: Howto + Community.
            // Both two-line labels so they can be a bit taller and
            // more visible without dominating the bar.
            HStack(spacing: 8) {
                Spacer()
                howtoButton
                communityButton
            }
            .frame(width: 260, height: 46)
        }
        // Hard height so the bar can't grow regardless of child
        // intrinsics. Bumped 50→54pt 2026-05-03 to fit the two-line
        // Howto + Community pills with breathing room.
        .frame(height: 54)
        .padding(.horizontal, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// Howto button — moved here from the secondary toolbar 2026-05-03.
    /// Same violet pill styling as Community for visual cohesion.
    private var howtoButton: some View {
        Button {
            NotificationCenter.default.post(name: .openHowto, object: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Howto")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text("workflow guide")
                        .font(.system(size: 9, weight: .medium))
                        .opacity(0.85)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.34, blue: 0.92),
                    Color(red: 0.40, green: 0.20, blue: 0.78),
                ],
                startPoint: .leading, endPoint: .trailing
            ))
        )
        .help("Open the workflow guide in a movable, non-blocking window — keep it on screen while you work.")
    }

    /// Community button — two-line label (2026-05-03) so the meaning is
    /// clearer than just "Community". Same NotificationCenter trigger
    /// as before, no URL-scheme fallback (would cause the macOS
    /// "no app handles this URL" dialog).
    private var communityButton: some View {
        Button {
            NotificationCenter.default.post(name: .openCommunityFeed, object: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Community")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text("stacked thumbs")
                        .font(.system(size: 9, weight: .medium))
                        .opacity(0.85)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.34, blue: 0.92),
                    Color(red: 0.40, green: 0.20, blue: 0.78),
                ],
                startPoint: .leading, endPoint: .trailing
            ))
        )
        .help("Show other peoples' stack thumbnails — opens the Community Stacks window.")
    }
}

// MARK: - Target picker

/// Row of 6 target chips (Sun, Moon, Jupiter, Saturn, Mars, Other).
/// The chip matching the currently-active preset's target is rendered
/// in colour with an accent border; the others drop to 50% opacity
/// grey. Clicking any chip applies that target's first built-in
/// preset (which switches the highlight). Scrolling the file list
/// auto-detects the new file's target from filename keywords and
/// applies its preset — keeps the picker in sync as the user moves
/// between captures.
struct TargetPickerRow: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PresetTarget.allCases) { target in
                TargetChip(target: target, highlighted: highlightedTarget)
            }
        }
        .onChange(of: app.previewFileID) { _, _ in
            // File-change auto-detect: when the user scrolls / clicks
            // a different SER, re-run the keyword detect on the new
            // file's name + parent folder. If a target matches AND
            // it's different from the currently-active preset, swap
            // to that target's first built-in preset so the picker
            // stays in sync with what's being processed.
            applyPresetForCurrentFile()
        }
    }

    /// Active preset's target — the chip the user clicked OR the
    /// preset auto-applied for the current file. Falls back to the
    /// filename detection when no preset is active yet.
    private var highlightedTarget: PresetTarget? {
        if let activeID = app.presets.activeID,
           let active = app.presets.preset(withID: activeID) {
            return active.target
        }
        return detectedTargetForCurrentFile()
    }

    /// Run keyword detection on the current preview file's name +
    /// parent folder. Returns nil when there's no preview file or
    /// no keyword match.
    private func detectedTargetForCurrentFile() -> PresetTarget? {
        guard let id = app.previewFileID,
              let file = app.catalog.files.first(where: { $0.id == id })
        else { return nil }
        let candidates = [
            file.url.lastPathComponent,
            file.url.deletingLastPathComponent().lastPathComponent
        ]
        return PresetAutoDetect.detect(in: candidates)
    }

    /// Auto-apply the matching preset for the current file, but only
    /// when the detected target differs from the currently-active
    /// preset's target (so we don't clobber the user's tuning every
    /// time SwiftUI re-renders).
    private func applyPresetForCurrentFile() {
        guard let detected = detectedTargetForCurrentFile() else { return }
        let activeTarget = app.presets.activeID
            .flatMap { app.presets.preset(withID: $0) }?.target
        guard activeTarget != detected else { return }
        if let preset = app.presets.builtIn.first(where: { $0.target == detected }) {
            app.applyPreset(preset)
            app.luckyStack.winjuposTarget = preset.target.rawValue
        }
    }
}

/// One target chip: SF-Symbol icon + tiny label inside a rounded
/// rectangle. Highlighted (full colour + accent stroke) when
/// `target == detected`; otherwise dimmed to 50% grey.
private struct TargetChip: View {
    @EnvironmentObject private var app: AppModel
    let target: PresetTarget
    let highlighted: PresetTarget?

    private var isHighlighted: Bool { target == highlighted }

    // Brand-violet palette specifically for the picker chips. Distinct
    // from the rest of the UI's blue accent so the target picker reads
    // as a single visual unit you can spot at a glance.
    private static let pickerViolet      = Color(red: 0.55, green: 0.34, blue: 0.92)
    private static let pickerVioletDeep  = Color(red: 0.40, green: 0.20, blue: 0.78)
    private static let pickerVioletPale  = Color(red: 0.55, green: 0.34, blue: 0.92).opacity(0.18)

    var body: some View {
        Button(action: applyTargetPreset) {
            chipLabel
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    @ViewBuilder
    private var chipLabel: some View {
        if isHighlighted {
            highlightedChip
        } else {
            inactiveChip
        }
    }

    /// Active state — full violet fill, white icon + label, drop
    /// shadow + faint violet glow so it pops against the brand bar.
    private var highlightedChip: some View {
        VStack(spacing: 1) {
            Image(systemName: target.icon)
                .font(.system(size: 17, weight: .semibold))
            Text(target.rawValue)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundColor(.white)
        .frame(width: 50, height: 42)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(
                    colors: [Self.pickerViolet, Self.pickerVioletDeep],
                    startPoint: .top, endPoint: .bottom
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: Self.pickerViolet.opacity(0.55), radius: 5, x: 0, y: 0)
        .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
    }

    /// Inactive state — soft violet tint at 60% opacity, slim outline,
    /// no glow. Reads as available-but-not-active.
    private var inactiveChip: some View {
        VStack(spacing: 1) {
            Image(systemName: target.icon)
                .font(.system(size: 16))
            Text(target.rawValue)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(Self.pickerViolet)
        .frame(width: 50, height: 42)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Self.pickerVioletPale.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Self.pickerViolet.opacity(0.35), lineWidth: 0.75)
        )
        .opacity(0.6)
    }

    private var helpText: String {
        isHighlighted
            ? "\(target.rawValue) — currently active preset. Scrolling to a file with a different keyword in its name auto-switches."
            : "Switch to the \(target.rawValue) preset."
    }

    /// Apply this target's first built-in preset. Mirrors the path
    /// the auto-detector takes when a folder is opened — see
    /// AppModel.autoApplyDefaultPreset.
    private func applyTargetPreset() {
        if let preset = app.presets.builtIn.first(where: { $0.target == target }) {
            app.applyPreset(preset)
            app.luckyStack.winjuposTarget = preset.target.rawValue
        }
    }
}

/// Layered SF-Symbol logo mark: a sun/star core with sparkles + a focusing
/// circle, gradient-tinted in the brand palette. Pure SwiftUI — no asset
/// catalog dependency, scales crisp at any size.
struct BrandMark: View {
    var body: some View {
        ZStack {
            // Outer gradient disc — the "eyepiece" frame.
            Circle()
                .fill(AppPalette.brandGradient)
                .opacity(0.18)
            Circle()
                .strokeBorder(AppPalette.brandGradient, lineWidth: 1.5)

            // Crosshair cross.
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(AppPalette.accent.opacity(0.5))

            // Star core — a 4-point spark for that astro feel.
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(AppPalette.brandGradient)
                .shadow(color: AppPalette.accent.opacity(0.5), radius: 2)
        }
    }
}

// MARK: - App-wide colour palette

/// Centralised brand colours so darkening / theming happens in one place.
/// Accent is ~40% darker than the standard system blue per the request.
enum AppPalette {
    /// Primary accent — system-blue brought down a touch but kept bright
    /// enough to read against grey toolbar chrome (the previous very-dark
    /// blue washed out on light mode title bars).
    static let accent = Color(red: 0.22, green: 0.48, blue: 0.85)

    /// Secondary accent for gradient pairs.
    static let accentDeep = Color(red: 0.14, green: 0.32, blue: 0.66)

    /// Hero gradient used by the brand mark and big run buttons.
    static let brandGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
