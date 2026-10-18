@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import HoneycombCore

/// Records with the real recorders on this Mac's hardware and prints a timeline: health changes,
/// route callbacks, engine configuration changes, Core Audio device changes, and samples per second.
/// Off by default, because it needs a mic, the system audio permission, and about 20 s per run.
///
///     HONEYCOMB_HARDWARE_TESTS=1 HONEYCOMB_CAPTURE_SCENARIO=app \
///       swift test --scratch-path /tmp/hc-audio-build --filter CaptureHardwareTests
///
/// Scenarios: app (what AppModel.makeRecorders builds), mic-picked, mic-default, tap, tap-first, mic-first.
/// HONEYCOMB_CAPTURE_SECONDS sets the length. HONEYCOMB_CAPTURE_SOUND_AT=7,10 plays a short sound at
/// each of those seconds instead of nonstop speech, for a call that starts quiet.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HONEYCOMB_HARDWARE_TESTS"] == "1"))
struct CaptureHardwareTests {
    @Test func recordsContinuouslyOnRealHardware() async throws {
        let env = ProcessInfo.processInfo.environment
        let scenario = env["HONEYCOMB_CAPTURE_SCENARIO"] ?? "app"
        let seconds = Int(env["HONEYCOMB_CAPTURE_SECONDS"] ?? "") ?? 20
        let picked = InputDevicePicker.pick(devices: InputDevices.all(), defaultInput: InputDevices.defaultInput,
                                            callAppInputs: InputDevices.inputsInUse(of: []))
        let stages: [[any TrackRecorder]] = switch scenario {
        case "app": [[MicRecorder(deviceID: picked?.id), SystemAudioRecorder()]]
        case "mic-picked": [[MicRecorder(deviceID: picked?.id)]]
        case "mic-default": [[MicRecorder()]]
        case "tap": [[SystemAudioRecorder()]]
        case "tap-first": [[SystemAudioRecorder()], [MicRecorder(deviceID: picked?.id)]]
        case "mic-first": [[MicRecorder(deviceID: picked?.id)], [SystemAudioRecorder()]]
        default: []
        }
        try #require(!stages.isEmpty, "unknown scenario \(scenario)")

        let timeline = Timeline()
        timeline.note("scenario=\(scenario) seconds=\(seconds) mic_permission=\(Permissions.microphone.rawValue)")
        timeline.note("default_input=\(Probe.name(InputDevices.defaultInput)) default_output="
            + "\(Probe.name(CA.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))) picked_mic=\(picked?.name ?? "nil")")
        for device in Probe.devices { timeline.note("device \(Probe.describe(device))") }
        let probe = Probe(timeline: timeline)
        defer { probe.remove() }
        let speaker = Speaker(timeline: timeline)
        speaker.start()
        defer { speaker.stop() }

        var sessions: [RecordingSession] = []
        var readers: [Task<Void, Never>] = []
        var stageStartSecond: [Channel: Int64] = [:]
        for (index, recorders) in stages.enumerated() {
            if index > 0 { try await Task.sleep(for: .seconds(3)) }
            let wrapped = recorders.map { ProbedRecorder($0, timeline: timeline) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hc-hw-\(UUID().uuidString)")
            let session = RecordingSession(meetingID: UUID(), folder: folder, recorders: wrapped)
            timeline.mark("session.start \(wrapped.map(\.channel.rawValue)) folder=\(folder.path)")
            for recorder in wrapped { stageStartSecond[recorder.channel] = timeline.elapsedMs / 1000 }
            try await session.start()
            sessions.append(session)
            readers.append(Task { for await chunk in session.audio { timeline.count(chunk) } })
            readers.append(Task {
                var last: [Channel: TrackHealth] = [:]
                for await status in session.status {
                    for channel in wrapped.map(\.channel) where status.tracks[channel]?.health != last[channel] {
                        last[channel] = status.tracks[channel]?.health
                        timeline.mark("\(channel.rawValue) health=\(last[channel].map { "\($0)" } ?? "nil")")
                    }
                }
            })
        }
        try await Task.sleep(for: .seconds(seconds))

        var metas: [SessionMeta] = []
        for session in sessions {
            metas.append(await session.stop())
            timeline.mark("session.stop")
        }
        for reader in readers { await reader.value }
        timeline.print()

        for (meta, recorders) in zip(metas, stages) {
            for channel in recorders.map(\.channel) {
                let track = meta[channel]
                Swift.print("[\(channel.rawValue)] status=\(track.status.map(\.rawValue) ?? "nil")")
                for segment in track.segments {
                    Swift.print("[\(channel.rawValue)]   segment \(segment.file) start=\(segment.startOffsetMs)ms "
                        + "end=\(segment.endOffsetMs ?? -1)ms frames=\(segment.frames)")
                }
                for interruption in track.interruptions {
                    Swift.print("[\(channel.rawValue)]   interruption reason=\(interruption.reason.rawValue) "
                        + "at=\(interruption.startedAtMs)ms recovered=\(interruption.recoveredAtMs.map { "\($0)ms" } ?? "never") "
                        + "attempts=\(interruption.attempts)")
                }
                let holes = zip(track.segments, track.segments.dropFirst()).map { "\($1.startOffsetMs - ($0.endOffsetMs ?? 0))ms" }
                Swift.print("[\(channel.rawValue)]   audio missing between segments: \(holes)")
                let gaps = timeline.gaps(channel)
                let first = timeline.firstArrival(channel)
                Swift.print("[\(channel.rawValue)]   first samples in second \(first.map(String.init) ?? "never"), gaps over 500 ms: \(gaps)")
                #expect(track.status == .complete, "\(channel.rawValue) track status")
                #expect(track.interruptions.isEmpty, "\(channel.rawValue) interruptions")
                #expect(track.segments.count == 1, "\(channel.rawValue) segments")
                #expect(first.map { $0 <= stageStartSecond[channel]! + 1 } ?? false, "\(channel.rawValue) samples from the start")
                #expect(gaps.isEmpty, "\(channel.rawValue) samples missing")
            }
        }
    }
}

/// Wraps a real recorder to timestamp its starts, stops, and route callbacks.
private final class ProbedRecorder: TrackRecorder, @unchecked Sendable {
    let inner: any TrackRecorder
    let timeline: Timeline
    var channel: Channel { inner.channel }

    init(_ inner: any TrackRecorder, timeline: Timeline) {
        self.inner = inner
        self.timeline = timeline
    }

    func start(into sink: AudioSink, onRouteChange: @escaping @Sendable () -> Void) throws -> Double {
        let timeline = self.timeline
        let channel = self.channel
        timeline.mark("\(channel.rawValue) recorder.start")
        let rate = try inner.start(into: sink) {
            timeline.mark("\(channel.rawValue) recorder.route_change_callback")
            onRouteChange()
        }
        timeline.mark("\(channel.rawValue) recorder.started rate=\(rate)")
        return rate
    }

    func stop() {
        timeline.mark("\(channel.rawValue) recorder.stop")
        inner.stop()
        timeline.mark("\(channel.rawValue) recorder.stopped")
    }
}

/// Every timestamped line, plus 16 kHz samples per second of session time per channel.
private final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var lines: [String] = []
    private var samples: [Channel: [Int64: Int]] = [:]
    private var peaks: [Channel: [Int64: Float]] = [:]
    private var lastArrival: [Channel: Int64] = [:]
    private var gaps: [Channel: [String]] = [:]

    func note(_ text: String) {
        lock.withLock { lines.append(text) }
    }

    var elapsedMs: Int64 {
        let elapsed = ContinuousClock.now - start
        return elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }

    func mark(_ text: String) {
        note(String(format: "+%7.3fs  ", Double(elapsedMs) / 1000) + text)
    }

    /// Buckets by arrival time, not by position in the file: a stall inside a segment is invisible
    /// in file positions, because the writer keeps counting frames from where it left off.
    func count(_ chunk: AudioChunk) {
        let ms = elapsedMs
        let peak = chunk.samples.reduce(Float(0)) { max($0, abs($1)) }
        lock.withLock {
            samples[chunk.channel, default: [:]][ms / 1000, default: 0] += chunk.samples.count
            peaks[chunk.channel, default: [:]][ms / 1000] = max(peaks[chunk.channel]?[ms / 1000] ?? 0, peak)
            if let last = lastArrival[chunk.channel], ms - last > 500 {
                gaps[chunk.channel, default: []].append("\(last)ms+\(ms - last)ms")
            }
            lastArrival[chunk.channel] = ms
        }
    }

    /// Waits over 500 ms between chunks, after the first. Chunks arrive about every 50 ms.
    func gaps(_ channel: Channel) -> [String] {
        lock.withLock { gaps[channel] ?? [] }
    }

    func firstArrival(_ channel: Channel) -> Int64? {
        lock.withLock { samples[channel]?.keys.min() }
    }

    func print() {
        lock.withLock {
            for line in lines { Swift.print(line) }
            for channel in Channel.allCases {
                guard let counts = samples[channel] else { continue }
                let row = counts.keys.sorted().map { second in
                    String(format: "%lld:%d/%.3f", second, counts[second]!, peaks[channel]?[second] ?? 0)
                }
                Swift.print("samples/s by arrival [\(channel.rawValue)] (second:count/peak) " + row.joined(separator: " "))
            }
        }
    }
}

/// Logs engine configuration changes and Core Audio device changes while the run lasts.
private final class Probe: @unchecked Sendable {
    private let timeline: Timeline
    private let queue = DispatchQueue(label: "honeycomb.hardware-probe")
    private var observer: NSObjectProtocol?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(timeline: Timeline) {
        self.timeline = timeline
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { note in
            let engine = note.object as? AVAudioEngine
            timeline.mark("AVAudioEngineConfigurationChange engine=\(engine.map { ObjectIdentifier($0).hashValue } ?? 0) "
                + "running=\(engine?.isRunning ?? false) input_rate=\(engine?.inputNode.inputFormat(forBus: 0).sampleRate ?? 0)")
        }
        listen(CA.system, kAudioHardwarePropertyDevices) { "devices changed: " + Probe.devices.map(Probe.describe).joined(separator: ", ") }
        listen(CA.system, kAudioHardwarePropertyDefaultInputDevice) {
            "default input -> \(Probe.name(InputDevices.defaultInput))"
        }
        listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) {
            "default output -> \(Probe.name(CA.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)))"
        }
        for device in Probe.devices {
            listen(device, kAudioDevicePropertyNominalSampleRate) { "rate changed: \(Probe.describe(device))" }
            listen(device, kAudioDevicePropertyDeviceIsRunningSomewhere) { "running changed: \(Probe.describe(device))" }
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ text: @escaping @Sendable () -> String) {
        var address = CA.address(selector)
        let timeline = self.timeline
        let block: AudioObjectPropertyListenerBlock = { _, _ in timeline.mark("coreaudio " + text()) }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    func remove() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        listeners = []
    }

    static var devices: [AudioObjectID] { CA.objects(CA.system, kAudioHardwarePropertyDevices) }

    static func name(_ device: AudioObjectID?) -> String {
        guard let device else { return "nil" }
        return "\(device):" + (CA.string(device, kAudioObjectPropertyName) ?? "?")
    }

    static func describe(_ device: AudioObjectID) -> String {
        let rate = CA.read(device, kAudioDevicePropertyNominalSampleRate, default: Float64(0)) ?? 0
        let running = CA.read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, default: UInt32(0)) ?? 0
        return "\(name(device)) rate=\(Int(rate)) running=\(running)"
    }
}

/// Plays audio so the system tap has something to hear. Output may be muted; the tap still hears it.
/// By default it speaks without pause. HONEYCOMB_CAPTURE_SOUND_AT=3,12 plays one short sound at
/// each of those seconds instead, to show how the tap behaves around silence.
private final class Speaker: @unchecked Sendable {
    private let timeline: Timeline
    private var task: Task<Void, Never>?

    init(timeline: Timeline) {
        self.timeline = timeline
    }

    func start() {
        let timeline = self.timeline
        let schedule = ProcessInfo.processInfo.environment["HONEYCOMB_CAPTURE_SOUND_AT"]?
            .split(separator: ",").compactMap { Double($0) }
        task = Task.detached {
            guard let schedule else {
                while !Task.isCancelled {
                    Self.run("/usr/bin/say", "The quarterly numbers look fine and the renewal is on track for next month.")
                }
                return
            }
            let begin = ContinuousClock.now
            for second in schedule {
                try? await Task.sleep(until: begin + .milliseconds(Int(second * 1000)))
                if Task.isCancelled { return }
                timeline.mark("speaker.play")
                Self.run("/usr/bin/afplay", "/System/Library/Sounds/Ping.aiff")
                timeline.mark("speaker.done")
            }
        }
    }

    private static func run(_ tool: String, _ argument: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [argument]
        try? process.run()
        process.waitUntilExit()
    }

    func stop() {
        task?.cancel()
    }
}
