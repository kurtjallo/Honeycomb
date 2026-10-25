import Foundation
import Testing
@testable import HoneycombCore

/// A spoken call recorded through the capture path, transcribed by Parakeet, and written up by
/// `NoteWriter` on `BuiltInProvider` as in `AppModel.launch`.
/// Run with HONEYCOMB_MODEL_TESTS=1.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HONEYCOMB_MODEL_TESTS"] == "1"))
struct EndToEndTests {
    let database: AppDatabase
    let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString)"))
    let host: ModelHost
    let pipeline: Pipeline

    init() async throws {
        database = try AppDatabase.inMemory()
        try paths.createFolders()
        let store = ModelStore(root: Paths.standard.models, database: nil)
        host = ModelHost(store: store, speechIdleUnload: .seconds(1))
        pipeline = Pipeline(database: database, paths: paths, host: host)
        try database.seedBuiltIns()
        let writer = NoteWriter(database: database, chat: BuiltInProvider(llm: BuiltInLLM(store: store, host: host)))
        var handlers = Pipeline.Handlers()
        handlers.enhance = { try await writer.write($0) }
        await pipeline.setHandlers(handlers)
    }

    @Test func builtInModelWritesNotesForARecordedCall() async throws {
        let notes = try await notesForRecordedCall()
        #expect(notes.contains("sso") || notes.contains("single sign"), "notes mention the SSO condition")
        #expect(notes.contains("friday"), "notes mention the Friday deadline")
    }

    @Test func aNewRecordingPausesNotesAndTheyFinishAfter() async throws {
        let id = try await recordCall()
        await pipeline.start()
        await pipeline.meetingStopped(id)
        let streaming = try await waitFor(seconds: 300) {
            try database.enhancedNotes(id).first { $0.status == .generating && !$0.markdown.isEmpty }
        }
        print("E2E cut off after \(streaming.markdown.count) characters")

        host.gate.set(true)
        await pipeline.recordingStarted()
        try await Task.sleep(for: .seconds(3))
        let during = try #require(try database.meeting(id))
        let finishedDuring = try database.enhancedNotes(id).filter { $0.status == .done }
        #expect(during.currentEnhancedId == nil, "cut-off notes are not made current")
        #expect(finishedDuring.isEmpty, "cut-off notes are not saved as finished: \(finishedDuring.map(\.markdown.count))")

        host.gate.set(false)
        await pipeline.nudge()
        let meeting = try await waitForState(id, [.ready, .failed], seconds: 300)
        #expect(meeting.state == .ready)
        let current = try #require(try database.enhancedNotes(id).first { $0.id == meeting.currentEnhancedId })
        #expect(current.status == .done)
        #expect(current.markdown.count > streaming.markdown.count, "the notes were finished after the recording")
        await pipeline.stop()
    }

    private func notesForRecordedCall() async throws -> String {
        let id = try await recordCall()
        let started = ContinuousClock.now
        await pipeline.start()
        await pipeline.meetingStopped(id)
        let meeting = try await waitForState(id, [.ready, .failed, .waiting, .tooShort], seconds: 300)
        await pipeline.stop()
        let versions = try database.enhancedNotes(id)
        print("E2E state \(meeting.state) detail \(meeting.stateDetail ?? "-") after \(ContinuousClock.now - started)")
        for version in versions { print("E2E version \(version.status) \(version.model ?? "-") error \(version.errorCode ?? "-")\n\(version.markdown)") }
        #expect(meeting.state == .ready)
        let current = try #require(versions.first { $0.id == meeting.currentEnhancedId }, "a current version exists")
        #expect(current.status == .done)
        #expect(current.markdown.count > 100, "notes have substance")
        return current.markdown.lowercased()
    }

    private func recordCall() async throws -> UUID {
        let them = try SpeechModelTests.speak("""
            Thanks for making time. We're happy with the product, and we would renew the contract for another year \
            if single sign on lands by the end of the first quarter. Our security team needs SSO before we roll it out \
            to the sales team. Can you send the updated pricing by Friday? Also, Dana will be our new point of contact.
            """)
        let me = try SpeechModelTests.speak("""
            That works. Single sign on is on our roadmap for February, so the first quarter is realistic. \
            I will send the pricing deck to Dana by Friday morning, and I'll set up a call with your security team next week.
            """)
        let themSeconds = them.count / 16_000 + 1
        let recorder = MeetingRecorder(database: database, paths: paths, makeRecorders: {
            [PipelineTests.speaker(.them, them, delaySeconds: 0), PipelineTests.speaker(.me, me, delaySeconds: themSeconds)]
        }, freeBytes: { .max }, micAccess: { true })
        let (id, _) = try await recorder.start()
        try await Task.sleep(for: .seconds(Double(themSeconds + me.count / 16_000 + 2)))
        await recorder.stop()
        return id
    }

    private func waitForState(_ id: UUID, _ states: Set<MeetingState>, seconds: Double) async throws -> Meeting {
        try await waitFor(seconds: seconds) { try database.meeting(id).flatMap { states.contains($0.state) ? $0 : nil } }
    }

    private func waitFor<T>(seconds: Double, _ check: () throws -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = try check() { return value }
            try await Task.sleep(for: .milliseconds(200))
        }
        Issue.record("timed out after \(seconds) s")
        throw CancellationError()
    }
}
