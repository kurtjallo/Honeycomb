import Foundation
import Security
import Synchronization
import Testing
@testable import HoneycombCore

struct RouterTests {
    let database: AppDatabase
    let keychain = MemorySecretStore()
    let router: ProviderRouter

    init() throws {
        database = try AppDatabase.inMemory()
        try database.seedBuiltIns()
        let store = ModelStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)"),
                               database: nil)
        router = ProviderRouter(database: database, keychain: keychain, builtIn: BuiltInLLM(store: store, host: ModelHost(store: store)))
    }

    @Test func builtInProviderIsSeededOnce() throws {
        try database.seedBuiltIns()
        var renamed = ProviderRecord.builtIn
        renamed.contextTokens = 8_000
        try database.saveProvider(renamed)
        try database.seedBuiltIns()
        let builtIns = try database.providers().filter { $0.kind == .builtin }
        #expect(builtIns.count == 1)
        #expect(builtIns.first?.contextTokens == 8_000)
        #expect(builtIns.first?.isLocal == true)
    }

    @Test func builtInRouteResolvesToTheBuiltInModel() throws {
        try database.saveRoute(Route(task: .enhance, providerId: ProviderRecord.builtIn.id, model: ModelCatalog.builtInLLM))
        let resolved = try router.resolve(.enhance)
        #expect(resolved.provider is BuiltInProvider)
        #expect(resolved.model == ModelCatalog.builtInLLM)
        #expect(resolved.record.contextTokens == 32_768)
    }

    @Test func eachTaskUsesItsOwnRoute() throws {
        let ollama = try router.save(ProviderDraft(name: "Ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1",
                                                   contextTokens: 8_000))
        let claude = try router.save(ProviderDraft(name: "Claude", kind: .anthropic, baseURL: "https://api.anthropic.com",
                                                   apiKey: "sk-test", contextTokens: 200_000))
        try database.saveRoute(Route(task: .enhance, providerId: claude.id, model: "claude-opus-5-5"))
        try database.saveRoute(Route(task: .chat, providerId: ollama.id, model: "qwen3.5:9b"))

        let notes = try router.resolve(.enhance)
        #expect(notes.provider is AnthropicProvider)
        #expect(notes.model == "claude-opus-5-5")
        #expect(notes.record.isLocal == false)
        let chat = try router.resolve(.chat)
        #expect(chat.provider is OpenAICompatibleProvider)
        #expect(chat.model == "qwen3.5:9b")
        #expect(chat.record.isLocal == true)
    }

    @Test func missingRouteIsNotChosen() {
        #expect(throws: RouteError.notChosen) { try router.resolve(.enhance) }
    }

    @Test func anthropicWithoutAKeyIsUnauthorized() throws {
        let claude = try router.save(ProviderDraft(name: "Claude", kind: .anthropic, baseURL: "https://api.anthropic.com",
                                                   contextTokens: 200_000))
        #expect(claude.keyRef == nil)
        try database.saveRoute(Route(task: .enhance, providerId: claude.id, model: "claude-opus-5-5"))
        #expect(throws: ProviderError.unauthorized) { try router.resolve(.enhance) }
    }

    @Test("a Keychain read that fails, such as while the keychain is locked, is an error, not a missing key")
    func keychainReadFailureIsAnError() throws {
        #expect(throws: Keychain.KeychainError.status(errSecInteractionNotAllowed)) {
            try Keychain.secret(status: errSecInteractionNotAllowed, result: nil)
        }
        #expect(try Keychain.secret(status: errSecItemNotFound, result: nil) == nil)
    }

    @Test("a provider whose key can't be read fails with a lasting provider error instead of sending no key", arguments: [
        ProviderKind.openAICompatible, .anthropic,
    ])
    func unreadableKeyStopsTheRequest(kind: ProviderKind) throws {
        let saved = try router.save(ProviderDraft(name: "Cloud", kind: kind, baseURL: "https://api.example.com",
                                                  apiKey: "sk-1", contextTokens: 128_000))
        try database.saveRoute(Route(task: .enhance, providerId: saved.id, model: "x"))
        keychain.readError.withLock { $0 = Keychain.KeychainError.status(errSecInteractionNotAllowed) }

        let error = #expect(throws: ProviderError.self) { try router.resolve(.enhance) }
        #expect(error?.code == "keychain_unavailable")
        #expect(error?.isTransient == false)
        #expect(error.flatMap { ProviderError(code: $0.code) } == error, "a stored code reads back")
    }

    @Test func keysLiveInKeychainAndLeaveWithTheProvider() throws {
        let saved = try router.save(ProviderDraft(name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1",
                                                  apiKey: " sk-or-1 ", contextTokens: 128_000))
        let keyRef = try #require(saved.keyRef)
        #expect(try keychain.read(account: keyRef) == "sk-or-1")
        #expect(try database.provider(saved.id)?.keyRef == keyRef)
        try database.saveRoute(Route(task: .enhance, providerId: saved.id, model: "x"))

        try router.delete(saved)
        #expect(try keychain.read(account: keyRef) == nil)
        #expect(try database.provider(saved.id) == nil)
        #expect(try database.route(.enhance) == nil)
    }

    @Test("when the database refuses a new provider, its key leaves the keychain too")
    func failedSaveLeavesNoKey() throws {
        try database.writer.write {
            try $0.execute(sql: "CREATE TRIGGER refuse_provider BEFORE INSERT ON provider BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        #expect(throws: (any Error).self) {
            try router.save(ProviderDraft(name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1",
                                          apiKey: "sk-test", contextTokens: 128_000))
        }
        #expect(keychain.accounts.isEmpty)
    }

    @Test func builtInProviderCantBeDeleted() throws {
        try router.delete(ProviderRecord.builtIn)
        try database.deleteProvider(ProviderRecord.builtIn.id)
        #expect(try database.provider(ProviderRecord.builtIn.id) != nil)
    }

    @Test func draftsAreLocalOnlyOnPrivateHosts() throws {
        func draft(_ url: String) -> ProviderDraft {
            ProviderDraft(name: "", kind: .openAICompatible, baseURL: url, contextTokens: 8_000)
        }
        #expect(try draft("http://localhost:11434/v1").record().isLocal)
        #expect(try draft("http://192.168.1.20:1234/v1").record().isLocal)
        #expect(try !draft("https://api.openai.com/v1").record().isLocal)
        #expect(try draft("https://api.openai.com/v1").record().name == "api.openai.com")
        #expect(throws: ProviderError.insecureURL) { try draft("http://api.example.com/v1").record() }
        #expect(throws: ProviderError.invalidURL) { try draft("localhost:11434").record() }
    }

    func meetingWithTranscript() throws -> Meeting {
        let meeting = Meeting(title: "Zoom call", state: .transcribing)
        try database.insert(meeting)
        try database.replaceTranscript([
            TranscriptLine(channel: .them, startMs: 0, endMs: 3_000, text: "We'd renew if SSO lands by end of Q1."),
            TranscriptLine(channel: .me, startMs: 3_500, endMs: 5_000, text: "Got it, I'll send the pricing deck."),
        ], duplicates: [], meeting: meeting.id, engine: "test")
        return meeting
    }

    /// The real router picks the record and model. Only the network adapter is swapped for a fake.
    func writer() -> NoteWriter {
        NoteWriter(database: database) { [router] task in
            let resolved = try router.resolve(task)
            return ResolvedProvider(record: resolved.record, model: resolved.model,
                                    provider: FakeChat(chunks: ["# Acme renewal\n\n## Summary\n\n- Renews if SSO ships"]))
        }
    }

    func settled(_ id: UUID) async throws -> Meeting {
        for _ in 0..<200 {
            if let meeting = try database.meeting(id), [.waiting, .ready, .failed].contains(meeting.state),
               try !database.hasOpenJob(.enhance, meeting: id) {
                return meeting
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    @Test func noRouteWaitsForTheAIChoice() async throws {
        let meeting = try meetingWithTranscript()
        #expect(try await writer().write(meeting.id) == .waiting(.aiNotChosen))
        #expect(try database.enhancedNotes(meeting.id).isEmpty)
    }

    @Test func builtInModelStillDownloadingLeavesNoVersion() async throws {
        let meeting = try meetingWithTranscript()
        try database.saveRoute(Route(task: .enhance, providerId: ProviderRecord.builtIn.id, model: ModelCatalog.builtInLLM))
        let writer = NoteWriter(database: database) { [router] in try router.resolve($0) }
        await #expect(throws: ModelHostError.modelMissing(ModelCatalog.builtInLLM)) { try await writer.write(meeting.id) }
        #expect(PipelineError.waitReason(for: ModelHostError.modelMissing(ModelCatalog.builtInLLM)) == .modelMissing)
        #expect(try database.enhancedNotes(meeting.id).isEmpty)
    }

    @Test func cloudRouteWaitsForConsentThenWrites() async throws {
        let meeting = try meetingWithTranscript()
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)"))
        let store = ModelStore(root: paths.models, database: nil)
        let pipeline = Pipeline(database: database, paths: paths, host: ModelHost(store: store))
        var handlers = Pipeline.Handlers()
        handlers.enhance = { [writer = writer()] in try await writer.write($0) }
        await pipeline.setHandlers(handlers)
        await pipeline.start()

        await pipeline.enhanceAnyway(meeting.id)
        var waiting = try await settled(meeting.id)
        #expect(waiting.waitReason == .aiNotChosen)

        let cloud = try router.save(ProviderDraft(name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1",
                                                  contextTokens: 128_000))
        try database.saveRoute(Route(task: .enhance, providerId: cloud.id, model: "gpt-5"))
        await pipeline.enhanceAnyway(meeting.id)
        waiting = try await settled(meeting.id)
        #expect(waiting.state == .waiting)
        #expect(waiting.stateDetail == "cloud_consent")
        #expect(try database.enhancedNotes(meeting.id).isEmpty)

        try database.grantCloudConsent(cloud.id)
        await pipeline.enhanceAnyway(meeting.id)
        let written = try await settled(meeting.id)
        #expect(written.state == .ready)
        let note = try #require(try database.enhancedNotes(meeting.id).first)
        #expect(written.currentEnhancedId == note.id)
        #expect(note.providerId == cloud.id)
        #expect(note.model == "gpt-5")
        #expect(written.title == "Acme renewal")
        await pipeline.stop()
    }

    @Test("two adapters for one provider take turns, and two providers run at once")
    func oneRequestAtATimePerProvider() async throws {
        let first = StubServer(.init(headers: eventStream, closes: false), .init(body: sse(content("second"), "[DONE]")))
        let other = StubServer(.init(headers: eventStream, closes: false))
        let router = ProviderRouter(database: database, keychain: keychain, builtIn: self.router.builtIn, session: first.session)
        func save(_ server: StubServer) throws -> ProviderRecord {
            try router.save(ProviderDraft(name: server.host, kind: .openAICompatible, baseURL: server.url("/v1").absoluteString,
                                          contextTokens: 8_000))
        }
        let a = try save(first)
        let b = try save(other)
        let request = ChatRequest(model: "m", messages: [ChatMessage(.user, "Hi")])
        let (hangingAdapter, queuedAdapter, otherAdapter) = try (router.adapter(for: a), router.adapter(for: a), router.adapter(for: b))

        let hanging = Task { await Outcome(hangingAdapter.stream(request)) }
        try await waitUntil { first.requests.count == 1 }
        let elsewhere = Task { await Outcome(otherAdapter.stream(request)) }
        try await waitUntil { other.requests.count == 1 }
        #expect(other.requests.count == 1, "another provider doesn't wait for this one")

        let queued = Task { await Outcome(queuedAdapter.stream(request)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(first.requests.count == 1, "a second adapter for the same provider waits its turn")

        hanging.cancel()
        #expect(await queued.value.text == "second")
        #expect(first.requests.count == 2)
        elsewhere.cancel()
    }

    @Test func storedErrorCodesReadBack() {
        #expect(ProviderError(code: "unauthorized") == .unauthorized)
        #expect(ProviderError(code: "rate_limited")?.message == ProviderError.rateLimited(retryAfter: 3).message)
        #expect(ProviderError(code: "job_failed") == nil)
    }
}

final class MemorySecretStore: SecretStore {
    private let secrets = Mutex<[String: String]>([:])
    let readError = Mutex<(any Error)?>(nil)

    var accounts: [String] { secrets.withLock { Array($0.keys) } }

    func set(_ secret: String, account: String) throws {
        secrets.withLock { $0[account] = secret }
    }

    func read(account: String) throws -> String? {
        if let error = readError.withLock({ $0 }) { throw error }
        return secrets.withLock { $0[account] }
    }

    func delete(account: String) {
        _ = secrets.withLock { $0.removeValue(forKey: account) }
    }
}

func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}
