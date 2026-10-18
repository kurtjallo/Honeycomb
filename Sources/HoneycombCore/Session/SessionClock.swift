import Darwin

/// Milliseconds since the recording started, from the monotonic host clock.
/// Changing the wall clock during a call can't shift a track.
public struct SessionClock: Sendable {
    public let startHostTime: UInt64
    private let numer: UInt64
    private let denom: UInt64

    public init(startHostTime: UInt64 = mach_absolute_time()) {
        self.startHostTime = startHostTime
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numer = UInt64(info.numer)
        denom = UInt64(info.denom)
    }

    public func offsetMs(hostTime: UInt64) -> Int64 {
        let delta = Int64(bitPattern: hostTime &- startHostTime)
        return delta * Int64(numer) / Int64(denom) / 1_000_000
    }

    public func nowMs() -> Int64 {
        offsetMs(hostTime: mach_absolute_time())
    }
}
