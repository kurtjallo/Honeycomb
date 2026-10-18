@preconcurrency import AVFoundation

/// Converts mono Float32 audio at the device rate to 16 kHz mono, keeping filter state between calls.
final class Resampler {
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init(inputRate: Double) {
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AACSegmentWriter.sampleRate,
                                     channels: 1, interleaved: false)!
        ratio = AACSegmentWriter.sampleRate / inputRate
        converter = inputRate == AACSegmentWriter.sampleRate ? nil : AVAudioConverter(from: inputFormat, to: outputFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }

    func convert(_ samples: UnsafePointer<Float>, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard let converter else { return Array(UnsafeBufferPointer(start: samples, count: count)) }
        let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count))!
        input.frameLength = AVAudioFrameCount(count)
        input.floatChannelData![0].update(from: samples, count: count)
        let capacity = AVAudioFrameCount(Double(count) * ratio + 64)
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
        // The input block runs synchronously inside convert(to:error:), never concurrently.
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let pending = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return pending
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
