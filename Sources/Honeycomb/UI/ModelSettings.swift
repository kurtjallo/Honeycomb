import HoneycombCore
import SwiftUI

struct ModelSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ModelDownloadRow(id: ModelCatalog.builtInLLM) { model.downloadModel(ModelCatalog.builtInLLM) }
            } header: {
                Text("Built-in")
            } footer: {
                Text("Honeycomb writes your notes with this model, on this Mac.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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
        switch state {
        case .missing, .failed: return true
        default: return false
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .ready:
            caption("Ready")
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
