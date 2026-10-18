import Foundation
import Testing
@testable import HoneycombCore

struct TrackPipelineTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pipe-\(UUID().uuidString)")

    @Test func hungStopNeverTearsDownALaterCapture() throws {
        let recorder = HangingStopRecorder()
        let pipeline = TrackPipeline(recorder: recorder, folder: folder, clock: SessionClock(), existingSegments: 0,
                                     stopTimeout: .milliseconds(250)) { _ in }
        try pipeline.begin()
        recorder.hangNextStop()
        pipeline.end()
        let restarted = (try? pipeline.begin()) != nil
        pipeline.end()
        recorder.finishHungStop()
        #expect(recorder.isCapturing == restarted, "the hung stop tore down the capture that started after it")
        #expect(!recorder.calledDuringHungStop)

        pipeline.end()
        try pipeline.begin()
        #expect(recorder.isCapturing)
        pipeline.end()
        #expect(!recorder.isCapturing)
    }

    @Test func aStartDuringAHungStopFailsAtOnce() throws {
        let recorder = HangingStopRecorder()
        let pipeline = TrackPipeline(recorder: recorder, folder: folder, clock: SessionClock(), existingSegments: 0,
                                     stopTimeout: .seconds(1)) { _ in }
        try pipeline.begin()
        recorder.hangNextStop()
        pipeline.end()
        let clock = ContinuousClock()
        let started = clock.now
        #expect(throws: RecorderError.self) { try pipeline.begin() }
        #expect(clock.now - started < .milliseconds(500), "the health machine paces the retries, not a wait on the session actor")
        recorder.finishHungStop()
        try pipeline.begin()
        pipeline.end()
    }
}

private final class HangingStopRecorder: TrackRecorder, @unchecked Sendable {
    let channel = Channel.them
    private let lock = NSLock()
    private var capturing = false
    private var hangNext = false
    private var hanging = false
    private var overlapped = false
    private let release = DispatchSemaphore(value: 0)
    private let stopReturned = DispatchSemaphore(value: 0)

    var isCapturing: Bool { lock.withLock { capturing } }
    var calledDuringHungStop: Bool { lock.withLock { overlapped } }

    func hangNextStop() {
        lock.withLock { hangNext = true }
    }

    func finishHungStop() {
        release.signal()
        stopReturned.wait()
    }

    func start(into sink: AudioSink, onRouteChange: @escaping @Sendable () -> Void) throws -> Double {
        lock.withLock {
            overlapped = overlapped || hanging
            capturing = true
        }
        return 48_000
    }

    func stop() {
        let hang = lock.withLock {
            overlapped = overlapped || hanging
            let hang = hangNext
            hangNext = false
            if hang { hanging = true }
            return hang
        }
        if hang { release.wait() }
        lock.withLock {
            capturing = false
            if hang { hanging = false }
        }
        if hang { stopReturned.signal() }
    }
}
