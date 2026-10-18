import Foundation

/// Where Honeycomb keeps its files. Tests point `root` at a temporary folder.
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let standard = Paths(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Honeycomb", isDirectory: true)
    )

    public var database: URL { root.appendingPathComponent("honeycomb.sqlite") }
    public var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    public var audio: URL { root.appendingPathComponent("Audio", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("Cache", isDirectory: true) }

    public func audioFolder(for meeting: UUID) -> URL {
        audio.appendingPathComponent(meeting.uuidString, isDirectory: true)
    }

    public static var logs: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Honeycomb", isDirectory: true)
    }

    public func createFolders() throws {
        for folder in [root, backups, audio, models, cache] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Models can be downloaded again, so Time Machine skips them.
        var models = self.models
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? models.setResourceValues(values)
    }
}
