import Foundation

/// Claude through Anthropic's Messages API. Chat only: Anthropic has no embeddings endpoint.
public struct AnthropicProvider: ChatProvider {
    private let apiKey: String
    private let root: URL
    private let transport: ProviderTransport

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!,
                session: URLSession = .shared, policy: ProviderPolicy = .cloud, gate: RequestGate = RequestGate()) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        root = OpenAICompatibleProvider.apiRoot(baseURL)
        transport = ProviderTransport(session: session, policy: policy, gate: gate)
    }

    public func models() async throws -> [ModelInfo] {
        // The list is paged at 20 by default. 1,000 is the largest page, which holds every model.
        let url = root.appending(path: "models").appending(queryItems: [URLQueryItem(name: "limit", value: "1000")])
        let data = try await transport.data(url, headers: headers, waitsForTurn: false)
        return try ProviderTransport.decode(ModelList.self, from: data).data.map { ModelInfo(id: $0.id) }
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, any Error> {
        let system = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let body = MessagesBody(model: request.model, system: system.isEmpty ? nil : system,
                                messages: request.messages.filter { $0.role != .system },
                                maxTokens: request.maxTokens, temperature: request.temperature)
        return transport.stream(root.appending(path: "messages"), headers: headers, json: body,
                                decoder: AnthropicStreamDecoder.self)
    }

    private var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
    }
}

private struct MessagesBody: Encodable, Sendable {
    var model: String
    var system: String?
    var messages: [ChatMessage]
    var maxTokens: Int
    var temperature: Double
    var stream = true
}

private struct ModelList: Decodable {
    struct Model: Decodable {
        var id: String
    }

    var data: [Model]
}

/// Keeps `text_delta` pieces and skips thinking, signature, and ping events.
private struct AnthropicStreamDecoder: ChatStreamDecoder {
    private struct Event: Decodable {
        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stopReason: String?
        }

        var type: String
        var delta: Delta?
        var error: ProviderWireError?
    }

    /// `model_context_window_exceeded` also cuts the answer short, so it is marked truncated too.
    private static let truncatedStops: Set = ["max_tokens", "model_context_window_exceeded"]
    private var finish: FinishReason?

    mutating func decode(_ event: SSEEvent) throws -> [ChatDelta] {
        let event = try ProviderTransport.decode(Event.self, from: Data(event.data.utf8))
        switch event.type {
        case "content_block_delta" where event.delta?.type == "text_delta":
            return [.text(event.delta?.text ?? "")]
        case "message_delta":
            switch event.delta?.stopReason {
            case nil: break
            case "refusal": throw ProviderError.refused
            case let reason?: finish = Self.truncatedStops.contains(reason) ? .length : .stop
            }
            return []
        case "message_stop":
            return [.finished(finish ?? .stop)]
        case "error":
            throw event.error?.providerError ?? ProviderError.invalidResponse
        default:
            return []
        }
    }

    func end() -> [ChatDelta] {
        finish.map { [.finished($0)] } ?? []
    }
}
