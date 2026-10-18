import AVFoundation
import CoreAudio

struct CoreAudioError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ step: String) throws {
    if status != noErr { throw CoreAudioError(step: step, status: status) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func defaultOutputDevice() throws -> AudioDeviceID {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device),
              "read default output device")
    return device
}

func processObject(for pid: pid_t) -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
    return object
}

func audioProcessObjects() -> [AudioObjectID] {
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
    return objects
}

/// Root-mean-square level of the first channel, 0...1.
func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
    let stride = buffer.stride
    let samples = data[0]
    var sum: Float = 0
    for i in 0..<Int(buffer.frameLength) {
        let s = samples[i * stride]
        sum += s * s
    }
    return (sum / Float(buffer.frameLength)).squareRoot()
}

func hostTimeToSeconds(_ hostTime: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(hostTime) * Double(info.numer) / Double(info.denom) / 1_000_000_000
}
