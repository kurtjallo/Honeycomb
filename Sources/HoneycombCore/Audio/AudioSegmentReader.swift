@preconcurrency import AVFoundation

/// Reads a recorded segment back as 16 kHz mono samples aligned to its start offset.
public enum AudioSegmentReader {
    /// Returns nil for a missing or empty file. AVFoundation throws an Objective-C exception on
    /// some empty files, so the size is checked first.
    public static func samples(of segment: SegmentMeta, in folder: URL) throws -> [Float]? {
        let url = folder.appendingPathComponent(segment.file)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0 else { return nil }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > segment.primingFrames else { return nil }
        let format = file.processingFormat
        guard format.sampleRate == AACSegmentWriter.sampleRate, format.channelCount == 1 else {
            throw RecorderError("unexpected segment format")
        }
        file.framePosition = segment.primingFrames
        let wanted = segment.frames > 0 ? min(segment.frames, file.length - segment.primingFrames)
                                        : file.length - segment.primingFrames
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted)) else { return nil }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(wanted))
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Frames actually decodable in a segment file, after lead-in. Used to repair meta.json after a crash.
    public static func recoveredFrames(file url: URL, primingFrames: Int64) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0, let file = try? AVAudioFile(forReading: url) else { return 0 }
        return max(0, file.length - primingFrames)
    }
}
