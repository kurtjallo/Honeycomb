import Foundation

public struct ModelFile: Sendable, Equatable {
    public let path: String
    public let size: Int64
    public let sha256: String
}

/// A model pinned to one Hugging Face commit, with every file's size and hash.
public struct ModelSpec: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: ModelKind
    public let name: String
    public let repo: String
    public let revision: String
    public let license: String
    public let credit: String
    public let files: [ModelFile]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var folderName: String { "\(id)@\(revision.prefix(12))" }

    public func url(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
    }
}

public enum ModelCatalog {
    public static var all: [ModelSpec] { generated }

    public static func spec(_ id: String) -> ModelSpec? {
        all.first { $0.id == id }
    }

    public static let vad = "silero-vad"
    public static let parakeet = "parakeet-tdt-0.6b-v2"
    public static let builtInLLM = "qwen3.5-4b"
    public static let embedder = "qwen3-embedding-0.6b"
}
