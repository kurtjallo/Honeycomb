import Foundation

/// ProseMirror JSON, exactly as the TipTap editor stores it. Swift and the editor share this
/// schema: paragraph, heading, bulletList, orderedList, listItem, taskList, taskItem, text,
/// hardBreak; marks bold, italic, code, link, ai.
public struct PMNode: Codable, Equatable, Sendable {
    public var type: String
    public var attrs: [String: JSONValue]?
    public var content: [PMNode]?
    public var text: String?
    public var marks: [PMMark]?

    public init(type: String, attrs: [String: JSONValue]? = nil, content: [PMNode]? = nil,
                text: String? = nil, marks: [PMMark]? = nil) {
        self.type = type
        self.attrs = attrs
        self.content = content
        self.text = text
        self.marks = marks
    }

    public static func doc(_ content: [PMNode]) -> PMNode { PMNode(type: "doc", content: content) }

    public static func text(_ text: String, marks: [PMMark] = []) -> PMNode {
        PMNode(type: "text", text: text, marks: marks.isEmpty ? nil : marks)
    }

    public var blockID: String? {
        if case .string(let id) = attrs?["blockId"] { return id }
        return nil
    }

    /// All text in this node, without formatting.
    public var plainText: String {
        if let text { return text }
        if type == "hardBreak" { return "\n" }
        return (content ?? []).map(\.plainText).joined(separator: type == "doc" ? "\n" : "")
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{\"type\":\"doc\"}"
    }

    public static func decode(_ json: String) -> PMNode? {
        try? JSONDecoder().decode(PMNode.self, from: Data(json.utf8))
    }

    /// Blocks that carry a block ID: paragraphs, headings, and list items.
    public static let identifiedBlocks: Set<String> = ["paragraph", "heading", "listItem", "taskItem"]
}

public struct PMMark: Codable, Equatable, Sendable {
    public var type: String
    public var attrs: [String: JSONValue]?

    public init(type: String, attrs: [String: JSONValue]? = nil) {
        self.type = type
        self.attrs = attrs
    }

    public static let bold = PMMark(type: "bold")
    public static let italic = PMMark(type: "italic")
    public static let code = PMMark(type: "code")
    public static let ai = PMMark(type: "ai")
    public static func link(_ href: String) -> PMMark { PMMark(type: "link", attrs: ["href": .string(href)]) }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .int(Int(value))
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
