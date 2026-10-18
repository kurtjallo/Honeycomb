import AppKit
import ApplicationServices
import CoreAudio
import Observation

struct LogEvent: Identifiable {
    let id = UUID()
    let time: Date
    let kind: String
    let detail: String
}

@MainActor
@Observable
final class SpikeModel {
    var isRecording = false
    var micLevel: Float = 0
    var systemLevel: Float = 0
    var events: [LogEvent] = []
    var toneResult = "Not run yet"
    var stats = ""
    var sessionFolder: URL?
    var accessibilityTrusted = AXIsProcessTrusted()
    var tapOnly = false {
        didSet { tap.tapOnly = tapOnly }
    }

    private let tap = SystemTap()
    private let mic = MicCapture()
    private let monitor = MicMonitor()
    private var lastCPU: Double = 0
    private var lastWall = Date()
    private var maxTapGap: Double = 0
    private var lastTapHostTime: UInt64 = 0
    private let baseFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HoneycombS1")
    private var logHandle: FileHandle?

    init() {
        try? FileManager.default.createDirectory(at: baseFolder, withIntermediateDirectories: true)
        let logURL = baseFolder.appendingPathComponent("events.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        log("launch", "HoneycombS1 build \(version), pid \(ProcessInfo.processInfo.processIdentifier)")

        monitor.onEvent = { [weak self] kind, detail in self?.log(kind, detail) }
        monitor.start()

        tap.onBuffer = { [weak self] level, hostTime in
            Task { @MainActor in self?.receivedTapBuffer(level: level, hostTime: hostTime) }
        }
        mic.onBuffer = { [weak self] level, _ in
            Task { @MainActor in self?.micLevel = level }
        }
        mic.onEvent = { [weak self] detail in self?.log("mic", detail) }

        watchOutputDevice()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleStats() }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = baseFolder.appendingPathComponent(stamp)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try tap.start(writingTo: folder.appendingPathComponent("system.caf"))
            try mic.start(folder: folder)
            sessionFolder = folder
            let logURL = folder.appendingPathComponent("events.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            sessionLog = try? FileHandle(forWritingTo: logURL)
            isRecording = true
            maxTapGap = 0
            log("record", "Started. System: \(tap.formatDescription) via \(tap.outputDeviceName). Mic: \(mic.formatDescription). Folder: \(folder.path)")
        } catch {
            log("error", "Could not start recording: \(error)")
            tap.stop()
            mic.stop()
        }
    }

    private func stopRecording() {
        tap.stop()
        mic.stop()
        isRecording = false
        writeTimeline()
        log("record", "Stopped. Longest gap between system-audio buffers: \(String(format: "%.2f", maxTapGap)) s")
        try? sessionLog?.close()
        sessionLog = nil
    }

    private func receivedTapBuffer(level: Float, hostTime: UInt64) {
        systemLevel = level
        if lastTapHostTime != 0 {
            let gap = hostTimeToSeconds(hostTime) - hostTimeToSeconds(lastTapHostTime)
            if gap > maxTapGap { maxTapGap = gap }
            if gap > 1 { log("gap", String(format: "System audio had a %.2f s gap", gap)) }
        }
        lastTapHostTime = hostTime
        toneLevelPeak = max(toneLevelPeak, level)
    }

    private func writeTimeline() {
        guard let sessionFolder else { return }
        let timeline: [String: Any] = [
            "system_first_host_seconds": tap.firstHostTime.map(hostTimeToSeconds) ?? NSNull(),
            "mic_first_host_seconds": mic.firstHostTime.map(hostTimeToSeconds) ?? NSNull(),
            "max_system_gap_seconds": maxTapGap,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: sessionFolder.appendingPathComponent("timeline.json"))
        }
    }

    // MARK: Output device changes (speakers → AirPods)

    private func watchOutputDevice() {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            Task { @MainActor in self?.outputDeviceChanged() }
        }
    }

    private func outputDeviceChanged() {
        guard isRecording else {
            log("device", "Output device changed (not recording)")
            return
        }
        if tapOnly {
            log("device", "Output device changed. Tap-only mode, so the tap is not rebuilt. Watch for gaps.")
            return
        }
        let before = Date()
        do {
            try tap.restart()
            log("device", String(format: "Output changed to %@. Tap rebuilt in %.2f s", tap.outputDeviceName,
                                 Date().timeIntervalSince(before)))
        } catch {
            log("error", "Tap rebuild failed after output change: \(error)")
        }
    }

    // MARK: Tone test (is system-audio permission really granted?)

    private var toneLevelPeak: Float = 0

    func runToneTest() {
        toneResult = "Playing a tone from a separate process…"
        toneLevelPeak = 0
        let startedTap = !isRecording
        do {
            if startedTap { try tap.start(writingTo: nil) }
        } catch {
            toneResult = "Could not start the tap: \(error)"
            return
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ToneHelper")
        let process = Process()
        process.executableURL = helper
        do { try process.run() } catch {
            toneResult = "Could not launch ToneHelper at \(helper.path): \(error)"
            if startedTap { tap.stop() }
            return
        }
        let started = Date()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            let elapsed = Date().timeIntervalSince(started)
            if startedTap { tap.stop() }
            if toneLevelPeak > 0.01 {
                toneResult = String(format: "Heard the tone (level %.3f). System-audio permission works.", toneLevelPeak)
            } else {
                toneResult = String(format: "Heard nothing after %.1f s. System-audio permission is probably denied.", elapsed)
            }
            log("tone test", toneResult)
        }
    }

    // MARK: Accessibility

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        log("accessibility", accessibilityTrusted ? "Granted" : "Asked. Grant it in System Settings, then come back.")
    }

    // MARK: Stats and log

    private func sampleStats() {
        accessibilityTrusted = AXIsProcessTrusted()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let now = Date()
        let percent = (cpu - lastCPU) / now.timeIntervalSince(lastWall) * 100
        lastCPU = cpu
        lastWall = now
        stats = String(format: "CPU %.1f%%   Memory %.0f MB", percent, Double(footprint()) / 1_048_576)
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func log(_ kind: String, _ detail: String) {
        let event = LogEvent(time: Date(), kind: kind, detail: detail)
        events.insert(event, at: 0)
        let line = "\(ISO8601DateFormatter().string(from: event.time))  [\(kind)]  \(detail)\n"
        logHandle?.write(Data(line.utf8))
        sessionLog?.write(Data(line.utf8))
    }

    private var sessionLog: FileHandle?

    func openFolder() {
        NSWorkspace.shared.open(sessionFolder ?? baseFolder)
    }
}
