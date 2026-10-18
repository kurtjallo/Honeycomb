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

/// A process recording from input devices right now.
public struct InputUse: Sendable, Equatable {
    public let bundleID: String
    public let devices: [AudioDeviceID]

    public init(bundleID: String, devices: [AudioDeviceID]) {
        self.bundleID = bundleID
        self.devices = devices
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

    /// The input devices call apps record from. Other recorders, such as OBS on a virtual device
    /// or Siri listening, never choose the mic.
    public static func inputsToFollow(_ uses: [InputUse], callApps: Set<String>) -> [AudioDeviceID] {
        uses.filter { use in callApps.contains { CallAppCatalog.process(use.bundleID, belongsTo: $0) } }
            .flatMap(\.devices)
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

    /// Input devices that call apps are recording from right now.
    public static func inputsInUse(preferring bundleIDs: Set<String>) -> [AudioDeviceID] {
        InputDevicePicker.inputsToFollow(uses(), callApps: bundleIDs)
    }

    /// Other processes recording right now.
    public static func uses() -> [InputUse] {
        let own = ProcessInfo.processInfo.processIdentifier
        return CA.processObjects.compactMap { process in
            guard CA.read(process, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) == 1,
                  CA.read(process, kAudioProcessPropertyPID, default: pid_t(0)) != own
            else { return nil }
            return InputUse(bundleID: CA.string(process, kAudioProcessPropertyBundleID) ?? "",
                            devices: CA.objects(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
        }
    }
}
