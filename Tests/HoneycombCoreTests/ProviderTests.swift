import Foundation
import Synchronization
import Testing
@testable import HoneycombCore

private let chat = ChatRequest(model: "test-model", messages: [ChatMessage(.system, "Write notes."), ChatMessage(.user, "Transcript")])

@Suite struct ProviderURLPolicyTests {
    @Test("https, and plain http on this Mac or the local network, are allowed", arguments: [
        "https://api.openai.com/v1", "http://localhost:11434", "http://127.0.0.1:1234", "http://[::1]:8080",
        "http://192.168.1.5:1234", "http://10.0.0.2", "http://172.16.0.9", "http://mac.local:11434",
        "http://0.0.0.0:11434", "http://[fe80::1]:8080", "http://[fe80::1%25en0]:8080", "http://[::ffff:192.168.1.5]:1234",
        "http://[::ffff:127.0.0.1]:1234",
    ])
    func allows(_ url: String) throws {
        try ProviderURLPolicy.check(#require(URL(string: url)))
    }

    @Test("plain http to a public address, or any other scheme, is refused", arguments: [
        "http://example.com", "http://8.8.8.8", "http://172.32.0.1", "ftp://192.168.1.5", "http://[::ffff:8.8.8.8]",
        "http://100.64.0.1",
    ])
    func refuses(_ url: String) throws {
        let url = try #require(URL(string: url))
        #expect(throws: ProviderError.insecureURL) { try ProviderURLPolicy.check(url) }
    }
}

@Suite struct ThinkFilterTests {
    private func filtered(_ pieces: String...) -> String {
        var filter = ThinkFilter()
        return pieces.map { filter.feed($0) }.joined() + filter.finish()
    }

    @Test func tagsSplitAcrossPieces() {
        #expect(filtered("Hel", "lo<th", "ink>hidden</thi", "nk> world") == "Hello world")
        #expect(filtered("<think>plan the notes", "</think>\n\nAnswer") == "Answer", "blank lines after </think> are dropped")
        #expect(filtered("x <t", "ea") == "x <tea", "a held partial tag that turns out to be text is released")
    }

    @Test func unclosedBlockAtStreamEnd() {
        #expect(filtered("Answer. <think>never clo", "ses") == "Answer. ")
        #expect(filtered("<think>only thoughts") == "")
        #expect(filtered("Done <thi") == "Done <thi", "a partial tag still held at the end is text")
    }

    @Test("a </think> before any visible text, with no <think> before it, is dropped")
    func strayLeadingClose() {
        #expect(filtered("</think>\n\nAnswer") == "Answer")
        #expect(filtered("\n", "</thi", "nk>\n\nAnswer") == "Answer")
        #expect(filtered("\n</thi") == "</thi", "a partial tag still held at the end is text")
    }

    @Test("a literal </think> after visible text or after a block stays in the answer")
    func literalCloseLater() {
        #expect(filtered("Answer first. ", "Then </think> later") == "Answer first. Then </think> later")
        #expect(filtered("<think>plan</think>Close with </think> here") == "Close with </think> here")
        #expect(filtered("</think>A ", "</think> B") == "A </think> B")
    }
}

@Suite struct CompleteTests {
    @Test("complete() throws CancellationError when its task is cancelled mid-answer")
    func cancelledMidAnswer() async {
        let (deltas, continuation) = AsyncThrowingStream.makeStream(of: ChatDelta.self)
        continuation.yield(.text("Partial"))
        let task = Task { try await StreamChat(deltas: deltas).complete(chat) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        continuation.finish()
    }

    @Test("complete() throws CancellationError when the stream ends without .finished")
    func endsWithoutFinish() async {
        let (deltas, continuation) = AsyncThrowingStream.makeStream(of: ChatDelta.self)
        continuation.yield(.text("Partial"))
        continuation.finish()
        await #expect(throws: CancellationError.self) { try await StreamChat(deltas: deltas).complete(chat) }
    }

    @Test("complete() returns the text on .finished(.stop) and throws .truncated on .finished(.length)")
    func finished() async throws {
        let (stopped, stop) = AsyncThrowingStream.makeStream(of: ChatDelta.self)
        stop.yield(.text("Done"))
        stop.yield(.finished(.stop))
        stop.finish()
        #expect(try await StreamChat(deltas: stopped).complete(chat) == "Done")

        let (cut, length) = AsyncThrowingStream.makeStream(of: ChatDelta.self)
        length.yield(.text("Cut"))
        length.yield(.finished(.length))
        length.finish()
        await #expect(throws: ProviderError.truncated) { try await StreamChat(deltas: cut).complete(chat) }
    }
}

private struct StreamChat: ChatProvider {
    let deltas: AsyncThrowingStream<ChatDelta, any Error>

    func models() async throws -> [ModelInfo] { [] }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, any Error> { deltas }
}

@Suite struct ProviderErrorTests {
    @Test("request errors and spent credit are not transient, so they show at once and are not retried", arguments: [
        (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}"#,
         "out_of_credit"),
        (429, #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#,
         "out_of_credit"),
        (402, #"{"error":{"code":402,"message":"Insufficient credits"}}"#, "out_of_credit"),
        (400, #"{"error":{"message":"Unsupported parameter: 'max_tokens'","type":"invalid_request_error"}}"#, "bad_request"),
        (422, "", "bad_request"),
    ])
    func requestErrors(status: Int, body: String, code: String) {
        let error = ProviderError.from(status: status, retryAfter: nil, body: body)
        #expect(error.code == code)
        #expect(!error.isTransient)
        #expect(ProviderError(code: code)?.code == code, "a stored code reads back")
    }

    @Test("an error object in a stream maps the same way as a failed response")
    func wireErrors() throws {
        let quota = try JSONDecoder().decode(ProviderWireError.self, from: Data(
            #"{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}"#.utf8))
        #expect(quota.providerError.code == "out_of_credit")
        let credit = try JSONDecoder().decode(ProviderWireError.self, from: Data(
            #"{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}"#.utf8))
        #expect(credit.providerError.code == "out_of_credit")
    }

    @Test("the transport retries exactly the HTTP failures the job queue calls transient: 5xx and rate limits")
    func retryAgreesWithTransient() {
        let wrong = (400..<600).filter { status in
            let error = ProviderError.from(status: status, retryAfter: nil, body: "")
            let retried = ProviderPolicy.cloud.retryWait(after: error, retries: 0) != nil
            return error.isTransient != (status >= 500 || status == 429) || retried != error.isTransient
        }
        #expect(wrong.isEmpty)
    }

    @Test("a base URL with no host is not transient")
    func malformedURL() {
        do {
            _ = try ProviderURLPolicy.parse("localhost:11434")
            Issue.record("a URL with no host parsed")
        } catch {
            #expect(!error.isTransient)
            #expect(ProviderError(code: error.code)?.code == error.code, "a stored code reads back")
        }
    }

    @Test("OpenAI's insufficient_quota 429 fails at once instead of being retried as a rate limit")
    func quotaIsNotRetried() async {
        let server = StubServer(.init(status: 429, body: Data(
            #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8)))
        var policy = ProviderPolicy.cloud
        policy.backoff = [.milliseconds(10), .milliseconds(10), .milliseconds(10)]
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: "sk-test", isLocal: false, session: server.session,
                                                policy: policy)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.error?.code == "out_of_credit")
        #expect(server.requests.count == 1)
    }
}

@Suite struct OpenAICompatibleProviderTests {
    @Test("an OpenAI stream assembles its text, and a length finish ends it as .length")
    func streamsText() async throws {
        let server = StubServer(.init(body: sse(
            #"{"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#,
            content("Hello"), content(" world"),
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#,
            "[DONE]")))
        let provider = OpenAICompatibleProvider(baseURL: server.url("/v1"), apiKey: " sk-test ", isLocal: false, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Hello"), .text(" world"), .finished(.length)])
        #expect(outcome.error == nil)
        let request = try #require(server.requests.first)
        #expect(request.url?.path() == "/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-test")
        let body = try SentBody(request)
        #expect(body.model == "test-model" && body.messages == chat.messages && body.maxTokens == 2_000 && body.stream == true)
    }

    @Test("on api.openai.com, max_completion_tokens replaces max_tokens, and reasoning models get no temperature and low effort")
    func openAIReasoningModels() async throws {
        let server = StubServer(host: "api.openai.com", .init(body: sse(content("ok"), "[DONE]")))
        let provider = OpenAICompatibleProvider(baseURL: server.url("/v1"), apiKey: "sk-test", isLocal: false, session: server.session)

        for model in ["gpt-5-mini", "o3", "o4-mini", "gpt-4.1"] {
            _ = try await provider.complete(ChatRequest(model: model, messages: chat.messages))
        }

        let bodies = try server.requests.map(SentBody.init)
        #expect(bodies.map(\.model) == ["gpt-5-mini", "o3", "o4-mini", "gpt-4.1"])
        #expect(bodies.map(\.maxTokens) == [nil, nil, nil, nil])
        #expect(bodies.map(\.maxCompletionTokens) == [27_000, 27_000, 27_000, 2_000],
                "hidden reasoning counts against the limit, so reasoning models get room for it on top of the answer")
        #expect(bodies.map(\.reasoningEffort) == ["low", "low", "low", nil])
        #expect(bodies.map(\.temperature) == [nil, nil, nil, 0.3])
    }

    @Test("other OpenAI-compatible servers keep max_tokens and temperature for models that aren't OpenAI reasoning models")
    func otherServersKeepMaxTokens() async throws {
        let server = StubServer(.init(body: sse(content("ok"), "[DONE]")))
        let provider = OpenAICompatibleProvider(baseURL: server.url("/v1"), apiKey: nil, isLocal: true, session: server.session)

        _ = try await provider.complete(ChatRequest(model: "llama3.2", messages: chat.messages))

        let body = try SentBody(#require(server.requests.first))
        #expect(body.maxTokens == 2_000 && body.maxCompletionTokens == nil && body.temperature == 0.3)
    }

    @Test("OpenAI reasoning models get their parameters through any gateway, such as LiteLLM or OpenRouter",
          arguments: ["gpt-5", "openai/gpt-5-mini", "o3"])
    func reasoningModelsThroughGateways(model: String) async throws {
        let server = StubServer(.init(body: sse(content("ok"), "[DONE]")))
        let provider = OpenAICompatibleProvider(baseURL: server.url("/v1"), apiKey: "sk-test", isLocal: false, session: server.session)

        _ = try await provider.complete(ChatRequest(model: model, messages: chat.messages))

        let body = try SentBody(#require(server.requests.first))
        #expect(body.maxTokens == nil && body.maxCompletionTokens == 27_000 && body.temperature == nil)
        #expect(body.reasoningEffort == "low")
    }

    @Test("an Ollama stream drops a <think> block whose tags are split across chunks")
    func dropsThinkBlock() async {
        let server = StubServer(.init(body: sse(
            content("<thi"), content("nk>reason"), content("ing</thi"), content(#"nk>\n\nAns"#), content("wer"), "[DONE]")))
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: nil, isLocal: true, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.text == "Answer")
        #expect(outcome.deltas.last == .finished(.stop))
        #expect(server.requests.first?.value(forHTTPHeaderField: "authorization") == nil, "no key, no authorization header")
    }

    @Test("reasoning_content and reasoning deltas never reach the text")
    func ignoresReasoning() async {
        let server = StubServer(.init(body: sse(
            #"{"choices":[{"index":0,"delta":{"reasoning_content":"Let me think"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"reasoning":"Still thinking"},"finish_reason":null}]}"#,
            content("Notes"),
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "[DONE]")))
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: nil, isLocal: true, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Notes"), .finished(.stop)])
    }

    @Test("an error object mid-stream throws its mapped error after the partial text")
    func midStreamError() async {
        let server = StubServer(.init(body: sse(
            content("Partial"),
            #"{"error":{"message":"This model's maximum context length is 8192 tokens","type":"invalid_request_error","code":"context_length_exceeded"}}"#)))
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: nil, isLocal: true, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Partial")])
        #expect(outcome.error == .contextTooLong)
    }

    @Test("HTTP failures map to one error each and are not retried", arguments: [
        (401, ProviderError.unauthorized), (404, ProviderError.modelNotFound),
    ])
    func httpStatus(status: Int, expected: ProviderError) async {
        let server = StubServer(.init(status: status, body: Data(#"{"error":{"message":"nope"}}"#.utf8)))
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: "sk-test", isLocal: false, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.error == expected)
        await #expect(throws: expected) { try await provider.models() }
        #expect(server.requests.count == 2, "one request each for the stream and the model list")
    }

    @Test("a 429 with retry-after is retried, and then the answer streams")
    func retriesRateLimit() async {
        let server = StubServer(
            .init(status: 429, headers: ["retry-after": "1"],
                  body: Data(#"{"error":{"message":"Rate limit reached","type":"requests","code":"rate_limit_exceeded"}}"#.utf8)),
            .init(body: sse(content("Recovered"), "[DONE]")))
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: "sk-test", isLocal: false, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Recovered"), .finished(.stop)])
        #expect(server.requests.count == 2)
    }

    @Test("a rate limit after text has streamed is not retried")
    func noRetryAfterText() async {
        let server = StubServer(
            .init(body: sse(content("Partial"), #"{"error":{"message":"Rate limit reached","type":"requests","code":"rate_limit_exceeded"}}"#)),
            .init(body: sse(content("Again"), "[DONE]")))
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: "sk-test", isLocal: false, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Partial")])
        #expect(outcome.error == .rateLimited(retryAfter: nil))
        #expect(server.requests.count == 1, "a retry would repeat text the caller already has")
    }

    @Test("models() decodes the list and names /v1 once", arguments: [
        ("", "/v1/models"), ("/v1", "/v1/models"), ("/v1/", "/v1/models"), ("/api/v1", "/api/v1/models"),
        ("/v1/chat/completions", "/v1/models"), ("/api/v1/chat/completions/", "/api/v1/models"),
    ])
    func models(basePath: String, expectedPath: String) async throws {
        let server = StubServer(.init(body: Data(
            #"{"object":"list","data":[{"id":"llama3.2","object":"model"},{"id":"qwen/qwen3-32b","context_length":40960}]}"#.utf8)))
        let provider = OpenAICompatibleProvider(baseURL: server.url(basePath), apiKey: nil, isLocal: true, session: server.session)

        #expect(try await provider.models() == [ModelInfo(id: "llama3.2"), ModelInfo(id: "qwen/qwen3-32b", contextTokens: 40960)])
        #expect(server.requests.map { $0.url?.path() } == [expectedPath])
    }

    @Test("embed() names the embedding model, names /v1 once, and returns vectors in input order", arguments: ["", "/v1"])
    func embed(basePath: String) async throws {
        let server = StubServer(.init(body: Data(
            #"{"object":"list","data":[{"index":1,"embedding":[0.5,0.25]},{"index":0,"embedding":[1,0]}]}"#.utf8)))
        let provider = OpenAICompatibleProvider(baseURL: server.url(basePath), apiKey: nil, isLocal: true, session: server.session,
                                                embeddingModel: "nomic-embed-text")

        #expect(try await provider.embed(["first", "second"]) == [[1, 0], [0.5, 0.25]])
        let request = try #require(server.requests.first)
        #expect(request.url?.path() == "/v1/embeddings")
        let body = try SentBody(request)
        #expect(body.model == "nomic-embed-text" && body.input == ["first", "second"])
    }

    @Test("plain http to a public host is refused before anything is sent")
    func refusesInsecureURL() async {
        let server = StubServer(.init(body: sse("[DONE]")))
        let provider = OpenAICompatibleProvider(baseURL: server.url(scheme: "http"), apiKey: "sk-test", isLocal: false, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.error == .insecureURL)
        #expect(server.requests.isEmpty, "the key never leaves over plain http")
    }

    @Test("no first token within the policy's budget throws .timedOut")
    func firstTokenTimeout() async {
        let server = StubServer(.init(headers: eventStream, closes: false))
        var policy = ProviderPolicy(firstToken: .milliseconds(500))
        policy.connect = .milliseconds(100)
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: nil, isLocal: true, session: server.session, policy: policy)
        let start = ContinuousClock.now

        let outcome = await Outcome(provider.stream(chat))

        let elapsed = ContinuousClock.now - start
        #expect(outcome.error == .timedOut)
        #expect(elapsed >= .milliseconds(500), "headers arrived, so the first-token budget applies, not the connect budget")
        #expect(elapsed < .seconds(10), "the 500 ms budget applies, not the 120 s local default")
        #expect(server.requests.count == 1, "a timeout has used its whole budget, so it is not retried")
    }

    @Test("a stream that closes with no finish_reason and no [DONE] fails as cut off instead of finishing")
    func closesUnfinished() async {
        let server = StubServer(.init(body: sse(content("Half the no"))))
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: nil, isLocal: true, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Half the no")])
        #expect(outcome.error == .unreachable, "transient, so the job queue retries it later")
    }

    @Test("a stream that sends its finish_reason but closes before [DONE] still finishes")
    func finishReasonWithoutDone() async {
        let server = StubServer(.init(body: sse(content("Notes"), #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#)))
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: nil, isLocal: true, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Notes"), .finished(.stop)])
    }

    @Test("a content_filter finish is an error, not a clean stop")
    func contentFilter() async {
        let server = StubServer(.init(body: sse(
            content("Notes"), #"{"choices":[{"index":0,"delta":{},"finish_reason":"content_filter"}]}"#, "[DONE]")))
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: "sk-test", isLocal: false, session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Notes")])
        #expect(outcome.error?.code == "refused")
        #expect(outcome.error?.isTransient == false)
    }

    @Test("SSE comment lines, such as OpenRouter's while a reasoning model thinks, keep the attempt alive")
    func commentsKeepTheAttemptAlive() async {
        let keepAlive = Data(": OPENROUTER PROCESSING\n\n".utf8)
        let server = StubServer(.init(headers: eventStream, later: Array(repeating: keepAlive, count: 8)
            + [sse(content("Notes"), #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, "[DONE]")]))
        var policy = ProviderPolicy(firstToken: .milliseconds(400))
        policy.silence = .milliseconds(400)
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: nil, isLocal: false, session: server.session, policy: policy)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.error == nil, "900 ms of comments 100 ms apart outlast a 400 ms budget only if each one counts")
        #expect(outcome.deltas == [.text("Notes"), .finished(.stop)])
    }

    @Test("silence after text throws .timedOut and keeps the text")
    func silenceTimeout() async {
        let server = StubServer(.init(headers: eventStream, body: sse(content("Partial")), closes: false))
        var policy = ProviderPolicy.local
        policy.silence = .milliseconds(300)
        let provider = OpenAICompatibleProvider(baseURL: server.url(), apiKey: nil, isLocal: true, session: server.session, policy: policy)
        let start = ContinuousClock.now

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Partial")])
        #expect(outcome.error == .timedOut)
        #expect(ContinuousClock.now - start < .seconds(5), "the first event moves the deadline earlier, to 300 ms of silence")
    }
}

@Suite struct AnthropicProviderTests {
    @Test("an Anthropic stream keeps text deltas, skips thinking, and ends max_tokens as .length")
    func streamsText() async throws {
        let server = StubServer(.init(body: Data("""
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"stop_reason":null}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user wants notes."}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: ping
            data: {"type":"ping"}

            event: content_block_start
            data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Decisions"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" made"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":1}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":2000}}

            event: message_stop
            data: {"type":"message_stop"}


            """.utf8)))
        let provider = AnthropicProvider(apiKey: "sk-ant-test", baseURL: server.url(), session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Decisions"), .text(" made"), .finished(.length)])
        #expect(outcome.error == nil)
        let request = try #require(server.requests.first)
        #expect(request.url?.path() == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try SentBody(request)
        #expect(body.system == "Write notes.", "system messages move to the top-level system field")
        #expect(body.messages == [ChatMessage(.user, "Transcript")])
        #expect(body.maxTokens == 2_000 && body.stream == true)
    }

    @Test("a stream that closes with no stop_reason and no message_stop fails as cut off instead of finishing")
    func closesUnfinished() async {
        let server = StubServer(.init(body: Data("""
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half"}}


            """.utf8)))
        let provider = AnthropicProvider(apiKey: "sk-ant-test", baseURL: server.url(), session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("Half")])
        #expect(outcome.error == .unreachable)
    }

    @Test("a refusal stop is an error, not a clean stop")
    func refusal() async {
        let server = StubServer(.init(body: Data("""
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null}}

            event: message_stop
            data: {"type":"message_stop"}


            """.utf8)))
        let provider = AnthropicProvider(apiKey: "sk-ant-test", baseURL: server.url(), session: server.session)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas == [.text("I")])
        #expect(outcome.error?.code == "refused")
    }

    @Test("an overloaded_error event maps to .rateLimited")
    func overloaded() async {
        let server = StubServer(.init(body: Data("""
            event: error
            data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}


            """.utf8)))
        var policy = ProviderPolicy.cloud
        policy.backoff = []
        let provider = AnthropicProvider(apiKey: "sk-ant-test", baseURL: server.url(), session: server.session, policy: policy)

        let outcome = await Outcome(provider.stream(chat))

        #expect(outcome.deltas.isEmpty)
        #expect(outcome.error == .rateLimited(retryAfter: nil))
    }

    @Test("models() decodes the list, names /v1 once, and asks for every model in one page", arguments: ["", "/v1", "/v1/messages"])
    func models(basePath: String) async throws {
        let server = StubServer(.init(body: Data(
            #"{"data":[{"type":"model","id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5"}],"has_more":false}"#.utf8)))
        let provider = AnthropicProvider(apiKey: "sk-ant-test", baseURL: server.url(basePath), session: server.session)

        #expect(try await provider.models() == [ModelInfo(id: "claude-sonnet-4-5")])
        let request = try #require(server.requests.first)
        #expect(request.url?.path() == "/v1/models")
        #expect(request.url?.query() == "limit=1000")
    }
}

/// Without a content type, URLSession holds the response back to sniff the first 512 bytes.
let eventStream = ["content-type": "text/event-stream"]

func sse(_ payloads: String...) -> Data {
    Data(payloads.map { "data: \($0)\n\n" }.joined().utf8)
}

func content(_ text: String) -> String {
    #"{"choices":[{"index":0,"delta":{"content":"\#(text)"},"finish_reason":null}]}"#
}

struct Outcome {
    var deltas: [ChatDelta] = []
    var error: ProviderError?

    init(_ stream: AsyncThrowingStream<ChatDelta, any Error>) async {
        do {
            for try await delta in stream { deltas.append(delta) }
        } catch let error as ProviderError {
            self.error = error
        } catch {
            Issue.record(error, "a provider stream throws only ProviderError")
        }
    }

    var text: String {
        deltas.map { if case .text(let piece) = $0 { piece } else { "" } }.joined()
    }
}

private struct SentBody: Decodable {
    var model: String
    var system: String?
    var messages: [ChatMessage]?
    var input: [String]?
    var maxTokens: Int?
    var maxCompletionTokens: Int?
    var reasoningEffort: String?
    var temperature: Double?
    var stream: Bool?

    init(_ request: URLRequest) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self = try decoder.decode(Self.self, from: request.httpBody ?? Data())
    }
}

/// Every test gets its own host, so tests can run in parallel against one shared stub.
struct StubServer {
    let host: String
    let session: URLSession

    init(host: String = "\(UUID().uuidString.lowercased()).test", _ replies: Stub.Reply...) {
        self.host = host
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        session = URLSession(configuration: configuration)
        Stub.serve(replies, at: host)
    }

    var requests: [URLRequest] { Stub.requests(to: host) }

    func url(_ path: String = "", scheme: String = "https") -> URL {
        URL(string: "\(scheme)://\(host)\(path)")!
    }
}

/// URLProtocol predates Sendable. The stub sends a reply's later pieces in order from one task.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Answers each request with the host's next reply. The last reply repeats.
final class Stub: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Sent one at a time after `body`, `interval` apart, before the reply closes.
        var later: [Data] = []
        var interval: Duration = .milliseconds(100)
        var closes = true
    }

    private struct Route {
        var replies: [Reply]
        var requests: [URLRequest] = []
    }

    private static let routes = Mutex<[String: Route]>([:])

    static func serve(_ replies: [Reply], at host: String) {
        routes.withLock { $0[host] = Route(replies: replies) }
    }

    static func requests(to host: String) -> [URLRequest] {
        routes.withLock { $0[host]?.requests ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.take(request),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        guard !reply.later.isEmpty else {
            if reply.closes { client?.urlProtocolDidFinishLoading(self) }
            return
        }
        let loader = Unchecked(value: self)
        Task {
            for piece in reply.later {
                try? await Task.sleep(for: reply.interval)
                loader.value.client?.urlProtocol(loader.value, didLoad: piece)
            }
            if reply.closes { loader.value.client?.urlProtocolDidFinishLoading(loader.value) }
        }
    }

    override func stopLoading() {}

    private static func take(_ request: URLRequest) -> Reply? {
        var seen = request
        seen.httpBody = request.httpBodyStream.map(readAll)
        return routes.withLock { routes in
            guard let host = request.url?.host(), var route = routes[host], let reply = route.replies.first else { return nil }
            route.requests.append(seen)
            if route.replies.count > 1 { route.replies.removeFirst() }
            routes[host] = route
            return reply
        }
    }

    /// URLSession hands a protocol the body as a stream, never as `httpBody`.
    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
            data.append(buffer, count: count)
        }
        return data
    }
}
