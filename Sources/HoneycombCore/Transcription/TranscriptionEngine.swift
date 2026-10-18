/// A word with its time in milliseconds, relative to the start of the audio it came from.
public struct TimedWord: Sendable, Equatable {
    public var text: String
    public var startMs: Int64
    public var endMs: Int64

    public init(_ text: String, _ startMs: Int64, _ endMs: Int64) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct TranscriptPiece: Sendable, Equatable {
    public var text: String
    public var words: [TimedWord]

    public init(text: String, words: [TimedWord]) {
        self.text = text
        self.words = words
    }
}

/// Speech-to-text. Parakeet and Apple's engine implement it, and tests use a fake.
/// Input is 16 kHz mono. Engines load in `prepare()` and free memory in `release()`.
public protocol TranscriptionEngine: Sendable {
    var engineID: String { get }
    func prepare() async throws
    func transcribe(_ samples: [Float]) async throws -> TranscriptPiece
    func release() async
}

/// One transcript line on the session clock.
public struct TranscriptLine: Sendable, Equatable, Identifiable {
    public var id: String { "\(channel.rawValue)-\(startMs)" }
    public var channel: Channel
    public var startMs: Int64
    public var endMs: Int64
    public var text: String

    public init(channel: Channel, startMs: Int64, endMs: Int64, text: String) {
        self.channel = channel
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// Groups timed words into readable lines: a new line after a sentence ends, after a pause
/// longer than 1 second, or at 60 words.
public enum LineBuilder {
    public static func lines(from words: [TimedWord], channel: Channel, offsetMs: Int64,
                             maxGapMs: Int64 = 1_000, maxWords: Int = 60) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            lines.append(TranscriptLine(channel: channel, startMs: offsetMs + first.startMs,
                                        endMs: offsetMs + last.endMs, text: text))
            current = []
        }

        for word in words where !word.text.isEmpty {
            if let last = current.last, word.startMs - last.endMs > maxGapMs { flush() }
            current.append(word)
            let endsSentence = word.text.last.map { ".?!".contains($0) } ?? false
            if (endsSentence && current.count >= 3) || current.count >= maxWords { flush() }
        }
        flush()
        return lines
    }
}
