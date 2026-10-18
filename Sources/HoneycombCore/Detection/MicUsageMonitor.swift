import AppKit
import ApplicationServices
import CoreAudio
import Foundation

/// Reports which other apps start and stop using a microphone, by checking Core Audio's process
/// list twice a second. Honeycomb's own process is skipped.
public final class MicUsageMonitor: @unchecked Sendable {
    public struct Change: Sendable, Equatable {
        public let key: String
        public let bundleID: String
        public let pid: pid_t
        public let started: Bool
    }

    private let queue = DispatchQueue(label: "honeycomb.mic-monitor")
    private var timer: DispatchSourceTimer?
    private var active: [AudioObjectID: (bundleID: String, pid: pid_t)] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    public func start(_ onChange: @escaping @Sendable (Change) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.poll(onChange) }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll(_ onChange: @Sendable (Change) -> Void) {
        var seen = Set<AudioObjectID>()
        for process in CA.processObjects
        where CA.read(process, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) == 1 {
            let pid = CA.read(process, kAudioProcessPropertyPID, default: pid_t(0)) ?? 0
            guard pid != ownPID else { continue }
            seen.insert(process)
            guard active[process] == nil else { continue }
            let bundleID = CA.string(process, kAudioProcessPropertyBundleID) ?? ""
            active[process] = (bundleID, pid)
            onChange(Change(key: String(process), bundleID: bundleID, pid: pid, started: true))
        }
        for (process, info) in active where !seen.contains(process) {
            active[process] = nil
            onChange(Change(key: String(process), bundleID: info.bundleID, pid: info.pid, started: false))
        }
    }
}

public enum BrowserTitles {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Accessibility settings.
    @discardableResult
    public static func requestTrust() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func windowTitles(bundleID: String) -> [String] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
              let windows = windows as? [AXUIElement]
        else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
            return title as? String
        }
    }
}
