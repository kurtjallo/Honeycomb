import Foundation
import Testing
@testable import HoneycombCore

/// Records spoken audio through the real capture path, then runs the real pipeline with the
/// real speech models. Run with HONEYCOMB_MODEL_TESTS=1.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HONEYCOMB_MODEL_TESTS"] == "1"))
struct PipelineTests {
    let database: AppDatabase
    let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("pipe-\(UUID().uuidString)"))
    let host: ModelHost
    let pipeline: Pipeline

    init() throws {
        database = try AppDatabase.inMemory()
        try paths.createFolders()
        let store = ModelStore(root: Paths.standard.models, database: nil)
        host = ModelHost(store: store, speechIdleUnload: .seconds(1))
        pipeline = Pipeline(database: database, paths: paths, host: host)
    }

    static func speaker(_ channel: Channel, _ samples: [Float], delaySeconds: Int) -> ReplayRecorder {
        let silence = 16_000 * delaySeconds
        return ReplayRecorder(channel: channel, sampleRate: 16_000) { index in
            index >= silence && index - silence < samples.count ? samples[index - silence] : 0
        }
    }

    func waitForState(_ id: UUID, _ states: Set<MeetingState>, seconds: Double = 60) async throws -> Meeting {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let meeting = try database.meeting(id), states.contains(meeting.state) { return meeting }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CancellationError()
    }

    @Test func recordedCallGetsAFinalTranscript() async throws {
        let them = try SpeechModelTests.speak("We would renew the contract if single sign on lands by the end of the first quarter. Can you send the pricing by Friday?")
        let me = try SpeechModelTests.speak("Yes, I will send the pricing deck to Dana by Friday morning.")
        let themSeconds = them.count / 16_000 + 1
        let recorder = MeetingRecorder(database: database, paths: paths, makeRecorders: {
            [Self.speaker(.them, them, delaySeconds: 0), Self.speaker(.me, me, delaySeconds: themSeconds)]
        }, freeBytes: { .max }, micAccess: { true })
        let (id, _) = try await recorder.start()
        try await Task.sleep(for: .seconds(Double(themSeconds + me.count / 16_000 + 2)))
        await recorder.stop()

        try database.saveTerm(DictionaryTerm(term: "Dana", kind: .name))
        await pipeline.start()
        await pipeline.meetingStopped(id)
        let meeting = try await waitForState(id, [.ready, .tooShort, .failed])
        await pipeline.stop()
        let lines = try database.transcript(id)
        for line in lines { print("FINAL", line.channel, line.startMs, line.text) }
        #expect(meeting.state == .tooShort)
        let themText = lines.filter { $0.channel == .them }.map(\.text).joined(separator: " ").lowercased()
        let meText = lines.filter { $0.channel == .me }.map(\.text).joined(separator: " ").lowercased()
        #expect(themText.contains("renew the contract"))
        #expect(meText.contains("pricing deck"))
        let meStart = try #require(lines.first { $0.channel == .me }?.startMs)
        #expect(abs(meStart - Int64(themSeconds) * 1000) < 1_000)
        #expect(lines.allSatisfy { $0.pass == .final && $0.engine == "parakeet-v2" })
    }

    @Test func crashedRecordingIsRepairedAndTranscribed() async throws {
        let them = try SpeechModelTests.speak("This call was cut off when the app crashed, but the audio should still be saved.")
        let meeting = Meeting(title: "Crash test", state: .recording)
        try database.insert(meeting)
        let folder = paths.audioFolder(for: meeting.id)
        let crashing = RecordingSession(meetingID: meeting.id, folder: folder, recorders: [
            Self.speaker(.them, them, delaySeconds: 0), Self.speaker(.me, [], delaySeconds: 0),
        ])
        try await crashing.start()
        try await Task.sleep(for: .seconds(Double(them.count / 16_000 + 1)))

        await pipeline.start()
        #expect(try database.meeting(meeting.id)?.state == .interrupted)
        let done = try await waitForState(meeting.id, [.ready, .tooShort, .failed])
        await pipeline.stop()
        #expect(done.state == .tooShort)
        let repaired = try SessionMeta.read(from: folder)
        #expect(repaired[.them].status == .incomplete)
        #expect((repaired[.them].segments.first?.frames ?? 0) > 16_000 * 3)
        let text = try database.transcript(meeting.id).map(\.text).joined(separator: " ").lowercased()
        print("RECOVERED:", text)
        #expect(text.contains("audio should still be saved"))
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HONEYCOMB_MODEL_TESTS"] == "1"))
struct LiveTranscriptTests {
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Date, LiveUpdate)] = []
        func add(_ update: LiveUpdate) { lock.withLock { items.append((Date(), update)) } }
        var all: [(Date, LiveUpdate)] { lock.withLock { items } }
    }

    @Test func linesAppearWithinSecondsDuringTheCall() async throws {
        let database = try AppDatabase.inMemory()
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)"))
        try paths.createFolders()
        let host = ModelHost(store: ModelStore(root: Paths.standard.models, database: nil))
        let speech = try SpeechModelTests.speak("Let's go over the launch plan. Marketing wants the beta in two weeks. Engineering thinks that is too early.")
        let recorder = MeetingRecorder(database: database, paths: paths, makeRecorders: {
            [PipelineTests.speaker(.them, speech, delaySeconds: 1), PipelineTests.speaker(.me, [], delaySeconds: 0)]
        }, freeBytes: { .max }, micAccess: { true }, host: host)
        let collected = Collected()
        let started = Date()
        let (id, _) = try await recorder.start(onLive: { collected.add($0) })
        let speechEnd = started.addingTimeInterval(1 + Double(speech.count) / 16_000)
        try await Task.sleep(for: .seconds(1 + Double(speech.count) / 16_000 + 5))
        let duringCall = collected.all
        await recorder.stop()

        let finals = duringCall.compactMap { item -> (Date, TranscriptLine)? in
            if case .final(let line) = item.1 { (item.0, line) } else { nil }
        }
        for (date, line) in finals { print("LIVE +\(String(format: "%.1f", date.timeIntervalSince(started)))s", line.startMs, line.text) }
        #expect(!finals.isEmpty)
        let text = finals.map(\.1.text).joined(separator: " ").lowercased()
        #expect(text.contains("launch plan"))
        if let last = finals.last { #expect(last.0.timeIntervalSince(speechEnd) < 5) }
        #expect(duringCall.contains { if case .partial = $0.1 { true } else { false } })
        #expect(try !database.transcript(id).isEmpty)
    }
}
