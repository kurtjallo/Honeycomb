import Foundation
import Synchronization
import Testing
@testable import HoneycombCore

/// Stands in for MLX. Each model is its folder name, and every call is logged in order.
final class FakeRuntime: LLMRuntime {
    private let log = Mutex<[String]>([])
    private let held = Mutex<(holding: Bool, loads: [CheckedContinuation<Void, Never>])>((false, []))

    var events: [String] { log.withLock { $0 } }

    func holdLoads() {
        held.withLock { $0.holding = true }
    }

    func releaseLoads() {
        let loads = held.withLock { held in
            defer { held = (false, []) }
            return held.loads
        }
        for load in loads { load.resume() }
    }

    func load(from folder: URL) async throws -> String {
        let event = "load \(folder.lastPathComponent)"
        if held.withLock({ $0.holding }) {
            await withCheckedContinuation { load in
                held.withLock { $0.loads.append(load) }
                log.withLock { $0.append(event) }
            }
        } else {
            log.withLock { $0.append(event) }
        }
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
    let folder = ModelCatalog.spec(ModelCatalog.builtInLLM)!.folderName

    /// The store counts a model as downloaded when its folder exists.
    func makeLLM(idleUnload: Duration = .seconds(300)) throws -> LocalLLM<FakeRuntime> {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        let store = ModelStore(root: root, database: nil)
        return LocalLLM(store: store, host: ModelHost(store: store), runtime: runtime, idleUnload: idleUnload)
    }

    @Test("the model unloads after its last user has been idle for the wait")
    func unloadsWhenIdle() async throws {
        let llm = try makeLLM(idleUnload: .milliseconds(200))
        _ = try await llm.use()
        await llm.done()

        let deadline = ContinuousClock.now + .seconds(3)
        while await llm.isLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await !llm.isLoaded)
        #expect(runtime.events == ["load \(folder)", "clear"], "the idle unload released the model's memory")
    }

    @Test("a use cancelled during a slow load doesn't keep the model or go on to use it")
    func cancelledDuringLoad() async throws {
        let llm = try makeLLM()
        runtime.holdLoads()
        let using = Task { try await llm.use() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !runtime.events.contains("load \(folder)"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        using.cancel()
        runtime.releaseLoads()

        await #expect(throws: CancellationError.self) { try await using.value }
        #expect(await !llm.isLoaded, "the model is dropped at once, not after the idle wait")
        #expect(runtime.events.last == "clear", "MLX's buffer cache is released with it")
    }

    @Test("a use that arrives during a load waits for that load instead of starting another")
    func usesDuringALoadShareIt() async throws {
        let llm = try makeLLM()
        runtime.holdLoads()
        let uses = (0..<2).map { _ in Task { try await llm.use() } }
        let deadline = ContinuousClock.now + .seconds(3)
        while !runtime.events.contains("load \(folder)"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))

        runtime.releaseLoads()

        for use in uses { #expect(try await use.value == folder) }
        #expect(runtime.events == ["load \(folder)"])
    }
}
