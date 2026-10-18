import Synchronization

/// "A recording holds the local models." The app writes it from the recording lifecycle; Pipeline
/// and ModelHost read it without an await, so a job can't be claimed between the write and the read.
public final class RecordingGate: Sendable {
    private let recording = Mutex(false)

    public init() {}

    public var isRecording: Bool { recording.withLock { $0 } }

    public func set(_ value: Bool) {
        recording.withLock { $0 = value }
    }
}
