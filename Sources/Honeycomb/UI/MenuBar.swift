import HoneycombCore
import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.isRecording ? "hexagon.fill" : "hexagon")
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.isStartingRecording ? "Starting…" : model.isStoppingRecording ? "Stopping…"
               : model.isRecording ? "Stop Recording" : "Start Notes") {
            model.toggleRecording()
        }
        .disabled(model.isStartingRecording || model.isStoppingRecording)
        if model.isRecording, !model.isStoppingRecording {
            Button(model.status.isPaused ? "Resume" : "Pause") {
                model.pauseOrResume()
            }
        }
        Divider()
        Button("Open Honeycomb") {
            openWindow(id: "main")
            model.showMainWindow()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Honeycomb") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
