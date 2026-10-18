@preconcurrency import AVFoundation
import CoreAudio

/// Records the microphone (the "Me" track) in one explicit mono format, voice processing off.
/// A multichannel device's own format can deliver pure silence, so the format is never left to the device.
public final class MicRecorder: TrackRecorder, @unchecked Sendable {
    public let channel = Channel.me
    /// Which input to use. Nil means the system default.
    public var deviceID: AudioDeviceID?

    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    public init(deviceID: AudioDeviceID? = nil) {
        self.deviceID = deviceID
    }

    public func start(into sink: AudioSink, onRouteChange: @escaping @Sendable () -> Void) throws -> Double {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var deviceID, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.error("mic.set_device_failed", ["status": .status(status)]) }
        }
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate,
                                       channels: 1, interleaved: false)
        else { throw RecorderError("read mic format") }

        input.installTap(onBus: 0, bufferSize: 1024, format: mono) { buffer, time in
            guard let samples = buffer.floatChannelData?[0] else { return }
            sink.pushMono(samples, count: Int(buffer.frameLength), hostTime: time.isHostTimeValid ? time.hostTime : mach_absolute_time())
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in onRouteChange() }
        self.engine = engine
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw RecorderError("start mic engine", Int32((error as NSError).code))
        }
        return hardware.sampleRate
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
