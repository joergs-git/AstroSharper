// StoreKit 2 tip jar — three consumable "coffee" products that let Mac
// App Store users support development. Tips unlock NOTHING (App Review
// Guideline 3.1.1: a pure thank-you, not a paid feature), which is exactly
// why this is the compliant replacement for the external buymeacoffee link
// that Apple rejected. The Developer-ID / GitHub build keeps the direct
// buymeacoffee link (gated by `#if !APP_STORE` elsewhere); this tip jar is
// only ever surfaced from the App Store build.
//
// Product IDs MUST match the In-App Purchases created in App Store Connect
// exactly. See README of the release procedure / the ASC walkthrough.
import Foundation
import StoreKit

@MainActor
final class TipJar: ObservableObject {

    /// Shared instance so loaded `Product` metadata is cached across the
    /// auto-prompt and the menu-triggered presentation.
    static let shared = TipJar()

    /// The three consumable tiers. `rawValue` is the App Store Connect
    /// Product ID — keep these stable once products are live.
    enum Tip: String, CaseIterable, Identifiable {
        case small  = "com.joergsflow.AstroSharper.tip.small"
        case medium = "com.joergsflow.AstroSharper.tip.medium"
        case large  = "com.joergsflow.AstroSharper.tip.large"

        var id: String { rawValue }

        /// Shown only until StoreKit metadata loads (then we use the
        /// localized `Product.displayName` instead).
        var fallbackName: String {
            switch self {
            case .small:  return "Small Coffee"
            case .medium: return "Medium Coffee"
            case .large:  return "Big Coffee"
            }
        }

        var cups: String {
            switch self {
            case .small:  return "☕️"
            case .medium: return "☕️☕️"
            case .large:  return "☕️☕️☕️"
            }
        }
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published var purchaseInFlight: Product.ID?
    /// Flips true after any successful tip so the view can swap to a
    /// warm thank-you state.
    @Published var didThankYou = false

    private static let orderedIDs = Tip.allCases.map(\.rawValue)

    // MARK: - Auto-prompt scheduling
    //
    // Mirrors the cadence of the (now App-Store-disabled) coffee dialog:
    // the first auto-prompt lands at a random launch in [10, 20] so not
    // every user sees it on the same launch; a dismissal snoozes it; a
    // successful tip silences it forever.

    private enum Key {
        static let nextPromptAt = "AstroSharper.tipNextPromptAt"
        static let everTipped   = "AstroSharper.tipEverTipped"
        // Reuse LaunchTracker's persisted counter so we schedule against
        // the same number it increments on launch.
        static let launchCount  = "AstroSharper.launchCount.v1"
    }

    /// Whether the tip jar should auto-present on this launch. Safe to
    /// call once per launch; it self-schedules on first ever call.
    static func shouldAutoPrompt(currentLaunchCount: Int) -> Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: Key.everTipped) { return false }
        guard let due = d.object(forKey: Key.nextPromptAt) as? Int else {
            d.set(currentLaunchCount + Int.random(in: 10...20), forKey: Key.nextPromptAt)
            return false
        }
        return currentLaunchCount >= due
    }

    /// Push the next auto-prompt out by `n` launches (user dismissed).
    static func snooze(byLaunches n: Int) {
        let cur = UserDefaults.standard.integer(forKey: Key.launchCount)
        UserDefaults.standard.set(cur + max(1, n), forKey: Key.nextPromptAt)
    }

    private static func markTipped() {
        UserDefaults.standard.set(true, forKey: Key.everTipped)
    }

    // MARK: - StoreKit

    /// Load product metadata from the App Store. Idempotent — a second
    /// call with products already loaded is a no-op.
    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoading = true
        loadFailed = false
        do {
            let fetched = try await Product.products(for: Self.orderedIDs)
            // Force small → medium → large order regardless of API order.
            products = Self.orderedIDs.compactMap { id in fetched.first { $0.id == id } }
            loadFailed = products.isEmpty
        } catch {
            loadFailed = true
        }
        isLoading = false
    }

    /// Buy a tip. Consumable → there is nothing to unlock; we simply
    /// finish the transaction, record that the user tipped (so we stop
    /// auto-prompting), and show the thank-you state.
    func purchase(_ product: Product) async {
        purchaseInFlight = product.id
        defer { purchaseInFlight = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    Self.markTipped()
                    didThankYou = true
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            // Stay quiet — the sheet remains open so the user can retry.
        }
    }
}
