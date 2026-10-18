import Darwin
import Foundation

/// A test recorder that plays generated samples in real time, so the capture path runs
/// without audio hardware or permissions.
public final class ReplayRecorder: TrackRecorder, @unchecked Sendable {
    public let channel: Channel
    private let sampleRate: Double
    private let generate: @Sendable (Int) -> Float
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var position = 0
    /// Starts that will fail before one succeeds, to exercise restarts.
    public var failingStarts = 0
    /// Stop delivering audio after this many samples, to simulate a stalled device.
    public var stallAfterSamples: Int?
    public private(set) var startCount = 0

    public init(channel: Channel, sampleRate: Double = 48_000, generate: @escaping @Sendable (Int) -> Float) {
        self.channel = channel
        self.sampleRate = sampleRate
        self.generate = generate
    }

    public func start(into sink: AudioSink, onRouteChange: @escaping @Sendable () -> Void) throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        startCount += 1
        if failingStarts > 0 {
            failingStarts -= 1
            throw RecorderError("replay start")
        }
        let stall = stallAfterSamples
        stallAfterSamples = nil
        let chunk = Int(sampleRate / 100)
        var buffer = [Float](repeating: 0, count: chunk)
        var delivered = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "honeycomb.replay"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [self] in
            if let stall, delivered >= stall { return }
            lock.lock()
            for index in 0..<chunk { buffer[index] = generate(position + index) }
            position += chunk
            lock.unlock()
            delivered += chunk
            buffer.withUnsafeBufferPointer { sink.pushMono($0.baseAddress!, count: chunk, hostTime: mach_absolute_time()) }
        }
        timer.resume()
        self.timer = timer
        return sampleRate
    }

    public func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }
}
