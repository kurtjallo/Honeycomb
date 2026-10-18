import AVFoundation
import Foundation
import Testing
@testable import HoneycombCore

struct AudioFileTests {
    @Test func aacSegmentKeepsTiming() throws {
        let folder = FileManager.default.temporaryDirectory
        let name = "\(UUID()).aac"
        let writer = try AACSegmentWriter(url: folder.appendingPathComponent(name))
        var samples = [Float](repeating: 0, count: 32_000)
        for index in 8_000..<8_320 { samples[index] = sin(Float(index) * 0.6) * 0.8 }
        try samples.withUnsafeMutableBufferPointer { try writer.write($0.baseAddress!, count: $0.count) }
        writer.close()
        #expect(writer.frames == 32_000)
        #expect(writer.primingFrames > 0)
        let segment = SegmentMeta(file: name, startOffsetMs: 0, frames: writer.frames,
                                  sampleRate: 16_000, primingFrames: writer.primingFrames)
        let decoded = try #require(try AudioSegmentReader.samples(of: segment, in: folder))
        #expect(decoded.count == 32_000)
        let burst = decoded.firstIndex { abs($0) > 0.2 }
        #expect(burst.map { abs($0 - 8_000) < 16 } == true)
        let size = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as! Int
        #expect(size < 16_000)
    }

    @Test func emptySegmentIsSkipped() throws {
        let folder = FileManager.default.temporaryDirectory
        let name = "\(UUID()).aac"
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        let segment = SegmentMeta(file: name, startOffsetMs: 0, sampleRate: 16_000)
        #expect(try AudioSegmentReader.samples(of: segment, in: folder) == nil)
    }

    @Test func resamplerKeepsDuration() {
        let resampler = Resampler(inputRate: 48_000)
        var total = 0
        let chunk = [Float](repeating: 0.1, count: 480)
        for _ in 0..<100 {
            total += chunk.withUnsafeBufferPointer { resampler.convert($0.baseAddress!, count: $0.count).count }
        }
        #expect(abs(total - 16_000) < 200)
    }

    @Test func ringBufferWrapsAndDrops() {
        let ring = RingBuffer(capacity: 8)
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        var output = [Float](repeating: 0, count: 8)
        #expect(input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) } == 6)
        #expect(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 4) } == 4)
        #expect(Array(output[0..<4]) == [1, 2, 3, 4])
        #expect(input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) } == 6)
        #expect(input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) } == 0)
        #expect(ring.dropped == 6)
        #expect(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 8) } == 8)
        #expect(output == [5, 6, 1, 2, 3, 4, 5, 6])
    }

    @Test func sinkDownmixesInterleavedStereo() {
        let sink = AudioSink(seconds: 1, sampleRate: 100)
        var stereo: [Float] = [1, 0, 0.5, 0.5, 0, 1]
        stereo.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 24, mData: raw.baseAddress))
            sink.push(&list, hostTime: 42)
        }
        var output = [Float](repeating: 9, count: 3)
        #expect(output.withUnsafeMutableBufferPointer { sink.ring.read(into: $0.baseAddress!, maxCount: 3) } == 3)
        #expect(output == [0.5, 0.5, 0.5])
        #expect(sink.firstHostTime == 42)
    }
}
