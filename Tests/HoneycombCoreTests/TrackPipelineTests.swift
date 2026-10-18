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
        recorder.finishHungStop()
        #expect(recorder.isCapturing == restarted, "the hung stop tore down the capture that started after it")

        pipeline.end()
        try pipeline.begin()
        #expect(recorder.isCapturing)
        pipeline.end()
        #expect(!recorder.isCapturing)
    }
}

/// Like the real recorders, a stop tears down whatever capture is current when it gets there.
private final class HangingStopRecorder: TrackRecorder, @unchecked Sendable {
    let channel = Channel.them
    private let lock = NSLock()
    private var capturing = false
    private var hangNext = false
    private let release = DispatchSemaphore(value: 0)
    private let stopReturned = DispatchSemaphore(value: 0)

    var isCapturing: Bool { lock.withLock { capturing } }

    func hangNextStop() {
        lock.withLock { hangNext = true }
    }

    func finishHungStop() {
        release.signal()
        stopReturned.wait()
    }

    func start(into sink: AudioSink, onRouteChange: @escaping @Sendable () -> Void) throws -> Double {
        lock.withLock { capturing = true }
        return 48_000
    }

    func stop() {
        let hang = lock.withLock {
            defer { hangNext = false }
            return hangNext
        }
        if hang { release.wait() }
        lock.withLock { capturing = false }
        if hang { stopReturned.signal() }
    }
}
