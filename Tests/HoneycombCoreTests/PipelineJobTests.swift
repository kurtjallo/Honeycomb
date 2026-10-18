import Foundation
import Testing
@testable import HoneycombCore

/// The job loop with fake handlers and short timings. No model loads.
struct PipelineJobTests {
    static let fast = Pipeline.Policy(waitRetry: 0.05, idlePoll: 0.05, retryDelays: [0.05], maxAttempts: 3)

    let database: AppDatabase
    let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString)"))
    let host: ModelHost
    let pipeline: Pipeline
    let meeting: Meeting

    init() throws {
        database = try AppDatabase.inMemory()
        try database.seedBuiltIns()
        host = ModelHost(store: ModelStore(root: paths.models, database: nil))
        pipeline = Pipeline(database: database, paths: paths, host: host, policy: Self.fast)
        meeting = Meeting(title: "Zoom call", state: .ready)
        try database.insert(meeting)
    }

    func handle(_ enhance: @escaping @Sendable (UUID) async throws -> NoteWriter.Outcome) async {
        var handlers = Pipeline.Handlers()
        handlers.enhance = enhance
        await pipeline.setHandlers(handlers)
    }

    func enhanceJob() throws -> Job? {
        try database.jobs(for: meeting.id).last { $0.kind == .enhance }
    }

    func eventually(seconds: Double = 2, _ check: () async throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await check() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func stopPutsTheJobBackAndEndsTheLoop() async throws {
        let calls = CallCounter()
        await handle { _ in
            await calls.add()
            try await Task.sleep(for: .seconds(30))
            return .written(UUID())
        }
        await pipeline.start()
        await pipeline.enqueue(.enhance, meeting: meeting.id)
        #expect(await eventually { await calls.count == 1 })

        await pipeline.stop()
        #expect(try await eventually { try enhanceJob()?.status == .queued })
        await pipeline.nudge()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await calls.count == 1, "the loop stopped")
    }

    @Test func noModelJobStartsOnceTheRecordingGateIsSet() async throws {
        let calls = CallCounter()
        await handle { _ in
            await calls.add()
            return .written(UUID())
        }
        await pipeline.start()
        host.gate.set(true)
        await pipeline.enqueue(.enhance, meeting: meeting.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await calls.count == 0, "the loop read the gate before claiming")
        #expect(try enhanceJob()?.status == .queued)

        host.gate.set(false)
        await pipeline.nudge()
        #expect(await eventually { await calls.count == 1 })
        await pipeline.stop()
    }

    func routeNotes(to baseURL: String) throws {
        try database.saveProvider(ProviderRecord(id: "server", name: "Server", kind: .openAICompatible, baseUrl: baseURL,
                                                 contextTokens: 32_000, isLocal: false))
        try database.saveRoute(Route(task: .enhance, providerId: "server", model: "m"))
    }

    @Test(arguments: [("https://api.openai.com/v1", false), ("http://192.168.1.20:11434/v1", false),
                      ("http://localhost:11434/v1", true), ("http://127.0.0.1:1234/v1", true), ("http://[::1]:11434/v1", true)])
    func aRecordingStopsNotesOnlyWhenTheyRunOnThisMac(baseURL: String, onThisMac: Bool) async throws {
        try routeNotes(to: baseURL)
        let calls = CallCounter()
        let release = AsyncStream<Void>.makeStream()
        await handle { _ in
            await calls.add()
            for await _ in release.stream { break }
            try Task.checkCancellation()
            return .written(UUID())
        }
        await pipeline.start()
        await pipeline.enqueue(.enhance, meeting: meeting.id)
        #expect(await eventually { await calls.count == 1 })

        host.gate.set(true)
        await pipeline.recordingStarted()
        release.continuation.yield()
        if onThisMac {
            #expect(try await eventually { try enhanceJob()?.status == .queued }, "the notes wait for the recording")
        } else {
            #expect(try await eventually { try enhanceJob()?.status == .done }, "the notes finish during the recording")
            #expect(try database.meeting(meeting.id)?.state == .indexing)
        }
        await pipeline.stop()
    }

    @Test func notesOnAnotherMachineStartDuringARecording() async throws {
        try routeNotes(to: "https://api.openai.com/v1")
        let calls = CallCounter()
        await handle { _ in
            await calls.add()
            return .written(UUID())
        }
        host.gate.set(true)
        await pipeline.start()
        await pipeline.enqueue(.enhance, meeting: meeting.id)
        #expect(await eventually { await calls.count == 1 })
        await pipeline.stop()
    }

    @Test func stopPutsAJobThatIgnoresCancellationBackAtOnce() async throws {
        let latch = Latch()
        await handle { _ in
            await latch.wait()
            return .written(UUID())
        }
        await pipeline.start()
        await pipeline.enqueue(.enhance, meeting: meeting.id)
        #expect(try await eventually { try enhanceJob()?.status == .running })

        await pipeline.stop()
        let job = try #require(try enhanceJob())
        #expect(job.status == .queued, "a quit right now leaves the job queued, not running")
        #expect(job.attempt == 0, "a normal quit doesn't count as a crash")
        await latch.open()
    }

    @Test func launchFinishesAStopThatNeverReachedThePipeline() async throws {
        let stranded = Meeting(title: "Stopped, then crashed", state: .transcribing)
        let queued = Meeting(title: "Waiting for notes", state: .transcribing)
        try database.insert(stranded)
        try database.insert(queued)
        try database.enqueue(.enhance, meeting: queued.id)

        await pipeline.start()
        await pipeline.stop()
        #expect(try database.jobs(for: stranded.id).map(\.kind) == [.finalizeAudio])
        #expect(try database.jobs(for: queued.id).map(\.kind) == [.enhance])
    }

    @Test func retryAfterAFailedFinalPassRunsTheFinalPass() async throws {
        try database.appendLiveLines([TranscriptLine(channel: .them, startMs: 0, endMs: 2_000, text: "Live words only.")],
                                     meeting: meeting.id, engine: "test")
        await pipeline.retry(meeting.id)
        #expect(try database.jobs(for: meeting.id).map(\.kind) == [.finalizeAudio])
    }

    @Test func aFailedJobRetriesAfterThePolicyDelay() async throws {
        let calls = CallCounter()
        await handle { _ in
            if await calls.add() == 1 { throw ProviderError.unreachable }
            return .written(UUID())
        }
        await pipeline.start()
        await pipeline.enqueue(.enhance, meeting: meeting.id)
        #expect(await eventually { await calls.count == 2 })
        await pipeline.stop()
    }

    @Test func aNewRecordingPutsTheNotesBackInTheQueue() async throws {
        try database.replaceTranscript([
            TranscriptLine(channel: .them, startMs: 0, endMs: 3_000, text: "We'd renew if SSO lands by end of Q1."),
        ], duplicates: [], meeting: meeting.id, engine: "test")
        let streams = CallCounter()
        let provider = ScriptedChat { _, continuation in
            guard await streams.add() > 1 else {
                continuation.yield(.text("# Acme renewal\n\n## Summary\n\n- Renews if"))
                return
            }
            continuation.answer("# Acme renewal\n\n## Summary\n\n- Renews if SSO ships by Q1")
        }
        let writer = NoteWriter(database: database) { _ in
            ResolvedProvider(record: ProviderRecord(id: "builtin", name: "x", kind: .builtin, contextTokens: 32_000, isLocal: true),
                             model: "m", provider: provider)
        }
        await handle { try await writer.write($0) }
        await pipeline.start()
        await pipeline.enqueue(.enhance, meeting: meeting.id)
        #expect(try await eventually { try database.enhancedNotes(meeting.id).first?.status == .generating })

        host.gate.set(true)
        await pipeline.recordingStarted()
        #expect(try await eventually { try enhanceJob()?.status == .queued }, "the job goes back in the queue")
        #expect(try database.enhancedNotes(meeting.id).map(\.status) == [.canceled])
        #expect(try database.meeting(meeting.id)?.currentEnhancedId == nil)
        #expect(try database.meeting(meeting.id)?.waitReason == .modelBusy, "the meeting says it waits for the recording")

        host.gate.set(false)
        await pipeline.nudge()
        #expect(try await eventually { try database.meeting(meeting.id)?.state == .ready })
        let finished = try #require(try database.meeting(meeting.id))
        let current = try #require(try database.enhancedNotes(meeting.id).first { $0.id == finished.currentEnhancedId })
        #expect(current.status == .done)
        #expect(current.markdown.contains("SSO ships by Q1"))
        await pipeline.stop()
    }

    @Test func launchCancelsNotesLeftGenerating() async throws {
        try database.saveEnhanced(EnhancedNote(meetingId: meeting.id, templateId: nil, providerId: nil, model: nil))
        await pipeline.start()
        await pipeline.stop()
        #expect(try database.enhancedNotes(meeting.id).map(\.status) == [.canceled])
    }

    @Test func aJobThatCrashesTheAppEveryTimeFails() async throws {
        try database.enqueue(.enhance, meeting: meeting.id)
        // Model jobs wait during a recording, so each relaunch only runs recovery.
        host.gate.set(true)
        for _ in 0..<Self.fast.maxAttempts {
            _ = try database.claimNextJob()
            let relaunched = Pipeline(database: database, paths: paths, host: host, policy: Self.fast)
            await relaunched.start()
            await relaunched.stop()
        }
        #expect(try enhanceJob()?.status == .failed)
        let failed = try #require(try database.meeting(meeting.id))
        #expect(failed.state == .failed)
        #expect(failed.stateDetail == "crashed")
    }

    @Test(arguments: [NoteWriter.Outcome.written(UUID()), .waiting(.cloudConsent)])
    func enqueueWhileTheJobRunsRunsItAgain(first: NoteWriter.Outcome) async throws {
        let calls = CallCounter()
        let release = AsyncStream<Void>.makeStream()
        await handle { _ in
            guard await calls.add() == 1 else { return .written(UUID()) }
            for await _ in release.stream { break }
            return first
        }
        await pipeline.start()
        await pipeline.enqueue(.enhance, meeting: meeting.id)
        #expect(await eventually { await calls.count == 1 })

        await pipeline.enqueue(.enhance, meeting: meeting.id)
        release.continuation.yield()
        #expect(await eventually { await calls.count == 2 }, "the second request ran")
        await pipeline.stop()
    }

    @Test func waitingForAModelLeavesTheMeetingRowAlone() async throws {
        let calls = CallCounter()
        await handle { _ in
            await calls.add()
            throw ModelHostError.modelMissing("qwen")
        }
        let updates = CallCounter()
        let watcher = Task { [database, meeting] in
            for try await _ in database.meetingUpdates(meeting.id) { await updates.add() }
        }
        await pipeline.start()
        await pipeline.enqueue(.enhance, meeting: meeting.id)
        #expect(await eventually { await calls.count >= 3 })
        let waiting = try #require(try database.meeting(meeting.id))
        #expect(waiting.waitReason == .modelMissing)
        let emitted = await updates.count

        #expect(await eventually { await calls.count >= 6 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(try database.meeting(meeting.id) == waiting, "the meeting row is not rewritten")
        #expect(await updates.count == emitted, "meeting observers are not woken")
        await pipeline.stop()
        watcher.cancel()
    }
}

/// Blocks until opened, and ignores cancellation, like a model that can't be interrupted.
actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
