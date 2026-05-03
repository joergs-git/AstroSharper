// CoffeeSupportDialog.swift
//
// Friendly, randomly-scheduled "buy me a coffee" prompt — ported from
// AstroTriage / AstroBlinkV2 verbatim so the experience matches the
// sister app.
//
// Cadence (driven by UserDefaults vs. launchCount):
//   - First prompt after a random offset of 10..100 launches from install
//   - "Yes, sure!"   → opens browser, sets coffeeThanked=true → never shown again
//   - "No thanks"    → reschedules ~50 launches out (with small jitter)
//   - "Maybe later"  → reschedules 2 launches out (lightweight nudge)
//
// Design: small (~56pt) circular avatar of the developer + first-person
// copy. A real face raises donation conversion meaningfully versus an
// anonymous logo (per the AstroTriage decision rationale).
//
// Presented as a floating NSWindow (NOT a SwiftUI sheet) so the dialog
// can sit non-modal alongside the running stack job — the user can see
// progress in the main window while reading the prompt.
import AppKit
import SwiftUI

enum CoffeeSupportDialog {

    private static let supportURL = AppLinks.buyMeACoffee

    // UserDefaults keys — namespaced under AstroSharper.coffee.* so they
    // don't collide with the parallel AstroTriage scheduling.
    private enum Key {
        static let nextPromptAt = "AstroSharper.coffeeNextPromptAt"
        static let thanked      = "AstroSharper.coffeeThanked"
    }

    /// Decide whether the dialog should fire on this launch, then
    /// present it. Safe to call from the main thread; returns
    /// immediately if the user already donated, opted out, or the
    /// scheduled launch hasn't arrived yet.
    @MainActor
    static func presentIfDue(currentLaunchCount: Int) {
        // Bail if the user already said "Yes" or "No" to a prior prompt.
        if UserDefaults.standard.bool(forKey: Key.thanked) {
            return
        }

        // First call ever: schedule the inaugural prompt at a random
        // launch in [+10, +100]. The randomness avoids every user on
        // the same release seeing the dialog at the exact same launch
        // number.
        let scheduled = UserDefaults.standard.object(forKey: Key.nextPromptAt) as? Int
        if scheduled == nil {
            let target = currentLaunchCount + Int.random(in: 10...100)
            UserDefaults.standard.set(target, forKey: Key.nextPromptAt)
            return
        }

        guard let due = scheduled, currentLaunchCount >= due else { return }
        present()
    }

    /// Force-present (no scheduling check). Reserved for a future
    /// "Help → Buy me a coffee" menu route.
    @MainActor
    static func presentNow() {
        present()
    }

    // MARK: - Presentation

    @MainActor
    private static func present() {
        // Hold a strong reference to the window via the OpenWindows
        // namespace — released only when the user closes it. Without
        // this the window deallocs as soon as the static returns.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 456, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Support AstroSharper"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()

        let view = CoffeeSupportView(
            onYes: {
                NSWorkspace.shared.open(supportURL)
                markThanked()
                window.close()
            },
            onNo: {
                snooze(by: Int.random(in: 50...60), markDone: false)
                window.close()
            },
            onLater: {
                snooze(by: 2, markDone: false)
                window.close()
            }
        )

        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        OpenWindows.coffee = window
    }

    // MARK: - State helpers

    private static func currentLaunchCount() -> Int {
        // Reads the LaunchTracker's persistent count directly so we
        // can schedule against the same number even if `presentIfDue`
        // is called multiple times in one launch.
        UserDefaults.standard.integer(forKey: "AstroSharper.launchCount.v1")
    }

    private static func snooze(by launches: Int, markDone: Bool) {
        let next = currentLaunchCount() + max(1, launches)
        UserDefaults.standard.set(next, forKey: Key.nextPromptAt)
        if markDone {
            UserDefaults.standard.set(true, forKey: Key.thanked)
        }
    }

    private static func markThanked() {
        UserDefaults.standard.set(true, forKey: Key.thanked)
    }

    /// Keep window alive while open. Static so SwiftUI's transient
    /// View lifetimes don't tear the dialog down mid-interaction.
    private enum OpenWindows {
        static var coffee: NSWindow?
    }
}

// MARK: - SwiftUI body

private struct CoffeeSupportView: View {
    let onYes: () -> Void
    let onNo: () -> Void
    let onLater: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Small circular portrait — kept intentionally compact.
            // The "real face raises donation conversion" rationale
            // from the AstroTriage port carries over.
            Image("JoergPortrait")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text("Hi, I'm Jörg ☕")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Text("I built AstroSharper in my spare time, between long imaging nights. If it's saved you some time or you just like it, fancy buying me a coffee?")
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                // Decorative coffee cup — large + centered, mirrors the
                // AstroTriage layout proportions.
                Text("☕")
                    .font(.system(size: 54))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    Button(action: onYes) {
                        Text("Yes, sure!")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                    Button(action: onLater) {
                        Text("Maybe later")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)

                    Button(action: onNo) {
                        Text("No thanks")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(18)
        .frame(width: 456, height: 280, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
