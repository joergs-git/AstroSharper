// AstroSharper v0.2.0 — native macOS sharpening, stabilization and lucky-imaging.
import SwiftUI

@main
struct AstroSharperApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { appModel.promptOpenFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
            CommandMenu("Process") {
                Button("Apply to Selection") { appModel.applyToSelection() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(!appModel.canApply)
            }
        }
    }
}
