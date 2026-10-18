import Foundation
import Synchronization
import Testing
@testable import HoneycombCore

/// Stands in for MLX. Each model is its folder name, and every call is logged in order.
/// After `holdLoads()`, a load is logged when it starts and returns only on `releaseLoads()`, like a slow MLX load.
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
        host.gate.set(true)

        await #expect(throws: ModelHostError.notAllowedNow) { try await llm.use(large) }
    }

    @Test("a use that fails or is refused still lets the loaded model unload when idle", arguments: [false, true])
    func failedUseKeepsTheIdleUnload(recording: Bool) async throws {
        let (llm, host) = try makeLLM(downloaded: recording ? [small, large] : [small], idleUnload: .milliseconds(200))
        _ = try await llm.use(small)
        await llm.done(small)
        host.gate.set(recording)

        await #expect(throws: (any Error).self) { try await llm.use(large) }

        let deadline = ContinuousClock.now + .seconds(3)
        while await llm.loadedModel != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await llm.loadedModel == nil)
        #expect(runtime.events == ["load \(folder(small))", "clear"], "the idle unload released the 4B's memory")
    }

    enum Interruption: CaseIterable {
        case cancel
        case recordingStarts
    }

    func interrupt(_ use: Task<String, any Error>, _ interruption: Interruption, host: ModelHost) async {
        switch interruption {
        case .cancel: use.cancel()
        case .recordingStarts: host.gate.set(true)
        }
    }

    func expectFailure(of use: Task<String, any Error>, after interruption: Interruption) async {
        switch interruption {
        case .cancel: await #expect(throws: CancellationError.self) { try await use.value }
        case .recordingStarts: await #expect(throws: ModelHostError.notAllowedNow) { try await use.value }
        }
    }

    @Test("a use cancelled, or overtaken by a recording, while it waits for the old model's last user never loads the new model",
          arguments: Interruption.allCases)
    func interruptedWhileWaiting(_ interruption: Interruption) async throws {
        let (llm, host) = try makeLLM(downloaded: [small, large])
        _ = try await llm.use(small)
        let switching = Task { try await llm.use(large) }
        try await Task.sleep(for: .milliseconds(200))

        await interrupt(switching, interruption, host: host)
        await llm.done(small)

        await expectFailure(of: switching, after: interruption)
        #expect(!runtime.events.contains("load \(folder(large))"))
        #expect(await llm.loadedModel == nil)
    }

    @Test("a use cancelled, or overtaken by a recording, during a slow load doesn't keep the model or go on to use it",
          arguments: Interruption.allCases)
    func interruptedDuringLoad(_ interruption: Interruption) async throws {
        let (llm, host) = try makeLLM(downloaded: [large])
        runtime.holdLoads()
        let using = Task { try await llm.use(large) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !runtime.events.contains("load \(folder(large))"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        await interrupt(using, interruption, host: host)
        runtime.releaseLoads()

        await expectFailure(of: using, after: interruption)
        #expect(await llm.loadedModel == nil, "the model is dropped at once, not after the idle wait")
        #expect(runtime.events.last == "clear", "MLX's buffer cache is released with it")
    }
}
