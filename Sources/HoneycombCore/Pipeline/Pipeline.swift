import Foundation

/// Runs the work after a call as durable jobs in SQLite, so it survives crashes and restarts:
/// repair audio, final transcript, notes, search index, Markdown. Every job reads its inputs from
/// the database and replaces only its own outputs, so running one twice is safe.
public actor Pipeline {
    public struct Handlers: Sendable {
        public var enhance: (@Sendable (UUID) async throws -> Void)?
        public var index: (@Sendable (UUID) async throws -> Void)?
        public var sourceLink: (@Sendable (UUID) async throws -> Void)?
        public var mirrorMarkdown: (@Sendable (UUID) async throws -> Void)?

        public init() {}
    }

    public struct Policy: Sendable {
        /// How often a job waiting for a model to download or free up tries again.
        public var waitRetry: TimeInterval
        /// How long the loop sleeps when no job is due. A new job wakes it sooner.
        public var idlePoll: TimeInterval
        /// The delay before each retry of a failed job.
        public var retryDelays: [TimeInterval]
        public var maxAttempts: Int

        public init(waitRetry: TimeInterval = 30, idlePoll: TimeInterval = 5, retryDelays: [TimeInterval] = [10, 60, 300],
                    maxAttempts: Int = 3) {
            self.waitRetry = waitRetry
            self.idlePoll = idlePoll
            self.retryDelays = retryDelays
            self.maxAttempts = maxAttempts
        }
    }

    public static let minimumWords = 50

    private let database: AppDatabase
    private let paths: Paths
    private let host: ModelHost
    private let policy: Policy
    private var handlers = Handlers()
    private var loop: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var current: (job: Job, task: Task<Void, Error>, again: Bool)?

    public init(database: AppDatabase, paths: Paths, host: ModelHost, policy: Policy = Policy()) {
        self.database = database
        self.paths = paths
        self.host = host
        self.policy = policy
    }

    public func setHandlers(_ handlers: Handlers) {
        self.handlers = handlers
    }

    /// Launch recovery, then the job loop.
    public func start() {
        guard loop == nil else { return }
        recover()
        loop = Task { await self.run() }
    }

    /// Ends the loop. The job in progress stops and goes back in the queue at once, without using
    /// an attempt.
    public func stop() {
        loop?.cancel()
        loop = nil
        if let current {
            current.task.cancel()
            try? database.deferJob(current.job, until: Date())
        }
        nudge()
    }

    public func meetingStopped(_ meeting: UUID) {
        enqueue(.finalizeAudio, meeting: meeting)
    }

    public func enqueue(_ kind: JobKind, meeting: UUID) {
        if let job = current?.job, job.kind == kind, job.meetingId == meeting {
            // The running job may have read its inputs already, such as the template.
            current?.again = true
            return
        }
        if (try? database.hasOpenJob(kind, meeting: meeting)) == true { return }
        _ = try? database.enqueue(kind, meeting: meeting)
        nudge()
    }

    public func nudge() {
        wake?.resume()
        wake = nil
    }

    /// A new recording takes priority: model work in progress stops and goes back in the queue.
    public func recordingStarted() {
        guard let current, needsModel(current.job.kind) else { return }
        current.task.cancel()
    }

    private func needsModel(_ kind: JobKind) -> Bool {
        switch kind {
        case .finalizeAudio, .mirrorMarkdown: false
        case .transcribeFinal, .enhance, .index, .sourceLink: true
        }
    }

    private func recover() {
        do {
            try database.requeueRunningJobs(maxAttempts: policy.maxAttempts)
            try database.cancelGeneratingNotes()
            for meeting in try database.meetings(in: [.recording, .paused]) {
                try database.setState(meeting.id, .interrupted)
                if try !database.hasOpenJob(.finalizeAudio, meeting: meeting.id) {
                    try database.enqueue(.finalizeAudio, meeting: meeting.id)
                }
                Log.info("pipeline.recovered_meeting", ["meeting": .id(meeting.id)])
            }
            for meeting in try database.meetings(in: [.transcribing])
            where try !database.jobs(for: meeting.id).contains(where: { [.queued, .running].contains($0.status) }) {
                try database.enqueue(.finalizeAudio, meeting: meeting.id)
                Log.info("pipeline.recovered_meeting", ["meeting": .id(meeting.id)])
            }
        } catch {
            Log.error("pipeline.recovery_failed")
        }
    }

    private func run() async {
        while true {
            if Task.isCancelled { return }
            guard let (job, task) = claimNextJob() else {
                await sleep(for: .seconds(policy.idlePoll))
                continue
            }
            let result = await task.result
            let again = current?.again == true
            current = nil
            finish(job, result: result, preempted: task.isCancelled)
            if again, let meeting = job.meetingId { enqueue(job.kind, meeting: meeting) }
        }
    }

    /// Synchronous, so no suspension point can fall between reading the recording gate and making the
    /// job `current`: a recording that starts at any moment either keeps model jobs from being
    /// claimed or finds the job to cancel in `recordingStarted()`.
    private func claimNextJob() -> (Job, Task<Void, Error>)? {
        let modelJobs = Set(JobKind.allCases.filter(needsModel))
        guard let job = try? database.claimNextJob(skipping: host.gate.isRecording ? modelJobs : []) else { return nil }
        let task = Task { try await self.perform(job) }
        current = (job, task, false)
        return (job, task)
    }

    private func sleep(for duration: Duration) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            await self?.nudge()
        }
        await withCheckedContinuation { wake = $0 }
        timer.cancel()
    }

    private func finish(_ job: Job, result: Result<Void, Error>, preempted: Bool) {
        switch result {
        case .success:
            try? database.finishJob(job)
        case .failure(let error) where PipelineError.waitReason(for: error) != nil:
            let reason = PipelineError.waitReason(for: error)
            try? database.deferJob(job, until: Date().addingTimeInterval(policy.waitRetry))
            if let meeting = job.meetingId { try? database.setState(meeting, .waiting, detail: reason?.rawValue) }
        case .failure where preempted:
            try? database.deferJob(job, until: Date())
            if job.kind == .enhance, let meeting = job.meetingId {
                try? database.setState(meeting, .waiting, detail: WaitReason.modelBusy.rawValue)
            }
            Log.info("pipeline.job_preempted", ["job": .int(Int(job.id ?? 0))])
        case .failure(let error):
            let code = PipelineError.code(for: error)
            if job.attempt < policy.maxAttempts, PipelineError.isRetryable(error) {
                let delay = policy.retryDelays[min(job.attempt - 1, policy.retryDelays.count - 1)]
                try? database.retryJob(job, errorCode: code, at: Date().addingTimeInterval(delay))
            } else {
                try? database.failJob(job, errorCode: code)
                if let meeting = job.meetingId { try? database.setState(meeting, .failed, detail: code) }
            }
            Log.error("pipeline.job_failed", ["job": .int(Int(job.id ?? 0)), "attempt": .int(job.attempt)])
        }
    }

    private func perform(_ job: Job) async throws {
        guard let meeting = job.meetingId else { return }
        switch job.kind {
        case .finalizeAudio:
            try finalizeAudio(meeting)
            enqueue(.transcribeFinal, meeting: meeting)
        case .transcribeFinal:
            try await transcribeFinal(meeting)
        case .enhance:
            // A job polling for a model stays `waiting` until the writer gets an answer, so the
            // meeting doesn't flip to writing and back on every try.
            if try ![.modelMissing, .modelBusy].contains(database.meeting(meeting)?.waitReason) {
                try database.setState(meeting, .writingNotes)
            }
            guard let enhance = handlers.enhance else { return try database.setState(meeting, .ready) }
            try await enhance(meeting)
            try database.setState(meeting, .indexing)
            enqueue(.index, meeting: meeting)
            enqueue(.sourceLink, meeting: meeting)
            enqueue(.mirrorMarkdown, meeting: meeting)
        case .index:
            try await handlers.index?(meeting)
            try database.setState(meeting, .ready)
        case .sourceLink:
            try await handlers.sourceLink?(meeting)
        case .mirrorMarkdown:
            try await handlers.mirrorMarkdown?(meeting)
        }
    }

    /// Closes out the audio. After a crash, segments have no end, so their length comes from the
    /// frames that are really on disk.
    private func finalizeAudio(_ id: UUID) throws {
        let folder = paths.audioFolder(for: id)
        var meta = try SessionMeta.read(from: folder)
        if meta.status == nil {
            for channel in Channel.allCases {
                var track = meta[channel]
                for index in track.segments.indices where track.segments[index].endOffsetMs == nil {
                    let segment = track.segments[index]
                    let frames = AudioSegmentReader.recoveredFrames(file: folder.appendingPathComponent(segment.file),
                                                                    primingFrames: segment.primingFrames)
                    track.segments[index].frames = frames
                    track.segments[index].endOffsetMs = segment.startOffsetMs + frames * 1000 / 16_000
                }
                track.status = .incomplete
                meta[channel] = track
            }
            let end = meta.tracks.flatMap(\.segments).compactMap(\.endOffsetMs).max() ?? 0
            meta.durationMs = end
            meta.endedAt = meta.startedAt.addingTimeInterval(Double(end) / 1000)
            if let open = meta.pauses.last, open.endMs == nil { meta.pauses[meta.pauses.count - 1].endMs = end }
            try meta.write(to: folder)
        }
        var gaps = meta.pauses.map { Gap(meetingId: id, startMs: $0.startMs, endMs: $0.endMs ?? $0.startMs, reason: .paused) }
        for track in meta.tracks {
            for interruption in track.interruptions {
                let end = interruption.recoveredAtMs ?? meta.durationMs ?? interruption.startedAtMs
                gaps.append(Gap(meetingId: id, startMs: interruption.startedAtMs, endMs: end, reason: .captureLost))
            }
        }
        try database.replaceGaps(gaps, meeting: id)
        try database.recordingStopped(id, endAt: meta.endedAt, durationMs: meta.durationMs)
    }

    private func transcribeFinal(_ id: UUID) async throws {
        try database.setState(id, .transcribing)
        let folder = paths.audioFolder(for: id)
        let meta = try SessionMeta.read(from: folder)
        let models = try await host.acquireSpeech()
        let lines: [TranscriptLine]
        do {
            lines = try await FinalTranscriber(engine: models.engine, detector: models.detector)
                .transcribe(meta: meta, folder: folder)
        } catch {
            await host.releaseSpeech()
            throw error
        }
        let engine = models.engine.engineID
        await host.releaseSpeech()

        let terms = try database.dictionaryTerms().map(\.term)
        let corrected = lines.map { line in
            var line = line
            line.text = DictionaryCorrector.correct(line.text, terms: terms)
            return line
        }
        let duplicates = Dedupe.duplicateMeLines(corrected)
        try database.replaceTranscript(corrected, duplicates: duplicates, meeting: id, engine: engine)
        let words = corrected.enumerated().filter { !duplicates.contains($0.offset) }
            .reduce(0) { $0 + $1.element.text.split(separator: " ").count }
        Log.info("pipeline.transcribed", ["meeting": .id(id), "lines": .int(corrected.count), "words": .int(words)])
        if words < Self.minimumWords {
            try database.setState(id, .tooShort)
        } else {
            enqueue(.enhance, meeting: id)
        }
    }

    /// "Enhance anyway" on a meeting under 50 words.
    public func enhanceAnyway(_ meeting: UUID) {
        enqueue(.enhance, meeting: meeting)
    }

    public func retry(_ meeting: UUID) {
        let hasFinal = (try? database.transcript(meeting).contains { $0.pass == .final }) ?? false
        let next: JobKind = hasFinal ? .enhance : .finalizeAudio
        enqueue(next, meeting: meeting)
    }
}

enum PipelineError {
    static func code(for error: Error) -> String {
        switch error {
        case let error as ChatError: error.rawValue
        case SessionMeta.ReadError.unreadable: "audio_meta_unreadable"
        default: "job_failed"
        }
    }

    /// A model still downloading or busy: wait without using up an attempt.
    static func waitReason(for error: Error) -> WaitReason? {
        switch error {
        case ModelHostError.modelMissing: .modelMissing
        case ModelHostError.notAllowedNow: .modelBusy
        default: nil
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case SessionMeta.ReadError.unreadable, is ChatError: false
        default: true
        }
    }
}
