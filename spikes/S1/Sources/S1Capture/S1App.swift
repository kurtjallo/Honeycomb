import SwiftUI

@main
struct S1App: App {
    @State private var model = SpikeModel()

    var body: some Scene {
        WindowGroup("Honeycomb S1") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 560)
        }
    }
}

struct ContentView: View {
    @Bindable var model: SpikeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button(model.isRecording ? "Stop recording" : "Start recording") { model.toggleRecording() }
                    .keyboardShortcut("r")
                    .buttonStyle(.borderedProminent)
                    .tint(model.isRecording ? .red : .accentColor)
                Button("Tone test") { model.runToneTest() }
                Button(model.accessibilityTrusted ? "Accessibility: on" : "Allow Accessibility") {
                    model.requestAccessibility()
                }
                .disabled(model.accessibilityTrusted)
                Button("Open folder") { model.openFolder() }
                Toggle("Tap only (Quill)", isOn: $model.tapOnly)
                    .disabled(model.isRecording)
                Spacer()
                Text(model.stats).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }

            Meter(label: "Me (mic)", level: model.micLevel)
            Meter(label: "Them (system audio)", level: model.systemLevel)

            Text("Tone test: \(model.toneResult)").font(.callout)

            Text("Events (newest first). Also saved to ~/Library/Application Support/HoneycombS1/events.log")
                .font(.caption).foregroundStyle(.secondary)
            List(model.events) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.time, format: .dateTime.hour().minute().second())
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text(event.kind).font(.caption.bold()).frame(width: 90, alignment: .leading)
                    Text(event.detail).font(.callout).textSelection(.enabled)
                }
            }
            .listStyle(.bordered)
        }
        .padding(16)
    }
}

struct Meter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            ProgressView(value: Double(min(level * 4, 1)))
        }
    }
}
