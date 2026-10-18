import AudioToolbox
import Foundation

/// Writes 16 kHz mono speech as AAC in an ADTS stream (`.aac`). ADTS frames each carry their own
/// header, so a file cut off by a crash still plays up to the last frame. AAC inside CAF does not:
/// its packet table is only written on close, and a killed process leaves 0 readable frames.
public final class AACSegmentWriter {
    public static let sampleRate: Double = 16_000
    public let url: URL
    public private(set) var frames: Int64 = 0
    /// Encoder lead-in at the start of the decoded file. ADTS can't store it, so meta.json does.
    public private(set) var primingFrames: Int64 = 0
    private var file: ExtAudioFileRef?

    public init(url: URL, bitRate: UInt32 = 48_000) throws {
        self.url = url
        var aac = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var ref: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAAC_ADTSType, &aac, nil,
                                               AudioFileFlags.eraseFile.rawValue, &ref)
        guard status == noErr, let ref else { throw RecorderError("create aac file", status) }
        file = ref
        var client = Self.clientFormat
        status = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { throw RecorderError("set aac client format", status) }
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        if ExtAudioFileGetProperty(ref, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr, let converter {
            var rate = bitRate
            AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
            var prime = AudioConverterPrimeInfo()
            var primeSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
            if AudioConverterGetProperty(converter, kAudioConverterPrimeInfo, &primeSize, &prime) == noErr {
                primingFrames = Int64(prime.leadingFrames)
            }
            // A null config makes ExtAudioFile apply the converter change above.
            var config: UnsafeRawPointer?
            ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ConverterConfig,
                                    UInt32(MemoryLayout<UnsafeRawPointer?>.size), &config)
        }
    }

    static var clientFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    }

    public func write(_ samples: UnsafeMutablePointer<Float>, count: Int) throws {
        guard let file, count > 0 else { return }
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: samples))
        let status = ExtAudioFileWrite(file, UInt32(count), &list)
        guard status == noErr else { throw RecorderError("write aac", status) }
        frames += Int64(count)
    }

    public func close() {
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }

    deinit {
        close()
    }
}
