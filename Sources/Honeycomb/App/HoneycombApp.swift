import HoneycombCore
import SwiftUI

@main
struct HoneycombApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Honeycomb", id: "main") {
            MainWindow()
                .environment(delegate.model)
                .tint(.accentStrong)
                .honeycombAppearance()
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 960, height: 760)
        .commands { AppCommands(model: delegate.model) }

        MenuBarExtra {
            MenuBarContent()
                .environment(delegate.model)
                .honeycombAppearance()
        } label: {
            MenuBarLabel(model: delegate.model)
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
                .tint(.accentStrong)
                .honeycombAppearance()
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(model.isStartingRecording ? "Starting…" : model.isStoppingRecording ? "Stopping…"
                   : model.isRecording ? "Stop Recording" : "Start Recording") {
                model.toggleRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.isStartingRecording || model.isStoppingRecording)
        }
    }
}
