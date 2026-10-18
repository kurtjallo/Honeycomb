import Foundation
import os

/// A value allowed in a log line. Text only enters as `StaticString`, so transcript text,
/// notes, titles, emails, and keys can't reach the logs.
public enum LogValue: Sendable {
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case id(UUID)
    case code(StaticString)

    var json: Any {
        switch self {
        case .int(let value): value
        case .double(let value): (value * 1000).rounded() / 1000
        case .bool(let value): value
        case .id(let value): value.uuidString
        case .code(let value): value.description
        }
    }
}

extension LogValue {
    public static func int(_ value: Int) -> LogValue { .int(Int64(value)) }
    public static func status(_ value: OSStatus) -> LogValue { .int(Int64(value)) }
    public static func seconds(_ value: Duration) -> LogValue {
        let (seconds, attoseconds) = value.components
        return .double(Double(seconds) + Double(attoseconds) / 1e18)
    }
}

/// JSON-lines logger at `~/Library/Logs/Honeycomb`, rotated across 5 files of 5 MB.
public enum Log {
    public static func info(_ event: StaticString, _ fields: KeyValuePairs<StaticString, LogValue> = [:]) {
        write(level: "info", event, fields)
    }

    public static func error(_ event: StaticString, _ fields: KeyValuePairs<StaticString, LogValue> = [:]) {
        write(level: "error", event, fields)
    }

    private static let system = Logger(subsystem: "io.github.kurtjallo.Honeycomb", category: "app")
    /// Only the app writes the log file. Test runners and command-line tools have no bundle ID.
    private static let file: LogFile? = Bundle.main.bundleIdentifier == nil ? nil : LogFile(folder: Paths.logs)

    private static func write(level: String, _ event: StaticString, _ fields: KeyValuePairs<StaticString, LogValue>) {
        var line: [String: Any] = [
            "t": ISO8601DateFormatter.logStamp.string(from: Date()),
            "level": level,
            "event": event.description,
        ]
        for (key, value) in fields { line[key.description] = value.json }
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return }
        system.log("\(text, privacy: .public)")
        file?.append(text + "\n")
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let logStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

final class LogFile: @unchecked Sendable {
    private let folder: URL
    private let queue = DispatchQueue(label: "honeycomb.log")
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private let maxSize: UInt64 = 5 * 1024 * 1024
    private let keep = 5

    init(folder: URL) {
        self.folder = folder
    }

    private var current: URL { folder.appendingPathComponent("honeycomb.log") }

    func append(_ line: String) {
        queue.async { [self] in
            if handle == nil { open() }
            guard let handle else { return }
            let data = Data(line.utf8)
            handle.write(data)
            size += UInt64(data.count)
            if size > maxSize { rotate() }
        }
    }

    private func open() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: current.path) {
            FileManager.default.createFile(atPath: current.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: current)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(at: folder.appendingPathComponent("honeycomb.\(keep - 1).log"))
        for index in stride(from: keep - 2, through: 1, by: -1) {
            try? manager.moveItem(at: folder.appendingPathComponent("honeycomb.\(index).log"),
                                  to: folder.appendingPathComponent("honeycomb.\(index + 1).log"))
        }
        try? manager.moveItem(at: current, to: folder.appendingPathComponent("honeycomb.1.log"))
        open()
    }
}
