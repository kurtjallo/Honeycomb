import Foundation

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
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
    public var messages: [ChatMessage]
    /// Output tokens reserved for the answer.
    public var maxTokens: Int
    public var temperature: Double

    public init(messages: [ChatMessage], maxTokens: Int = 2_000, temperature: Double = 0.3) {
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

public enum ChatError: String, Error, Sendable {
    case contextTooLong = "context_too_long"
    case truncated
    case cancelled

    public var message: String {
        switch self {
        case .contextTooLong: "This meeting is too long for the AI model to write notes."
        case .truncated: "The model stopped before the notes were finished. Regenerate to try again."
        case .cancelled: "The request was cancelled."
        }
    }
}

/// The stream yields text pieces, then one `.finished`.
public protocol ChatProvider: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error>
}
