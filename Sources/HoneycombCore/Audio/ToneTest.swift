import Foundation

/// Checks that system-audio permission really works. A denied tap still runs and delivers silence,
/// so Honeycomb plays a tone from a helper process and listens for it.
public enum ToneTest {
    public static func run(helper: URL, listenFor: Duration = .milliseconds(2_500)) async -> Bool {
        let recorder = SystemAudioRecorder()
        let sink = AudioSink(seconds: 5)
        do {
            _ = try recorder.start(into: sink) {}
        } catch {
            Log.error("tone_test.tap_failed")
            return false
        }
        defer { recorder.stop() }
        let process = Process()
        process.executableURL = helper
        do {
            try process.run()
        } catch {
            Log.error("tone_test.helper_failed")
            return false
        }
        var peak: Float = 0
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 48_000)
        defer { buffer.deallocate() }
        let deadline = ContinuousClock.now + listenFor
        while ContinuousClock.now < deadline, peak <= 0.01 {
            try? await Task.sleep(for: .milliseconds(100))
            let count = sink.ring.read(into: buffer, maxCount: 48_000)
            for index in 0..<count { peak = max(peak, abs(buffer[index])) }
        }
        Log.info("tone_test.done", ["heard": .bool(peak > 0.01)])
        return peak > 0.01
    }
}
