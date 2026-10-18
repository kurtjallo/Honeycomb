/// Every timing the detection rules use.
public struct DetectionPolicy: Sendable, Equatable {
    /// A call app must use the mic this long before Honeycomb asks. Short blips are ignored.
    public var askAfterMs: Int64 = 3_000
    /// After the recorded app lets go of the mic, wait this long before calling the call ended.
    public var endAfterMs: Int64 = 5_000
    /// While no browser window title shows a meeting, read the titles again this often. The meeting
    /// tab may still be loading, or in a window the user is not looking at yet.
    public var titleRetryMs: Int64 = 2_000
    /// Stop reading titles this long after the first read, and stay quiet for that mic use.
    public var titleGiveUpAfterMs: Int64 = 60_000

    public init() {}
}

public enum PromptKind: Sendable, Equatable {
    /// "Zoom call detected"
    case app(String)
    /// "Google Meet detected" in a browser, from the tab title.
    case site(String)
    /// "Call detected in Chrome": a browser without Accessibility permission to read the title.
    case browser(String)

    public var headline: String {
        switch self {
        case .app(let name): "\(name) call detected"
        case .site(let name): "\(name) detected"
        case .browser(let name): "Call detected in \(name)"
        }
    }
}

public struct CallPrompt: Sendable, Equatable {
    public let key: String
    public let app: CallApp
    public let kind: PromptKind
    /// Shown while another meeting is recording: "Stop current and start new".
    public let replacesRecording: Bool
}

public enum DetectionEvent: Sendable, Equatable {
    case micStarted(key: String, bundleID: String, atMs: Int64)
    case micStopped(key: String, atMs: Int64)
    /// Every window title the browser has open. Empty when Accessibility could not read them.
    case titleRead(key: String, titles: [String])
    case tick(atMs: Int64)
    case startNotes(key: String)
    case notNow(key: String)
    /// A recording started by hand or from a prompt. `key` is the call it belongs to, if any.
    case recordingStarted(key: String?)
    case recordingStopped
}

public enum DetectionCommand: Sendable, Equatable {
    case readTitle(key: String, bundleID: String)
    case show(CallPrompt)
    case hide(key: String)
    case startRecording(CallPrompt)
    /// The recorded call app let go of the mic: stop and write notes.
    case callEnded
    /// The recorded call app took the mic back after `.callEnded`: keep recording.
    case callResumed
}

/// Decides when to ask "Take notes?" and when a call has ended, from which apps use the mic.
/// Pure: the mic monitor reports events and the app carries out the commands. Only apps in the
/// call-app table count, so dictation tools never trigger a prompt.
public struct DetectionMachine: Sendable {
    enum Phase: Sendable, Equatable {
        case waiting(sinceMs: Int64)
        /// A title read is out. `sinceMs` is when the first read for this mic use went out.
        case readingTitle(sinceMs: Int64, readMs: Int64)
        /// No window title showed a meeting at the read sent at `readMs`.
        case titleUnmatched(sinceMs: Int64, readMs: Int64)
        case prompted
        case quiet
        case recording
    }

    /// Whether the recorded call app still holds the mic.
    enum CallEnd: Sendable, Equatable {
        case ongoing
        case ending(sinceMs: Int64)
        case ended
    }

    struct Activation: Sendable, Equatable {
        var app: CallApp
        var phase: Phase
        var kind: PromptKind?
    }

    public let policy: DetectionPolicy
    public var callApps: [CallApp]
    public var accessibilityTrusted: Bool
    private var activations: [String: Activation] = [:]
    private var isRecording = false
    private var recordedApp: CallApp?
    private var callEnd = CallEnd.ongoing

    public init(policy: DetectionPolicy = DetectionPolicy(), callApps: [CallApp], accessibilityTrusted: Bool) {
        self.policy = policy
        self.callApps = callApps
        self.accessibilityTrusted = accessibilityTrusted
    }

    public func callApp(for bundleID: String) -> CallApp? {
        callApps.first { CallAppCatalog.process(bundleID, belongsTo: $0.bundleId) }
    }

    public mutating func handle(_ event: DetectionEvent) -> [DetectionCommand] {
        switch event {
        case .micStarted(let key, let bundleID, let at):
            guard let app = callApp(for: bundleID), app.ask else { return [] }
            if isRecording, app.bundleId == recordedApp?.bundleId {
                let ended = callEnd == .ended
                callEnd = .ongoing
                activations[key] = Activation(app: app, phase: .recording)
                return ended ? [.callResumed] : []
            }
            if activations.values.contains(where: { $0.app.bundleId == app.bundleId && $0.phase == .quiet }) {
                activations[key] = Activation(app: app, phase: .quiet)
                return []
            }
            activations[key] = Activation(app: app, phase: .waiting(sinceMs: at))
            return []

        case .micStopped(let key, let at):
            guard let activation = activations.removeValue(forKey: key) else { return [] }
            var commands: [DetectionCommand] = []
            if activation.phase == .prompted { commands.append(.hide(key: key)) }
            if activation.phase == .recording, isRecording,
               !activations.values.contains(where: { $0.phase == .recording }) {
                callEnd = .ending(sinceMs: at)
            }
            return commands

        case .titleRead(let key, let titles):
            guard var activation = activations[key], case .readingTitle(let since, let read) = activation.phase else {
                return []
            }
            guard let site = titles.lazy.compactMap({ MeetingSites.match($0) }).first else {
                activation.phase = .titleUnmatched(sinceMs: since, readMs: read)
                activations[key] = activation
                return []
            }
            activation.kind = .site(site)
            activation.phase = .prompted
            activations[key] = activation
            return [.show(prompt(key, activation))]

        case .tick(let now):
            var commands: [DetectionCommand] = []
            if case .ending(let since) = callEnd, now - since >= policy.endAfterMs {
                callEnd = .ended
                commands.append(.callEnded)
            }
            for (key, activation) in activations {
                var next = activation
                switch activation.phase {
                case .waiting(let since) where now - since >= policy.askAfterMs:
                    switch activation.app.kind {
                    case .app:
                        next.kind = .app(activation.app.name)
                        next.phase = .prompted
                        commands.append(.show(prompt(key, next)))
                    case .browser where accessibilityTrusted:
                        next.phase = .readingTitle(sinceMs: now, readMs: now)
                        commands.append(.readTitle(key: key, bundleID: activation.app.bundleId))
                    case .browser:
                        next.kind = .browser(activation.app.name)
                        next.phase = .prompted
                        commands.append(.show(prompt(key, next)))
                    }
                case .titleUnmatched(let since, let read) where now - read >= policy.titleRetryMs:
                    if now - since >= policy.titleGiveUpAfterMs {
                        next.phase = .quiet
                    } else {
                        next.phase = .readingTitle(sinceMs: since, readMs: now)
                        commands.append(.readTitle(key: key, bundleID: activation.app.bundleId))
                    }
                default:
                    continue
                }
                activations[key] = next
            }
            return commands

        case .startNotes(let key):
            guard var activation = activations[key], activation.phase == .prompted else { return [] }
            // The call counts as recorded only once capture starts, in `.recordingStarted(key)`.
            activation.phase = .quiet
            activations[key] = activation
            return [.hide(key: key), .startRecording(prompt(key, activation))]

        case .notNow(let key):
            guard var activation = activations[key] else { return [] }
            let wasPrompted = activation.phase == .prompted
            activation.phase = .quiet
            activations[key] = activation
            return wasPrompted ? [.hide(key: key)] : []

        case .recordingStarted(let key):
            isRecording = true
            callEnd = .ongoing
            recordedApp = key.flatMap { activations[$0]?.app }
            if let key { activations[key]?.phase = .recording }
            return []

        case .recordingStopped:
            isRecording = false
            recordedApp = nil
            callEnd = .ongoing
            for (key, activation) in activations where activation.phase == .recording {
                activations[key]?.phase = .quiet
            }
            return []
        }
    }

    private func prompt(_ key: String, _ activation: Activation) -> CallPrompt {
        CallPrompt(key: key, app: activation.app, kind: activation.kind ?? .app(activation.app.name),
                   replacesRecording: isRecording)
    }
}

/// Recognizes a web meeting from a browser window title, which is the title of the window's active tab.
public enum MeetingSites {
    public static func match(_ title: String?) -> String? {
        guard let title else { return nil }
        if title.hasPrefix("Meet - ") || title.hasPrefix("Meet – ") || title.contains("Google Meet") { return "Google Meet" }
        if title.contains("Zoom Meeting") || title.contains("Zoom Workplace") || title.hasSuffix("- Zoom") { return "Zoom" }
        if title.contains("Microsoft Teams") { return "Microsoft Teams" }
        if title.localizedCaseInsensitiveContains("webex") { return "Webex" }
        if title.contains("Slack") && title.localizedCaseInsensitiveContains("huddle") { return "Slack huddle" }
        return nil
    }
}
