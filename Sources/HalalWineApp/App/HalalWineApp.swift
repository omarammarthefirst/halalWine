import AppKit
import SwiftUI

@main
struct HalalWineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window(L("app.name"), id: "main") {
            ContentView()
                .environment(model)
                .appLanguageEnvironment()
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("menu.addGame")) { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .appLanguageEnvironment()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in AppModel.shared.onLaunch() }
    }

    /// Dropping files on the Dock icon or "Open With → halalWine" in Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.addItems(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
