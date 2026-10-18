import CoreAudio
import Foundation

public struct InputDevice: Sendable, Equatable, Identifiable {
    public enum Transport: Sendable, Equatable {
        case builtIn
        case bluetooth
        case usb
        case virtual
        case other
    }

    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: Transport

    public init(id: AudioDeviceID, uid: String, name: String, transport: Transport) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
    }
}

/// Picks the mic to record. Follow the device the call app uses. Without one, avoid a Bluetooth
/// mic when a built-in one exists: opening an AirPods mic drops AirPods playback to call quality.
public enum InputDevicePicker {
    public static func pick(devices: [InputDevice], defaultInput: AudioDeviceID?,
                            callAppInputs: [AudioDeviceID]) -> InputDevice? {
        if let used = callAppInputs.lazy.compactMap({ id in devices.first { $0.id == id } }).first {
            return used
        }
        let fallback = devices.first { $0.id == defaultInput } ?? devices.first
        if fallback?.transport == .bluetooth, let builtIn = devices.first(where: { $0.transport == .builtIn }) {
            return builtIn
        }
        return fallback
    }
}

/// Reads the Mac's input devices and which ones other apps are recording from.
public enum InputDevices {
    public static func all() -> [InputDevice] {
        CA.objects(CA.system, kAudioHardwarePropertyDevices).compactMap { id in
            let streams = CA.objects(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            guard !streams.isEmpty, let uid = CA.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            if uid.hasPrefix("CADefaultDeviceAggregate") { return nil }
            let name = CA.string(id, kAudioObjectPropertyName) ?? uid
            let transportType = CA.read(id, kAudioDevicePropertyTransportType, default: UInt32(0)) ?? 0
            let transport: InputDevice.Transport = switch transportType {
            case kAudioDeviceTransportTypeBuiltIn: .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
            case kAudioDeviceTransportTypeUSB: .usb
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: .virtual
            default: .other
            }
            return InputDevice(id: id, uid: uid, name: name, transport: transport)
        }
    }

    public static var defaultInput: AudioDeviceID? {
        CA.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Input devices used by other processes that are recording right now, call apps first.
    public static func inputsInUse(preferring bundleIDs: Set<String>) -> [AudioDeviceID] {
        let own = ProcessInfo.processInfo.processIdentifier
        var preferred: [AudioDeviceID] = []
        var others: [AudioDeviceID] = []
        for process in CA.processObjects {
            guard CA.read(process, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) == 1,
                  CA.read(process, kAudioProcessPropertyPID, default: pid_t(0)) != own
            else { continue }
            let devices = CA.objects(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
            let bundle = CA.string(process, kAudioProcessPropertyBundleID) ?? ""
            if bundleIDs.contains(where: { bundle.hasPrefix($0) }) { preferred += devices } else { others += devices }
        }
        return preferred + others
    }
}
