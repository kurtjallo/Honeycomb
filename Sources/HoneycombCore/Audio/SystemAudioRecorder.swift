import AudioToolbox
import CoreAudio
import Foundation

/// Records everything the Mac plays, except Honeycomb itself, through a global Core Audio process tap.
/// This is the "Them" track. No bot joins the call.
public final class SystemAudioRecorder: TrackRecorder, @unchecked Sendable {
    public let channel = Channel.them
    /// With false, the aggregate device holds only the tap, so switching speakers to AirPods needs
    /// no rebuild. With true, the default output is a sub-device, and a route change that stops the
    /// audio restarts it.
    public let includeOutputDevice: Bool

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "honeycomb.system-audio", qos: .userInteractive)

    public init(includeOutputDevice: Bool = false) {
        self.includeOutputDevice = includeOutputDevice
    }

    public func start(into sink: AudioSink, onRouteChange: @escaping @Sendable () -> Void) throws -> Double {
        let excluded = CA.processObject(pid: ProcessInfo.processInfo.processIdentifier).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Honeycomb"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw RecorderError("create process tap", status) }
        tapID = tap

        guard let format = CA.read(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription()),
              format.mSampleRate > 0, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else {
            stop()
            throw RecorderError("read tap format")
        }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Honeycomb system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // With auto-start, IO waits for the first sound any app plays, so a quiet start to a call
            // delivers no buffers and reads as a stall. Without it, silence arrives as zeros.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if includeOutputDevice, let output = CA.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
           let uid = CA.string(output, kAudioDevicePropertyDeviceUID) {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = uid
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        } else {
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [] as [[String: Any]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            stop()
            throw RecorderError("create aggregate device", status)
        }
        aggregateID = device

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, input, inputTime, _, _ in
            sink.push(input, hostTime: inputTime.pointee.mHostTime)
        }
        guard status == noErr, let proc else {
            stop()
            throw RecorderError("create io proc", status)
        }
        procID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            stop()
            throw RecorderError("start aggregate device", status)
        }

        if includeOutputDevice {
            var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
            let listener: AudioObjectPropertyListenerBlock = { _, _ in onRouteChange() }
            AudioObjectAddPropertyListenerBlock(CA.system, &addr, queue, listener)
            outputListener = listener
        }
        return format.mSampleRate
    }

    public func stop() {
        if let outputListener {
            var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(CA.system, &addr, queue, outputListener)
        }
        outputListener = nil
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
