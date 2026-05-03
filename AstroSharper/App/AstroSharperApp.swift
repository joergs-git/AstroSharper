// AstroSharper — native macOS sharpening, stabilization and lucky-imaging.
import SwiftUI
import AppKit

/// Cross-cutting notification used by the View menu's zoom items so the
/// preview coordinator can react without being directly referenced from
/// the menu code.
extension Notification.Name {
    static let previewZoomCommand = Notification.Name("AstroSharper.previewZoomCommand")
    /// Posted by the headline-bar Community button + Help menu item
    /// to open the Community Stacks floating window. Listened for in
    /// the WindowGroup body via `.onReceive`.
    static let openCommunityFeed = Notification.Name("AstroSharper.openCommunityFeed")
    /// Posted by the headline-bar Howto button to open the workflow
    /// guide window. Mirrors the openCommunityFeed pattern so the
    /// BrandHeader doesn't need direct access to `openWindow`.
    static let openHowto = Notification.Name("AstroSharper.openHowto")
}

enum PreviewZoomCommand {
    case zoomIn        // +25%
    case zoomOut       // -25%
    case fit           // scale 1.0, pan 0
    case oneToOne      // 1:1 — image-pixel = view-pixel (actual size)
    case oneToTwo      // 1:2 — image at 50% (every 2 image px → 1 view px)
    case oneToFour     // 1:4 — image at 25%
    case oneToEight    // 1:8 — image at 12.5%
}

@main
struct AstroSharperApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var launchTracker = LaunchTracker.shared
    @State private var showingAbout = false
    @State private var showingSplash = false
    @State private var showingRatingPrompt = false
    /// Set true the first time a stack job starts within this launch
    /// so the coffee prompt fires once per stacking session, not once
    /// per file in a batch.
    @State private var coffeeShownThisSession = false

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    setWindowTitle()
                    showSplashIfNeeded()
                    checkRatingPromptOnLaunch()
                }
                .onReceive(NotificationCenter.default.publisher(for: .openCommunityFeed)) { _ in
                    openWindow(id: "community-feed")
                }
                .onReceive(NotificationCenter.default.publisher(for: .openHowto)) { _ in
                    openWindow(id: "howto")
                }
                .onChange(of: appModel.jobStatus) { _, newStatus in
                    // Coffee prompt fires while the user is waiting on
                    // a stack job — gives them a natural moment to
                    // read it without interrupting interaction.
                    //
                    // GATED OFF until first public release (2026-05-02):
                    // we don't want the prompt firing on the user's own
                    // dev / test runs. Flip `coffeePromptEnabled = true`
                    // when v0.4.x ships publicly.
                    let coffeePromptEnabled = false
                    if coffeePromptEnabled,
                       case .running = newStatus,
                       !coffeeShownThisSession {
                        coffeeShownThisSession = true
                        // Small delay so the prompt doesn't fire at
                        // the exact instant the run button is clicked.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            CoffeeSupportDialog.presentIfDue(
                                currentLaunchCount: launchTracker.launchCount
                            )
                        }
                    }
                }
                .sheet(isPresented: $showingSplash) {
                    SplashView { showingSplash = false }
                }
                .sheet(isPresented: $showingAbout) {
                    AboutView { showingAbout = false }
                }
                .alert("Enjoying AstroSharper?", isPresented: $showingRatingPrompt) {
                    Button("Rate on App Store") {
                        NSWorkspace.shared.open(AppLinks.appStoreReview)
                        launchTracker.recordRatingResponse(.yes)
                    }
                    Button("Not now") { launchTracker.recordRatingResponse(.no) }
                    Button("Later") { launchTracker.recordRatingResponse(.later) }
                } message: {
                    Text("You've launched AstroSharper \(launchTracker.launchCount) times. A short review on the App Store helps a lot — thanks!")
                }
                .alert(
                    "Upload community thumbnail?",
                    isPresented: Binding(
                        get: { appModel.pendingCommunityShare != nil },
                        set: { if !$0 { appModel.pendingCommunityShare = nil } }
                    ),
                    presenting: appModel.pendingCommunityShare
                ) { share in
                    Button("Yes, upload") {
                        CommunityShare.upload(
                            stackedURL: share.stackedURL,
                            target: share.target,
                            frameCount: share.frameCount,
                            elapsedSec: share.elapsedSec
                        )
                        appModel.pendingCommunityShare = nil
                    }
                    Button("No") {
                        appModel.pendingCommunityShare = nil
                    }
                    Button("Always off") {
                        appModel.setCommunityShareEnabled(false)
                        appModel.pendingCommunityShare = nil
                    }
                } message: { _ in
                    Text("Share a small thumbnail of this stack with the community? Only the JPEG (max 800 px), the target keyword, the frame count and a random per-machine UUID are uploaded. No filenames, no hostnames, no personal data. You can disable community share globally via the bottom-bar icon.")
                }
        }

        // Non-blocking floating Howto window — opens via the toolbar button
        // and the Help menu's "How AstroSharper works" item. User can keep
        // it on screen while working in the main window (own NSWindow).
        Window("How AstroSharper works", id: "howto") {
            HowToView { /* user closes via standard window close box */ }
        }
        .defaultPosition(.center)
        .defaultSize(width: 660, height: 640)
        .windowResizability(.contentSize)

        // "Show other peoples thumbs" — Community Stacks feed window.
        // Opens via the violet headline-bar button + Help menu item.
        // Non-modal, own NSWindow so the user can keep it on-screen
        // alongside the main window while continuing to work.
        Window("Community Stacks", id: "community-feed") {
            CommunityFeedWindow()
        }
        .defaultPosition(.center)
        .defaultSize(width: 600, height: 700)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About AstroSharper") { showingAbout = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { appModel.promptOpenFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
            CommandMenu("Process") {
                Button("Apply to Selection") { appModel.applyToSelection() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(!appModel.canApply)
            }
            CommandMenu("View") {
                // Zoom shortcuts. PreviewCoordinator listens for these
                // notifications and updates its own zoom/pan state — keeps
                // the menu code free of any direct view coupling.
                //
                // Cmd++ (was Cmd+= which on US keyboards is the same key,
                // but on a German layout the unshifted key is "+" — using
                // "+" directly works on both layouts.)
                Button("Zoom In") {
                    NotificationCenter.default.post(name: .previewZoomCommand, object: PreviewZoomCommand.zoomIn)
                }
                .keyboardShortcut("+", modifiers: [.command])
                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .previewZoomCommand, object: PreviewZoomCommand.zoomOut)
                }
                .keyboardShortcut("-", modifiers: [.command])
                Divider()
                Button("Fit to Window") {
                    NotificationCenter.default.post(name: .previewZoomCommand, object: PreviewZoomCommand.fit)
                }
                .keyboardShortcut("0", modifiers: [.command])
                Button("Actual Size (1:1)") {
                    NotificationCenter.default.post(name: .previewZoomCommand, object: PreviewZoomCommand.oneToOne)
                }
                .keyboardShortcut("1", modifiers: [.command])
                Button("Zoom 1:2 (50%)") {
                    NotificationCenter.default.post(name: .previewZoomCommand, object: PreviewZoomCommand.oneToTwo)
                }
                .keyboardShortcut("2", modifiers: [.command])
                Button("Zoom 1:4 (25%)") {
                    NotificationCenter.default.post(name: .previewZoomCommand, object: PreviewZoomCommand.oneToFour)
                }
                .keyboardShortcut("3", modifiers: [.command])
                Button("Zoom 1:8 (12.5%)") {
                    NotificationCenter.default.post(name: .previewZoomCommand, object: PreviewZoomCommand.oneToEight)
                }
                .keyboardShortcut("4", modifiers: [.command])
                Divider()
                // I = info / inspector. Toggles the translucent stats overlay
                // in the bottom-left corner of the preview.
                Button(appModel.hudVisible ? "Hide Preview HUD" : "Show Preview HUD") {
                    appModel.hudVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [])
            }
            CommandGroup(replacing: .help) {
                Button("Show Welcome Screen…") { showingSplash = true }
                Button("Show other peoples' stacks…") {
                    openWindow(id: "community-feed")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("AstroSharper on GitHub") { NSWorkspace.shared.open(AppLinks.github) }
                Button("Example images on AstroBin") { NSWorkspace.shared.open(AppLinks.astrobinProfile) }
                Button("Buy me a coffee ☕️")    { CoffeeSupportDialog.presentNow() }
            }
        }
    }

    private func setWindowTitle() {
        DispatchQueue.main.async {
            NSApp.windows.first?.title = "AstroSharper \(AppVersion.shortString)"
        }
    }

    /// Show the welcome / splash sheet if the user hasn't opted out.
    /// Fires on every launch until they tick "Don't show again".
    private func showSplashIfNeeded() {
        guard !launchTracker.splashSuppressed else { return }
        // Tiny delay so the main window has settled before the sheet
        // animates in — feels less jarring than firing during view
        // construction.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showingSplash = true
        }
    }

    /// Rating prompt fires at launch, NOT during stacking — it's a
    /// "you've used this enough to know if it's good" moment, distinct
    /// from the coffee prompt which is meant to land while the user is
    /// idle waiting on a job.
    private func checkRatingPromptOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if launchTracker.shouldShowRatingPrompt {
                showingRatingPrompt = true
            }
        }
    }
}
