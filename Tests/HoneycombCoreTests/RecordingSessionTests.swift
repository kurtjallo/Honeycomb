import Foundation
import Testing
@testable import HoneycombCore

@Suite(.serialized)
struct RecordingSessionTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")

    static func tone(_ frequency: Double) -> @Sendable (Int) -> Float {
        { index in Float(sin(Double(index) * 2 * .pi * frequency / 48_000) * 0.3) }
    }

    @Test func recordsBothTracksAligned() async throws {
        let session = RecordingSession(meetingID: UUID(), folder: folder, recorders: [
            ReplayRecorder(channel: .me, generate: Self.tone(440)),
            ReplayRecorder(channel: .them, sampleRate: 44_100, generate: { _ in 0.2 }),
        ])
        try await session.start()
        try await Task.sleep(for: .milliseconds(1_500))
        let meta = await session.stop()

        let saved = try SessionMeta.read(from: folder)
        #expect(saved.tracks == meta.tracks)
        #expect(meta.status == .complete)
        for channel in Channel.allCases {
            let segments = meta[channel].segments
            #expect(segments.count == 1)
            let segment = try #require(segments.first)
            #expect(segment.startOffsetMs < 100)
            #expect(segment.frames > 16_000)
            #expect(segment.frames < 28_000)
            let samples = try #require(try AudioSegmentReader.samples(of: segment, in: folder))
            #expect(Int64(samples.count) == segment.frames)
        }
    }

    @Test func pauseStartsNewSegmentsAndRecordsTheGap() async throws {
        let session = RecordingSession(meetingID: UUID(), folder: folder, recorders: [
            ReplayRecorder(channel: .me, generate: Self.tone(300)),
            ReplayRecorder(channel: .them, generate: Self.tone(500)),
        ])
        try await session.start()
        try await Task.sleep(for: .milliseconds(600))
        await session.pause()
        try await Task.sleep(for: .milliseconds(500))
        try await session.resume()
        try await Task.sleep(for: .milliseconds(600))
        let meta = await session.stop()

        #expect(meta.pauses.count == 1)
        let pause = try #require(meta.pauses.first)
        let pauseEnd = try #require(pause.endMs)
        #expect(pauseEnd - pause.startMs >= 450)
        for channel in Channel.allCases {
            let segments = meta[channel].segments
            #expect(segments.map(\.file) == [channel.segmentFileName(index: 1), channel.segmentFileName(index: 2)])
            #expect(segments[1].startOffsetMs >= pauseEnd)
        }
        #expect(meta.status == .complete)
    }

    @Test func stalledTrackRestartsIntoANewSegment() async throws {
        var policy = CapturePolicy()
        policy.startupGraceMs = 300
        policy.stallAfterMs = 300
        policy.stableWindowMs = 300
        let stalling = ReplayRecorder(channel: .them, generate: Self.tone(700))
        stalling.stallAfterSamples = 48_000 / 2
        let session = RecordingSession(meetingID: UUID(), folder: folder, recorders: [
            ReplayRecorder(channel: .me, generate: Self.tone(300)),
            stalling,
        ], policy: policy, tickInterval: .milliseconds(50))
        try await session.start()
        try await Task.sleep(for: .milliseconds(2_000))
        let meta = await session.stop()

        #expect(stalling.startCount == 2)
        let them = meta[.them]
        #expect(them.segments.count == 2)
        #expect(them.interruptions.count == 1)
        let interruption = try #require(them.interruptions.first)
        #expect(interruption.reason == .stalled)
        #expect(interruption.recoveredAtMs != nil)
        #expect(them.status == .recovered)
        #expect(meta[.me].status == .complete)
        #expect(meta.status == .recovered)
    }

    @Test func failingStartThrows() async throws {
        let broken = ReplayRecorder(channel: .me, generate: { _ in 0 })
        broken.failingStarts = 1
        let session = RecordingSession(meetingID: UUID(), folder: folder, recorders: [broken])
        await #expect(throws: RecorderError.self) { try await session.start() }
        #expect(await session.state == .stopped)
    }
}
