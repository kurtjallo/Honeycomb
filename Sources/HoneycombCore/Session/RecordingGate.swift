import Synchronization

public final class RecordingGate: Sendable {
    private let recording = Mutex(false)

    public init() {}

    public var isRecording: Bool { recording.withLock { $0 } }

    public func set(_ value: Bool) {
        recording.withLock { $0 = value }
    }
}
