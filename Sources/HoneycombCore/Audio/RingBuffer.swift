import CoreAudio
import Synchronization

/// Single-producer, single-consumer ring of mono samples. The producer is a real-time audio
/// callback, so `write` never allocates, locks, or blocks. When full, new samples are dropped.
public final class RingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let droppedCount = Atomic<Int>(0)

    public init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    public var available: Int { written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring) }
    public var dropped: Int { droppedCount.load(ordering: .relaxed) }

    @discardableResult
    public func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        let head = written.load(ordering: .relaxed)
        let tail = consumed.load(ordering: .acquiring)
        let count = max(0, count)
        let n = min(count, capacity - (head - tail))
        if n < count { droppedCount.add(count - n, ordering: .relaxed) }
        guard n > 0 else { return 0 }
        let start = head % capacity
        let first = min(n, capacity - start)
        (storage + start).update(from: samples, count: first)
        if n > first { storage.update(from: samples + first, count: n - first) }
        written.store(head + n, ordering: .releasing)
        return n
    }

    public func read(into output: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let tail = consumed.load(ordering: .relaxed)
        let head = written.load(ordering: .acquiring)
        let n = min(maxCount, head - tail)
        guard n > 0 else { return 0 }
        let start = tail % capacity
        let first = min(n, capacity - start)
        output.update(from: storage + start, count: first)
        if n > first { (output + first).update(from: storage, count: n - first) }
        consumed.store(tail + n, ordering: .releasing)
        return n
    }
}

/// Where a recorder's callback puts samples. It downmixes to mono into a preallocated scratch
/// buffer, then copies into the ring, so it is safe on a real-time thread.
public final class AudioSink: @unchecked Sendable {
    public let ring: RingBuffer
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 16_384
    private let firstHost = Atomic<UInt64>(0)

    public init(seconds: Double = 30, sampleRate: Double = 48_000) {
        ring = RingBuffer(capacity: Int(seconds * sampleRate))
        scratch = .allocate(capacity: scratchCapacity)
    }

    deinit {
        scratch.deallocate()
    }

    /// Host time of the first sample, or nil before any audio arrived.
    public var firstHostTime: UInt64? {
        let value = firstHost.load(ordering: .acquiring)
        return value == 0 ? nil : value
    }

    public func pushMono(_ samples: UnsafePointer<Float>, count: Int, hostTime: UInt64) {
        markFirst(hostTime)
        ring.write(samples, count: count)
    }

    /// Float32 audio, interleaved or not, any channel count.
    public func push(_ list: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let firstBuffer = buffers.first, firstBuffer.mData != nil else { return }
        markFirst(hostTime)
        if buffers.count == 1 {
            let channels = Int(max(1, firstBuffer.mNumberChannels))
            let frames = Int(firstBuffer.mDataByteSize) / (4 * channels)
            let samples = firstBuffer.mData!.assumingMemoryBound(to: Float.self)
            if channels == 1 {
                ring.write(samples, count: frames)
                return
            }
            var done = 0
            while done < frames {
                let chunk = min(scratchCapacity, frames - done)
                for frame in 0..<chunk {
                    var sum: Float = 0
                    let base = (done + frame) * channels
                    for channel in 0..<channels { sum += samples[base + channel] }
                    scratch[frame] = sum / Float(channels)
                }
                ring.write(scratch, count: chunk)
                done += chunk
            }
        } else {
            let frames = Int(firstBuffer.mDataByteSize) / 4
            let count = Float(buffers.count)
            var done = 0
            while done < frames {
                let chunk = min(scratchCapacity, frames - done)
                for frame in 0..<chunk { scratch[frame] = 0 }
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for frame in 0..<chunk { scratch[frame] += data[done + frame] }
                }
                for frame in 0..<chunk { scratch[frame] /= count }
                ring.write(scratch, count: chunk)
                done += chunk
            }
        }
    }

    private func markFirst(_ hostTime: UInt64) {
        if firstHost.load(ordering: .relaxed) == 0 {
            firstHost.store(max(hostTime, 1), ordering: .releasing)
        }
    }
}
