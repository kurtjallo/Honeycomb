import HoneycombCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AudioSettings()
                .tabItem { Label("Audio", systemImage: "waveform") }
            ModelSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @AppStorage(AppearanceChoice.defaultsKey) private var appearance = AppearanceChoice.system
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .tint(.accentStrong)
            Toggle("Open Honeycomb when you log in", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
    }
}

struct AudioSettings: View {
    @AppStorage("systemAudioIncludesOutput") private var includeOutput = false
    @State private var toneResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Button(testing ? "Listening…" : "Test system audio") {
                        Task {
                            testing = true
                            let heard = await ToneTest.run(helper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ToneHelper"))
                            toneResult = heard
                                ? "Works. Honeycomb heard the test tone."
                                : "Honeycomb heard nothing. Turn it on in System Settings → Privacy & Security → System Audio Recording."
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if let toneResult { Text(toneResult).font(.callout).foregroundStyle(.secondary) }
                }
            } footer: {
                Text("Plays a short tone and checks that Honeycomb can hear it.")
            }
            Section {
                Toggle("Rebuild the audio tap when the speakers change", isOn: $includeOutput)
            } footer: {
                Text("Leave this off unless call audio goes missing after switching to AirPods.")
            }
        }
    }
}
