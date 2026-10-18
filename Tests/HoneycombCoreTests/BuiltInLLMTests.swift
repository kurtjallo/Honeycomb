import Foundation
import Synchronization
import Testing
@testable import HoneycombCore

/// Stands in for MLX. Each model is its folder name, and every call is logged in order.
final class FakeRuntime: LLMRuntime {
    private let log = Mutex<[String]>([])

    var events: [String] { log.withLock { $0 } }

    func load(from folder: URL) async throws -> String {
        log.withLock { $0.append("load \(folder.lastPathComponent)") }
        return folder.lastPathComponent
    }

    func clearCache() {
        log.withLock { $0.append("clear") }
    }

    func limitCache(recording: Bool) {}
}

struct BuiltInLLMTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("llm-\(UUID().uuidString)")
    let runtime = FakeRuntime()
    let small = ModelCatalog.builtInLLM
    let large = ModelCatalog.largeLLM

    /// The store counts a model as downloaded when its folder exists.
    func makeLLM(downloaded: [String], idleUnload: Duration = .seconds(300)) throws -> (LocalLLM<FakeRuntime>, ModelHost) {
        for id in downloaded {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder(id)), withIntermediateDirectories: true)
        }
        let store = ModelStore(root: root, database: nil)
        let host = ModelHost(store: store)
        return (LocalLLM(store: store, host: host, runtime: runtime, idleUnload: idleUnload), host)
    }

    func folder(_ id: String) -> String {
        ModelCatalog.spec(id)?.folderName ?? id
    }

    @Test("switching models waits for the old model's last user and unloads it before the new one loads")
    func switchWaitsForTheOldModel() async throws {
        let (llm, _) = try makeLLM(downloaded: [small, large])
        _ = try await llm.use(small)

        let switching = (0..<2).map { _ in Task { try await llm.use(large) } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(runtime.events == ["load \(folder(small))"], "the 9B doesn't load while the 4B is in use")

        await llm.done(small)
        for task in switching { #expect(try await task.value == folder(large)) }
        #expect(runtime.events == ["load \(folder(small))", "clear", "load \(folder(large))"])
        #expect(await llm.loadedModel == large)
    }

    @Test("during a recording, the 9B that is already loaded can't be used")
    func recordingRefusesTheLoaded9B() async throws {
        let (llm, host) = try makeLLM(downloaded: [large])
        _ = try await llm.use(large)
        await llm.done(large)
        await host.setRecording(true)

        await #expect(throws: ModelHostError.notAllowedNow) { try await llm.use(large) }
    }

    @Test("a use that fails or is refused still lets the loaded model unload when idle", arguments: [false, true])
    func failedUseKeepsTheIdleUnload(recording: Bool) async throws {
        let (llm, host) = try makeLLM(downloaded: recording ? [small, large] : [small], idleUnload: .milliseconds(200))
        _ = try await llm.use(small)
        await llm.done(small)
        await host.setRecording(recording)

        await #expect(throws: (any Error).self) { try await llm.use(large) }

        let deadline = ContinuousClock.now + .seconds(3)
        while await llm.loadedModel != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await llm.loadedModel == nil)
        #expect(runtime.events == ["load \(folder(small))", "clear"], "the idle unload released the 4B's memory")
    }
}
