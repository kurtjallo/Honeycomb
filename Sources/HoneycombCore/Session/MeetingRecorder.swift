@preconcurrency import AVFoundation
import Foundation

public enum RecordingError: Error, Equatable, Sendable {
    case alreadyRecording
    case lowDisk(availableBytes: Int64)
    case micDenied
    case captureFailed
}

/// Starts and stops recordings and keeps the meeting row in step. Capture needs no model,
/// so a recording starts at once, even while notes for an earlier meeting are being written.
public actor MeetingRecorder {
    public static let minimumFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

    private let database: AppDatabase
    private let paths: Paths
    private let makeRecorders: @Sendable () -> [any TrackRecorder]
    private let freeBytes: @Sendable () -> Int64
    private let micAccess: @Sendable () async -> Bool
    private let host: ModelHost?
    private var phase = Phase.idle
    private var live: Task<Void, Never>?
    /// The meeting whose live transcriber holds the speech models. A stop waits only for that one,
    /// never for a model that is still loading.
    private var liveMeeting: UUID?

    private enum Phase {
        case idle
        case starting
        case recording(meetingID: UUID, session: RecordingSession)
        case stopping(Task<UUID, Never>)
    }

    public init(database: AppDatabase, paths: Paths,
                makeRecorders: @escaping @Sendable () -> [any TrackRecorder],
                freeBytes: @escaping @Sendable () -> Int64 = { DiskSpace.available(at: Paths.standard.root) },
                micAccess: @escaping @Sendable () async -> Bool = { await Permissions.requestMicrophone() },
                host: ModelHost? = nil) {
        self.database = database
        self.host = host
        self.paths = paths
        self.makeRecorders = makeRecorders
        self.freeBytes = freeBytes
        self.micAccess = micAccess
    }

    /// Records into `existing` (a draft note made before the call) or a new meeting.
    /// `onLive` receives live transcript lines, on whatever task produces them.
    public func start(existing: UUID? = nil, title: String? = nil, callApp: CallApp? = nil, templateId: String? = nil,
                      onLive: (@Sendable (LiveUpdate) -> Void)? = nil) async throws -> (UUID, RecordingSession) {
        guard case .idle = phase else { throw RecordingError.alreadyRecording }
        phase = .starting
        do {
            let (id, session) = try await open(existing: existing, title: title, callApp: callApp, templateId: templateId)
            phase = .recording(meetingID: id, session: session)
            startLiveTranscript(meeting: id, session: session, onLive: onLive)
            return (id, session)
        } catch {
            phase = .idle
            throw error
        }
    }

    private func open(existing: UUID?, title: String?, callApp: CallApp?, templateId: String?) async throws -> (UUID, RecordingSession) {
        let free = freeBytes()
        guard free >= Self.minimumFreeBytes else { throw RecordingError.lowDisk(availableBytes: free) }
        guard await micAccess() else { throw RecordingError.micDenied }

        let now = Date()
        var meeting: Meeting
        if let existing, let draft = try database.meeting(existing) {
            meeting = draft
        } else {
            meeting = Meeting(title: title ?? Meeting.defaultTitle(appName: callApp?.name, at: now),
                              callAppId: callApp?.bundleId, state: .recording, templateId: templateId, now: now)
            try database.insert(meeting)
        }
        let folder = paths.audioFolder(for: meeting.id)
        meeting.state = .recording
        meeting.startAt = meeting.startAt ?? now
        meeting.audioDir = folder.lastPathComponent
        if meeting.callAppId == nil { meeting.callAppId = callApp?.bundleId }
        try database.save(meeting)

        let session = RecordingSession(meetingID: meeting.id, folder: folder, recorders: makeRecorders(), startedAt: now)
        do {
            try await session.start()
        } catch {
            try? database.setState(meeting.id, .failed, detail: "capture_failed")
            throw RecordingError.captureFailed
        }
        return (meeting.id, session)
    }

    /// Live lines come from the same speech models as the final pass. Capture never waits for them:
    /// if they're missing or still loading, the call is recorded and transcribed afterwards.
    private func startLiveTranscript(meeting: UUID, session: RecordingSession, onLive: (@Sendable (LiveUpdate) -> Void)?) {
        guard let host else { return }
        let database = self.database
        live = Task.detached(priority: .userInitiated) {
            guard let models = try? await host.acquireSpeech() else {
                Log.info("live.unavailable", ["meeting": .id(meeting)])
                return
            }
            guard await self.liveReady(meeting) else {
                await host.releaseSpeech()
                return
            }
            let transcriber = LiveTranscriber(engine: models.engine, detector: models.detector)
            let engineID = models.engine.engineID
            let writer = Task {
                var batch: [TranscriptLine] = []
                var lastWrite = ContinuousClock.now
                for await update in transcriber.updates {
                    onLive?(update)
                    if case .final(let line) = update { batch.append(line) }
                    if ContinuousClock.now - lastWrite >= .seconds(1), !batch.isEmpty {
                        try? database.appendLiveLines(batch, meeting: meeting, engine: engineID)
                        batch = []
                        lastWrite = ContinuousClock.now
                    }
                }
                try? database.appendLiveLines(batch, meeting: meeting, engine: engineID)
            }
            await transcriber.run(session.audio)
            await writer.value
            await host.releaseSpeech()
        }
    }

    /// False once the recording has stopped, so a model that finished loading late writes nothing.
    private func liveReady(_ meeting: UUID) -> Bool {
        guard case .recording(let id, _) = phase, id == meeting else { return false }
        liveMeeting = meeting
        return true
    }

    public func pause() async {
        guard case .recording(let id, let session) = phase else { return }
        await session.pause()
        try? database.setState(id, .paused)
    }

    public func resume() async throws {
        guard case .recording(let id, let session) = phase else { return }
        try await session.resume()
        try? database.setState(id, .recording)
    }

    /// Stops capture and hands the meeting to the pipeline as `transcribing`. A stop called while
    /// another runs waits for it and returns the same meeting.
    @discardableResult
    public func stop() async -> UUID? {
        switch phase {
        case .idle, .starting:
            return nil
        case .stopping(let task):
            return await task.value
        case .recording(let id, let session):
            let task = Task { await finishStop(id, session) }
            phase = .stopping(task)
            return await task.value
        }
    }

    private func finishStop(_ id: UUID, _ session: RecordingSession) async -> UUID {
        let live = self.live
        self.live = nil
        let meta = await session.stop()
        if liveMeeting == id { await live?.value }
        liveMeeting = nil
        if var meeting = try? database.meeting(id) {
            meeting.state = .transcribing
            meeting.endAt = Date()
            meeting.durationMs = meta.durationMs
            try? database.save(meeting)
        }
        phase = .idle
        return id
    }
}

public enum DiskSpace {
    public static func available(at url: URL) -> Int64 {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : FileManager.default.homeDirectoryForCurrentUser
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}

public enum Permissions {
    public static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    public static func requestMicrophone() async -> Bool {
        switch microphone {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
