import Foundation
import Testing
@testable import HoneycombCore

/// Downloads the real 1 MB voice-detector model. Run with HONEYCOMB_NETWORK_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HONEYCOMB_NETWORK_TESTS"] == "1"))
struct ModelStoreNetworkTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")

    @Test func downloadsVerifiesAndResumes() async throws {
        let spec = try #require(ModelCatalog.spec(ModelCatalog.vad))
        let weights = try #require(spec.files.first { $0.path.hasSuffix("weight.bin") })
        let partial = root.appendingPathComponent(spec.folderName + ".partial")
        let half = try await URLSession.shared.data(for: {
            var request = URLRequest(url: spec.url(for: weights))
            request.setValue("bytes=0-\(weights.size / 2 - 1)", forHTTPHeaderField: "Range")
            return request
        }()).0
        #expect(Int64(half.count) == weights.size / 2)
        let target = partial.appendingPathComponent(weights.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try half.write(to: target)

        let store = ModelStore(root: root, database: try AppDatabase.inMemory())
        try await store.install(spec.id)
        #expect(await store.isReady(spec.id))
        let folder = try #require(await store.folder(spec.id))
        #expect(try FileDownload.sha256(of: folder.appendingPathComponent(weights.path)) == weights.sha256)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func corruptFileIsRejected() async throws {
        let spec = try #require(ModelCatalog.spec(ModelCatalog.vad))
        let weights = try #require(spec.files.first { $0.path.hasSuffix("weight.bin") })
        let target = root.appendingPathComponent(spec.folderName + ".partial").appendingPathComponent(weights.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: Int(weights.size)).write(to: target)

        let store = ModelStore(root: root, database: nil)
        await #expect(throws: DownloadError.checksumMismatch(weights.path)) { try await store.install(spec.id) }
        #expect(await store.state(spec.id) == .failed("checksum_mismatch"))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

struct ModelStoreTests {
    @Test func lowDiskStopsADownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        let store = ModelStore(root: root, database: nil, freeBytes: { 1_000 })
        await #expect(throws: DownloadError.self) { try await store.install(ModelCatalog.parakeet) }
        #expect(await store.state(ModelCatalog.parakeet) == .failed("low_disk"))
    }

    @Test func catalogIsPinned() {
        for spec in ModelCatalog.all {
            #expect(spec.revision.count == 40)
            #expect(spec.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
        }
        #expect(ModelCatalog.firstRun.allSatisfy { ModelCatalog.spec($0) != nil })
    }
}

/// Fills the app's real models folder, like first launch does. Run with HONEYCOMB_INSTALL_MODELS=<ids, comma separated>.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HONEYCOMB_INSTALL_MODELS"] != nil))
struct InstallModels {
    @Test func install() async throws {
        let ids = ProcessInfo.processInfo.environment["HONEYCOMB_INSTALL_MODELS"]!.split(separator: ",").map(String.init)
        try Paths.standard.createFolders()
        let database = try AppDatabase.open(at: Paths.standard.database, backups: Paths.standard.backups)
        let store = ModelStore(root: Paths.standard.models, database: database)
        for id in ids { try await store.install(id) }
    }
}
