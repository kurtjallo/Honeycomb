import Foundation

public struct RecordingPolicy: Sendable, Equatable {
    /// After the call app lets go of the mic, the recording pauses, then stops this long after
    /// unless the user or the call resumes it.
    public var autoStopAfterMs: Int64 = 8_000
    /// Once the user commits to quitting, the app exits this long after, even if a start, a stop,
    /// or saving the notes hangs.
    public var quitDeadlineMs: Int64 = 4_000

    public init() {}
}

public enum StartTarget: Sendable, Equatable {
    case newMeeting
    case draft(UUID)
    case call(CallPrompt)

    var callKey: String? {
        if case .call(let prompt) = self { prompt.key } else { nil }
    }
}

public struct ActiveRecording: Sendable, Equatable {
    public let meetingID: UUID
    public let callKey: String?
}

public enum RecordingPhase: Sendable, Equatable {
    public enum AfterStop: Sendable, Equatable {
        case nothing
        case start(StartTarget)
        case quit(byMs: Int64)
    }

    case idle
    case starting(StartTarget, quitByMs: Int64?)
    case recording(ActiveRecording)
    case paused(ActiveRecording)
    case autoStopping(ActiveRecording, stopAtMs: Int64, userPaused: Bool)
    case stopping(ActiveRecording, then: AfterStop)
    case quitting(byMs: Int64)

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

    /// `.quitting` holds them so that clearing the gate on the way out never wakes the pipeline
    /// into a model load the exit can't interrupt.
    var quitByMs: Int64? {
        switch self {
        case .starting(_, let by): by
        case .stopping(_, .quit(let by)), .quitting(let by): by
        default: nil
        }
    }

    public var holdsModels: Bool {
        switch self {
        case .idle: false
        case .starting, .recording, .paused, .autoStopping, .stopping, .quitting: true
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
    case start(StartTarget)
    case stop
    case pause
    case resume
    case quitConfirmed(atMs: Int64)
    case quitCancelled
    case quitRequested(atMs: Int64)
    case callEnded(atMs: Int64)
    case callResumed
    case tick(atMs: Int64)
    case captureOpened(meetingID: UUID)
    case captureFailed(RecordingError?)
    case resumeFailed
    case stopFinished
}

public enum RecordingCommand: Sendable, Equatable {
    case startCapture(StartTarget)
    case cancelStart
    case began(ActiveRecording)
    case pauseCapture
    case resumeCapture
    case stopCapture
    case askToQuit
    case quit
    /// The quit deadline passed: exit now, whatever still hangs.
    case quitNow
    case cancelQuit
    case alert(RecordingError)
}

public struct RecordingLifecycle: Sendable {
    public let policy: RecordingPolicy
    public private(set) var phase = RecordingPhase.idle

    public init(policy: RecordingPolicy = RecordingPolicy()) {
        self.policy = policy
    }

    public func secondsUntilAutoStop(atMs now: Int64) -> Int? {
        guard case .autoStopping(_, let stopAt, _) = phase else { return nil }
        return Int(max(0, stopAt - now + 999) / 1000)
    }

    public mutating func handle(_ event: RecordingEvent) -> [RecordingCommand] {
        if let by = phase.quitByMs, case .tick(let now) = event, now >= by {
            phase = .quitting(byMs: by)
            return [.quitNow]
        }
        if case .quitting = phase { return [] }
        switch event {
        case .start(let target):
            if case .idle = phase {
                phase = .starting(target, quitByMs: nil)
                return [.startCapture(target)]
            }
            guard case .call(let prompt) = target else { return [] }
            if case .stopping(let active, .nothing) = phase {
                phase = .stopping(active, then: .start(target))
                return []
            }
            guard let active = phase.capturing, prompt.replacesRecording else { return [] }
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
            guard case .starting(let target, let quitBy) = phase else { return [] }
            let active = ActiveRecording(meetingID: meetingID, callKey: target.callKey)
            if let quitBy {
                phase = .stopping(active, then: .quit(byMs: quitBy))
                return [.stopCapture]
            }
            phase = .recording(active)
            return [.began(active)]

        case .captureFailed(let error):
            guard case .starting(_, let quitBy) = phase else { return [] }
            phase = quitBy.map { .quitting(byMs: $0) } ?? .idle
            return (error.map { [.alert($0)] } ?? []) + (quitBy != nil ? [.quit] : [])

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
                phase = .starting(target, quitByMs: nil)
                return [.startCapture(target)]
            case .quit(let by):
                phase = .quitting(byMs: by)
                return [.quit]
            }

        case .quitRequested(let now):
            guard phase.quitByMs == nil else { return [] }
            let by = now + policy.quitDeadlineMs
            switch phase {
            case .idle:
                phase = .quitting(byMs: by)
                return [.quit]
            case .stopping(let active, _):
                phase = .stopping(active, then: .quit(byMs: by))
                return []
            default:
                return [.askToQuit]
            }

        case .quitConfirmed(let now):
            guard phase.quitByMs == nil else { return [] }
            let by = now + policy.quitDeadlineMs
            switch phase {
            case .idle:
                phase = .quitting(byMs: by)
                return [.quit]
            case .starting(let target, _):
                phase = .starting(target, quitByMs: by)
                return [.cancelStart]
            case .stopping(let active, _):
                phase = .stopping(active, then: .quit(byMs: by))
                return []
            default:
                guard let active = phase.capturing else { return [] }
                phase = .stopping(active, then: .quit(byMs: by))
                return [.stopCapture]
            }

        case .quitCancelled:
            return [.cancelQuit]
        }
    }
}
