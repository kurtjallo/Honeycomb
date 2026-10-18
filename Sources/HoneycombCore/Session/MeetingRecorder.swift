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
    private var active: (meetingID: UUID, session: RecordingSession)?
    private var live: Task<Void, Never>?

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

    public var activeSession: RecordingSession? { active?.session }
    public var activeMeetingID: UUID? { active?.meetingID }

    /// Records into `existing` (a draft note made before the call) or a new meeting.
    /// `onLive` receives live transcript lines, on whatever task produces them.
    public func start(existing: UUID? = nil, title: String? = nil, callApp: CallApp? = nil, templateId: String? = nil,
                      onLive: (@Sendable (LiveUpdate) -> Void)? = nil) async throws -> (UUID, RecordingSession) {
        guard active == nil else { throw RecordingError.alreadyRecording }
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
        active = (meeting.id, session)
        startLiveTranscript(meeting: meeting.id, session: session, onLive: onLive)
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

    public func pause() async {
        guard let active else { return }
        await active.session.pause()
        try? database.setState(active.meetingID, .paused)
    }

    public func resume() async throws {
        guard let active else { return }
        try await active.session.resume()
        try? database.setState(active.meetingID, .recording)
    }

    /// Stops capture and hands the meeting to the pipeline as `transcribing`.
    @discardableResult
    public func stop() async -> UUID? {
        guard let active else { return nil }
        self.active = nil
        let meta = await active.session.stop()
        await live?.value
        live = nil
        if var meeting = try? database.meeting(active.meetingID) {
            meeting.state = .transcribing
            meeting.endAt = Date()
            meeting.durationMs = meta.durationMs
            try? database.save(meeting)
        }
        return active.meetingID
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
