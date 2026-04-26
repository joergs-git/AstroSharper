// Custom About sheet — opened from the standard "About AstroSharper"
// menu item (replacing the default about panel). Shows version, links to
// GitHub + BuyMeACoffee + App Store review, and a short tagline.
import SwiftUI
import AppKit

struct AboutView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            BrandMark().frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text("AstroSharper")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppPalette.brandGradient)
                Text(AppVersion.shortString)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("Lucky imaging helper for macOS")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(spacing: 8) {
                LinkButton(label: "GitHub Repo", systemImage: "chevron.left.forwardslash.chevron.right", url: AppLinks.github)
                LinkButton(label: "Rate on App Store", systemImage: "star.fill", url: AppLinks.appStoreReview)
                LinkButton(label: "Buy me a coffee ☕️", systemImage: "cup.and.saucer.fill", url: AppLinks.buyMeACoffee)
            }

            Divider()

            Text("© 2026 joergsflow · Built with Metal + SwiftUI")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Button("Close") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360)
    }
}

private struct LinkButton: View {
    let label: String
    let systemImage: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(label)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }
}
