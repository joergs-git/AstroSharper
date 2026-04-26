// Top-of-window brand strip: logo mark + product name + tagline. Sits above
// the path bar so the app identity is always visible without crowding the
// working area.
import SwiftUI

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            BrandMark()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("AstroSharper")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppPalette.brandGradient)
                    Text(AppVersion.shortString)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text("Lucky imaging helper for macOS")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
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
