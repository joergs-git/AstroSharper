// Small target icon view used by the toolbar target picker.
// Renders custom belted-disc (Jupiter) and ringed-disc (Saturn) shapes
// for visual recognisability — SF Symbols don't have matching glyphs.
// All other targets fall back to their `PresetTarget.icon` SF Symbol.
//
// Callers pass `size` (matches the font(.system(size:)) used for SF
// Symbols) and an explicit `color` (Shape strokes / fills don't
// automatically inherit `.foregroundColor()` from the environment).
import SwiftUI

struct TargetIconView: View {
    let target: PresetTarget
    let size: CGFloat
    let color: Color

    var body: some View {
        switch target {
        case .jupiter: JupiterIcon(size: size, color: color)
        case .saturn:  SaturnIcon(size: size, color: color)
        default:
            Image(systemName: target.icon)
                // SF Symbols typically render at ~85% of the requested
                // font size in glyph terms, matching the look of the
                // pre-refactor `.font(.system(size:))` chip icons.
                .font(.system(size: size, weight: .semibold))
        }
    }
}

/// Jupiter: filled disc with two diagonal cloud-bands across it.
/// The bands use `blendMode(.destinationOut)` to punch through the
/// disc so the chip's underlying violet (highlighted) or pale-violet
/// (inactive) background shows through — gives a crisp belted look
/// regardless of the chip background, without needing to know it.
private struct JupiterIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
            Group {
                Capsule()
                    .fill(Color.white)  // colour irrelevant — destinationOut only uses alpha
                    .frame(width: size * 1.10, height: size * 0.13)
                    .offset(y: -size * 0.16)
                Capsule()
                    .fill(Color.white)
                    .frame(width: size * 1.10, height: size * 0.13)
                    .offset(y: size * 0.16)
            }
            .blendMode(.destinationOut)
            .rotationEffect(.degrees(-12))  // slight tilt = "schräge Querstriche"
        }
        .frame(width: size, height: size)
        .compositingGroup()
    }
}

/// Saturn: small filled disc + flattened ring around it.
/// The ring is an ellipse stroke rotated slightly so it reads as a
/// 3D ring perspective rather than a perfect circle.
private struct SaturnIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            // Squashed ring (ellipse outline, rotated for perspective).
            Ellipse()
                .stroke(color, lineWidth: max(1.0, size * 0.085))
                .frame(width: size * 1.05, height: size * 0.42)
                .rotationEffect(.degrees(-18))
            // Planet disc — smaller than the ring's horizontal extent so
            // the ring visibly wraps around it on both sides.
            Circle()
                .fill(color)
                .frame(width: size * 0.55, height: size * 0.55)
        }
        .frame(width: size, height: size)
    }
}
