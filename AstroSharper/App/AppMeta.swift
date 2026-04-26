// App-wide metadata: version readers, launch counter, About / GitHub /
// BuyMeACoffee links, milestone-driven prompts.
import AppKit
import Foundation
import SwiftUI

enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    /// e.g. "v0.3.0 (5)" — used in the brand header + window title.
    static var shortString: String { "v\(marketing) (\(build))" }
}

enum AppLinks {
    static let github = URL(string: "https://github.com/joergsflow/astrosharper")!
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/joergsflow")!
    static let appStoreReview = URL(string: "macappstore://itunes.apple.com/app/idPLACEHOLDER?action=write-review")!
}

/// Counts launches and fires the rating + coffee prompts at the configured
/// milestones. Single-shot per milestone (won't nag the user repeatedly).
@MainActor
final class LaunchTracker: ObservableObject {
    static let shared = LaunchTracker()

    private let countKey   = "AstroSharper.launchCount.v1"
    private let ratedKey   = "AstroSharper.ratedAtCount"
    private let coffeeKey  = "AstroSharper.coffeeAtCount"

    @Published var launchCount: Int

    private init() {
        let prev = UserDefaults.standard.integer(forKey: countKey)
        let next = prev + 1
        UserDefaults.standard.set(next, forKey: countKey)
        self.launchCount = next
    }

    /// Should the rating prompt be shown for this launch? True at launch
    /// 10, then never again (sticks via UserDefaults).
    var shouldShowRatingPrompt: Bool {
        launchCount >= 10 && UserDefaults.standard.integer(forKey: ratedKey) == 0
    }
    func markRatingPromptShown() {
        UserDefaults.standard.set(launchCount, forKey: ratedKey)
    }

    /// Coffee prompt at launch 20.
    var shouldShowCoffeePrompt: Bool {
        launchCount >= 20 && UserDefaults.standard.integer(forKey: coffeeKey) == 0
    }
    func markCoffeePromptShown() {
        UserDefaults.standard.set(launchCount, forKey: coffeeKey)
    }
}
