import AppKit
import ApplicationServices
import CoreAudio

/// Watches which processes use audio input, and logs what the "Meeting detected" rules would do.
final class MicMonitor {
    enum Kind { case callApp(String), browser(String), other }

    struct Activation {
        let pid: pid_t
        let bundleID: String
        let start: Date
        var decided = false
    }

    static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime",
        "Cisco-Systems.Spark": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
    ]

    static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.apple.Safari": "Safari",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
    ]

    static let meetingTitleMarkers = ["Meet - ", "Meet – ", "Google Meet", "Zoom", "Microsoft Teams", "Webex"]

    var onEvent: ((String, String) -> Void)?
    private var active: [AudioObjectID: Activation] = [:]
    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        var seen = Set<AudioObjectID>()
        for object in audioProcessObjects() where readUInt32(object, kAudioProcessPropertyIsRunningInput) == 1 {
            seen.insert(object)
            if active[object] != nil { continue }
            let pid = pid_t(bitPattern: readUInt32(object, kAudioProcessPropertyPID) ?? 0)
            if pid == ownPID { continue }
            let bundleID = readString(object, kAudioProcessPropertyBundleID) ?? "unknown"
            active[object] = Activation(pid: pid, bundleID: bundleID, start: Date())
            onEvent?("mic start", "\(bundleID) (pid \(pid))")
        }

        for (object, activation) in active {
            if !seen.contains(object) {
                let seconds = Date().timeIntervalSince(activation.start)
                onEvent?("mic stop", "\(activation.bundleID) after \(String(format: "%.1f", seconds)) s")
                active[object] = nil
            } else if !activation.decided, Date().timeIntervalSince(activation.start) >= 3 {
                active[object]?.decided = true
                onEvent?("pop-up rule", decide(activation))
            }
        }
    }

    private func decide(_ activation: Activation) -> String {
        switch Self.classify(activation.bundleID) {
        case .callApp(let name):
            return "SHOW \"\(name) call detected\" (\(activation.bundleID))"
        case .browser(let mainID):
            let name = Self.browsers[mainID] ?? mainID
            guard AXIsProcessTrusted() else {
                return "SHOW generic \"Call detected in \(name)\" (no Accessibility permission)"
            }
            let titles = Self.windowTitles(bundleID: mainID)
            let listed = titles.isEmpty ? "no window titles" : titles.map { "\"\($0)\"" }.joined(separator: ", ")
            if let match = titles.first(where: { title in Self.meetingTitleMarkers.contains { title.contains($0) } }) {
                return "SHOW meeting in \(name): \"\(match)\""
            }
            return "IGNORE \(name), not a meeting site (\(listed))"
        case .other:
            return "IGNORE \(activation.bundleID), not a known call app"
        }
    }

    static func classify(_ bundleID: String) -> Kind {
        if let name = callApps[bundleID] { return .callApp(name) }
        if let main = browsers.keys.first(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }) {
            return .browser(main)
        }
        if bundleID.hasPrefix("com.apple.WebKit"),
           !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty {
            return .browser("com.apple.Safari")
        }
        return .other
    }

    /// Titles of every window of the app, front window first. Needs Accessibility permission.
    static func windowTitles(bundleID: String) -> [String] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var titles: [String] = []
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused, let title = title(of: focused as! AXUIElement) {
            titles.append(title)
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement] {
            for window in list {
                if let title = title(of: window), !titles.contains(title) { titles.append(title) }
            }
        }
        return titles
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
