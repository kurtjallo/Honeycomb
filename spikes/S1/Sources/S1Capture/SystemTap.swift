import AVFoundation
import CoreAudio

/// Records everything the Mac plays (the "Them" track) through a global Core Audio process tap.
final class SystemTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "s1.system-tap", qos: .userInteractive)
    private var format: AVAudioFormat?
    private var file: AVAudioFile?

    /// Called on the tap queue with the RMS level and the buffer's host time.
    var onBuffer: ((Float, UInt64) -> Void)?
    private(set) var firstHostTime: UInt64?
    private(set) var lastBufferHostTime: UInt64 = 0
    private(set) var outputDeviceName = "?"
    var formatDescription: String { format.map { "\(Int($0.sampleRate)) Hz, \($0.channelCount) ch" } ?? "?" }
    /// Quill's setup: an aggregate device holding only the tap, with no output device inside it.
    var tapOnly = false
    var isRunning: Bool { procID != nil }

    /// Starts the tap. Pass a file URL on the first start; restarts keep writing to the same file.
    func start(writingTo url: URL?) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses())
        description.uuid = UUID()
        description.name = "Honeycomb S1"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "read tap format")
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError(step: "AVAudioFormat from tap format", status: -1)
        }
        format = tapFormat

        let output = try defaultOutputDevice()
        guard let outputUID = readString(output, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(step: "read output device UID", status: -1)
        }
        outputDeviceName = readString(output, kAudioObjectPropertyName) ?? outputUID

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Honeycomb S1 tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if tapOnly {
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [] as [[String: Any]]
            outputDeviceName = "tap only"
        } else {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice),
                  "AudioHardwareCreateAggregateDevice")
        aggregateID = aggregateDevice

        if let url {
            file = try AVAudioFile(forWriting: url, settings: tapFormat.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: tapFormat.isInterleaved)
        }

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
            self?.handle(input, hostTime: inputTime.pointee.mHostTime)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        procID = proc
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    /// Rebuilds the tap and aggregate device, for example after the output device changed.
    func restart() throws {
        let keptFile = file
        teardown(closeFile: false)
        try start(writingTo: nil)
        file = keptFile
    }

    func stop() {
        teardown(closeFile: true)
    }

    private func teardown(closeFile: Bool) {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        if closeFile { file = nil }
    }

    private func handle(_ input: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
        else { return }
        if firstHostTime == nil { firstHostTime = hostTime }
        lastBufferHostTime = hostTime
        // Writing inside the IO callback is not real-time safe. Acceptable for a spike; the app uses a ring buffer.
        try? file?.write(from: buffer)
        onBuffer?(rmsLevel(buffer), hostTime)
    }

    private func excludedProcesses() -> [AudioObjectID] {
        let own = processObject(for: ProcessInfo.processInfo.processIdentifier)
        return own == kAudioObjectUnknown ? [] : [own]
    }
}
