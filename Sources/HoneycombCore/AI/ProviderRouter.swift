import Foundation
import Synchronization

public enum RouteError: Error, Equatable, Sendable {
    /// No route is stored for the task: the user hasn't made the "Ask once" AI choice yet.
    case notChosen
}

/// Picks the provider and model for each task from the stored `route` and `provider` rows.
/// API keys come from Keychain by `keyRef`, never from SQLite.
public struct ProviderRouter: Sendable {
    let database: AppDatabase
    let keychain: any SecretStore
    let builtIn: BuiltInLLM
    let session: URLSession
    private let gates = RequestGates()

    public init(database: AppDatabase, keychain: any SecretStore, builtIn: BuiltInLLM, session: URLSession = .shared) {
        self.database = database
        self.keychain = keychain
        self.builtIn = builtIn
        self.session = session
    }

    public func resolve(_ task: AITask) throws -> ResolvedProvider {
        guard let route = try database.route(task), let record = try database.provider(route.providerId) else {
            throw RouteError.notChosen
        }
        return ResolvedProvider(record: record, model: route.model, provider: try adapter(for: record))
    }

    /// The adapter for a saved provider, with its key from Keychain.
    public func adapter(for record: ProviderRecord) throws -> any ChatProvider {
        try adapter(for: record, apiKey: record.keyRef.flatMap { keychain.get(account: $0) })
    }

    /// The adapter for a provider that may not be saved yet, for "Test connection".
    public func adapter(for record: ProviderRecord, apiKey: String?) throws -> any ChatProvider {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch record.kind {
        case .builtin:
            return BuiltInProvider(llm: builtIn)
        case .openAICompatible:
            let url = try ProviderURLPolicy.parse(record.baseUrl ?? "")
            return OpenAICompatibleProvider(baseURL: url, apiKey: key, isLocal: record.isLocal, session: session,
                                            gate: gates.gate(for: record.id))
        case .anthropic:
            guard let key else { throw ProviderError.unauthorized }
            let gate = gates.gate(for: record.id)
            guard let baseUrl = record.baseUrl else { return AnthropicProvider(apiKey: key, session: session, gate: gate) }
            return AnthropicProvider(apiKey: key, baseURL: try ProviderURLPolicy.parse(baseUrl), session: session, gate: gate)
        }
    }

    /// Saves a new provider. Its key goes to Keychain, and SQLite keeps only the account name.
    public func save(_ draft: ProviderDraft) throws -> ProviderRecord {
        let record = try draft.record()
        if let keyRef = record.keyRef { try keychain.set(draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: keyRef) }
        do {
            try database.saveProvider(record)
        } catch {
            if let keyRef = record.keyRef { keychain.delete(account: keyRef) }
            throw error
        }
        return record
    }

    /// Removes a provider, its key, and the routes that used it. The built-in provider stays.
    public func delete(_ record: ProviderRecord) throws {
        guard record.kind != .builtin else { return }
        try database.deleteProvider(record.id)
        if let keyRef = record.keyRef { keychain.delete(account: keyRef) }
    }
}

/// One gate per provider id. The router builds a new adapter for every call, so the gate has to
/// outlive the adapters for "one request at a time per provider" to hold.
final class RequestGates: Sendable {
    private let gates = Mutex<[String: RequestGate]>([:])

    func gate(for providerID: String) -> RequestGate {
        gates.withLock { gates in
            if let gate = gates[providerID] { return gate }
            let gate = RequestGate()
            gates[providerID] = gate
            return gate
        }
    }
}

extension ProviderRecord {
    /// Qwen inside Honeycomb. Seeded at launch, and never deleted.
    public static let builtIn = ProviderRecord(id: "builtin", name: "Built-in", kind: .builtin,
                                               contextTokens: BuiltInProvider.contextTokens, isLocal: true)
}

/// What the "Add provider" form collects before it is saved.
public struct ProviderDraft: Sendable, Equatable {
    public var name: String
    public var kind: ProviderKind
    public var baseURL: String
    public var apiKey: String
    public var contextTokens: Int

    public init(name: String, kind: ProviderKind, baseURL: String, apiKey: String = "", contextTokens: Int) {
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.contextTokens = contextTokens
    }

    /// Checks the address and builds the row to save. Loopback and private hosts are Local.
    public func record(id: String = UUID().uuidString) throws(ProviderError) -> ProviderRecord {
        let url = try ProviderURLPolicy.parse(baseURL)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? url.host(percentEncoded: false) ?? "Provider"
        let hasKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
        return ProviderRecord(id: id, name: name, kind: kind, baseUrl: url.absoluteString, keyRef: hasKey ? id : nil,
                              contextTokens: contextTokens, isLocal: ProviderURLPolicy.isLocal(url))
    }
}

extension ProviderURLPolicy {
    /// Reads a typed base URL. Plain http to a public address fails with `.insecureURL`, and an
    /// address with no host fails with `.invalidURL`.
    public static func parse(_ text: String) throws(ProviderError) -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host(percentEncoded: false)?.isEmpty == false else { throw .invalidURL }
        do {
            try check(url)
        } catch {
            throw .insecureURL
        }
        return url
    }

    public static func isLocal(_ url: URL) -> Bool {
        isPrivate(host: url.host(percentEncoded: false) ?? "")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
