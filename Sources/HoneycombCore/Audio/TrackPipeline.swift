import Darwin
import Foundation

/// 16 kHz mono samples from one channel, placed on the session clock.
public struct AudioChunk: Sendable {
    public let channel: Channel
    public let startMs: Int64
    public let samples: [Float]

    public init(channel: Channel, startMs: Int64, samples: [Float]) {
        self.channel = channel
        self.startMs = startMs
        self.samples = samples
    }

    public var endMs: Int64 { startMs + Int64(samples.count) * 1000 / Int64(AACSegmentWriter.sampleRate) }
}

/// Moves one channel from its recorder's ring buffer to disk, off the audio thread: drain the ring,
/// resample to 16 kHz mono, append to the current `.aac` segment, and pass the samples on.
/// Each start opens a new numbered segment. A segment is never reopened.
final class TrackPipeline: @unchecked Sendable {
    enum Event: Sendable {
        case wrote(atMs: Int64, silent: Bool, level: Float)
        case segmentOpened(SegmentMeta)
        case routeChanged(atMs: Int64)
        case writeFailed(atMs: Int64)
        case audio(AudioChunk)
    }

    let channel: Channel
    private let recorder: any TrackRecorder
    private let folder: URL
    private let clock: SessionClock
    private let emit: @Sendable (Event) -> Void
    private let queue: DispatchQueue
    private let drainInterval: DispatchTimeInterval
    private let stopTimeout: DispatchTimeInterval

    private var segmentCount: Int
    private var sink: AudioSink?
    private var resampler: Resampler?
    private var writer: AACSegmentWriter?
    private var current: SegmentMeta?
    private var timer: DispatchSourceTimer?
    private let readBuffer: UnsafeMutablePointer<Float>
    private let readCapacity = 96_000

    init(recorder: any TrackRecorder, folder: URL, clock: SessionClock, existingSegments: Int,
         drainInterval: DispatchTimeInterval = .milliseconds(50), stopTimeout: DispatchTimeInterval = .seconds(5),
         emit: @escaping @Sendable (Event) -> Void) {
        channel = recorder.channel
        self.recorder = recorder
        self.folder = folder
        self.clock = clock
        self.emit = emit
        self.drainInterval = drainInterval
        self.stopTimeout = stopTimeout
        segmentCount = existingSegments
        queue = DispatchQueue(label: "honeycomb.track.\(recorder.channel.rawValue)", qos: .userInitiated)
        readBuffer = .allocate(capacity: readCapacity)
    }

    deinit {
        readBuffer.deallocate()
    }

    func begin() throws {
        try queue.sync {
            let sink = AudioSink()
            let clock = self.clock
            let emit = self.emit
            let rate = try recorder.start(into: sink) { emit(.routeChanged(atMs: clock.nowMs())) }
            self.sink = sink
            resampler = Resampler(inputRate: rate)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + drainInterval, repeating: drainInterval)
            timer.setEventHandler { [weak self] in self?.drain() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Stops the recorder, writes what is left, and returns the closed segment, if any audio arrived.
    @discardableResult
    func end() -> SegmentMeta? {
        let timer = queue.sync { () -> DispatchSourceTimer? in
            let timer = self.timer
            self.timer = nil
            return timer
        }
        timer?.cancel()
        stopRecorder()
        return queue.sync {
            drain()
            let closed = closeSegment()
            sink = nil
            resampler = nil
            return closed
        }
    }

    /// Core Audio teardown can hang, so give up after the time limit and keep what was written.
    private func stopRecorder() {
        let done = DispatchSemaphore(value: 0)
        let recorder = self.recorder
        DispatchQueue.global(qos: .userInitiated).async {
            recorder.stop()
            done.signal()
        }
        if done.wait(timeout: .now() + stopTimeout) == .timedOut {
            Log.error("recorder.stop_timeout", ["channel": .code(channel == .me ? "me" : "them")])
        }
    }

    private func drain() {
        guard let sink, let resampler else { return }
        while true {
            let count = sink.ring.read(into: readBuffer, maxCount: readCapacity)
            guard count > 0 else { return }
            var peak: Float = 0
            var sumSquares: Float = 0
            for index in 0..<count {
                let sample = readBuffer[index]
                peak = max(peak, abs(sample))
                sumSquares += sample * sample
            }
            var output = resampler.convert(readBuffer, count: count)
            do {
                if writer == nil { try openSegment(firstHostTime: sink.firstHostTime) }
                guard let writer, let current else { return }
                let startMs = current.startOffsetMs + writer.frames * 1000 / Int64(AACSegmentWriter.sampleRate)
                try output.withUnsafeMutableBufferPointer { try writer.write($0.baseAddress!, count: $0.count) }
                emit(.audio(AudioChunk(channel: channel, startMs: startMs, samples: output)))
                emit(.wrote(atMs: clock.nowMs(), silent: peak == 0, level: (sumSquares / Float(count)).squareRoot()))
            } catch {
                emit(.writeFailed(atMs: clock.nowMs()))
                return
            }
        }
    }

    private func openSegment(firstHostTime: UInt64?) throws {
        segmentCount += 1
        let name = channel.segmentFileName(index: segmentCount)
        let writer = try AACSegmentWriter(url: folder.appendingPathComponent(name))
        let startMs = clock.offsetMs(hostTime: firstHostTime ?? mach_absolute_time())
        let segment = SegmentMeta(file: name, startOffsetMs: max(0, startMs), sampleRate: AACSegmentWriter.sampleRate,
                                  primingFrames: writer.primingFrames)
        self.writer = writer
        current = segment
        emit(.segmentOpened(segment))
    }

    private func closeSegment() -> SegmentMeta? {
        guard let writer, var current else { return nil }
        writer.close()
        current.frames = writer.frames
        current.endOffsetMs = current.startOffsetMs + writer.frames * 1000 / Int64(AACSegmentWriter.sampleRate)
        self.writer = nil
        self.current = nil
        return current
    }
}
