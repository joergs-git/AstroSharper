// AstroSharper — native macOS sharpening, stabilization and lucky-imaging.
import SwiftUI
import AppKit

/// Cross-cutting notification used by the View menu's zoom items so the
/// preview coordinator can react without being directly referenced from
/// the menu code.
extension Notification.Name {
    static let previewZoomCommand = Notification.Name("AstroSharper.previewZoomCommand")
}

enum PreviewZoomCommand {
    case zoomIn        // +25%
    case zoomOut       // -25%
    case fit           // scale 1.0, pan 0
    case oneToOne      // image-pixel = view-pixel
    case twoHundred    // 200% of fit
}

@main
struct AstroSharperApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var launchTracker = LaunchTracker.shared
    @State private var showingAbout = false
    @State private var showingRatingPrompt = false
    @State private var showingCoffeePrompt = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    setWindowTitle()
                    checkLaunchPrompts()
                }
                .sheet(isPresented: $showingAbout) {
                    AboutView { showingAbout = false }
                }
                .alert("Enjoying AstroSharper?", isPresented: $showingRatingPrompt) {
                    Button("Rate on App Store") {
                        NSWorkspace.shared.open(AppLinks.appStoreReview)
                        launchTracker.markRatingPromptShown()
                    }
                    Button("Maybe later") { launchTracker.markRatingPromptShown() }
                } message: {
                    Text("You've launched AstroSharper \(launchTracker.launchCount) times. A short review on the App Store helps a lot — thanks!")
                }
                .alert("Buy me a coffee?", isPresented: $showingCoffeePrompt) {
                    Button("Sure, take me there ☕️") {
                        NSWorkspace.shared.open(AppLinks.buyMeACoffee)
                        launchTracker.markCoffeePromptShown()
                    }
                    Button("Not now") { launchTracker.markCoffeePromptShown() }
                } message: {
                    Text("\(launchTracker.launchCount) launches — looks like AstroSharper found a home on your machine. If it's saving you time, a small coffee tip would make my day. Cheers!")
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
                Button("Zoom In") {
                    NotificationCenter.default.post(name: .previewZoomCommand, object: PreviewZoomCommand.zoomIn)
                }
                .keyboardShortcut("=", modifiers: [.command])
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
                Button("Zoom 200%") {
                    NotificationCenter.default.post(name: .previewZoomCommand, object: PreviewZoomCommand.twoHundred)
                }
                .keyboardShortcut("2", modifiers: [.command])
            }
            CommandGroup(replacing: .help) {
                Button("AstroSharper on GitHub") { NSWorkspace.shared.open(AppLinks.github) }
                Button("Buy me a coffee ☕️")    { NSWorkspace.shared.open(AppLinks.buyMeACoffee) }
            }
        }
    }

    private func setWindowTitle() {
        DispatchQueue.main.async {
            NSApp.windows.first?.title = "AstroSharper \(AppVersion.shortString)"
        }
    }

    private func checkLaunchPrompts() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if launchTracker.shouldShowRatingPrompt {
                showingRatingPrompt = true
            } else if launchTracker.shouldShowCoffeePrompt {
                showingCoffeePrompt = true
            }
        }
    }
}
