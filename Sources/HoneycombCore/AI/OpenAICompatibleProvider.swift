import Foundation

/// Ollama, LM Studio, OpenRouter, OpenAI, and any other server that speaks OpenAI's chat API.
public struct OpenAICompatibleProvider: ChatProvider, EmbeddingProvider {
    private let root: URL
    private let isOpenAI: Bool
    private let apiKey: String?
    private let embeddingModel: String?
    private let transport: ProviderTransport

    /// `embed(_:)` needs `embeddingModel`, because the call itself names no model. Adapters for one
    /// provider share its `gate`, so only one request at a time reaches it.
    public init(baseURL: URL, apiKey: String?, isLocal: Bool, session: URLSession = .shared,
                embeddingModel: String? = nil, policy: ProviderPolicy? = nil, gate: RequestGate = RequestGate()) {
        root = Self.apiRoot(baseURL)
        isOpenAI = baseURL.host(percentEncoded: false)?.lowercased() == "api.openai.com"
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = key?.isEmpty == false ? key : nil
        self.embeddingModel = embeddingModel
        transport = ProviderTransport(session: session, policy: policy ?? (isLocal ? .local : .cloud), gate: gate)
    }

    /// People paste base URLs with or without `/v1`. A path that already names a version, such as
    /// `/api/v1` or Gemini's `/v1beta/openai`, is used as given.
    static func apiRoot(_ url: URL) -> URL {
        let hasVersion = url.pathComponents.contains { $0.first == "v" && $0.dropFirst().first?.isNumber == true }
        return hasVersion ? url : url.appending(path: "v1")
    }

    public func models() async throws -> [ModelInfo] {
        let data = try await transport.data(root.appending(path: "models"), headers: headers, waitsForTurn: false)
        return try ProviderTransport.decode(ModelList.self, from: data).data
            .map { ModelInfo(id: $0.id, contextTokens: $0.contextLength) }
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, any Error> {
        transport.stream(root.appending(path: "chat/completions"), headers: headers, json: ChatBody(request, isOpenAI: isOpenAI),
                         decoder: OpenAIStreamDecoder.self)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let embeddingModel else { throw ProviderError.modelNotFound }
        let data = try await transport.data(root.appending(path: "embeddings"), headers: headers,
                                            json: EmbeddingBody(model: embeddingModel, input: texts), waitsForTurn: true)
        let rows = try ProviderTransport.decode(EmbeddingList.self, from: data).data.sorted { $0.index < $1.index }
        guard rows.count == texts.count else { throw ProviderError.invalidResponse }
        return rows.map(\.embedding)
    }

    private var headers: [String: String] {
        apiKey.map { ["authorization": "Bearer \($0)"] } ?? [:]
    }
}

/// OpenAI itself replaced `max_tokens` with `max_completion_tokens`, and its reasoning models (the
/// o-series and gpt-5 family) refuse both `max_tokens` and any temperature but the default. Those
/// models are found by name, because gateways such as LiteLLM, Helicone, and OpenRouter pass the
/// fields through to OpenAI. Other servers, such as Ollama and LM Studio, only read `max_tokens`.
private struct ChatBody: Encodable, Sendable {
    var model: String
    var messages: [ChatMessage]
    var maxTokens: Int?
    var maxCompletionTokens: Int?
    var reasoningEffort: String?
    var temperature: Double?
    var stream = true

    /// Hidden reasoning counts against `max_completion_tokens`, and a limit reached while reasoning
    /// leaves an empty answer. OpenAI's reasoning guide says to reserve at least 25,000 tokens for
    /// reasoning when starting out, so that much goes on top of the answer's own budget. Low effort
    /// keeps the reasoning well inside it, and only the tokens used are billed.
    static let reasoningTokens = 25_000

    init(_ request: ChatRequest, isOpenAI: Bool) {
        model = request.model
        messages = request.messages
        if Self.isReasoningModel(request.model) {
            maxCompletionTokens = request.maxTokens + Self.reasoningTokens
            reasoningEffort = "low"
        } else if isOpenAI {
            maxCompletionTokens = request.maxTokens
            temperature = request.temperature
        } else {
            maxTokens = request.maxTokens
            temperature = request.temperature
        }
    }

    /// Gateways may prefix the vendor, as in OpenRouter's `openai/gpt-5`.
    static func isReasoningModel(_ model: String) -> Bool {
        let name = model.split(separator: "/").last.map { $0.lowercased() } ?? ""
        return name.hasPrefix("gpt-5") || (name.first == "o" && name.dropFirst().first?.isNumber == true)
    }
}

private struct EmbeddingBody: Encodable, Sendable {
    var model: String
    var input: [String]
}

private struct ModelList: Decodable {
    struct Model: Decodable {
        var id: String
        var contextLength: Int?
    }

    var data: [Model]
}

private struct EmbeddingList: Decodable {
    struct Row: Decodable {
        var index: Int
        var embedding: [Float]
    }

    var data: [Row]
}

/// Reads `choices[0].delta.content`. Reasoning fields (`reasoning_content`, `reasoning`) are left
/// undecoded, so they never reach the notes.
private struct OpenAIStreamDecoder: ChatStreamDecoder {
    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                var content: String?
            }

            var delta: Delta?
            var finishReason: String?
        }

        var choices: [Choice]?
        var error: ProviderWireError?
    }

    private var think = ThinkFilter()
    private var finish: FinishReason?

    mutating func decode(_ event: SSEEvent) throws -> [ChatDelta] {
        if event.data == "[DONE]" {
            finish = finish ?? .stop
            return end()
        }
        let chunk = try ProviderTransport.decode(StreamChunk.self, from: Data(event.data.utf8))
        if let error = chunk.error { throw error.providerError }
        guard let choice = chunk.choices?.first else { return [] }
        let text = think.feed(choice.delta?.content ?? "")
        switch choice.finishReason {
        case nil: break
        case "length": finish = .length
        case "content_filter": throw ProviderError.refused
        default: finish = .stop
        }
        return [.text(text)]
    }

    mutating func end() -> [ChatDelta] {
        [.text(think.finish())] + (finish.map { [.finished($0)] } ?? [])
    }
}
