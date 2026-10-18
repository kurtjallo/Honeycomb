import GRDB
import Foundation

/// Notes as HTML for pasting into Slack, Notion, Docs, or email, keeping headings and lists.
public enum NoteExport {
    public static func html(_ doc: PMNode) -> String {
        (doc.content ?? []).map(block).joined(separator: "\n")
    }

    static func block(_ node: PMNode) -> String {
        switch node.type {
        case "heading":
            var level = 2
            if case .int(let value) = node.attrs?["level"] { level = value }
            return "<h\(level)>\(inline(node.content ?? []))</h\(level)>"
        case "paragraph":
            return "<p>\(inline(node.content ?? []))</p>"
        case "bulletList", "taskList":
            return "<ul>" + (node.content ?? []).map { item in
                let box = node.type == "taskList" ? (item.attrs?["checked"] == .bool(true) ? "☑ " : "☐ ") : ""
                return "<li>" + box + (item.content ?? []).map { $0.type == "paragraph" ? inline($0.content ?? []) : block($0) }.joined() + "</li>"
            }.joined() + "</ul>"
        case "orderedList":
            var start = ""
            if case .int(let number) = node.attrs?["start"], number != 1 { start = " start=\"\(number)\"" }
            return "<ol\(start)>" + (node.content ?? []).map { item in
                "<li>" + (item.content ?? []).map { $0.type == "paragraph" ? inline($0.content ?? []) : block($0) }.joined() + "</li>"
            }.joined() + "</ol>"
        default:
            return "<p>\(escape(node.plainText))</p>"
        }
    }

    static func inline(_ nodes: [PMNode]) -> String {
        nodes.map { node in
            if node.type == "hardBreak" { return "<br>" }
            var text = escape(node.text ?? "")
            let marks = node.marks ?? []
            if marks.contains(.code) { text = "<code>\(text)</code>" }
            if marks.contains(.italic) { text = "<em>\(text)</em>" }
            if marks.contains(.bold) { text = "<strong>\(text)</strong>" }
            if let link = marks.first(where: { $0.type == "link" }), case .string(let href) = link.attrs?["href"],
               Markdown.isSafeLink(href) {
                text = "<a href=\"\(escape(href))\">\(text)</a>"
            }
            return text
        }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A safe file name from a meeting title: "Acme renewal hinges on SSO.md".
    public static func fileName(_ title: String, date: Date) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        let stem = cleaned.isEmpty ? "Meeting" : String(cleaned.prefix(80))
        return "\(date.formatted(.iso8601.year().month().day())) \(stem).md"
    }

    /// The Markdown file for a meeting: a heading, the date, the AI notes, and the transcript.
    public static func markdownFile(meeting: Meeting, notes: String, transcript: [TranscriptSegment]) -> String {
        var parts = ["# \(meeting.title)", (meeting.startAt ?? meeting.createdAt).formatted(date: .long, time: .shortened)]
        if !notes.isEmpty { parts.append(notes) }
        if !transcript.isEmpty {
            parts.append("## Transcript\n\n" + NotesPrompt.transcript(transcript))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}

extension AppDatabase {
    public func sourcedBlocks(_ enhanced: UUID) throws -> [String] {
        try reader.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT block_id FROM note_source WHERE enhanced_id = ?", arguments: [enhanced])
        }
    }

    public func sources(_ enhanced: UUID, block: String) throws -> [TranscriptSegment] {
        try reader.read { db in
            try TranscriptSegment.fetchAll(db, sql: """
                SELECT segment.* FROM note_source JOIN segment ON segment.id = note_source.segment_id
                WHERE note_source.enhanced_id = ? AND note_source.block_id = ? ORDER BY note_source.score DESC
                """, arguments: [enhanced, block])
        }
    }
}
