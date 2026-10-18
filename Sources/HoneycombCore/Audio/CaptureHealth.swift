/// Every timing value the capture health machine uses, so tests can use short ones.
public struct CapturePolicy: Sendable, Equatable {
    public var startupGraceMs: Int64 = 5000
    public var stallAfterMs: Int64 = 3000
    public var routeDebounceMs: Int64 = 750
    public var restartDelaysMs: [Int64] = [0, 500, 2000]
    public var stableWindowMs: Int64 = 5000
    public var tailToleranceMs: Int64 = 3000
    public var silenceWarningMs: Int64 = 15000
    public var lostRetryMs: Int64 = 10000

    public init() {}

    public static let standard = CapturePolicy()
}

public enum CaptureEvent: Sendable, Equatable {
    case started(atMs: Int64)
    case wrote(atMs: Int64, silent: Bool)
    case routeChanged(atMs: Int64)
    case writeFailed(atMs: Int64)
    case restartSucceeded(atMs: Int64)
    case restartFailed(atMs: Int64)
    case paused(atMs: Int64)
    case tick(atMs: Int64)
}

public enum CaptureCommand: Sendable, Equatable {
    /// Tear the recorder down and start a new segment.
    case restart(attempt: Int)
    case interruptionStarted(reason: InterruptionReason, atMs: Int64)
    case interruptionRecovered(resumedAtMs: Int64, attempts: Int)
    case captureLost(atMs: Int64)
    case silenceWarning(Bool)
}

public enum TrackHealth: Sendable, Equatable {
    case ok
    case recovering
    case lost
}

/// Decides when one track must restart. It does no I/O: the recorder reports events, and the
/// session carries out the returned commands. Times are milliseconds on the session clock.
public struct CaptureHealthMachine: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        case starting(sinceMs: Int64)
        case running
        case debouncingRoute(untilMs: Int64)
        case waitingToRestart(attempt: Int, atMs: Int64)
        case restarting(attempt: Int)
        case lost(retryAtMs: Int64)
        case paused
    }

    public let policy: CapturePolicy
    public private(set) var phase: Phase = .idle
    public private(set) var lastWriteMs: Int64?
    public private(set) var hadInterruption = false
    private var openInterruption: (reason: InterruptionReason, attempts: Int, resumedAtMs: Int64?)?
    private var silenceSinceMs: Int64?
    private var silenceWarned = false
    private var pausedAtMs: Int64?
    private var staleBeforeMs: Int64?
    private var lossReported = false

    public init(policy: CapturePolicy = .standard) {
        self.policy = policy
    }

    public var health: TrackHealth {
        if case .lost = phase { return .lost }
        return openInterruption == nil ? .ok : .recovering
    }

    public mutating func handle(_ event: CaptureEvent) -> [CaptureCommand] {
        switch event {
        case .started(let now):
            phase = .starting(sinceMs: now)
            staleBeforeMs = now
            pausedAtMs = nil
            silenceSinceMs = nil
            return []

        case .wrote(let now, let silent):
            if let staleBeforeMs, now <= staleBeforeMs { return [] }
            var commands = trackSilence(now: now, silent: silent)
            lastWriteMs = now
            switch phase {
            case .starting, .lost: phase = .running
            default: break
            }
            if phase == .running { lossReported = false }
            if openInterruption != nil, openInterruption?.resumedAtMs == nil, phase == .running {
                openInterruption?.resumedAtMs = now
            }
            commands += checkRecovered(now: now)
            return commands

        case .routeChanged(let now):
            switch phase {
            case .idle, .paused, .starting, .restarting, .waitingToRestart:
                return []
            case .running, .debouncingRoute:
                phase = .debouncingRoute(untilMs: now + policy.routeDebounceMs)
                return []
            case .lost:
                // A new route may work, so retry soon instead of waiting out the lost interval.
                phase = .lost(retryAtMs: now + policy.routeDebounceMs)
                return []
            }

        case .writeFailed(let now):
            switch phase {
            case .starting, .running, .debouncingRoute:
                return interrupt(.writeFailed, now: now)
            default:
                return []
            }

        case .restartSucceeded(let now):
            guard case .restarting = phase else { return [] }
            phase = .starting(sinceMs: now)
            staleBeforeMs = now
            openInterruption?.resumedAtMs = nil
            return []

        case .restartFailed(let now):
            guard case .restarting = phase else { return [] }
            staleBeforeMs = now
            return scheduleRestart(now: now)

        case .paused(let now):
            phase = .paused
            pausedAtMs = now
            silenceSinceMs = nil
            return []

        case .tick(let now):
            return tick(now: now)
        }
    }

    /// The track's status at stop: complete, recovered after an interruption, or incomplete.
    public func finalStatus(stoppedAtMs: Int64) -> TrackStatus {
        switch phase {
        case .lost, .restarting, .waitingToRestart:
            return .incomplete
        default:
            break
        }
        let end = pausedAtMs ?? stoppedAtMs
        guard let lastWriteMs, end - lastWriteMs <= policy.tailToleranceMs else { return .incomplete }
        return hadInterruption ? .recovered : .complete
    }

    private mutating func tick(now: Int64) -> [CaptureCommand] {
        switch phase {
        case .idle, .paused, .restarting:
            return []
        case .starting(let since):
            let deadline = max(since + policy.startupGraceMs, (lastWriteMs ?? since) + policy.stallAfterMs)
            return now >= deadline ? interrupt(.stalled, now: now) : []
        case .running:
            guard let lastWriteMs else { return [] }
            if now - lastWriteMs >= policy.stallAfterMs { return interrupt(.stalled, now: now) }
            return checkRecovered(now: now)
        case .debouncingRoute(let until):
            guard now >= until else { return [] }
            // AVAudioEngine posts a configuration change each time it starts on a chosen mic, and keeps
            // running. Samples captured before a real change can drain just after it, so only a write in
            // the second half of the window proves the recorder survived.
            if let lastWriteMs, lastWriteMs >= until - policy.routeDebounceMs / 2 {
                phase = .running
                return []
            }
            return interrupt(.routeChanged, now: now)
        case .waitingToRestart(let attempt, let at):
            guard now >= at else { return [] }
            phase = .restarting(attempt: attempt)
            openInterruption?.attempts = attempt
            return [.restart(attempt: attempt)]
        case .lost(let retryAt):
            guard now >= retryAt else { return [] }
            let attempt = (openInterruption?.attempts ?? 0) + 1
            phase = .restarting(attempt: attempt)
            openInterruption?.attempts = attempt
            return [.restart(attempt: attempt)]
        }
    }

    private mutating func interrupt(_ reason: InterruptionReason, now: Int64) -> [CaptureCommand] {
        var commands: [CaptureCommand] = []
        if openInterruption == nil {
            openInterruption = (reason, 0, nil)
            hadInterruption = true
            commands.append(.interruptionStarted(reason: reason, atMs: now))
        }
        return commands + scheduleRestart(now: now)
    }

    private mutating func scheduleRestart(now: Int64) -> [CaptureCommand] {
        let used = openInterruption?.attempts ?? 0
        if used < policy.restartDelaysMs.count {
            let attempt = used + 1
            phase = .waitingToRestart(attempt: attempt, atMs: now + policy.restartDelaysMs[used])
            return tick(now: now)
        }
        phase = .lost(retryAtMs: now + policy.lostRetryMs)
        openInterruption?.resumedAtMs = nil
        guard !lossReported else { return [] }
        lossReported = true
        return [.captureLost(atMs: now)]
    }

    private mutating func checkRecovered(now: Int64) -> [CaptureCommand] {
        guard phase == .running, let open = openInterruption, let resumed = open.resumedAtMs,
              now - resumed >= policy.stableWindowMs
        else { return [] }
        openInterruption = nil
        return [.interruptionRecovered(resumedAtMs: resumed, attempts: open.attempts)]
    }

    private mutating func trackSilence(now: Int64, silent: Bool) -> [CaptureCommand] {
        guard silent else {
            silenceSinceMs = nil
            if silenceWarned {
                silenceWarned = false
                return [.silenceWarning(false)]
            }
            return []
        }
        let since = silenceSinceMs ?? now
        silenceSinceMs = since
        if !silenceWarned, now - since >= policy.silenceWarningMs {
            silenceWarned = true
            return [.silenceWarning(true)]
        }
        return []
    }
}
