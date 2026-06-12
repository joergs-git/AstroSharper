// The tip-jar sheet — a warm, friendly "buy me a coffee" panel backed by
// StoreKit consumables (see TipJar.swift). Hosted in its own NSWindow via
// `TipJarPresenter` so it survives SwiftUI's transient view lifetimes and
// can be raised from a launch milestone or the Help / About menu.
//
// Visual goal: inviting, not naggy — a coffee-toned header, three clearly
// priced tiers, and a one-tap path to leave a review. Tips unlock nothing;
// the copy makes that explicit so it reads as genuine support.
import SwiftUI
import AppKit
import StoreKit

struct TipJarView: View {
    @ObservedObject var tipJar: TipJar
    let onClose: () -> Void

    // Warm espresso → crema gradient for the header band.
    private var coffeeGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.36, green: 0.21, blue: 0.11),
                     Color(red: 0.72, green: 0.45, blue: 0.20)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if tipJar.didThankYou {
                    thankYou
                } else if tipJar.loadFailed {
                    loadError
                } else {
                    chooser
                }
            }
            .padding(20)
        }
        .frame(width: 380)
        .background(Color(NSColor.windowBackgroundColor))
        .task { await tipJar.loadProducts() }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            coffeeGradient
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 72, height: 72)
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                }
                Text("Support AstroSharper")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text("Free · ad-free · made by one person")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tier chooser

    private var chooser: some View {
        VStack(spacing: 14) {
            Text("If AstroSharper turned a long capture night into a printable image, a coffee keeps features shipping. It's purely a thank-you — nothing to unlock.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if tipJar.isLoading && tipJar.products.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, 12)
            } else {
                VStack(spacing: 8) {
                    ForEach(tipJar.products, id: \.id) { product in
                        tierRow(product)
                    }
                }
            }

            // Review nudge — opens the Mac App Store "write a review" sheet.
            Button {
                NSWorkspace.shared.open(AppLinks.appStoreReview)
            } label: {
                Label("Enjoying it? Leave a quick review", systemImage: "star.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.link)

            Button("Maybe later") { onClose() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
    }

    /// One priced tier. Reads the localized name + price straight from
    /// StoreKit so currency/format follow the user's storefront.
    private func tierRow(_ product: Product) -> some View {
        let tier = TipJar.Tip(rawValue: product.id)
        return HStack(spacing: 12) {
            Text(tier?.cups ?? "☕️")
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 1) {
                Text(product.displayName.isEmpty ? (tier?.fallbackName ?? "Coffee") : product.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if !product.description.isEmpty {
                    Text(product.description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await tipJar.purchase(product) }
            } label: {
                if tipJar.purchaseInFlight == product.id {
                    ProgressView().controlSize(.small)
                        .frame(width: 56)
                } else {
                    Text(product.displayPrice)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(minWidth: 56)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(tipJar.purchaseInFlight != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Thank-you state

    private var thankYou: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.system(size: 34))
                .foregroundStyle(.pink)
            Text("Thank you so much! ☕️")
                .font(.system(size: 15, weight: .semibold))
            Text("Your support genuinely keeps AstroSharper moving. Clear skies!")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { onClose() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
    }

    // MARK: - Load error

    private var loadError: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Couldn't reach the App Store")
                .font(.system(size: 13, weight: .semibold))
            Text("Please check your connection and try again.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                Button("Retry") { Task { await tipJar.loadProducts() } }
                Button("Close") { onClose() }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Window presenter

/// Hosts `TipJarView` in a floating panel. Static window reference so the
/// panel isn't deallocated the moment the presenting call returns (same
/// pattern as the legacy CoffeeSupportDialog).
enum TipJarPresenter {
    private static var window: NSWindow?

    @MainActor
    static func present() {
        // Reuse an already-open panel instead of stacking duplicates.
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let tipJar = TipJar.shared
        tipJar.didThankYou = false

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Support AstroSharper"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()

        let view = TipJarView(tipJar: tipJar) {
            window?.close()
            window = nil
        }
        panel.contentView = NSHostingView(rootView: view)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }
}
