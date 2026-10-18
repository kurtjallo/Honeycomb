import AppKit
import HoneycombCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// The SwiftUI modifier sets the appearance only once the menu bar label renders, after the window can draw.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = UserDefaults.standard.string(forKey: AppearanceChoice.defaultsKey).flatMap(AppearanceChoice.init)?.appearance
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.quitRequested()
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
