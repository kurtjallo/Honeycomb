import Foundation

/// Owns every model download. FluidAudio and MLX only ever load from folders this store
/// finished and verified, so their own downloaders never run.
public actor ModelStore {
    public enum State: Sendable, Equatable {
        case missing
        case downloading(received: Int64, total: Int64)
        case waitingForNetwork(received: Int64, total: Int64)
        case verifying
        case ready
        case failed(String)
    }

    public nonisolated let updates: AsyncStream<[String: State]>
    private let continuation: AsyncStream<[String: State]>.Continuation
    private let root: URL
    private let database: AppDatabase?
    private let freeBytes: @Sendable () -> Int64
    private var states: [String: State] = [:]
    private var installs: [String: Task<Void, Error>] = [:]

    public init(root: URL, database: AppDatabase?,
                freeBytes: (@Sendable () -> Int64)? = nil) {
        self.root = root
        self.database = database
        self.freeBytes = freeBytes ?? { DiskSpace.available(at: root) }
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        for spec in ModelCatalog.all {
            let ready = FileManager.default.fileExists(atPath: root.appendingPathComponent(spec.folderName).path)
            states[spec.id] = ready ? .ready : .missing
        }
    }

    public func state(_ id: String) -> State { states[id] ?? .missing }
    public var allStates: [String: State] { states }

    /// The verified folder of a ready model, or nil.
    public func folder(_ id: String) -> URL? {
        guard let spec = ModelCatalog.spec(id), states[id] == .ready else { return nil }
        return root.appendingPathComponent(spec.folderName)
    }

    public func isReady(_ id: String) -> Bool { states[id] == .ready }

    /// Downloads a model if needed. Safe to call again: a running install is joined, not repeated.
    public func install(_ id: String) async throws {
        guard let spec = ModelCatalog.spec(id) else { return }
        if states[id] == .ready { return }
        if let running = installs[id] { return try await running.value }
        let task = Task { try await self.download(spec) }
        installs[id] = task
        defer { installs[id] = nil }
        do {
            try await task.value
        } catch {
            if !(error is CancellationError) { set(id, .failed(Self.code(for: error))) }
            throw error
        }
    }

    public func cancel(_ id: String) {
        installs[id]?.cancel()
    }

    public func delete(_ id: String) throws {
        guard let spec = ModelCatalog.spec(id) else { return }
        installs[id]?.cancel()
        let manager = FileManager.default
        try? manager.removeItem(at: root.appendingPathComponent(spec.folderName))
        try? manager.removeItem(at: root.appendingPathComponent(spec.folderName + ".partial"))
        try database?.deleteModel(id)
        set(id, .missing)
    }

    private func download(_ spec: ModelSpec) async throws {
        let manager = FileManager.default
        let partial = root.appendingPathComponent(spec.folderName + ".partial")
        let final = root.appendingPathComponent(spec.folderName)
        try manager.createDirectory(at: partial, withIntermediateDirectories: true)

        let onDisk = spec.files.reduce(Int64(0)) { sum, file in
            sum + ((try? manager.attributesOfItem(atPath: partial.appendingPathComponent(file.path).path)[.size] as? Int64) ?? 0)
        }
        let needed = Int64(Double(spec.totalBytes - onDisk) * 1.2) + 2 * 1024 * 1024 * 1024
        guard freeBytes() >= needed else { throw DownloadError.lowDisk(neededBytes: needed) }

        Log.info("model.download_started", ["bytes": .int(spec.totalBytes)])
        var completed: Int64 = 0
        set(spec.id, .downloading(received: onDisk, total: spec.totalBytes))
        for file in spec.files {
            let target = partial.appendingPathComponent(file.path)
            try await fetchVerified(file, of: spec, to: target, completedBefore: completed)
            completed += file.size
        }
        set(spec.id, .verifying)
        try? manager.removeItem(at: final)
        try manager.moveItem(at: partial, to: final)
        try database?.saveModel(ModelRecord(id: spec.id, kind: spec.kind, revision: spec.revision, path: spec.folderName,
                                            sizeBytes: spec.totalBytes, sha256: nil, status: .ready))
        set(spec.id, .ready)
        Log.info("model.download_finished")
    }

    /// Retries network failures with growing waits, so a download resumes when Wi-Fi comes back.
    /// A checksum mismatch deletes the file and fails, because retrying would fetch the same bytes.
    private func fetchVerified(_ file: ModelFile, of spec: ModelSpec, to target: URL, completedBefore: Int64) async throws {
        var failures = 0
        while true {
            try Task.checkCancellation()
            do {
                let id = spec.id
                let total = spec.totalBytes
                try await FileDownload.fetch(spec.url(for: file), to: target, expectedSize: file.size) { received in
                    Task { await self.set(id, .downloading(received: completedBefore + received, total: total)) }
                }
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard let wait = Self.retryWait(after: error, failures: failures) else { throw error }
                let received = completedBefore + ((try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0)
                set(spec.id, .waitingForNetwork(received: received, total: spec.totalBytes))
                Log.error("model.download_retry", ["attempt": .int(failures + 1)])
                try await Task.sleep(for: wait)
                failures += 1
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
        guard size == file.size else {
            try? FileManager.default.removeItem(at: target)
            throw DownloadError.sizeMismatch(file.path)
        }
        guard try FileDownload.sha256(of: target) == file.sha256 else {
            try? FileManager.default.removeItem(at: target)
            Log.error("model.checksum_mismatch")
            throw DownloadError.checksumMismatch(file.path)
        }
    }

    /// The wait before trying a failed file again, or nil to fail the install.
    static func retryWait(after error: any Error, failures: Int) -> Duration? {
        let waits: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(30)]
        if error is DownloadError { return nil }
        return waits[min(failures, waits.count - 1)]
    }

    private func set(_ id: String, _ state: State) {
        if case .downloading = state, case .ready = states[id] { return }
        states[id] = state
        continuation.yield(states)
    }

    static func code(for error: Error) -> String {
        switch error {
        case DownloadError.checksumMismatch: "checksum_mismatch"
        case DownloadError.sizeMismatch: "size_mismatch"
        case DownloadError.lowDisk: "low_disk"
        case DownloadError.http(let status): "http_\(status)"
        default: "download_failed"
        }
    }
}

extension AppDatabase {
    public func saveModel(_ record: ModelRecord) throws {
        try writer.write { try record.save($0) }
    }

    public func deleteModel(_ id: String) throws {
        _ = try writer.write { try ModelRecord.deleteOne($0, key: id) }
    }
}
