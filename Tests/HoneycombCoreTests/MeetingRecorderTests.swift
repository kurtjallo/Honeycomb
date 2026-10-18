import Foundation
import Synchronization
import Testing
@testable import HoneycombCore

@Suite(.serialized)
struct MeetingRecorderTests {
    let database: AppDatabase
    let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("hc-\(UUID().uuidString)"))

    init() throws {
        database = try AppDatabase.inMemory()
        try paths.createFolders()
    }

    func recorder(free: Int64 = .max, mic: @escaping @Sendable () async -> Bool = { true },
                  them: @escaping @Sendable () -> any TrackRecorder = { ReplayRecorder(channel: .them, generate: { _ in 0.1 }) })
        -> MeetingRecorder {
        MeetingRecorder(database: database, paths: paths, makeRecorders: {
            [ReplayRecorder(channel: .me, generate: { _ in 0.1 }), them()]
        }, freeBytes: { free }, micAccess: mic)
    }

    static func failingSystemAudio() -> any TrackRecorder {
        let them = ReplayRecorder(channel: .them, generate: { _ in 0.1 })
        them.failingStarts = 1
        return them
    }

    func audioFolders() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.audio.path)
    }

    func eventually(_ check: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func startAndStopUpdateTheMeeting() async throws {
        let recorder = recorder()
        let zoom = CallApp(bundleId: "us.zoom.xos", name: "Zoom", kind: .app)
        let (id, _) = try await recorder.start(callApp: zoom)
        var meeting = try #require(try database.meeting(id))
        #expect(meeting.state == .recording)
        #expect(meeting.title.hasPrefix("Zoom call, "))
        #expect(meeting.callAppId == "us.zoom.xos")
        await #expect(throws: RecordingError.alreadyRecording) { _ = try await recorder.start() }

        try await Task.sleep(for: .milliseconds(400))
        await recorder.pause()
        #expect(try database.meeting(id)?.state == .paused)
        try await recorder.resume()
        try await Task.sleep(for: .milliseconds(300))
        await recorder.stop()

        meeting = try #require(try database.meeting(id))
        #expect(meeting.state == .transcribing)
        #expect((meeting.durationMs ?? 0) > 500)
        let meta = try SessionMeta.read(from: paths.audioFolder(for: id))
        #expect(meta[.me].segments.count == 2)
    }

    @Test func aSecondStopWaitsForTheFirstAndAStartIsRefused() async throws {
        let them = GatedRecorder(channel: .them)
        let recorder = recorder(them: { them })
        let (id, _) = try await recorder.start()
        let first = Task { await recorder.stop() }
        let second = Task { await recorder.stop() }
        #expect(await eventually { them.stopEntered })

        await #expect(throws: RecordingError.alreadyRecording) { _ = try await recorder.start() }
        them.open()
        #expect(await first.value == id)
        #expect(await second.value == id, "the second stop returns when the first one has finished")
        #expect(try database.meetings(in: MeetingState.allCases).map(\.id) == [id])
    }

    @Test func aFailedStartLeavesNoMeeting() async throws {
        let recorder = recorder(them: Self.failingSystemAudio)
        await #expect(throws: RecordingError.captureFailed) { _ = try await recorder.start() }
        #expect(try database.meetings(in: MeetingState.allCases).isEmpty)
        #expect(try audioFolders().isEmpty)
    }

    @Test func aFailedStartPutsTheDraftBack() async throws {
        let draft = Meeting(title: "Acme renewal", titleSource: .user, state: .draft)
        try database.insert(draft)
        let recorder = recorder(them: Self.failingSystemAudio)
        await #expect(throws: RecordingError.captureFailed) { _ = try await recorder.start(existing: draft.id) }
        let row = try #require(try database.meeting(draft.id))
        #expect(row.state == .draft)
        #expect(row.audioDir == nil)
        #expect(row.startAt == nil)
        #expect(try audioFolders().isEmpty)
    }

    @Test func aCancelledStartLeavesNoMeeting() async throws {
        let permission = Latch()
        let recorder = recorder(mic: {
            await permission.wait()
            return true
        })
        let start = Task { try await recorder.start() }
        start.cancel()
        await permission.open()
        await #expect(throws: CancellationError.self) { _ = try await start.value }
        #expect(try database.meetings(in: MeetingState.allCases).isEmpty)
        #expect(try audioFolders().isEmpty)
        _ = try await recorder.start()
        await recorder.stop()
    }

    @Test func draftNoteKeepsItsRow() async throws {
        let draft = Meeting(title: "Acme renewal", titleSource: .user, state: .draft)
        try database.insert(draft)
        let recorder = recorder()
        let (id, _) = try await recorder.start(existing: draft.id)
        #expect(id == draft.id)
        #expect(try database.meeting(id)?.title == "Acme renewal")
        await recorder.stop()
    }

    @Test func lowDiskBlocksRecording() async throws {
        let recorder = recorder(free: 1_000_000_000)
        await #expect(throws: RecordingError.lowDisk(availableBytes: 1_000_000_000)) { _ = try await recorder.start() }
        #expect(try database.meetings(in: MeetingState.allCases).isEmpty)
    }

    @Test func micDeniedBlocksRecording() async throws {
        await #expect(throws: RecordingError.micDenied) { _ = try await recorder(mic: { false }).start() }
    }
}

final class GatedRecorder: TrackRecorder, Sendable {
    let channel: Channel
    private let replay: ReplayRecorder
    private let gate = DispatchSemaphore(value: 0)
    private let entered = Mutex(false)

    init(channel: Channel) {
        self.channel = channel
        replay = ReplayRecorder(channel: channel, generate: { _ in 0.1 })
    }

    var stopEntered: Bool { entered.withLock { $0 } }

    func start(into sink: AudioSink, onRouteChange: @escaping @Sendable () -> Void) throws -> Double {
        try replay.start(into: sink, onRouteChange: onRouteChange)
    }

    func stop() {
        entered.withLock { $0 = true }
        gate.wait()
        replay.stop()
    }

    func open() {
        gate.signal()
    }
}
