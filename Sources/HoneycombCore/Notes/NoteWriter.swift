import Foundation

/// The `enhance` job: writes AI notes into a new version and makes it current. The pipeline owns
/// it, so notes are saved even when no window is open.
public struct NoteWriter: Sendable {
    let database: AppDatabase
    let chat: any ChatProvider
    let contextTokens: Int

    public init(database: AppDatabase, chat: any ChatProvider, contextTokens: Int = BuiltInProvider.contextTokens) {
        self.database = database
        self.chat = chat
        self.contextTokens = contextTokens
    }

    public func write(_ meetingID: UUID) async throws {
        guard let meeting = try database.meeting(meetingID) else { return }
        let input = NotesPrompt.Meeting(
            title: meeting.title, startedAt: meeting.startAt, durationMs: meeting.durationMs,
            appName: meeting.callAppId.flatMap { id in CallAppCatalog.builtIn.first { $0.bundleId == id }?.name },
            template: try database.template(meeting.templateId),
            userNotes: try database.userNote(meetingID)?.markdown ?? "",
            terms: try database.dictionaryTerms().map(\.term))
        let transcript = NotesPrompt.transcript(try database.transcript(meetingID))
        let messages = try await prompt(input, transcript: transcript, meeting: meetingID)

        var note = EnhancedNote(meetingId: meetingID, templateId: input.template.id, model: ModelCatalog.builtInLLM)
        var raw = ""
        // Nil until the first words arrive. The version is added then, so a model that isn't ready
        // yet leaves nothing behind.
        var lastWrite: ContinuousClock.Instant?
        let finish: FinishReason
        do {
            let request = ChatRequest(model: ModelCatalog.builtInLLM, messages: messages, maxTokens: NotesPrompt.outputTokens)
            finish = try await read(request, for: meetingID) { piece in
                raw += piece
                if let lastWrite, ContinuousClock.now - lastWrite < .seconds(1) { return }
                if lastWrite == nil { Log.info("notes.started", ["meeting": .id(meetingID)]) }
                note.markdown = NotesPrompt.parseOutput(raw, sections: input.template.sections).body
                try database.saveEnhanced(note)
                lastWrite = .now
            }
            let output = NotesPrompt.parseOutput(raw, sections: input.template.sections)
            if output.body.isEmpty { throw ChatError.truncated }
            // Notes open with a heading, so an answer cut off before its first one was still reasoning.
            if finish == .length, output.title == nil, !output.body.hasPrefix("#") { throw ChatError.truncated }
            let doc = Authorship.apply(to: Markdown.document(output.body), userNotes: input.userNotes)
            note.doc = doc.encoded()
            note.markdown = output.body
            note.status = .done
            note.errorCode = finish == .length ? ChatError.truncated.rawValue : nil
            try database.finishEnhanced(note, suggestedTitle: output.title)
        } catch {
            let cancelled = error is CancellationError || error as? ChatError == .cancelled
            if lastWrite != nil {
                note.markdown = NotesPrompt.parseOutput(raw, sections: input.template.sections).body
                note.status = cancelled ? .canceled : .failed
                note.errorCode = (error as? ChatError)?.rawValue ?? "failed"
                try? database.saveEnhanced(note)
            }
            throw error
        }
        Log.info("notes.finished", ["meeting": .id(meetingID), "truncated": .bool(finish == .length)])
    }

    /// Rounds of summarizing summaries before a meeting counts as too long for the model.
    static let summaryRounds = 4

    /// Long transcripts that don't fit the model are summarized in parts. The summaries are
    /// summarized again until they fit, because a small context can't hold one round of them.
    private func prompt(_ input: NotesPrompt.Meeting, transcript: String, meeting: UUID) async throws -> [ChatMessage] {
        let system = NotesPrompt.system(input)
        let budget = contextTokens - NotesPrompt.outputTokens
        let partBudget = max(1_000, budget - NotesPrompt.estimateTokens(NotesPrompt.partSystem) - 500)
        var text = transcript
        var rounds = 0
        while true {
            let user = NotesPrompt.user(input, transcript: text, isSummary: rounds > 0)
            if NotesPrompt.estimateTokens(system + user) <= budget { return [ChatMessage(.system, system), ChatMessage(.user, user)] }
            guard rounds < Self.summaryRounds else { throw ChatError.contextTooLong }
            var summaries: [String] = []
            for part in NotesPrompt.parts(text, maxTokens: partBudget) {
                try Task.checkCancellation()
                let request = ChatRequest(model: ModelCatalog.builtInLLM, messages: [
                    ChatMessage(.system, NotesPrompt.partSystem), ChatMessage(.user, part),
                ], maxTokens: NotesPrompt.outputTokens)
                var summary = ""
                let finish = try await read(request, for: meeting) { summary += $0 }
                summary = NotesPrompt.answer(summary)
                if finish == .length, summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ChatError.truncated }
                summaries.append(summary)
            }
            text = summaries.joined(separator: "\n")
            rounds += 1
        }
    }

    /// Reads one answer to its end. The meeting shows its notes being written once the model
    /// answers, which after a wait is the first sign the model is ready. An `AsyncThrowingStream`
    /// just ends when its task is cancelled, so an answer without `.finished` was cut off.
    private func read(_ request: ChatRequest, for meeting: UUID, onText: (String) throws -> Void) async throws -> FinishReason {
        var answered = false
        var finish: FinishReason?
        for try await delta in chat.stream(request) {
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
