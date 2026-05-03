// App-wide metadata: version readers, launch counter, About / GitHub /
// BuyMeACoffee links, milestone-driven prompts.
//
// Prompt cadence (2026-05-02 redesign — ships with the splash screen
// + during-stacking coffee popup):
//   - Coffee:  first at launch 5, then every 50 after that. Triggered
//              while a stack job is running so the user has time to
//              read it. Yes/No/Later semantics:
//                yes   → mark as "thanks given", suppress for 100 launches
//                no    → suppress for 20 launches
//                later → don't mark, show again next eligible launch
//   - Rating:  first at launch 50, then every 50.
//              yes   → opens App Store, suppress for 200 launches
//              later → re-fire next launch
//   - Splash:  modal sheet at app start. "Don't show again" persists
//              via UserDefaults. Manual menu item to re-open later.
import AppKit
import Combine
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
    /// AstroBin profile — community visibility for the user's actual
    /// imaging output. Surfaced in the splash + About so visitors
    /// land on real example images.
    static let astrobinProfile = URL(string: "https://app.astrobin.com/u/joergsflow")!
    static let appStoreReview = URL(string: "macappstore://itunes.apple.com/app/idPLACEHOLDER?action=write-review")!
}

/// User's choice in the coffee / rating prompt. Drives suppression
/// state: "yes" suppresses for the longest, "no" for a moderate
/// stretch, "later" not at all (re-fires next eligible launch).
enum PromptResponse {
    case yes
    case no
    case later
}

/// Counts launches and fires the rating + coffee prompts at the
/// configured milestones. Suppression respects "later" vs "no" so
/// the user isn't nagged about something they explicitly declined.
@MainActor
final class LaunchTracker: ObservableObject {
    static let shared = LaunchTracker()

    // UserDefaults keys.
    private let countKey            = "AstroSharper.launchCount.v1"
    private let ratingSuppressKey   = "AstroSharper.ratingSuppressUntilLaunch"
    private let splashSuppressedKey = "AstroSharper.splashSuppressed.v1"

    // Cadence (see header comment for the rationale).
    private let ratingFirstAt: Int     = 50
    private let ratingRecurringEvery   = 50
    private let ratingNoSuppressFor    = 50
    private let ratingYesSuppressFor   = 200

    @Published var launchCount: Int

    private init() {
        let prev = UserDefaults.standard.integer(forKey: countKey)
        let next = prev + 1
        UserDefaults.standard.set(next, forKey: countKey)
        self.launchCount = next
    }

    // MARK: - Splash

    /// Has the user opted out of the splash screen?
    var splashSuppressed: Bool {
        UserDefaults.standard.bool(forKey: splashSuppressedKey)
    }
    func setSplashSuppressed(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: splashSuppressedKey)
    }

    // Coffee scheduling lives in CoffeeSupportDialog (UserDefaults
    // keys `AstroSharper.coffeeNextPromptAt` / `.coffeeThanked`) —
    // ported from AstroTriage's same-named dialog 2026-05-03 to keep
    // the two apps' donation UX identical. LaunchTracker still
    // exposes `launchCount` so the dialog can schedule against it.

    // MARK: - Rating

    var shouldShowRatingPrompt: Bool {
        guard launchCount >= ratingFirstAt else { return false }
        let suppressUntil = UserDefaults.standard.integer(forKey: ratingSuppressKey)
        guard launchCount >= suppressUntil else { return false }
        if launchCount == ratingFirstAt { return true }
        let delta = launchCount - ratingFirstAt
        return delta > 0 && delta % ratingRecurringEvery == 0
    }

    func recordRatingResponse(_ response: PromptResponse) {
        switch response {
        case .yes:
            UserDefaults.standard.set(launchCount + ratingYesSuppressFor,
                                      forKey: ratingSuppressKey)
        case .no:
            UserDefaults.standard.set(launchCount + ratingNoSuppressFor,
                                      forKey: ratingSuppressKey)
        case .later:
            break
        }
    }
}
