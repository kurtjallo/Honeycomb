import Foundation

public struct ChatMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
    }

    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatRequest: Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    /// Output tokens reserved for the answer.
    public var maxTokens: Int
    public var temperature: Double

    public init(model: String, messages: [ChatMessage], maxTokens: Int = 2_000, temperature: Double = 0.3) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public enum FinishReason: String, Sendable, Equatable {
    case stop
    /// The model hit its output limit. The notes are marked truncated and offer Regenerate.
    case length
}

public enum ChatDelta: Sendable, Equatable {
    case text(String)
    case finished(FinishReason)
}

public struct ModelInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var contextTokens: Int?

    public init(id: String, contextTokens: Int? = nil) {
        self.id = id
        self.contextTokens = contextTokens
    }
}

/// Each case maps to one plain message and one action in the UI.
public enum ProviderError: Error, Equatable, Sendable {
    case unreachable
    case unauthorized
    case modelNotFound
    case contextTooLong
    case rateLimited(retryAfter: TimeInterval?)
    /// The account has run out of prepaid credit or hit its spending quota.
    case outOfCredit
    /// A 4xx with no more specific case, such as a parameter the model doesn't accept.
    case badRequest
    /// A 5xx.
    case server(status: Int)
    case truncated
    case cancelled
    case invalidResponse
    /// Plain http to a public address. Only loopback and private networks may skip TLS.
    case insecureURL
    /// A base URL with no host, such as `localhost:11434` without `http://`.
    case invalidURL
    case timedOut

    public var code: String {
        switch self {
        case .unreachable: "unreachable"
        case .unauthorized: "unauthorized"
        case .modelNotFound: "model_not_found"
        case .contextTooLong: "context_too_long"
        case .rateLimited: "rate_limited"
        case .outOfCredit: "out_of_credit"
        case .badRequest: "bad_request"
        case .server: "server"
        case .truncated: "truncated"
        case .cancelled: "cancelled"
        case .invalidResponse: "invalid_response"
        case .insecureURL: "insecure_url"
        case .invalidURL: "invalid_url"
        case .timedOut: "timed_out"
        }
    }

    /// Reads back a stored `code`, such as a failed meeting's detail. Cases with values get none.
    public init?(code: String) {
        let all: [ProviderError] = [.unreachable, .unauthorized, .modelNotFound, .contextTooLong, .rateLimited(retryAfter: nil),
                                    .outOfCredit, .badRequest, .server(status: 500), .truncated, .cancelled, .invalidResponse,
                                    .insecureURL, .invalidURL, .timedOut]
        guard let match = all.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    /// The plain sentence shown in Settings and on a meeting's banner.
    public var message: String {
        switch self {
        case .unreachable: "Honeycomb couldn't reach the provider. Check the address and that the server is running."
        case .unauthorized: "The API key was rejected. Check it in Settings → Models."
        case .modelNotFound: "The provider doesn't have this model. Pick another in Settings → Models."
        case .contextTooLong: "This meeting is too long for the model. Pick a model with a larger context."
        case .rateLimited: "The provider is busy or rate limited. Try again in a few minutes."
        case .outOfCredit: "Your account with the provider is out of credit or over its quota. Add credit on the provider's site, then try again."
        case .badRequest: "The provider refused the request. Check the model in Settings → Models, or pick another."
        case .server: "The provider had a server error. Try again in a few minutes."
        case .truncated: "The model stopped before the notes were finished. Regenerate to try again."
        case .cancelled: "The request was cancelled."
        case .invalidResponse: "The provider sent a reply Honeycomb couldn't read. Check the base URL."
        case .insecureURL: "Use an https address. Plain http only works for this Mac and your local network."
        case .invalidURL: "Enter the full address, such as http://localhost:11434 or https://api.openai.com/v1."
        case .timedOut: "The provider took too long to answer. Check that the server is running, then try again."
        }
    }

    /// Errors worth retrying: they may pass on their own. A request error or an empty account
    /// fails the same way every time.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .rateLimited, .server, .timedOut: true
        default: false
        }
    }
}

/// A chat model: the built-in Qwen, an OpenAI-compatible server (Ollama, LM Studio, OpenRouter,
/// OpenAI), or Anthropic. The stream yields text pieces, then one `.finished`.
public protocol ChatProvider: Sendable {
    func models() async throws -> [ModelInfo]
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error>
}

public protocol EmbeddingProvider: Sendable {
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension ChatProvider {
    /// Collects the whole answer. Throws `.truncated` if the model ran out of output tokens.
    /// A stream that ends without `.finished` was cut off, usually because this task was cancelled,
    /// so it throws `CancellationError` instead of returning part of the answer.
    public func complete(_ request: ChatRequest) async throws -> String {
        var text = ""
        for try await delta in stream(request) {
            switch delta {
            case .text(let piece): text += piece
            case .finished(.length): throw ProviderError.truncated
            case .finished(.stop): return text
            }
        }
        throw CancellationError()
    }
}
