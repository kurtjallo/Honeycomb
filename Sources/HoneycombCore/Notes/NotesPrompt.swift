import Foundation

/// Builds the prompt that turns a transcript (and any notes you typed) into notes in a template's
/// sections. Typed notes are optional: without them the prompt has no "My notes" part.
public enum NotesPrompt {
    public struct Meeting: Sendable {
        public var title: String
        public var startedAt: Date?
        public var durationMs: Int64?
        public var appName: String?
        public var template: TemplateRecord
        public var userNotes: String
        public var terms: [String]

        public init(title: String, startedAt: Date?, durationMs: Int64?, appName: String?, template: TemplateRecord,
                    userNotes: String, terms: [String]) {
            self.title = title
            self.startedAt = startedAt
            self.durationMs = durationMs
            self.appName = appName
            self.template = template
            self.userNotes = userNotes
            self.terms = terms
        }
    }

    /// Room kept for the answer.
    public static let outputTokens = 2_000

    public static func system(_ meeting: Meeting) -> String {
        var rules = """
        You write meeting notes from a call transcript.

        Format:
        - Markdown only. The first line is "# " and a short title for the meeting, at most 8 words.
        - Then these sections as "## " headings, in this order: \(meeting.template.sections.joined(separator: ", ")).
        - Leave out a section only if nothing in the call fits it. Never fill a section with guesses.
        - Short bullets, most important first. Action items are "- [ ] " checkboxes.

        Accuracy:
        - Use only what the transcript says. Never invent names, numbers, dates, owners, or decisions.
        - Name an owner only if the transcript makes clear who will do it. Add a date only if someone said one.
        - "Me" is the person these notes are for. "Them" is everyone else on the call. Use people's names when they're said.
        - The transcript comes from speech recognition, so fix obvious misheard words from context.
        """
        if !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rules += """

            - "My notes" are what I typed during the call. They mark what matters most. Every point in them must appear in the notes, expanded with detail from the transcript.
            """
        }
        if !meeting.terms.isEmpty {
            rules += "\n- Spell these names and terms exactly like this: \(meeting.terms.joined(separator: ", "))."
        }
        rules += "\n\nFocus for this kind of meeting: \(meeting.template.instructions)"
        return rules
    }

    public static func user(_ meeting: Meeting, transcript: String, isSummary: Bool = false) -> String {
        var lines = ["Meeting: \(meeting.title)"]
        if let start = meeting.startedAt { lines.append("Date: \(start.formatted(date: .abbreviated, time: .shortened))") }
        if let duration = meeting.durationMs { lines.append("Length: \(max(1, duration / 60_000)) minutes") }
        if let app = meeting.appName { lines.append("Call app: \(app)") }
        let notes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { lines.append("\n## My notes\n\(notes)") }
        lines.append(isSummary ? "\n## Transcript, summarized in parts\n\(transcript)" : "\n## Transcript\n\(transcript)")
        return lines.joined(separator: "\n")
    }

    /// "[12:04] Them: We'd renew if SSO lands by end of Q1."
    public static func transcript(_ segments: [TranscriptSegment]) -> String {
        segments.map { line in
            "[\(Duration.milliseconds(line.startMs).formatted(.time(pattern: .minuteSecond)))] \(line.channel == .me ? "Me" : "Them"): \(line.text)"
        }.joined(separator: "\n")
    }

    /// Characters ÷ 3 plus a 20% margin: a safe overestimate for English with these tokenizers.
    public static func estimateTokens(_ text: String) -> Int {
        Int(Double(text.count) / 3 * 1.2)
    }

    /// Splits a transcript into parts that each fit in `tokens`, breaking only between lines.
    public static func parts(_ transcript: String, maxTokens tokens: Int) -> [String] {
        var parts: [String] = []
        var current: [Substring] = []
        var size = 0
        for line in transcript.split(separator: "\n") {
            let cost = estimateTokens(String(line)) + 1
            if size + cost > tokens, !current.isEmpty {
                parts.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(line)
            size += cost
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    public static let partSystem = """
    You summarize one part of a longer call transcript so notes can be written from all parts later.
    List every point discussed, decision, action item (with owner and date only if said), number, and name, as short bullets.
    Start each bullet with the [mm:ss] time it came from. Use only what the transcript says. Output only the bullets.
    """

    /// Splits the model's output into the title line and the notes body. A first line that names
    /// one of the template's sections is a heading the model wrote at the wrong level, not a title.
    public static func parseOutput(_ text: String, sections: [String]) -> (title: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("# ") else { return (nil, trimmed) }
        let firstLine = trimmed.prefix { $0 != "\n" }
        let title = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        if sections.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) { return (nil, trimmed) }
        let body = trimmed.dropFirst(firstLine.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? nil : String(title.prefix(80)), body)
    }
}
