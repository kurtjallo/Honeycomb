import Foundation

/// What the recording pill shows, published about 4 times a second.
public struct RecordingStatus: Sendable, Equatable {
    public struct Track: Sendable, Equatable {
        public var health: TrackHealth = .ok
        public var level: Float = 0
        public var silent = false

        public init() {}
    }

    public var elapsedMs: Int64 = 0
    public var isPaused = false
    public var tracks: [Channel: Track] = [.me: Track(), .them: Track()]

    public init() {}

    /// The pill turns red when any track is restarting or lost.
    public var isHealthy: Bool { tracks.values.allSatisfy { $0.health == .ok } }
}

/// One recording: two tracks, their health machines, and `meta.json`. Capture needs no model,
/// so it starts at once. Live transcription reads `audio`.
public actor RecordingSession {
    public enum State: Sendable {
        case idle
        case recording
        case paused
        case stopped
    }

    public nonisolated let meetingID: UUID
    public nonisolated let folder: URL
    public nonisolated let status: AsyncStream<RecordingStatus>
    public nonisolated let audio: AsyncStream<AudioChunk>

    private let statusContinuation: AsyncStream<RecordingStatus>.Continuation
    private let audioContinuation: AsyncStream<AudioChunk>.Continuation
    private let clock = SessionClock()
    private let recorders: [any TrackRecorder]
    private let policy: CapturePolicy
    private let tickInterval: Duration
    private var meta: SessionMeta
    private var pipelines: [Channel: TrackPipeline] = [:]
    private var machines: [Channel: CaptureHealthMachine] = [:]
    private var snapshot = RecordingStatus()
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var events: AsyncStream<(Channel, TrackPipeline.Event)>.Continuation?
    public private(set) var state = State.idle

    public init(meetingID: UUID, folder: URL, recorders: [any TrackRecorder], policy: CapturePolicy = .standard,
                tickInterval: Duration = .milliseconds(250), startedAt: Date = Date()) {
        self.meetingID = meetingID
        self.folder = folder
        self.recorders = recorders
        self.policy = policy
        self.tickInterval = tickInterval
        meta = SessionMeta(meetingID: meetingID, startedAt: startedAt)
        (status, statusContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (audio, audioContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(2_000))
    }

    public func start() throws {
        guard state == .idle else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try meta.write(to: folder)

        let (stream, continuation) = AsyncStream.makeStream(of: (Channel, TrackPipeline.Event).self)
        events = continuation
        for recorder in recorders {
            let channel = recorder.channel
            pipelines[channel] = TrackPipeline(recorder: recorder, folder: folder, clock: clock, existingSegments: 0) {
                continuation.yield((channel, $0))
            }
            machines[channel] = CaptureHealthMachine(policy: policy)
        }
        do {
            for (channel, pipeline) in pipelines {
                try pipeline.begin()
                apply(machines[channel]!.handle(.started(atMs: clock.nowMs())), to: channel)
            }
        } catch {
            for pipeline in pipelines.values { pipeline.end() }
            continuation.finish()
            state = .stopped
            throw error
        }
        state = .recording
        Log.info("recording.started", ["meeting": .id(meetingID)])

        eventTask = Task { [weak self] in
            for await (channel, event) in stream { await self?.handle(event, from: channel) }
        }
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.tick()
            }
        }
    }

    public func pause() {
        guard state == .recording else { return }
        let now = clock.nowMs()
        for (channel, pipeline) in pipelines {
            closed(pipeline.end(), on: channel)
            _ = machines[channel]?.handle(.paused(atMs: now))
        }
        meta.pauses.append(TimeSpan(startMs: now))
        state = .paused
        writeMeta()
        Log.info("recording.paused", ["meeting": .id(meetingID)])
    }

    public func resume() throws {
        guard state == .paused else { return }
        let now = clock.nowMs()
        if !meta.pauses.isEmpty { meta.pauses[meta.pauses.count - 1].endMs = now }
        for (channel, pipeline) in pipelines {
            try pipeline.begin()
            apply(machines[channel]!.handle(.started(atMs: now)), to: channel)
        }
        state = .recording
        writeMeta()
        Log.info("recording.resumed", ["meeting": .id(meetingID)])
    }

    /// Stops both tracks, waits for every pending event, and writes the final `meta.json`.
    @discardableResult
    public func stop() async -> SessionMeta {
        guard state == .recording || state == .paused else { return meta }
        tickTask?.cancel()
        let now = clock.nowMs()
        for (channel, pipeline) in pipelines {
            closed(pipeline.end(), on: channel)
        }
        events?.finish()
        await eventTask?.value
        if let open = meta.pauses.last, open.endMs == nil { meta.pauses[meta.pauses.count - 1].endMs = now }
        for (channel, machine) in machines {
            meta[channel].status = machine.finalStatus(stoppedAtMs: now)
        }
        meta.endedAt = Date()
        meta.durationMs = now
        state = .stopped
        writeMeta()
        statusContinuation.finish()
        audioContinuation.finish()
        Log.info("recording.stopped", ["meeting": .id(meetingID), "duration_ms": .int(now)])
        return meta
    }

    public var currentMeta: SessionMeta { meta }

    private func handle(_ event: TrackPipeline.Event, from channel: Channel) {
        switch event {
        case .wrote(let at, let silent, let level):
            snapshot.tracks[channel]?.level = level
            apply(machines[channel]?.handle(.wrote(atMs: at, silent: silent)) ?? [], to: channel)
        case .segmentOpened(let segment):
            if !meta[channel].segments.contains(where: { $0.file == segment.file }) {
                meta[channel].segments.append(segment)
                writeMeta()
            }
        case .routeChanged(let at):
            apply(machines[channel]?.handle(.routeChanged(atMs: at)) ?? [], to: channel)
        case .writeFailed(let at):
            apply(machines[channel]?.handle(.writeFailed(atMs: at)) ?? [], to: channel)
        case .audio(let chunk):
            audioContinuation.yield(chunk)
        }
    }

    private func tick() {
        guard state == .recording || state == .paused else { return }
        let now = clock.nowMs()
        for channel in machines.keys {
            apply(machines[channel]!.handle(.tick(atMs: now)), to: channel)
        }
        let paused = meta.pauses.reduce(Int64(0)) { $0 + (($1.endMs ?? now) - $1.startMs) }
        snapshot.elapsedMs = now - paused
        snapshot.isPaused = state == .paused
        for (channel, machine) in machines { snapshot.tracks[channel]?.health = machine.health }
        statusContinuation.yield(snapshot)
    }

    private func apply(_ commands: [CaptureCommand], to channel: Channel) {
        for command in commands {
            switch command {
            case .restart(let attempt):
                restart(channel, attempt: attempt)
            case .interruptionStarted(let reason, let at):
                meta[channel].interruptions.append(InterruptionMeta(startedAtMs: at, reason: reason))
                writeMeta()
                Log.error("capture.interrupted", ["meeting": .id(meetingID), "channel": channel.logCode,
                                                  "reason": reason.logCode])
            case .interruptionRecovered(let resumed, let attempts):
                if var last = meta[channel].interruptions.last {
                    last.recoveredAtMs = resumed
                    last.attempts = attempts
                    meta[channel].interruptions[meta[channel].interruptions.count - 1] = last
                }
                writeMeta()
                Log.info("capture.recovered", ["meeting": .id(meetingID), "channel": channel.logCode,
                                               "attempts": .int(attempts)])
            case .captureLost:
                Log.error("capture.lost", ["meeting": .id(meetingID), "channel": channel.logCode])
            case .silenceWarning(let on):
                snapshot.tracks[channel]?.silent = on
            }
        }
    }

    private func restart(_ channel: Channel, attempt: Int) {
        guard let pipeline = pipelines[channel] else { return }
        closed(pipeline.end(), on: channel)
        if var last = meta[channel].interruptions.last {
            last.attempts = attempt
            meta[channel].interruptions[meta[channel].interruptions.count - 1] = last
        }
        let result: [CaptureCommand]
        do {
            try pipeline.begin()
            result = machines[channel]!.handle(.restartSucceeded(atMs: clock.nowMs()))
        } catch {
            Log.error("capture.restart_failed", ["channel": channel.logCode, "attempt": .int(attempt)])
            result = machines[channel]!.handle(.restartFailed(atMs: clock.nowMs()))
        }
        apply(result, to: channel)
    }

    private func closed(_ segment: SegmentMeta?, on channel: Channel) {
        guard let segment else { return }
        if let index = meta[channel].segments.firstIndex(where: { $0.file == segment.file }) {
            meta[channel].segments[index] = segment
        } else {
            meta[channel].segments.append(segment)
        }
        writeMeta()
    }

    private func writeMeta() {
        do {
            try meta.write(to: folder)
        } catch {
            Log.error("meta.write_failed", ["meeting": .id(meetingID)])
        }
    }
}

extension Channel {
    var logCode: LogValue { self == .me ? .code("me") : .code("them") }
}

extension InterruptionReason {
    var logCode: LogValue {
        switch self {
        case .stalled: .code("stalled")
        case .routeChanged: .code("route_changed")
        case .writeFailed: .code("write_failed")
        }
    }
}
