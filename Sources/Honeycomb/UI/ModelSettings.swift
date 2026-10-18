import HoneycombCore
import SwiftUI

struct ModelSettings: View {
    @Environment(AppModel.self) private var model
    @State private var addingProvider = false

    var body: some View {
        Form {
            Section("Providers") {
                ForEach(model.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            if let url = provider.baseUrl {
                                Text(url).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        PlaceBadge(isLocal: provider.isLocal)
                        if provider.kind != .builtin {
                            Button { model.deleteProvider(provider) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete this provider and its saved key")
                        }
                    }
                }
                Button("Add provider…") { addingProvider = true }
            }
            Section {
                RoutePicker(task: .enhance, title: "Notes")
                RoutePicker(task: .chat, title: "Chat")
            } header: {
                Text("Routes")
            } footer: {
                Text("Each task uses its own provider and model.")
            }
            Section {
                ModelDownloadRow(id: ModelCatalog.builtInLLM) { model.downloadModel(ModelCatalog.builtInLLM) }
                ModelDownloadRow(id: ModelCatalog.largeLLM) { model.downloadLargeModel() }
            } header: {
                Text("Built-in")
            } footer: {
                Text("The 9B writes better notes but needs more memory. Once it's downloaded, notes on the built-in model use it. It never loads during a recording.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .sheet(isPresented: $addingProvider) {
            ProviderForm(title: "Add provider", asksForModel: false,
                         onCancel: { addingProvider = false }, onSave: { addingProvider = false })
                .padding(20)
                .frame(width: 460)
        }
    }
}

struct PlaceBadge: View {
    let isLocal: Bool

    var body: some View {
        Text(isLocal ? "Local" : "Cloud")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color.textPrimary)
            .background(isLocal ? Color.accentSubtle : Color.warningSubtle, in: .capsule)
            .help(isLocal ? "Stays on this Mac or your local network" : "Sends meeting text to this service")
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

/// Picks the provider for one task, then a model from that provider's list. When the list can't
/// be fetched, a text field takes the model name instead.
struct RoutePicker: View {
    @Environment(AppModel.self) private var model
    let task: AITask
    let title: String
    @State private var providerID = ""
    @State private var models: [ModelInfo] = []
    @State private var listError: String?
    @State private var typedModel = ""
    @State private var pendingDownload: ModelSpec?

    private var route: Route? { model.routes[task] }
    private var provider: ProviderRecord? { model.providers.first { $0.id == providerID } }
    private var currentModel: String { route?.providerId == providerID ? route?.model ?? "" : "" }

    /// Chat runs during calls, when only the 4B may load. The 9B also needs enough memory.
    private func offered(_ models: [ModelInfo]) -> [ModelInfo] {
        guard provider?.kind == .builtin else { return models }
        return models.filter { info in
            (task != .chat || info.id == ModelCatalog.builtInLLM) && ModelDownloadRow.fitsThisMac(info.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(title, selection: $providerID) {
                    if provider == nil { Text("Not set").tag("") }
                    ForEach(model.providers) { Text($0.name).tag($0.id) }
                }
                if let provider { PlaceBadge(isLocal: provider.isLocal) }
            }
            if provider != nil {
                if let listError {
                    TextField("Model", text: $typedModel, prompt: Text("Model name"))
                        .onSubmit { save(typedModel) }
                    Text(listError).font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: Binding(get: { currentModel }, set: { save($0) })) {
                        if !models.contains(where: { $0.id == currentModel }) {
                            Text(currentModel.isEmpty ? "Choose a model" : currentModel).tag(currentModel)
                        }
                        ForEach(models) { Text($0.id).tag($0.id) }
                    }
                }
            }
        }
        .onAppear { providerID = route?.providerId ?? "" }
        .onChange(of: route?.providerId) { _, id in providerID = id ?? "" }
        .task(id: providerID) { await loadModels() }
        .confirmationDialog("Download \(pendingDownload?.name ?? "the model")?",
                            isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } })) {
            Button("Download") {
                if let pendingDownload { model.setRoute(task, provider: providerID, model: pendingDownload.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's \(ByteCountFormatter.string(fromByteCount: pendingDownload?.totalBytes ?? 0, countStyle: .file)). "
                 + "\(task == .chat ? "Chat waits" : "New notes wait") until the download finishes.")
        }
    }

    private func loadModels() async {
        models = []
        listError = nil
        typedModel = currentModel
        guard let provider else { return }
        do {
            let listed = try await model.models(for: provider)
            // A provider change cancels this task. Its late result belongs to the old provider.
            guard !Task.isCancelled else { return }
            models = offered(listed)
            if models.isEmpty { listError = "This provider lists no models. Type the model name." }
        } catch {
            guard !Task.isCancelled else { return }
            listError = (error as? ProviderError)?.message ?? ProviderError.invalidResponse.message
        }
    }

    private func save(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provider, !name.isEmpty else { return }
        if provider.kind == .builtin, model.modelStates[name] != .ready, let spec = ModelCatalog.spec(name) {
            pendingDownload = spec
            return
        }
        model.setRoute(task, provider: providerID, model: name)
    }
}

/// The ready-made addresses for common servers. "Other" leaves the address to fill in.
struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: ProviderKind
    let baseURL: String
    let contextTokens: Int

    static let all = [
        ProviderPreset(id: "ollama", name: "Ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", contextTokens: 8_192),
        ProviderPreset(id: "lmstudio", name: "LM Studio", kind: .openAICompatible, baseURL: "http://localhost:1234/v1", contextTokens: 8_192),
        ProviderPreset(id: "openrouter", name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1",
                       contextTokens: 128_000),
        ProviderPreset(id: "openai", name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1", contextTokens: 128_000),
        ProviderPreset(id: "custom", name: "Other OpenAI-compatible", kind: .openAICompatible, baseURL: "", contextTokens: 8_192),
        ProviderPreset(id: "anthropic", name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com", contextTokens: 200_000),
    ]

    var draft: ProviderDraft {
        ProviderDraft(name: id == "custom" ? "" : name, kind: kind, baseURL: baseURL, contextTokens: contextTokens)
    }
}

/// The "Add provider" form. With `asksForModel`, it also picks the model for notes and chat.
struct ProviderForm: View {
    @Environment(AppModel.self) private var model
    let title: String
    let asksForModel: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var preset = ProviderPreset.all[0]
    @State private var draft = ProviderPreset.all[0].draft
    @State private var testing = false
    @State private var testResult: String?
    @State private var models: [ModelInfo] = []
    @State private var routeModel = ""
    @State private var saveError: String?

    private var isLocal: Bool? { (try? ProviderURLPolicy.parse(draft.baseURL)).map(ProviderURLPolicy.isLocal) }
    private var needsKey: Bool { draft.kind == .anthropic && draft.apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canSave: Bool {
        !draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !needsKey
            && draft.contextTokens > 0
            && (!asksForModel || !routeModel.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Model lists come unsorted, and OpenAI's mixes in models that can't chat.
    static func defaultChatModel(_ models: [ModelInfo]) -> String? {
        let notChat = ["embed", "whisper", "tts", "dall-e", "image", "audio", "realtime", "transcribe",
                       "moderation", "search", "instruct", "davinci", "babbage", "sora", "codex"]
        let chat = models.map(\.id).filter { id in !notChat.contains { id.lowercased().contains($0) } }
        let preferred = ["gpt-4.1-mini", "gpt-4o-mini", "gpt-5-mini"]
        return preferred.first(where: chat.contains) ?? chat.sorted().first ?? models.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Form {
                Picker("Type", selection: $preset) {
                    ForEach(ProviderPreset.all) { Text($0.name).tag($0) }
                }
                TextField("Name", text: $draft.name, prompt: Text("My server"))
                TextField("Base URL", text: $draft.baseURL, prompt: Text("https://example.com/v1"))
                SecureField("API key", text: $draft.apiKey, prompt: Text(draft.kind == .anthropic ? "Required" : "Optional"))
                TextField("Context tokens", value: $draft.contextTokens, format: .number)
                if asksForModel {
                    if models.isEmpty {
                        TextField("Model", text: $routeModel, prompt: Text("Test the connection to pick one"))
                    } else {
                        Picker("Model", selection: $routeModel) {
                            ForEach(models) { Text($0.id).tag($0.id) }
                        }
                    }
                }
            }
            HStack {
                Button(testing ? "Testing…" : "Test connection") { Task { await test() } }
                    .disabled(testing)
                if let isLocal { PlaceBadge(isLocal: isLocal) }
                Spacer()
            }
            if let testResult {
                Text(testResult).font(.callout).foregroundStyle(.secondary)
            }
            Text("Match the context to your server's setting. Ollama cuts off longer prompts without an error.")
                .font(.caption).foregroundStyle(.secondary)
            if draft.contextTokens <= 0 {
                Text("Context tokens must be more than 0.").font(.callout).foregroundStyle(Color.recordingText)
            }
            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(Color.recordingText)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .onChange(of: preset) { _, preset in
            draft = preset.draft
            models = []
            routeModel = ""
            testResult = nil
            saveError = nil
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            models = try await model.models(for: draft)
            testResult = "Connected. \(models.count) \(models.count == 1 ? "model" : "models")."
            if !models.contains(where: { $0.id == routeModel }) { routeModel = Self.defaultChatModel(models) ?? routeModel }
        } catch {
            models = []
            testResult = (error as? ProviderError)?.message ?? ProviderError.invalidResponse.message
        }
    }

    private func save() {
        do {
            try model.addProvider(draft, routeModel: asksForModel ? routeModel.trimmingCharacters(in: .whitespaces) : nil)
            onSave()
        } catch {
            saveError = (error as? ProviderError)?.message ?? "Honeycomb couldn't save this provider."
        }
    }
}
