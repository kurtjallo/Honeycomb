import Foundation
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

    func recorder(free: Int64 = .max, mic: Bool = true) -> MeetingRecorder {
        MeetingRecorder(database: database, paths: paths, makeRecorders: {
            [ReplayRecorder(channel: .me, generate: { _ in 0.1 }), ReplayRecorder(channel: .them, generate: { _ in 0.1 })]
        }, freeBytes: { free }, micAccess: { mic })
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
        await #expect(throws: RecordingError.micDenied) { _ = try await recorder(mic: false).start() }
    }
}
