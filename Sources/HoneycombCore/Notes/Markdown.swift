import Foundation

/// Converts between Markdown (what models write and what users export) and the editor's
/// ProseMirror document. Only the subset notes use: headings, paragraphs, bullet, numbered,
/// and task lists (nested), bold, italic, code, and http, https, or mailto links. HTML is
/// never interpreted: it stays literal text.
public enum Markdown {
    // MARK: Markdown to document

    public static func document(_ markdown: String, newBlockID: () -> String = Markdown.newBlockID) -> PMNode {
        var blocks: [PMNode] = []
        var paragraph: [String] = []
        var listLines: [ListLine] = []
        var code: [String]?
        var blankInList = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(block("paragraph", inline(paragraph.reduce("", joinLine).trimmingCharacters(in: .newlines)), newBlockID()))
            paragraph = []
        }
        func flushList() {
            guard !listLines.isEmpty else { return }
            var index = 0
            blocks += lists(listLines, level: listLines.map(\.level).min() ?? 0, index: &index, newBlockID: newBlockID)
            listLines = []
        }
        func flushCode() {
            guard let lines = code else { return }
            code = nil
            let content = lines.enumerated().flatMap { offset, line in
                (offset == 0 ? [] : [PMNode(type: "hardBreak")]) + (line.isEmpty ? [] : [PMNode.text(line, marks: [.code])])
            }
            if !content.isEmpty { blocks.append(block("paragraph", content, newBlockID())) }
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineEnd = line.hasSuffix("  ") ? "\n" : ""
            if code != nil {
                if trimmed.hasPrefix("```") { flushCode() } else { code?.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushList()
                code = []
                continue
            }
            if trimmed.isEmpty || isRule(trimmed) {
                flushParagraph()
                if trimmed.isEmpty && !listLines.isEmpty {
                    blankInList = true
                    continue
                }
                flushList()
                continue
            }
            let afterBlank = blankInList
            blankInList = false
            if let heading = headingLine(trimmed) {
                flushParagraph()
                flushList()
                blocks.append(PMNode(type: "heading", attrs: ["level": .int(heading.level), "blockId": .string(newBlockID())],
                                     content: nonEmpty(inline(heading.text))))
                continue
            }
            if var item = listLine(line) {
                flushParagraph()
                item.text += lineEnd
                listLines.append(item)
                continue
            }
            if !listLines.isEmpty, line.hasPrefix("  ") {
                listLines[listLines.count - 1].addLine(trimmed + lineEnd, startsParagraph: afterBlank)
                continue
            }
            flushList()
            let isRow = trimmed.hasPrefix("|")
            if let last = paragraph.last, last.hasPrefix("|") != isRow { flushParagraph() }
            paragraph.append((trimmed.hasPrefix(">") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed)
                             + (isRow ? "\n" : lineEnd))
        }
        flushParagraph()
        flushList()
        flushCode()
        return .doc(blocks.isEmpty ? [PMNode(type: "paragraph", attrs: ["blockId": .string(newBlockID())])] : blocks)
    }

    static func joinLine(_ text: String, _ line: String) -> String {
        text.isEmpty || text.hasSuffix("\n") ? text + line : text + " " + line
    }

    public static func newBlockID() -> String {
        "b" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
    }

    struct ListLine {
        enum Kind { case bullet, ordered, task }
        var level: Int
        var kind: Kind
        var checked: Bool
        var start: Int
        var text: String
        var laterParagraphs: [String] = []

        mutating func addLine(_ line: String, startsParagraph: Bool) {
            if startsParagraph {
                laterParagraphs.append(line)
            } else if laterParagraphs.isEmpty {
                text = Markdown.joinLine(text, line)
            } else {
                laterParagraphs[laterParagraphs.count - 1] = Markdown.joinLine(laterParagraphs[laterParagraphs.count - 1], line)
            }
        }
    }

    static func listLine(_ line: String) -> ListLine? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        var kind = ListLine.Kind.bullet
        var start = 1
        var body: Substring
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            body = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let marker = after.first, ".)".contains(marker), after.dropFirst().first == " " else { return nil }
            kind = .ordered
            start = Int(digits) ?? 1
            body = after.dropFirst(2)
        }
        var checked = false
        if kind == .bullet, body.count >= 3, body.hasPrefix("["), ["[ ]", "[x]", "[X]"].contains(String(body.prefix(3))) {
            kind = .task
            checked = body.dropFirst().first != " "
            body = body.dropFirst(3)
        }
        return ListLine(level: indent / 2, kind: kind, checked: checked, start: start,
                        text: body.trimmingCharacters(in: .whitespaces))
    }

    static func lists(_ lines: [ListLine], level: Int, index: inout Int, newBlockID: () -> String) -> [PMNode] {
        var result: [PMNode] = []
        while index < lines.count, lines[index].level >= level {
            let kind = lines[index].kind
            let start = lines[index].start
            var items: [PMNode] = []
            while index < lines.count, lines[index].level >= level {
                if lines[index].level == level, lines[index].kind != kind { break }
                if lines[index].level > level, var last = items.popLast() {
                    let nested = lists(lines, level: lines[index].level, index: &index, newBlockID: newBlockID)
                    last.content = (last.content ?? []) + nested
                    items.append(last)
                    continue
                }
                let line = lines[index]
                let paragraphs = ([line.text] + line.laterParagraphs).map { text in
                    PMNode(type: "paragraph", content: nonEmpty(inline(text.trimmingCharacters(in: .newlines))))
                }
                var attrs: [String: JSONValue] = ["blockId": .string(newBlockID())]
                if kind == .task { attrs["checked"] = .bool(line.checked) }
                items.append(PMNode(type: kind == .task ? "taskItem" : "listItem", attrs: attrs, content: paragraphs))
                index += 1
            }
            switch kind {
            case .bullet: result.append(PMNode(type: "bulletList", content: items))
            case .task: result.append(PMNode(type: "taskList", content: items))
            case .ordered: result.append(PMNode(type: "orderedList", attrs: ["start": .int(start)], content: items))
            }
        }
        return result
    }

    static func headingLine(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return (min(hashes, 3), String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        line.count >= 3 && (Set(line) == ["-"] || Set(line) == ["*"] || Set(line) == ["_"])
    }

    static func block(_ type: String, _ content: [PMNode], _ id: String) -> PMNode {
        PMNode(type: type, attrs: ["blockId": .string(id)], content: nonEmpty(content))
    }

    static func nonEmpty(_ nodes: [PMNode]) -> [PMNode]? { nodes.isEmpty ? nil : nodes }

    // MARK: Inline

    public static func inline(_ text: String, marks: [PMMark] = []) -> [PMNode] {
        let chars = Array(text)
        var nodes: [PMNode] = []
        var plain = ""
        var index = 0

        func flush() {
            if !plain.isEmpty { nodes.append(.text(plain, marks: marks)) }
            plain = ""
        }
        func find(_ token: [Character], from start: Int) -> Int? {
            var position = start
            while position + token.count <= chars.count {
                if Array(chars[position..<position + token.count]) == token { return position }
                position += 1
            }
            return nil
        }
        func closingParen(from start: Int) -> Int? {
            var depth = 0
            for position in start..<chars.count {
                if chars[position] == "(" { depth += 1 }
                if chars[position] == ")" {
                    if depth == 0 { return position }
                    depth -= 1
                }
            }
            return nil
        }
        func adding(_ mark: PMMark) -> [PMMark] { marks.contains(mark) ? marks : marks + [mark] }

        while index < chars.count {
            let character = chars[index]
            if character == "\n" {
                flush()
                nodes.append(PMNode(type: "hardBreak"))
                index += 1
            } else if character == "`", let close = find(["`"], from: index + 1), close > index + 1 {
                flush()
                nodes.append(.text(String(chars[index + 1..<close]), marks: marks + [.code]))
                index = close + 1
            } else if character == "*" || character == "_",
                      index + 1 < chars.count, chars[index + 1] == character,
                      let close = find([character, character], from: index + 2), close > index + 2 {
                flush()
                nodes += inline(String(chars[index + 2..<close]), marks: adding(.bold))
                index = close + 2
            } else if character == "*" || (character == "_" && (index == 0 || !chars[index - 1].isLetter)),
                      index + 1 < chars.count, chars[index + 1] != " ",
                      let close = find([character], from: index + 1), close > index + 1,
                      character == "*" || close + 1 >= chars.count || !chars[close + 1].isLetter {
                flush()
                nodes += inline(String(chars[index + 1..<close]), marks: adding(.italic))
                index = close + 1
            } else if character == "[", let middle = find(["]"], from: index + 1),
                      middle + 1 < chars.count, chars[middle + 1] == "(", let close = closingParen(from: middle + 2) {
                flush()
                let label = String(chars[index + 1..<middle])
                let href = String(chars[middle + 2..<close]).trimmingCharacters(in: .whitespaces)
                nodes += inline(label, marks: isSafeLink(href) ? marks + [.link(href)] : marks)
                index = close + 1
            } else {
                plain.append(character)
                index += 1
            }
        }
        flush()
        return merge(nodes)
    }

    public static func isSafeLink(_ href: String) -> Bool {
        guard let scheme = URL(string: href)?.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }

    static func merge(_ nodes: [PMNode]) -> [PMNode] {
        var merged: [PMNode] = []
        for node in nodes where node.type != "text" || !(node.text ?? "").isEmpty {
            if var last = merged.last, last.type == "text", node.type == "text", last.marks == node.marks {
                last.text = (last.text ?? "") + (node.text ?? "")
                merged[merged.count - 1] = last
            } else {
                merged.append(node)
            }
        }
        return merged
    }

    // MARK: Document to Markdown

    public static func markdown(_ doc: PMNode) -> String {
        (doc.content ?? []).map { render($0, indent: "") }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func render(_ node: PMNode, indent: String) -> String {
        switch node.type {
        case "heading":
            var level = 1
            if case .int(let value) = node.attrs?["level"] { level = value }
            return String(repeating: "#", count: level) + " " + inlineMarkdown(node.content ?? [])
        case "paragraph":
            return indent + inlineMarkdown(node.content ?? []).replacingOccurrences(of: "\n", with: "\n" + indent)
        case "bulletList", "orderedList", "taskList":
            var number = 1
            if case .int(let start) = node.attrs?["start"] { number = start }
            return (node.content ?? []).map { item in
                let marker: String
                switch node.type {
                case "orderedList":
                    marker = "\(number). "
                    number += 1
                case "taskList":
                    marker = item.attrs?["checked"] == .bool(true) ? "- [x] " : "- [ ] "
                default:
                    marker = "- "
                }
                var lines: [String] = []
                for (offset, child) in (item.content ?? []).enumerated() {
                    if offset == 0, child.type == "paragraph" {
                        let text = inlineMarkdown(child.content ?? []).replacingOccurrences(of: "\n", with: "\n" + indent + "  ")
                        lines.append(indent + marker + text)
                    } else {
                        if child.type == "paragraph" { lines.append("") }
                        lines.append(render(child, indent: indent + "  "))
                    }
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")
        default:
            return node.plainText
        }
    }

    static func inlineMarkdown(_ nodes: [PMNode]) -> String {
        nodes.map { node in
            if node.type == "hardBreak" { return "  \n" }
            var text = node.text ?? ""
            let marks = node.marks ?? []
            if marks.contains(.code) { text = "`\(text)`" }
            if marks.contains(.italic) { text = "*\(text)*" }
            if marks.contains(.bold) { text = "**\(text)**" }
            if let link = marks.first(where: { $0.type == "link" }), case .string(let href) = link.attrs?["href"] {
                text = "[\(text)](\(href))"
            }
            return text
        }.joined()
    }
}

/// Grey AI text versus your own words. A block that restates one of your typed notes keeps
/// normal color. With no typed notes, nothing is marked and the notes show in normal color.
public enum Authorship {
    public static func apply(to doc: PMNode, userNotes: String) -> PMNode {
        let userLines = userNotes.components(separatedBy: .newlines).map(words).filter { $0.count >= 2 }
        guard !userLines.isEmpty else { return doc }
        return mark(doc, userLines: userLines)
    }

    static func mark(_ node: PMNode, userLines: [Set<String>]) -> PMNode {
        var node = node
        if node.type == "heading" { return node }
        if node.type == "paragraph" {
            let blockWords = words(node.plainText)
            let restatesUser = userLines.contains { line in
                Double(line.intersection(blockWords).count) / Double(line.count) >= 0.5
            }
            if !restatesUser {
                node.content = node.content?.map { child in
                    var child = child
                    if child.type == "text" { child.marks = (child.marks ?? []) + [.ai] }
                    return child
                }
            }
            return node
        }
        node.content = node.content?.map { mark($0, userLines: userLines) }
        return node
    }

    static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with", "is", "are",
                                         "was", "be", "it", "that", "this", "by", "at", "as", "we", "i", "you", "they"]

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(stopwords)
    }
}
