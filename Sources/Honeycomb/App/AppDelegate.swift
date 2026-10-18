import AppKit
import HoneycombCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
    }

    /// Quitting mid-call would cut the recording, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop and save the recording?"
        alert.informativeText = "Honeycomb is recording a meeting. Quitting stops the recording and keeps what was captured."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await model.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
