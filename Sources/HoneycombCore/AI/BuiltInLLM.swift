import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The MLX side of a local LLM, behind a protocol so the load and unload rules are tested without a real model.
public protocol LLMRuntime: Sendable {
    associatedtype Model: Sendable
    func load(from folder: URL) async throws -> Model
    /// Frees the GPU buffers MLX keeps for reuse.
    func clearCache()
    func limitCache(recording: Bool)
}

public struct MLXRuntime: LLMRuntime {
    /// MLX keeps freed GPU buffers for reuse. Capping the pool keeps memory flat during a call.
    static let recordingCacheLimit = 256 * 1024 * 1024

    public init() {}

    public func load(from folder: URL) async throws -> ModelContainer {
        let started = ContinuousClock.now
        let container = try await LLMModelFactory.shared.loadContainer(from: folder, using: TransformersTokenizerLoader())
        Log.info("llm.loaded", ["seconds": .seconds(ContinuousClock.now - started)])
        return container
    }

    public func clearCache() {
        Memory.clearCache()
    }

    public func limitCache(recording: Bool) {
        Memory.cacheLimit = recording ? Self.recordingCacheLimit : 1024 * 1024 * 1024
    }
}

/// The built-in Qwen model on MLX.
public typealias BuiltInLLM = LocalLLM<MLXRuntime>

extension LocalLLM where Runtime == MLXRuntime {
    public init(store: ModelStore, host: ModelHost) {
        self.init(store: store, host: host, runtime: MLXRuntime())
    }
}

/// A local LLM. It loads through ModelHost, so it never shares memory with a model it shouldn't,
/// and unloads after 5 idle minutes.
public actor LocalLLM<Runtime: LLMRuntime> {
    private let store: ModelStore
    private let host: ModelHost
    private let runtime: Runtime
    private let idleUnload: Duration
    private var loaded: (id: String, model: Runtime.Model)?
    private var loading: (id: String, task: Task<Runtime.Model, Error>)?
    private var idleTask: Task<Void, Never>?
    private var users = 0

    init(store: ModelStore, host: ModelHost, runtime: Runtime, idleUnload: Duration = .seconds(300)) {
        self.store = store
        self.host = host
        self.runtime = runtime
        self.idleUnload = idleUnload
    }

    public var loadedModel: String? { loaded?.id }

    /// Returns the model, loading it if needed. Pair every call with `done()`.
    func use(_ id: String) async throws -> Runtime.Model {
        idleTask?.cancel()
        users += 1
        do {
            try await host.beginUse(.llm(id))
        } catch {
            users -= 1
            scheduleIdleUnload()
            throw error
        }
        do {
            return try await model(id)
        } catch {
            await done(id)
            throw error
        }
    }

    func done(_ id: String) async {
        users = max(0, users - 1)
        await host.endUse(.llm(id))
        if host.isRecording { runtime.clearCache() }
        scheduleIdleUnload()
    }

    /// `use` cancels the countdown, so every way out of it restarts the countdown, failures
    /// included, or a model loaded earlier would stay in memory for good.
    private func scheduleIdleUnload() {
        guard users == 0 else { return }
        idleTask = Task { [weak self, idleUnload] in
            try? await Task.sleep(for: idleUnload)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    /// A model being replaced stays loaded until ModelHost evicts it, which waits for its last lease
    /// and then calls `forceUnload`. Callers that arrive meanwhile join the same load task.
    private func model(_ id: String) async throws -> Runtime.Model {
        if let loaded, loaded.id == id { return loaded.model }
        if let loading, loading.id == id { return try await loading.task.value }
        let task = Task { [store, host, runtime] in
            guard let folder = await store.folder(id) else { throw ModelHostError.modelMissing(id) }
            try await host.register(.llm(id)) { [weak self] in await self?.forceUnload() }
            let stillWanted = {
                try Task.checkCancellation()
                guard await host.canLoad(.llm(id)) else { throw ModelHostError.notAllowedNow }
            }
            do {
                try await stillWanted()
                let model = try await runtime.load(from: folder)
                try await stillWanted()
                return model
            } catch {
                runtime.clearCache()
                await host.unregister(.llm(id))
                throw error
            }
        }
        loading = (id, task)
        defer { loading = nil }
        let model = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        loaded = (id, model)
        runtime.limitCache(recording: host.isRecording)
        return model
    }

    private func unloadIfIdle() async {
        guard users == 0 else { return }
        await forceUnload()
    }

    /// ModelHost calls this when another model needs the memory.
    func forceUnload() async {
        guard let loaded else { return }
        self.loaded = nil
        runtime.clearCache()
        await host.unregister(.llm(loaded.id))
        Log.info("llm.unloaded")
    }
}

/// Qwen through MLX as a `ChatProvider`. Thinking is off: no hidden reasoning tokens, faster answers.
public struct BuiltInProvider: ChatProvider {
    public static let contextTokens = 32_768
    let llm: BuiltInLLM

    public init(llm: BuiltInLLM) {
        self.llm = llm
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        let llm = self.llm
        let id = request.model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let container = try await llm.use(id)
                    defer { Task { await llm.done(id) } }
                    let chat: [Chat.Message] = request.messages.map { message in
                        switch message.role {
                        case .system: .system(message.content)
                        case .user: .user(message.content)
                        case .assistant: .assistant(message.content)
                        }
                    }
                    let input = try await container.prepare(input: UserInput(chat: chat, additionalContext: ["enable_thinking": false]))
                    // MLX reads the whole prompt before its first token and can't be stopped partway.
                    try Task.checkCancellation()
                    let parameters = GenerateParameters(maxTokens: request.maxTokens, temperature: Float(request.temperature),
                                                        topP: 0.8, topK: 20, prefillStepSize: 512)
                    var reason = FinishReason.stop
                    for await generation in try await container.generate(input: input, parameters: parameters) {
                        try Task.checkCancellation()
                        switch generation {
                        case .chunk(let text):
                            continuation.yield(.text(text))
                        case .info(let info):
                            if info.stopReason == .length { reason = .length }
                        case .toolCall:
                            break
                        }
                    }
                    continuation.yield(.finished(reason))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ChatError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Reads `tokenizer.json` with swift-transformers and adapts it to MLX's tokenizer protocol.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
