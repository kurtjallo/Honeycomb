import HoneycombCore
import SwiftUI

struct ModelSettings: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDownload: ModelSpec?

    private var choices: [ModelSpec] {
        [ModelCatalog.builtInLLM, ModelCatalog.largeLLM].filter(ModelDownloadRow.fitsThisMac).compactMap(ModelCatalog.spec)
    }

    var body: some View {
        Form {
            Section {
                Picker("Notes model", selection: Binding(get: { model.notesModel }, set: { pick($0) })) {
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }
                ModelDownloadRow(id: ModelCatalog.builtInLLM) { model.downloadModel(ModelCatalog.builtInLLM) }
                ModelDownloadRow(id: ModelCatalog.largeLLM) { model.downloadLargeModel() }
            } header: {
                Text("Built-in")
            } footer: {
                Text("The 9B writes better notes but needs more memory. Once it's downloaded, notes use it. It never loads during a recording.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Download \(pendingDownload?.name ?? "the model")?",
                            isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } })) {
            Button("Download") {
                if let pendingDownload { model.setNotesModel(pendingDownload.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's \(ByteCountFormatter.string(fromByteCount: pendingDownload?.totalBytes ?? 0, countStyle: .file)). "
                 + "New notes wait until the download finishes.")
        }
    }

    private func pick(_ id: String) {
        if model.modelStates[id] != .ready, let spec = ModelCatalog.spec(id) {
            pendingDownload = spec
            return
        }
        model.setNotesModel(id)
    }
}

/// A built-in model's download state, with a Download button while it's missing.
struct ModelDownloadRow: View {
    @Environment(AppModel.self) private var model
    let id: String
    let download: () -> Void

    private var state: ModelStore.State { model.modelStates[id] ?? .missing }
    private var spec: ModelSpec? { ModelCatalog.spec(id) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(spec?.name ?? id)
                status
            }
            Spacer()
            if canDownload { Button("Download", action: download) }
        }
    }

    private var canDownload: Bool {
        guard Self.fitsThisMac(id) else { return false }
        switch state {
        case .missing, .failed: return true
        default: return false
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .ready:
            caption("Ready")
        case .missing where !Self.fitsThisMac(id):
            caption("Needs \(spec?.minRAMGB ?? 0) GB of memory. This Mac has \(ModelHost.ramGB) GB.")
        case .missing:
            caption("Not downloaded. \(ByteCountFormatter.string(fromByteCount: spec?.totalBytes ?? 0, countStyle: .file)).")
        case .downloading(let received, let total):
            progress(received, total, "Downloading… \(Int(Double(received) / Double(max(total, 1)) * 100))%")
        case .waitingForNetwork(let received, let total):
            progress(received, total, "Waiting for the network…")
        case .verifying:
            caption("Checking the download…")
        case .failed(let code):
            caption("The download failed. \(Self.failureMessage(code))")
        }
    }

    static func fitsThisMac(_ id: String) -> Bool {
        (ModelCatalog.spec(id)?.minRAMGB ?? 0) <= ModelHost.ramGB
    }

    /// The sentence for a `ModelStore` failure code.
    static func failureMessage(_ code: String) -> String {
        switch code {
        case "low_disk": "There isn't enough free disk space."
        case "checksum_mismatch", "size_mismatch": "The downloaded files were damaged."
        case _ where code.hasPrefix("http_"): "The download server returned an error."
        default: "Check the internet connection, then try again."
        }
    }

    private func progress(_ received: Int64, _ total: Int64, _ label: String) -> some View {
        ProgressView(value: Double(received), total: Double(max(total, 1))) { caption(label) }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
