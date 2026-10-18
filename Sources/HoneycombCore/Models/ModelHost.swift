import Foundation

/// Which local models may be in memory together. Pure, so the rules are tested directly.
/// One large model at a time (speech or an LLM). The exception: during a recording on a Mac with
/// 16 GB or more, the built-in 4B may sit beside speech to answer questions.
public enum ModelPolicy {
    public enum Model: Hashable, Sendable {
        case speech
        case llm(String)
        case embedder
    }

    public enum Decision: Equatable, Sendable {
        case load(evicting: Set<Model>)
        case refuse
    }

    public static func decide(adding model: Model, loaded: Set<Model>, recording: Bool, ramGB: Int) -> Decision {
        let others = loaded.subtracting([model])
        let big = ramGB >= 16
        switch model {
        case .speech:
            var evict = others.filter {
                if case .llm(let id) = $0 { return !(recording && big && id == ModelCatalog.builtInLLM) }
                return false
            }
            if recording || !big { evict.formUnion(others.filter { $0 == .embedder }) }
            return .load(evicting: evict)
        case .llm(let id):
            if recording && (id != ModelCatalog.builtInLLM || !big) { return .refuse }
            var evict = others.filter { if case .llm = $0 { true } else { false } }
            if !recording { evict.formUnion(others.filter { $0 == .speech }) }
            if !big { evict.formUnion(others.filter { $0 == .embedder }) }
            return .load(evicting: evict)
        case .embedder:
            if recording { return .refuse }
            return .load(evicting: big ? [] : others)
        }
    }
}

public struct SpeechModels: Sendable {
    public let engine: any TranscriptionEngine
    public let detector: VoiceDetector
}

public enum ModelHostError: Error, Equatable, Sendable {
    case modelMissing(String)
    case notAllowedNow
}

/// The only component that loads local models. Others hold a lease while they use one.
/// Speech unloads soon after its last lease ends. Parakeet is preferred; Apple's engine stands in
/// while Parakeet is still downloading.
public actor ModelHost {
    public static let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    private let store: ModelStore
    private let speechIdleUnload: Duration
    private var speech: SpeechModels?
    private var speechLeases = 0
    private var speechUnload: Task<Void, Never>?
    public private(set) var isRecording = false
    private var unloadHandlers: [ModelPolicy.Model: @Sendable () async -> Void] = [:]
    private var loaded: Set<ModelPolicy.Model> = []
    private var leases: [ModelPolicy.Model: Int] = [:]
    private var idleWaiters: [ModelPolicy.Model: [CheckedContinuation<Void, Never>]] = [:]

    public init(store: ModelStore, speechIdleUnload: Duration = .seconds(30)) {
        self.store = store
        self.speechIdleUnload = speechIdleUnload
    }

    public func setRecording(_ recording: Bool) {
        isRecording = recording
    }

    public func acquireSpeech() async throws -> SpeechModels {
        speechUnload?.cancel()
        speechUnload = nil
        if let speech {
            speechLeases += 1
            leases[.speech, default: 0] += 1
            return speech
        }
        guard let vadFolder = await store.folder(ModelCatalog.vad) else {
            throw ModelHostError.modelMissing(ModelCatalog.vad)
        }
        try await makeRoom(for: .speech)
        let engine: any TranscriptionEngine
        if let folder = await store.folder(ModelCatalog.parakeet) {
            engine = ParakeetEngine(folder: folder)
        } else {
            engine = AppleSpeechEngine()
        }
        try await engine.prepare()
        let models = SpeechModels(engine: engine, detector: try VoiceDetector(folder: vadFolder))
        if let current = speech {
            await engine.release()
            speechLeases += 1
            leases[.speech, default: 0] += 1
            return current
        }
        speech = models
        loaded.insert(.speech)
        unloadHandlers[.speech] = { [weak self] in await self?.unloadSpeech() }
        speechLeases += 1
        leases[.speech, default: 0] += 1
        return models
    }

    public func releaseSpeech() {
        speechLeases = max(0, speechLeases - 1)
        leases[.speech] = speechLeases
        guard speechLeases == 0 else { return }
        notifyIdle(.speech)
        let delay = speechIdleUnload
        speechUnload = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadSpeech()
        }
    }

    /// True when the loaded speech engine is Parakeet, not the stand-in.
    public var hasParakeet: Bool { speech?.engine.engineID == "parakeet-v2" }

    private func unloadSpeech() async {
        guard speechLeases == 0, let current = speech else { return }
        speech = nil
        loaded.remove(.speech)
        await current.engine.release()
        Log.info("model.speech_unloaded")
    }

    /// Registers a loaded model owned elsewhere (the built-in LLM, the embedder) so the rules see it.
    public func register(_ model: ModelPolicy.Model, unload: @escaping @Sendable () async -> Void) async throws {
        try await makeRoom(for: model)
        loaded.insert(model)
        unloadHandlers[model] = unload
    }

    public func unregister(_ model: ModelPolicy.Model) {
        loaded.remove(model)
        unloadHandlers[model] = nil
        leases[model] = nil
    }

    /// Takes a lease, or throws `.notAllowedNow` if the rules forbid the model right now, even
    /// when it is already loaded: during a recording only speech and the 4B may run.
    public func beginUse(_ model: ModelPolicy.Model) throws {
        guard canLoad(model) else { throw ModelHostError.notAllowedNow }
        leases[model, default: 0] += 1
    }

    public func endUse(_ model: ModelPolicy.Model) {
        leases[model] = max(0, (leases[model] ?? 1) - 1)
        if leases[model] == 0 { notifyIdle(model) }
    }

    public func canLoad(_ model: ModelPolicy.Model) -> Bool {
        ModelPolicy.decide(adding: model, loaded: loaded, recording: isRecording, ramGB: Self.ramGB) != .refuse
    }

    private func makeRoom(for model: ModelPolicy.Model) async throws {
        switch ModelPolicy.decide(adding: model, loaded: loaded, recording: isRecording, ramGB: Self.ramGB) {
        case .refuse:
            throw ModelHostError.notAllowedNow
        case .load(let evicting):
            for victim in evicting {
                while (leases[victim] ?? 0) > 0 {
                    await withCheckedContinuation { idleWaiters[victim, default: []].append($0) }
                }
                if let unload = unloadHandlers[victim] {
                    await unload()
                }
                loaded.remove(victim)
            }
        }
    }

    private func notifyIdle(_ model: ModelPolicy.Model) {
        let waiters = idleWaiters[model] ?? []
        idleWaiters[model] = nil
        for waiter in waiters { waiter.resume() }
    }
}
