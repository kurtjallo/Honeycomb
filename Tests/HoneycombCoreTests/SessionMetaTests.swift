import Foundation
import Testing
@testable import HoneycombCore

struct SessionMetaTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func roundTripsThroughDisk() throws {
        var meta = SessionMeta(meetingID: UUID(), startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        meta[.me].segments.append(SegmentMeta(file: "mic.aac", startOffsetMs: 12, endOffsetMs: 60_000, frames: 959_808, sampleRate: 16_000))
        meta[.them].interruptions.append(InterruptionMeta(startedAtMs: 30_000, reason: .routeChanged, recoveredAtMs: 31_200, attempts: 1))
        meta[.me].status = .complete
        meta[.them].status = .recovered
        try meta.write(to: folder)
        let read = try SessionMeta.read(from: folder)
        #expect(read == meta)
        #expect(read.status == .recovered)
        let text = try String(contentsOf: folder.appendingPathComponent("meta.json"), encoding: .utf8)
        #expect(text.contains("\"start_offset_ms\" : 12"))
        #expect(text.contains("\"schema_version\" : 1"))
    }

    @Test func statusIsNilWhileRecording() {
        var meta = SessionMeta(meetingID: UUID(), startedAt: Date())
        meta[.me].status = .complete
        #expect(meta.status == nil)
    }

    @Test func refusesNewerSchema() throws {
        try Data(#"{"schema_version": 99}"#.utf8).write(to: folder.appendingPathComponent("meta.json"))
        #expect(throws: SessionMeta.ReadError.newerSchema(99)) { try SessionMeta.read(from: folder) }
    }

    @Test func segmentNames() {
        #expect(Channel.me.segmentFileName(index: 1) == "mic.aac")
        #expect(Channel.them.segmentFileName(index: 2) == "system-002.aac")
    }
}
