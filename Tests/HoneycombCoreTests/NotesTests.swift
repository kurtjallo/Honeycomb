import Foundation
import Testing
@testable import HoneycombCore

struct MarkdownTests {

    func ids() -> () -> String {
        nonisolated(unsafe) var next = 0
        return {
            next += 1
            return "b\(next)"
        }
    }

    @Test func roundTripsNotes() {
        let markdown = """
        ## Summary

        Acme will renew if **SSO** ships by *end of Q1*.

        ## Action items

        - [ ] Dana sends the pricing deck
        - [x] Kurt books the follow-up

        ## Key points

        - Budget is approved
          - Only for 50 seats
        - Security review in `January`

        1. First
        2. Second
        """
        let doc = Markdown.document(markdown, newBlockID: ids())
        #expect(Markdown.markdown(doc) == markdown)
    }

    @Test func headingsListsAndIDs() {
        let doc = Markdown.document("# Title\n\nHello\n\n- a\n- b", newBlockID: ids())
        let types = (doc.content ?? []).map(\.type)
        #expect(types == ["heading", "paragraph", "bulletList"])
        #expect(doc.content?[0].blockID == "b1")
        #expect(doc.content?[2].content?.map(\.blockID) == ["b3", "b4"])
    }

    @Test func htmlStaysText() {
        let doc = Markdown.document("<script>alert(1)</script> and <img src=x onerror=alert(1)>")
        #expect(doc.plainText == "<script>alert(1)</script> and <img src=x onerror=alert(1)>")
    }

    @Test func unsafeLinksBecomePlainText() {
        let nodes = Markdown.inline("[click](javascript:alert(1)) and [site](https://acme.com)")
        #expect(nodes.contains { $0.marks?.contains(.link("https://acme.com")) == true })
        #expect(!nodes.contains { $0.marks?.contains { $0.type == "link" && $0.attrs?["href"] == .string("javascript:alert(1") } == true })
    }

    @Test func snakeCaseIsNotItalic() {
        #expect(Markdown.inline("use snake_case_names here").count == 1)
    }

    @Test func aListWhoseFirstItemIsIndentedKeepsEveryItem() {
        #expect(Markdown.document("  - a\n- b\n- c").plainText == "abc")
        #expect(Markdown.document("  1. x\n\n- y").plainText == "x\ny")
    }

    @Test func nestedEmphasisGivesEachMarkOnce() {
        #expect(Markdown.inline("**a __b__ c**") == [.text("a b c", marks: [.bold])])
        #expect(Markdown.inline("*a _b_ c*") == [.text("a b c", marks: [.italic])])
    }

    @Test func linksStartAtTheirOwnBracketAndKeepParensInTheURL() {
        #expect(Markdown.inline("[12:30] Them: see [deck](https://acme.com/deck)") == [
            .text("[12:30] Them: see "), .text("deck", marks: [.link("https://acme.com/deck")]),
        ])
        #expect(Markdown.inline("[wiki](https://en.wikipedia.org/wiki/Foo_(bar)).") == [
            .text("wiki", marks: [.link("https://en.wikipedia.org/wiki/Foo_(bar)")]), .text("."),
        ])
    }

    @Test func codeKeepsItsBoldAndLink() {
        let markdown = "**`x`** and [`y`](https://acme.com)"
        #expect(Markdown.markdown(Markdown.document(markdown)) == markdown)
    }

    @Test func aHardBreakInAListItemRoundTrips() {
        let paragraph = PMNode(type: "paragraph", content: [.text("a"), PMNode(type: "hardBreak"), .text("b")])
        let doc = PMNode.doc([PMNode(type: "bulletList", content: [
            PMNode(type: "listItem", attrs: ["blockId": .string("b1")], content: [paragraph]),
        ])])
        #expect(Markdown.document(Markdown.markdown(doc), newBlockID: ids()) == doc)
    }

    @Test func aListItemWithTwoParagraphsRoundTrips() {
        let doc = PMNode.doc([PMNode(type: "bulletList", content: [
            PMNode(type: "listItem", attrs: ["blockId": .string("b1")], content: [
                PMNode(type: "paragraph", content: [.text("a")]), PMNode(type: "paragraph", content: [.text("b")]),
            ]),
            PMNode(type: "listItem", attrs: ["blockId": .string("b2")], content: [PMNode(type: "paragraph", content: [.text("c")])]),
        ])])
        #expect(Markdown.document(Markdown.markdown(doc), newBlockID: ids()) == doc)
    }

    @Test func htmlExportKeepsTheListStart() {
        #expect(NoteExport.html(Markdown.document("3. a\n4. b")) == "<ol start=\"3\"><li>a</li><li>b</li></ol>")
    }

    @Test func aCodeFenceKeepsEachLineAsCode() {
        let doc = Markdown.document("Run this:\n\n```sh\n# not a heading\n- not a list\n```", newBlockID: ids())
        #expect(doc.content?.last == PMNode(type: "paragraph", attrs: ["blockId": .string("b2")], content: [
            .text("# not a heading", marks: [.code]), PMNode(type: "hardBreak"), .text("- not a list", marks: [.code]),
        ]))
        #expect(Markdown.document(Markdown.markdown(doc), newBlockID: ids()) == doc)
    }

    @Test func aBlankLineInACodeFenceRoundTrips() {
        let doc = Markdown.document("```\nlet a = 1\n\nlet b = 2\n```", newBlockID: ids())
        #expect(doc.content?.count == 1)
        #expect(Markdown.document(Markdown.markdown(doc), newBlockID: ids()) == doc)
    }

    @Test func aFenceThatNeverClosesIsText() {
        let stray = Markdown.document("## Summary\n\n- a\n\n```\n## Next steps\n\n- [ ] b", newBlockID: ids())
        #expect(stray.content?.map(\.type) == ["heading", "bulletList", "paragraph", "heading", "taskList"])
        #expect(stray.content?[2].plainText == "```")

        let inlineCode = Markdown.document("```make test``` runs the suite.\n\n```sh\nmake\n```", newBlockID: ids())
        #expect(inlineCode.content?.count == 2)
        #expect(inlineCode.content?.last?.content == [.text("make", marks: [.code])])
    }

    @Test func aTableKeepsEachRowOnItsOwnLine() {
        let table = "| Owner | Task |\n|---|---|\n| Dana | Deck |"
        #expect(Markdown.document("Owners:\n" + table).plainText == "Owners:\n" + table)
    }

    @Test func documentJSONRoundTrips() throws {
        let doc = Markdown.document("## Hi\n\n- [x] done")
        let decoded = try #require(PMNode.decode(doc.encoded()))
        #expect(decoded == doc)
    }
}

struct AuthorshipTests {
    let notes = Markdown.document("""
    ## Decisions

    Acme renews if SSO ships by end of Q1.

    The team discussed the onboarding timeline at length.
    """)

    func aiFlags(_ doc: PMNode) -> [Bool] {
        (doc.content ?? []).filter { $0.type == "paragraph" }.map { paragraph in
            paragraph.content?.allSatisfy { $0.marks?.contains(.ai) == true } ?? false
        }
    }

    @Test func userPointsStayNormalColor() {
        let marked = Authorship.apply(to: notes, userNotes: "acme renews if sso by Q1")
        #expect(aiFlags(marked) == [false, true])
        #expect(marked.content?.first?.content?.first?.marks == nil)
    }

    @Test func noTypedNotesMeansNoMarks() {
        #expect(Authorship.apply(to: notes, userNotes: "  ") == notes)
    }
}

struct FakeChat: ChatProvider {
    let chunks: [String]
    var finish: FinishReason = .stop
    var failAfter: Int?

    func models() async throws -> [ModelInfo] { [ModelInfo(id: "fake")] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            for (index, chunk) in chunks.enumerated() {
                if let failAfter, index == failAfter {
                    continuation.finish(throwing: ProviderError.unreachable)
                    return
                }
                continuation.yield(.text(chunk))
            }
            continuation.yield(.finished(finish))
            continuation.finish()
        }
    }
}

struct NoteWriterTests {
    let database: AppDatabase
    let meeting: Meeting

    init() throws {
        database = try AppDatabase.inMemory()
        try database.seedBuiltIns()
        var meeting = Meeting(title: "Zoom call, Oct 17 2:05 PM", state: .writingNotes, templateId: "customer")
        meeting.durationMs = 45 * 60_000
        try database.insert(meeting)
        self.meeting = meeting
        try database.replaceTranscript([
            TranscriptLine(channel: .them, startMs: 724_000, endMs: 727_100, text: "We'd renew if SSO lands by end of Q1."),
            TranscriptLine(channel: .me, startMs: 728_000, endMs: 730_000, text: "Got it, I'll send the pricing deck."),
        ], duplicates: [], meeting: meeting.id, engine: "test")
    }

    func writer(_ provider: any ChatProvider, local: Bool = true, context: Int = 32_000) -> NoteWriter {
        NoteWriter(database: database) { _ in
            ResolvedProvider(record: ProviderRecord(id: local ? "builtin" : "openai", name: "x", kind: local ? .builtin : .openAICompatible,
                                                    contextTokens: context, isLocal: local),
                             model: "m", provider: provider)
        }
    }

    @Test func writesNotesAndTitle() async throws {
        let output = ["# Acme renewal", " hinges on SSO\n\n## Summary\n\n- Acme renews if SSO ships by Q1\n\n", "## Next steps\n\n- [ ] Send the pricing deck"]
        let outcome = try await writer(FakeChat(chunks: output)).write(meeting.id)
        guard case .written(let id) = outcome else { Issue.record("not written"); return }
        let saved = try #require(try database.meeting(meeting.id))
        #expect(saved.currentEnhancedId == id)
        #expect(saved.title == "Acme renewal hinges on SSO")
        #expect(saved.titleSource == .ai)
        let note = try #require(try database.enhancedNotes(meeting.id).first)
        #expect(note.status == .done)
        #expect(note.markdown.hasPrefix("## Summary"))
        let doc = try #require(note.doc.flatMap(PMNode.decode))
        #expect(doc.plainText.contains("Send the pricing deck"))
        #expect(!doc.encoded().contains("\"ai\""))
    }

    @Test func userTitleIsKept() async throws {
        var renamed = meeting
        renamed.title = "Acme QBR"
        renamed.titleSource = .user
        try database.save(renamed)
        _ = try await writer(FakeChat(chunks: ["# Something else\n\n## Summary\n\n- x"])).write(meeting.id)
        #expect(try database.meeting(meeting.id)?.title == "Acme QBR")
    }

    @Test func renamingWhileNotesFinishKeepsBoth() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try AppDatabase.open(at: dir.appendingPathComponent("db.sqlite"), backups: dir)
        for _ in 0..<50 {
            let meeting = Meeting(title: "Zoom call", state: .writingNotes)
            try pool.insert(meeting)
            var note = EnhancedNote(meetingId: meeting.id, templateId: "general", providerId: "builtin", model: "m")
            note.status = .done
            let finished = note
            async let notes: Void = Task.detached { try pool.finishEnhanced(finished, suggestedTitle: "AI title") }.value
            async let rename: Void = Task.detached { try pool.renameMeeting(meeting.id, to: "Acme QBR") }.value
            _ = try await (notes, rename)
            let saved = try #require(try pool.meeting(meeting.id))
            #expect(saved.currentEnhancedId == note.id)
            #expect(saved.title == "Acme QBR")
            #expect(saved.titleSource == .user)
        }
    }

    @Test func stoppingKeepsAnEndAndLengthAlreadyStored() throws {
        let end = Date(timeIntervalSince1970: 1_000)
        try database.recordingStopped(meeting.id, endAt: end, durationMs: 60_000)
        try database.recordingStopped(meeting.id, endAt: Date(), durationMs: 1)
        let saved = try #require(try database.meeting(meeting.id))
        #expect(saved.state == .transcribing)
        #expect(saved.durationMs == 2_700_000)
        #expect(saved.endAt == end)
    }

    @Test func aFirstLineThatIsASectionIsNotTheTitle() async throws {
        _ = try await writer(FakeChat(chunks: ["# Summary\n\n- Acme renews if SSO ships by Q1"])).write(meeting.id)
        #expect(try database.meeting(meeting.id)?.title == meeting.title)
        #expect(try database.enhancedNotes(meeting.id).first?.markdown == "# Summary\n\n- Acme renews if SSO ships by Q1")
    }

    @Test func reasoningBeforeABareThinkCloseIsDropped() async throws {
        let answer = ["Okay, the user wants notes.\n</thi", "nk>\n\n# Acme renewal\n\n## Summary\n\n- a"]
        _ = try await writer(FakeChat(chunks: answer)).write(meeting.id)
        #expect(try database.meeting(meeting.id)?.title == "Acme renewal")
        #expect(try database.enhancedNotes(meeting.id).first?.markdown == "## Summary\n\n- a")
    }

    @Test("an answer wrapped in a code fence is saved as notes with its title", arguments: ["```", "```markdown", "```md"])
    func aFencedAnswerIsNotes(fence: String) async throws {
        _ = try await writer(FakeChat(chunks: ["\(fence)\n# Acme renewal\n\n## Summary\n\n- SSO by Q1\n```"])).write(meeting.id)
        #expect(try database.meeting(meeting.id)?.title == "Acme renewal")
        let note = try #require(try database.enhancedNotes(meeting.id).first)
        #expect(note.markdown == "## Summary\n\n- SSO by Q1")
        #expect(note.doc.flatMap(PMNode.decode)?.content?.first?.type == "heading")
    }

    @Test func typedNotesDriveAuthorship() async throws {
        try database.saveUserNote(UserNote(meetingId: meeting.id, doc: nil, markdown: "acme renews if SSO by Q1"))
        _ = try await writer(FakeChat(chunks: ["# T\n\n## Summary\n\nAcme renews if SSO ships by Q1.\n\nThey asked about seats."])).write(meeting.id)
        let doc = try #require(try database.enhancedNotes(meeting.id).first?.doc.flatMap(PMNode.decode))
        let paragraphs = (doc.content ?? []).filter { $0.type == "paragraph" }
        #expect(paragraphs[0].content?.first?.marks == nil)
        #expect(paragraphs[1].content?.first?.marks == [.ai])
    }

    @Test func failureMarksTheVersionFailed() async throws {
        await #expect(throws: ProviderError.unreachable) {
            _ = try await writer(FakeChat(chunks: ["# T", "x", "y"], failAfter: 2)).write(meeting.id)
        }
        #expect(try database.enhancedNotes(meeting.id).first?.status == .failed)
        #expect(try database.meeting(meeting.id)?.currentEnhancedId == nil)
    }

    @Test func aFailedVersionKeepsEveryWordThatArrived() async throws {
        await #expect(throws: ProviderError.unreachable) {
            _ = try await writer(FakeChat(chunks: ["# T\n\n## Summary\n", "- a", "x"], failAfter: 2)).write(meeting.id)
        }
        #expect(try database.enhancedNotes(meeting.id).first?.markdown == "## Summary\n- a")
    }

    @Test func cloudNeedsConsentOnce() async throws {
        let outcome = try await writer(FakeChat(chunks: ["# T"]), local: false).write(meeting.id)
        #expect(outcome == .waiting(.cloudConsent))
        try database.saveProvider(ProviderRecord(id: "openai", name: "OpenAI", kind: .openAICompatible, contextTokens: 128_000, isLocal: false))
        try database.grantCloudConsent("openai")
        guard case .written = try await writer(FakeChat(chunks: ["# T\n\n- a"]), local: false).write(meeting.id) else {
            Issue.record("not written")
            return
        }
    }

    @Test func truncatedNotesAreFlagged() async throws {
        _ = try await writer(FakeChat(chunks: ["# T\n\n- a"], finish: .length)).write(meeting.id)
        let note = try #require(try database.enhancedNotes(meeting.id).first)
        #expect(note.status == .done)
        #expect(note.errorCode == "truncated")
        #expect(try database.meeting(meeting.id)?.currentEnhancedId == note.id)
    }

    @Test func aTitleOnlyAnswerCutOffAtItsLimitFailsAndKeepsTheEarlierNotes() async throws {
        guard case .written(let good) = try await writer(FakeChat(chunks: ["# T\n\n- a"])).write(meeting.id) else {
            Issue.record("not written")
            return
        }
        await #expect(throws: ProviderError.truncated) {
            _ = try await writer(FakeChat(chunks: ["# Acme renewal"], finish: .length)).write(meeting.id)
        }
        #expect(try database.meeting(meeting.id)?.currentEnhancedId == good)
        #expect(try database.enhancedNotes(meeting.id).first?.status == .failed)
    }

    @Test func anAnswerCutOffWhileStillReasoningFailsAndKeepsTheEarlierNotes() async throws {
        guard case .written(let good) = try await writer(FakeChat(chunks: ["# T\n\n- a"])).write(meeting.id) else {
            Issue.record("not written")
            return
        }
        await #expect(throws: ProviderError.truncated) {
            _ = try await writer(FakeChat(chunks: ["Okay, let me look at the transcript. The customer said"], finish: .length))
                .write(meeting.id)
        }
        #expect(try database.meeting(meeting.id)?.currentEnhancedId == good)
        #expect(try database.enhancedNotes(meeting.id).first?.status == .failed)
    }

    @Test func notesCutOffAfterTheirFirstSectionAreKept() async throws {
        _ = try await writer(FakeChat(chunks: ["## Summary\n\n- Acme renews if SSO ships"], finish: .length)).write(meeting.id)
        let note = try #require(try database.enhancedNotes(meeting.id).first)
        #expect(note.status == .done)
        #expect(note.errorCode == "truncated")
    }

    @Test func anEmptyAnswerFails() async throws {
        await #expect(throws: ProviderError.truncated) { _ = try await writer(FakeChat(chunks: [])).write(meeting.id) }
        #expect(try database.meeting(meeting.id)?.currentEnhancedId == nil)
    }

    @Test func aFailedFinalSaveMarksTheVersionFailed() async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_done BEFORE UPDATE ON enhanced WHEN NEW.status = 'done'
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }
        await #expect(throws: (any Error).self) { _ = try await writer(FakeChat(chunks: ["# T\n\n- a"])).write(meeting.id) }
        #expect(try database.enhancedNotes(meeting.id).first?.status == .failed)
    }

    @Test func aModelThatIsNotReadyAddsNoVersion() async throws {
        let versionsWhenAsked = Recorded<Int>()
        let provider = ScriptedChat { [database, meeting] _, _ in
            await versionsWhenAsked.add(try database.enhancedNotes(meeting.id).count)
            throw ModelHostError.modelMissing("qwen")
        }
        await #expect(throws: ModelHostError.modelMissing("qwen")) { try await writer(provider).write(meeting.id) }
        #expect(await versionsWhenAsked.values == [0])
    }

    @Test func aMeetingWaitingForTheModelShowsWritingOnceItAnswers() async throws {
        try database.setState(meeting.id, .waiting, detail: WaitReason.modelMissing.rawValue)
        _ = try await writer(FakeChat(chunks: ["# T\n\n- a"])).write(meeting.id)
        #expect(try database.meeting(meeting.id)?.state == .writingNotes)
    }

    func longCall(minutes: Int) throws {
        let lines = (0..<minutes * 12).map { (index: Int) -> TranscriptLine in
            let start = Int64(index) * 5_000
            return TranscriptLine(channel: index % 2 == 0 ? .them : .me, startMs: start, endMs: start + 4_000,
                                  text: "This is a fairly long sentence number \(index) about the renewal and the security review.")
        }
        try database.replaceTranscript(lines, duplicates: [], meeting: meeting.id, engine: "test")
    }

    /// Answers like a small local model: each part summary is about 1,500 tokens, and a prompt
    /// that doesn't fit the context fails.
    func smallModel(context: Int, summaryFinish: FinishReason = .stop) -> ScriptedChat {
        ScriptedChat { request, continuation in
            guard NotesPrompt.estimateTokens(request.messages.map(\.content).joined()) <= context - request.maxTokens else {
                throw ProviderError.contextTooLong
            }
            if request.messages.first?.content == NotesPrompt.partSystem {
                let bullet = "- [00:05] A point about the renewal, the security review, and the pricing deck.\n"
                continuation.answer(String(repeating: bullet, count: 45), summaryFinish)
            } else {
                continuation.answer("# Acme renewal\n\n## Summary\n\n- Renews if SSO ships by Q1")
            }
        }
    }

    @Test func anHourLongCallFitsASmallModel() async throws {
        try longCall(minutes: 60)
        _ = try await writer(smallModel(context: 8_192), context: 8_192).write(meeting.id)
        #expect(try database.enhancedNotes(meeting.id).first?.status == .done)
    }

    @Test func aCutOffPartSummaryIsKept() async throws {
        try longCall(minutes: 30)
        _ = try await writer(smallModel(context: 8_192, summaryFinish: .length), context: 8_192).write(meeting.id)
        #expect(try database.enhancedNotes(meeting.id).first?.status == .done)
    }

    @Test func partSummariesDropReasoningBeforeABareThinkClose() async throws {
        try longCall(minutes: 30)
        let prompts = Recorded<String>()
        let provider = ScriptedChat { request, continuation in
            if request.messages.first?.content == NotesPrompt.partSystem {
                continuation.answer("Okay, the user wants bullets.\n</think>\n- [00:05] A point")
            } else {
                await prompts.add(request.messages.last?.content ?? "")
                continuation.answer("# T\n\n- a")
            }
        }
        _ = try await writer(provider, context: 8_192).write(meeting.id)
        let prompt = try #require(await prompts.values.last)
        #expect(prompt.contains("- [00:05] A point"))
        #expect(!prompt.contains("</think>"))
    }

    @Test func aPartSummaryCutOffBeforeAnyTextFails() async throws {
        try longCall(minutes: 30)
        let provider = ScriptedChat { request, continuation in
            if request.messages.first?.content == NotesPrompt.partSystem {
                continuation.answer("", .length)
            } else {
                continuation.answer("# T\n\n- a")
            }
        }
        await #expect(throws: ProviderError.truncated) { _ = try await writer(provider, context: 8_192).write(meeting.id) }
    }

    @Test func summariesThatNeverShrinkStopAsTooLong() async throws {
        try longCall(minutes: 30)
        await #expect(throws: ProviderError.contextTooLong) {
            _ = try await writer(smallModel(context: 4_096), context: 4_096).write(meeting.id)
        }
    }
}

actor CallCounter {
    var count = 0
    @discardableResult func add() -> Int {
        count += 1
        return count
    }
}

actor Recorded<Value: Sendable> {
    var values: [Value] = []
    func add(_ value: Value) { values.append(value) }
}

/// A chat model whose answer each test writes. An error it throws ends the stream.
struct ScriptedChat: ChatProvider {
    let answer: @Sendable (ChatRequest, AsyncThrowingStream<ChatDelta, Error>.Continuation) async throws -> Void

    func models() async throws -> [ModelInfo] { [] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await answer(request, continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

extension AsyncThrowingStream<ChatDelta, Error>.Continuation {
    func answer(_ text: String, _ reason: FinishReason = .stop) {
        yield(.text(text))
        yield(.finished(reason))
        finish()
    }
}

struct CountingChat: ChatProvider {
    let counter: CallCounter
    func models() async throws -> [ModelInfo] { [] }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        let counter = counter
        let size = NotesPrompt.estimateTokens(request.messages.map(\.content).joined())
        return AsyncThrowingStream { continuation in
            Task {
                await counter.add()
                if size > 8_000 - NotesPrompt.outputTokens {
                    continuation.finish(throwing: ProviderError.contextTooLong)
                    return
                }
                continuation.yield(.text("# T\n\n- [00:05] point"))
                continuation.yield(.finished(.stop))
                continuation.finish()
            }
        }
    }
}

/// Uses the real login keychain. Run with HONEYCOMB_KEYCHAIN_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HONEYCOMB_KEYCHAIN_TESTS"] == "1"))
struct KeychainTests {
    @Test func storesAndDeletesKeys() throws {
        let keychain = Keychain(service: "io.github.kurtjallo.Honeycomb.tests.\(UUID().uuidString)")
        try keychain.set("sk-one", account: "openai")
        #expect(try keychain.read(account: "openai") == "sk-one")
        try keychain.set("sk-two", account: "openai")
        #expect(try keychain.read(account: "openai") == "sk-two")
        keychain.deleteAll()
        #expect(try keychain.read(account: "openai") == nil)
    }
}
