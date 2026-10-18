import Foundation

public struct ResolvedProvider: Sendable {
    public let record: ProviderRecord
    public let model: String
    public let provider: any ChatProvider

    public init(record: ProviderRecord, model: String, provider: any ChatProvider) {
        self.record = record
        self.model = model
        self.provider = provider
    }
}

/// The `enhance` job: writes AI notes into a new version and makes it current. The pipeline owns
/// it, so notes are saved even when no window is open.
public struct NoteWriter: Sendable {
    let database: AppDatabase
    let resolve: @Sendable (AITask) async throws -> ResolvedProvider

    public init(database: AppDatabase, resolve: @escaping @Sendable (AITask) async throws -> ResolvedProvider) {
        self.database = database
        self.resolve = resolve
    }

    public enum Outcome: Equatable, Sendable {
        case written(UUID)
        /// The notes need the user first: an AI choice, or consent to send the meeting to a cloud provider.
        case waiting(WaitReason)
    }

    public func write(_ meetingID: UUID) async throws -> Outcome {
        guard let meeting = try database.meeting(meetingID) else { return .written(meetingID) }
        let resolved: ResolvedProvider
        do {
            resolved = try await resolve(.enhance)
        } catch RouteError.notChosen {
            return .waiting(.aiNotChosen)
        }
        if !resolved.record.isLocal, try !database.hasCloudConsent(resolved.record.id) {
            return .waiting(.cloudConsent)
        }
        let input = NotesPrompt.Meeting(
            title: meeting.title, startedAt: meeting.startAt, durationMs: meeting.durationMs,
            appName: meeting.callAppId.flatMap { id in CallAppCatalog.builtIn.first { $0.bundleId == id }?.name },
            template: try database.template(meeting.templateId),
            userNotes: try database.userNote(meetingID)?.markdown ?? "",
            terms: try database.dictionaryTerms().map(\.term))
        let transcript = NotesPrompt.transcript(try database.transcript(meetingID))
        let messages = try await prompt(input, transcript: transcript, resolved: resolved, meeting: meetingID)

        var note = EnhancedNote(meetingId: meetingID, templateId: input.template.id,
                                providerId: resolved.record.id, model: resolved.model)
        var raw = ""
        // Nil until the first words arrive. The version is added then, so a model that isn't ready
        // yet leaves nothing behind.
        var lastWrite: ContinuousClock.Instant?
        let finish: FinishReason
        do {
            let request = ChatRequest(model: resolved.model, messages: messages, maxTokens: NotesPrompt.outputTokens)
            finish = try await read(request, from: resolved.provider, for: meetingID) { piece in
                raw += piece
                if let lastWrite, ContinuousClock.now - lastWrite < .seconds(1) { return }
                if lastWrite == nil { Log.info("notes.started", ["meeting": .id(meetingID)]) }
                note.markdown = NotesPrompt.parseOutput(raw, sections: input.template.sections).body
                try database.saveEnhanced(note)
                lastWrite = .now
            }
        } catch {
            let cancelled = error is CancellationError || error as? ProviderError == .cancelled
            if lastWrite != nil {
                note.status = cancelled ? .canceled : .failed
                note.errorCode = (error as? ProviderError)?.code ?? "failed"
                try? database.saveEnhanced(note)
            }
            throw cancelled ? CancellationError() : error
        }

        let output = NotesPrompt.parseOutput(raw, sections: input.template.sections)
        let doc = Authorship.apply(to: Markdown.document(output.body), userNotes: input.userNotes)
        note.doc = doc.encoded()
        note.markdown = output.body
        note.status = .done
        note.errorCode = finish == .length ? ProviderError.truncated.code : nil
        try database.finishEnhanced(note, suggestedTitle: output.title)
        Log.info("notes.finished", ["meeting": .id(meetingID), "truncated": .bool(finish == .length)])
        return .written(note.id)
    }

    /// Rounds of summarizing summaries before a meeting counts as too long for the model.
    static let summaryRounds = 4

    /// Long transcripts that don't fit the model are summarized in parts. The summaries are
    /// summarized again until they fit, because a small context can't hold one round of them.
    private func prompt(_ input: NotesPrompt.Meeting, transcript: String, resolved: ResolvedProvider,
                        meeting: UUID) async throws -> [ChatMessage] {
        let system = NotesPrompt.system(input)
        let budget = resolved.record.contextTokens - NotesPrompt.outputTokens
        let partBudget = max(1_000, budget - NotesPrompt.estimateTokens(NotesPrompt.partSystem) - 500)
        var text = transcript
        var rounds = 0
        while true {
            let user = NotesPrompt.user(input, transcript: text, isSummary: rounds > 0)
            if NotesPrompt.estimateTokens(system + user) <= budget { return [ChatMessage(.system, system), ChatMessage(.user, user)] }
            guard rounds < Self.summaryRounds else { throw ProviderError.contextTooLong }
            var summaries: [String] = []
            for part in NotesPrompt.parts(text, maxTokens: partBudget) {
                try Task.checkCancellation()
                let request = ChatRequest(model: resolved.model, messages: [
                    ChatMessage(.system, NotesPrompt.partSystem), ChatMessage(.user, part),
                ], maxTokens: NotesPrompt.outputTokens)
                var summary = ""
                // A summary cut off at its length limit still covers most of its part.
                _ = try await read(request, from: resolved.provider, for: meeting) { summary += $0 }
                summaries.append(NotesPrompt.answer(summary))
            }
            text = summaries.joined(separator: "\n")
            rounds += 1
        }
    }

    /// Reads one answer to its end. The meeting shows its notes being written once the model
    /// answers, which after a wait is the first sign the model is ready. An `AsyncThrowingStream`
    /// just ends when its task is cancelled, so an answer without `.finished` was cut off.
    private func read(_ request: ChatRequest, from provider: any ChatProvider, for meeting: UUID,
                      onText: (String) throws -> Void) async throws -> FinishReason {
        var answered = false
        var finish: FinishReason?
        for try await delta in provider.stream(request) {
            if !answered {
                answered = true
                try database.setState(meeting, .writingNotes)
            }
            switch delta {
            case .text(let piece): try onText(piece)
            case .finished(let reason): finish = reason
            }
        }
        guard let finish, !Task.isCancelled else { throw CancellationError() }
        return finish
    }
}
