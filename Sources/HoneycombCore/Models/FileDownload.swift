import CryptoKit
import Foundation

public enum DownloadError: Error, Equatable, Sendable {
    case http(Int)
    case checksumMismatch(String)
    case sizeMismatch(String)
    case lowDisk(neededBytes: Int64)
}

/// Downloads one file to disk with HTTP range requests, so a dropped connection or an app
/// restart continues from the bytes already on disk.
final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var received: Int64 = 0
    private var progress: (@Sendable (Int64) -> Void)?
    private var failure: Error?

    /// Appends to `file` from its current size up to `expectedSize`.
    static func fetch(_ url: URL, to file: URL, expectedSize: Int64,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing = (try? manager.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        if existing > expectedSize {
            try manager.removeItem(at: file)
            existing = 0
        }
        if existing == expectedSize { return }
        if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }

        let delegate = FileDownload()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(existing))
        delegate.handle = handle
        delegate.received = existing
        delegate.progress = progress
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
            try? handle.close()
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.lock()
        defer { lock.unlock() }
        switch status {
        case 206:
            completionHandler(.allow)
        case 200:
            // The server ignored the range, so start the file over.
            try? handle?.truncate(atOffset: 0)
            received = 0
            completionHandler(.allow)
        default:
            failure = DownloadError.http(status)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
        } catch {
            failure = error
            dataTask.cancel()
        }
        let total = received
        let progress = self.progress
        lock.unlock()
        progress?(total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result = failure ?? error
        lock.unlock()
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
