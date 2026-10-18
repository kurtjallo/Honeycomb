/// Captures one channel. System audio, the mic, and the test replay recorder implement it.
/// The callback only copies samples into the sink. Everything else happens off the audio thread.
public protocol TrackRecorder: AnyObject, Sendable {
    var channel: Channel { get }
    /// Starts capturing into `sink` and returns the sample rate of the samples it delivers.
    /// `onRouteChange` fires when the recorder needs a restart, for example after a device change.
    func start(into sink: AudioSink, onRouteChange: @escaping @Sendable () -> Void) throws -> Double
    /// May block on Core Audio. The session calls it with a time limit.
    func stop()
}

public struct RecorderError: Error, CustomStringConvertible, Sendable {
    public let step: StaticString
    public let status: Int32

    public init(_ step: StaticString, _ status: Int32 = -1) {
        self.step = step
        self.status = status
    }

    public var description: String { "\(step) failed (\(status))" }
}
