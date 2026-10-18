import Foundation

/// Every timing the recording lifecycle uses.
public struct RecordingPolicy: Sendable, Equatable {
    /// After the call app lets go of the mic, the recording pauses, then stops this long after
    /// unless the user or the call resumes it.
    public var autoStopAfterMs: Int64 = 8_000

    public init() {}
}

/// What a click on Start records into.
public enum StartTarget: Sendable, Equatable {
    case newMeeting
    /// A draft note made before the call.
    case draft(UUID)
    /// A detected call, from its prompt.
    case call(CallPrompt)

    var callKey: String? {
        if case .call(let prompt) = self { prompt.key } else { nil }
    }
}

public struct ActiveRecording: Sendable, Equatable {
    public let meetingID: UUID
    /// The detected call it records, when it was started from a prompt.
    public let callKey: String?
}

public enum RecordingPhase: Sendable, Equatable {
    public enum AfterStop: Sendable, Equatable {
        case nothing
        case start(StartTarget)
        case quit
    }

    case idle
    /// `quitWhenOpen`: the user confirmed a quit while capture was starting.
    case starting(StartTarget, quitWhenOpen: Bool)
    case recording(ActiveRecording)
    /// Paused by the user. Only the user resumes it.
    case paused(ActiveRecording)
    /// The call ended: capture is paused and stops at `stopAtMs` unless resumed. `userPaused`: it
    /// was already paused by the user, so the call coming back doesn't resume it.
    case autoStopping(ActiveRecording, stopAtMs: Int64, userPaused: Bool)
    case stopping(ActiveRecording, then: AfterStop)
    /// The app is quitting. Nothing else happens.
    case quitting

    /// The recording that is capturing, paused, or counting down. Not one that is stopping.
    var capturing: ActiveRecording? {
        switch self {
        case .recording(let active), .paused(let active), .autoStopping(let active, _, _): active
        default: nil
        }
    }

    public var meetingID: UUID? {
        if case .stopping(let active, _) = self { return active.meetingID }
        return capturing?.meetingID
    }

    /// Local models are kept for the recording from the click on Start until the stop has finished.
    public var holdsModels: Bool {
        switch self {
        case .idle, .quitting: false
        case .starting, .recording, .paused, .autoStopping, .stopping: true
        }
    }

    public var isStarting: Bool {
        if case .starting = self { true } else { false }
    }

    public var isStopping: Bool {
        if case .stopping = self { true } else { false }
    }

    public var isPaused: Bool {
        switch self {
        case .paused, .autoStopping: true
        default: false
        }
    }
}

public enum RecordingEvent: Sendable, Equatable {
    // Clicks. Only `.start` leaves `.idle` toward capture.
    case start(StartTarget)
    case stop
    case pause
    case resume
    case quitConfirmed
    case quitCancelled
    // The system and call detection.
    case quitRequested
    case callEnded(atMs: Int64)
    case callResumed
    case tick(atMs: Int64)
    // Results of the commands.
    case captureOpened(meetingID: UUID)
    /// nil when the start was cancelled.
    case captureFailed(RecordingError?)
    case resumeFailed
    case stopFinished
}

public enum RecordingCommand: Sendable, Equatable {
    /// Take the models back from the pipeline, then open capture.
    case startCapture(StartTarget)
    case cancelStart
    /// Capture is open: show it and tell call detection.
    case began(ActiveRecording)
    case pauseCapture
    /// Resume capture, or send `.resumeFailed`.
    case resumeCapture
    /// Stop capture, hand the meeting to the pipeline, then send `.stopFinished`.
    case stopCapture
    /// Ask "Stop and save?", then send `.quitConfirmed` or `.quitCancelled`.
    case askToQuit
    /// Stop the pipeline, then let the app quit.
    case quit
    case cancelQuit
    case alert(RecordingError)
}

/// Start, pause, resume, the auto-stop after a call ends, stop, and quit, as one state machine.
/// Pure: the app feeds it clicks, detection events, ticks and command results, and runs the commands.
public struct RecordingLifecycle: Sendable {
    public let policy: RecordingPolicy
    public private(set) var phase = RecordingPhase.idle

    public init(policy: RecordingPolicy = RecordingPolicy()) {
        self.policy = policy
    }

    /// Seconds left before the auto-stop, for "Call ended. Writing notes in N s."
    public func secondsUntilAutoStop(atMs now: Int64) -> Int? {
        guard case .autoStopping(_, let stopAt, _) = phase else { return nil }
        return Int(max(0, stopAt - now + 999) / 1000)
    }

    public mutating func handle(_ event: RecordingEvent) -> [RecordingCommand] {
        if case .quitting = phase { return [] }
        switch event {
        case .start(let target):
            if case .idle = phase {
                phase = .starting(target, quitWhenOpen: false)
                return [.startCapture(target)]
            }
            guard let active = phase.capturing, case .call(let prompt) = target, prompt.replacesRecording else { return [] }
            phase = .stopping(active, then: .start(target))
            return [.stopCapture]

        case .stop:
            guard let active = phase.capturing else { return [] }
            phase = .stopping(active, then: .nothing)
            return [.stopCapture]

        case .pause:
            guard case .recording(let active) = phase else { return [] }
            phase = .paused(active)
            return [.pauseCapture]

        case .resume:
            guard phase.isPaused, let active = phase.capturing else { return [] }
            phase = .recording(active)
            return [.resumeCapture]

        case .callEnded(let at):
            let stopAt = at + policy.autoStopAfterMs
            switch phase {
            case .recording(let active):
                phase = .autoStopping(active, stopAtMs: stopAt, userPaused: false)
                return [.pauseCapture]
            case .paused(let active):
                phase = .autoStopping(active, stopAtMs: stopAt, userPaused: true)
                return []
            default:
                return []
            }

        case .callResumed:
            guard case .autoStopping(let active, _, let userPaused) = phase else { return [] }
            if userPaused {
                phase = .paused(active)
                return []
            }
            phase = .recording(active)
            return [.resumeCapture]

        case .tick(let now):
            guard case .autoStopping(let active, let stopAt, _) = phase, now >= stopAt else { return [] }
            phase = .stopping(active, then: .nothing)
            return [.stopCapture]

        case .captureOpened(let meetingID):
            guard case .starting(let target, let quitWhenOpen) = phase else { return [] }
            let active = ActiveRecording(meetingID: meetingID, callKey: target.callKey)
            if quitWhenOpen {
                phase = .stopping(active, then: .quit)
                return [.stopCapture]
            }
            phase = .recording(active)
            return [.began(active)]

        case .captureFailed(let error):
            guard case .starting(_, let quitWhenOpen) = phase else { return [] }
            phase = quitWhenOpen ? .quitting : .idle
            return (error.map { [.alert($0)] } ?? []) + (quitWhenOpen ? [.quit] : [])

        case .resumeFailed:
            guard case .recording(let active) = phase else { return [] }
            phase = .paused(active)
            return [.alert(.captureFailed)]

        case .stopFinished:
            guard case .stopping(_, let then) = phase else { return [] }
            switch then {
            case .nothing:
                phase = .idle
                return []
            case .start(let target):
                phase = .starting(target, quitWhenOpen: false)
                return [.startCapture(target)]
            case .quit:
                phase = .quitting
                return [.quit]
            }

        case .quitRequested:
            switch phase {
            case .idle:
                phase = .quitting
                return [.quit]
            case .stopping(let active, _):
                phase = .stopping(active, then: .quit)
                return []
            default:
                return [.askToQuit]
            }

        case .quitConfirmed:
            switch phase {
            case .idle:
                phase = .quitting
                return [.quit]
            case .starting(let target, _):
                phase = .starting(target, quitWhenOpen: true)
                return [.cancelStart]
            case .stopping(let active, _):
                phase = .stopping(active, then: .quit)
                return []
            default:
                guard let active = phase.capturing else { return [] }
                phase = .stopping(active, then: .quit)
                return [.stopCapture]
            }

        case .quitCancelled:
            return [.cancelQuit]
        }
    }
}
