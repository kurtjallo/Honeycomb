import Foundation
import Synchronization

/// Plain `http` is allowed only where traffic stays on this Mac or the local network, so keys and
/// transcripts never cross the internet unencrypted.
public enum ProviderURLPolicy {
    public static func check(_ url: URL) throws {
        switch url.scheme?.lowercased() {
        case "https": return
        case "http" where isPrivate(host: url.host(percentEncoded: false) ?? ""): return
        default: throw ProviderError.insecureURL
        }
    }

    static func isPrivate(host: String) -> Bool {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if let bytes = address(host, family: AF_INET, size: 4) {
            switch (bytes[0], bytes[1]) {
            case (127, _), (10, _), (172, 16...31), (192, 168), (169, 254): return true
            default: return false
            }
        }
        if let bytes = address(host, family: AF_INET6, size: 16) {
            return bytes == [UInt8](repeating: 0, count: 15) + [1] || bytes[0] & 0xFE == 0xFC
        }
        return false
    }

    private static func address(_ host: String, family: Int32, size: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: size)
        return inet_pton(family, host, &bytes) == 1 ? bytes : nil
    }
}

/// Timeouts and retries for one provider. Local servers get longer to start answering because they
/// may have to load the model and read a long transcript first.
public struct ProviderPolicy: Sendable, Equatable {
    public var connect: Duration = .seconds(10)
    public var firstToken: Duration
    public var silence: Duration = .seconds(60)
    public var backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    public var longestRetryAfter: Duration = .seconds(30)

    public init(firstToken: Duration) {
        self.firstToken = firstToken
    }

    public static let local = ProviderPolicy(firstToken: .seconds(120))
    public static let cloud = ProviderPolicy(firstToken: .seconds(60))

    /// The wait before the next try, or nil to give up. Only rate limits and server failures are
    /// retried here: a timeout has already used its whole budget, and the job queue retries network
    /// errors later, so retrying those here too would only stack the waits.
    func retryWait(after error: ProviderError, retries: Int) -> Duration? {
        guard retries < backoff.count else { return nil }
        switch error {
        case .rateLimited(let retryAfter?): return min(.seconds(max(retryAfter, 0)), longestRetryAfter)
        case .rateLimited, .server: return backoff[retries]
        default: return nil
        }
    }
}

extension ProviderError {
    /// Maps a failed HTTP response. Servers often report a too-long prompt only in the body of a 400.
    /// An empty account comes as Anthropic's 400 "credit balance is too low", OpenAI's 429
    /// `insufficient_quota`, or OpenRouter's 402, and must not be retried as a rate limit.
    static func from(status: Int, retryAfter: TimeInterval?, body: String) -> ProviderError {
        let body = body.lowercased()
        if creditPhrases.contains(where: { body.contains($0) }) { return .outOfCredit }
        switch status {
        case 401, 403: return .unauthorized
        case 402: return .outOfCredit
        case 404: return .modelNotFound
        case 413: return .contextTooLong
        case 429, 529: return .rateLimited(retryAfter: retryAfter)
        default: break
        }
        if contextLimitPhrases.contains(where: { body.contains($0) }) { return .contextTooLong }
        if body.contains("overloaded_error") { return .rateLimited(retryAfter: retryAfter) }
        switch status {
        case 400..<500: return .badRequest
        case 500..<600: return .server(status: status)
        default: return .invalidResponse
        }
    }

    private static let contextLimitPhrases = ["context length", "context_length", "maximum context", "context window", "too long"]
    private static let creditPhrases = ["credit balance", "insufficient_quota"]

    /// Every failure leaves a provider as a `ProviderError`, so the UI has one message per case.
    init(_ error: any Error) {
        switch error {
        case let error as ProviderError: self = error
        case is CancellationError: self = .cancelled
        case let error as URLError:
            switch error.code {
            case .cancelled: self = .cancelled
            case .timedOut: self = .timedOut
            case .appTransportSecurityRequiresSecureConnection: self = .insecureURL
            case .userAuthenticationRequired: self = .unauthorized
            case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData:
                self = .invalidResponse
            default: self = .unreachable
            }
        default: self = .invalidResponse
        }
    }
}

/// An error object inside a response body or stream: OpenAI's `{"message", "type", "code"}`,
/// Anthropic's `{"type", "message"}`, or Ollama's plain string.
struct ProviderWireError: Decodable {
    var type: String?
    var code: String?
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case type, code, message
    }

    init(from decoder: any Decoder) throws {
        if let message = try? decoder.singleValueContainer().decode(String.self) {
            self.message = message
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decode(String.self, forKey: .type)
        message = try? container.decode(String.self, forKey: .message)
        code = (try? container.decode(String.self, forKey: .code))
            ?? (try? container.decode(Int.self, forKey: .code)).map(String.init)
    }

    /// An error with no status or known name is treated as a server failure.
    var providerError: ProviderError {
        let status = code.flatMap { Int($0) }
            ?? code.flatMap { Self.statusByName[$0] }
            ?? type.flatMap { Self.statusByName[$0] }
            ?? 500
        return .from(status: status, retryAfter: nil, body: [type, code, message].compactMap { $0 }.joined(separator: " "))
    }

    /// The HTTP status each named error stands for in the OpenAI and Anthropic APIs.
    private static let statusByName: [String: Int] = [
        "invalid_request_error": 400,
        "authentication_error": 401,
        "invalid_api_key": 401,
        "permission_error": 403,
        "not_found_error": 404,
        "model_not_found": 404,
        "request_too_large": 413,
        "context_length_exceeded": 413,
        "rate_limit_error": 429,
        "rate_limit_exceeded": 429,
        "api_error": 500,
        "server_error": 500,
        "overloaded_error": 529,
    ]
}

struct SSEEvent: Sendable, Equatable {
    var event: String?
    var data: String
}

/// Reads server-sent events one byte or one line at a time.
struct SSEParser {
    private var line: [UInt8] = []
    private var afterCarriageReturn = false
    private var name: String?
    private var data: String?

    mutating func feed(_ byte: UInt8) -> SSEEvent? {
        switch byte {
        case UInt8(ascii: "\n") where afterCarriageReturn:
            afterCarriageReturn = false
            return nil
        case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
            afterCarriageReturn = byte == UInt8(ascii: "\r")
            defer { line.removeAll(keepingCapacity: true) }
            return feed(line: String(decoding: line, as: UTF8.self))
        default:
            afterCarriageReturn = false
            line.append(byte)
            return nil
        }
    }

    mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let colon = line.firstIndex(of: ":") ?? line.endIndex
        var value = colon == line.endIndex ? "" : line[line.index(after: colon)...]
        if value.hasPrefix(" ") { value = value.dropFirst() }
        switch line[..<colon] {
        case "data": data = data.map { $0 + "\n" + value } ?? String(value)
        case "event": name = String(value)
        default: break
        }
        return nil
    }

    /// The SSE spec drops an event that the stream ends before dispatching. Servers that skip the
    /// final blank line would then lose their last chunk, so it is dispatched instead.
    mutating func finish() -> SSEEvent? {
        if !line.isEmpty {
            _ = feed(line: String(decoding: line, as: UTF8.self))
            line.removeAll()
        }
        return dispatch()
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            name = nil
            data = nil
        }
        return data.map { SSEEvent(event: name, data: $0) }
    }
}

/// Server-sent events read from a byte stream such as `URLSession.AsyncBytes`.
struct ServerSentEvents<Bytes: AsyncSequence>: AsyncSequence where Bytes.Element == UInt8 {
    let bytes: Bytes

    func makeAsyncIterator() -> Iterator {
        Iterator(bytes: bytes.makeAsyncIterator())
    }

    struct Iterator: AsyncIteratorProtocol {
        var bytes: Bytes.AsyncIterator
        var parser = SSEParser()
        var ended = false

        mutating func next() async throws -> SSEEvent? {
            while !ended {
                guard let byte = try await bytes.next() else {
                    ended = true
                    return parser.finish()
                }
                if let event = parser.feed(byte) { return event }
            }
            return nil
        }
    }
}

/// Removes `<think>...</think>` blocks from streamed text, even when a tag is split across pieces.
/// Text inside a block is never shown, so a stream that ends mid-thought yields nothing from it.
///
/// Some Qwen3 templates put `<think>` in the prompt, so the reply has only the closing tag. A bare
/// `</think>` that comes before any visible text is dropped. After visible text it is kept as
/// text: what was shown can't be taken back, and the answer may be quoting the tag.
struct ThinkFilter: Sendable {
    private static let open = "<think>"
    private static let close = "</think>"
    private var held = ""
    private var thinking = false
    private var started = false
    private var sawTag = false

    mutating func feed(_ text: String) -> String {
        var rest = held + text
        var shown = ""
        if !started, !sawTag {
            let body = rest.drop(while: \.isWhitespace)
            if body.hasPrefix(Self.close) {
                rest = String(body.dropFirst(Self.close.count))
                sawTag = true
            } else if !body.isEmpty, Self.close.hasPrefix(body) {
                held = String(body)
                return ""
            }
        }
        while true {
            let tag = thinking ? Self.close : Self.open
            if let range = rest.range(of: tag) {
                if !thinking { shown += visible(rest[..<range.lowerBound]) }
                rest = String(rest[range.upperBound...])
                thinking.toggle()
                sawTag = true
            } else {
                let partial = Self.partialTagLength(rest, tag)
                if !thinking { shown += visible(rest.dropLast(partial)) }
                held = String(rest.suffix(partial))
                return shown
            }
        }
    }

    mutating func finish() -> String {
        defer {
            held = ""
            thinking = false
        }
        return thinking ? "" : visible(held[...])
    }

    /// Drops whitespace before the first visible text, so an answer doesn't open with the blank
    /// lines that follow `</think>`.
    private mutating func visible(_ text: Substring) -> String {
        if started { return String(text) }
        let trimmed = text.drop(while: \.isWhitespace)
        started = !trimmed.isEmpty
        return String(trimmed)
    }

    /// The length of the longest end of `text` that could be the start of `tag`.
    private static func partialTagLength(_ text: String, _ tag: String) -> Int {
        for length in stride(from: min(tag.count - 1, text.count), to: 0, by: -1) where text.hasSuffix(tag.prefix(length)) {
            return length
        }
        return 0
    }
}

/// Lets one request at a time reach a provider. Later requests wait in order, and a cancelled
/// waiter leaves the line at once.
public actor RequestGate {
    private var busy = false
    private var waiting: [(id: UUID, turn: CheckedContinuation<Void, any Error>)] = []

    public init() {}

    nonisolated func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    func acquire() async throws {
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().turn.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).turn.resume(throwing: CancellationError())
    }
}

/// Which timeout applies to one attempt right now.
struct AttemptClock: Sendable {
    enum Phase: Sendable, Equatable {
        /// Ends when the request body has been sent, not when headers arrive: local servers send
        /// headers only with the first token, which can take minutes.
        case connecting
        case waiting
        case streaming(lastEvent: ContinuousClock.Instant)
    }

    let start: ContinuousClock.Instant
    var phase = Phase.connecting
    var sentText = false

    func deadline(_ policy: ProviderPolicy) -> ContinuousClock.Instant {
        switch phase {
        case .connecting: start + min(policy.connect, policy.firstToken)
        case .waiting: start + policy.firstToken
        case .streaming(let lastEvent): lastEvent + policy.silence
        }
    }

    mutating func connected() {
        if phase == .connecting { phase = .waiting }
    }

    mutating func received(at now: ContinuousClock.Instant) {
        phase = .streaming(lastEvent: now)
    }
}

/// Shares one attempt's clock between the request, its URLSession task, and the watchdog.
final class AttemptTracker: NSObject, URLSessionTaskDelegate, Sendable {
    private let policy: ProviderPolicy
    private let clock: Mutex<AttemptClock>

    init(_ policy: ProviderPolicy) {
        self.policy = policy
        clock = Mutex(AttemptClock(start: .now))
        super.init()
    }

    var hasSentText: Bool { clock.withLock { $0.sentText } }
    func connected() { clock.withLock { $0.connected() } }
    func receivedEvent() { clock.withLock { $0.received(at: .now) } }
    func sentText() { clock.withLock { $0.sentText = true } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        connected()
    }

    /// Runs `body`, or fails with `.timedOut` if a deadline passes first.
    func watch<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await body() }
            group.addTask {
                try await self.sleepPastDeadline()
                return nil
            }
            guard let value = try await group.next() ?? nil else { throw ProviderError.timedOut }
            return value
        }
    }

    private func sleepPastDeadline() async throws {
        while true {
            let deadline = clock.withLock { $0.deadline(policy) }
            let now = ContinuousClock.now
            guard deadline > now else { return }
            // An event can move the deadline earlier, but never to less than `silence` from now.
            try await Task.sleep(until: min(deadline, now + policy.silence), clock: .continuous)
        }
    }
}

/// Turns one provider's server-sent events into deltas. Each attempt starts a fresh decoder.
protocol ChatStreamDecoder: Sendable {
    init()
    /// A `.finished` delta ends the stream.
    mutating func decode(_ event: SSEEvent) throws -> [ChatDelta]
    /// The deltas to send when the server closes the stream. They end with `.finished` only if the
    /// server said why the answer stopped.
    mutating func end() -> [ChatDelta]
}

/// The HTTP side that every remote provider shares: URL policy, one request at a time, timeouts,
/// retries, and error mapping. Everything it throws is a `ProviderError`.
struct ProviderTransport: Sendable {
    let session: URLSession
    let policy: ProviderPolicy
    let gate: RequestGate

    init(session: URLSession, policy: ProviderPolicy, gate: RequestGate) {
        self.session = session
        self.policy = policy
        self.gate = gate
    }

    func stream<D: ChatStreamDecoder>(_ url: URL, headers: [String: String], json body: any Encodable & Sendable,
                                      decoder: D.Type) -> AsyncThrowingStream<ChatDelta, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(url, headers: headers, json: body)
                    try await gate.run {
                        try await withRetries { tracker in
                            try await pump(request, as: D.self, tracker: tracker, into: continuation)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ProviderError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `waitsForTurn` is false for quick lookups such as the model list, so they don't queue
    /// behind a long answer.
    func data(_ url: URL, headers: [String: String], json body: (any Encodable & Sendable)? = nil,
              waitsForTurn: Bool) async throws -> Data {
        do {
            let request = try makeRequest(url, headers: headers, json: body)
            let fetch: @Sendable () async throws -> Data = {
                try await withRetries { tracker in
                    var data = Data()
                    for try await byte in try await open(request, tracker: tracker) { data.append(byte) }
                    return data
                }
            }
            return try await waitsForTurn ? gate.run(fetch) : fetch()
        } catch {
            throw ProviderError(error)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(ProviderError) -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw .invalidResponse
        }
    }

    private func makeRequest(_ url: URL, headers: [String: String], json body: (any Encodable)?) throws -> URLRequest {
        try ProviderURLPolicy.check(url)
        // The watchdog enforces the real deadlines. URLSession's idle timer must not fire first.
        var request = URLRequest(url: url, timeoutInterval: max(policy.firstToken, policy.silence).timeInterval)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpMethod = "POST"
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        return request
    }

    private func withRetries<T: Sendable>(_ attempt: @escaping @Sendable (AttemptTracker) async throws -> T) async throws -> T {
        var retries = 0
        while true {
            let tracker = AttemptTracker(policy)
            do {
                return try await tracker.watch { try await attempt(tracker) }
            } catch {
                let failure = ProviderError(error)
                guard !tracker.hasSentText, let wait = policy.retryWait(after: failure, retries: retries) else { throw failure }
                retries += 1
                Log.info("provider_retry", ["attempt": .int(retries), "wait": .seconds(wait)])
                try await Task.sleep(for: wait)
            }
        }
    }

    private func open(_ request: URLRequest, tracker: AttemptTracker) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request, delegate: tracker)
        tracker.connected()
        guard let response = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if (200..<300).contains(response.statusCode) { return bytes }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= 65_536 { break }
        }
        let retryAfter = response.value(forHTTPHeaderField: "retry-after")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        throw ProviderError.from(status: response.statusCode, retryAfter: retryAfter, body: String(decoding: body, as: UTF8.self))
    }

    private func pump<D: ChatStreamDecoder>(_ request: URLRequest, as _: D.Type, tracker: AttemptTracker,
                                           into continuation: AsyncThrowingStream<ChatDelta, any Error>.Continuation) async throws {
        var decoder = D()
        var sawEvent = false
        // Every line counts as life, comments included: OpenRouter sends only ": OPENROUTER PROCESSING"
        // while a reasoning model thinks, and other servers send ": ping".
        let bytes = try await open(request, tracker: tracker).map { byte in
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") { tracker.receivedEvent() }
            return byte
        }
        for try await event in ServerSentEvents(bytes: bytes) {
            sawEvent = true
            if send(try decoder.decode(event), to: continuation, tracker: tracker) { return }
        }
        // A 200 with no events at all would otherwise read as an empty answer.
        guard sawEvent else { throw ProviderError.invalidResponse }
        // A stream closed before the server said it was done was cut off, like a dropped connection.
        guard send(decoder.end(), to: continuation, tracker: tracker) else { throw ProviderError.unreachable }
    }

    /// Returns true once the stream has finished.
    private func send(_ deltas: [ChatDelta], to continuation: AsyncThrowingStream<ChatDelta, any Error>.Continuation,
                      tracker: AttemptTracker) -> Bool {
        for delta in deltas {
            switch delta {
            case .text(let text):
                if text.isEmpty { continue }
                tracker.sentText()
                continuation.yield(delta)
            case .finished:
                continuation.yield(delta)
                return true
            }
        }
        return false
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
