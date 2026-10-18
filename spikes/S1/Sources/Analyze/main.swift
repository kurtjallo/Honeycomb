import AVFoundation

// Usage: swift run Analyze <session folder>
// Finds the loudest moment (a clap) in the first and second half of each track, lines the tracks up with
// timeline.json, and prints how far apart the claps land. Clap once near the start and once near the end.

struct Track {
    let samples: [Float]
    let sampleRate: Double
}

func load(_ url: URL) throws -> Track {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let channel = buffer.floatChannelData![0]
    return Track(samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
                 sampleRate: format.sampleRate)
}

func peakTime(_ track: Track, from: Double, to: Double) -> Double {
    let start = max(0, Int(from * track.sampleRate))
    let end = min(track.samples.count, Int(to * track.sampleRate))
    guard start < end else { return .nan }
    var best = start
    for i in start..<end where abs(track.samples[i]) > abs(track.samples[best]) { best = i }
    return Double(best) / track.sampleRate
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("Usage: swift run Analyze <session folder>")
    exit(1)
}
let folder = URL(fileURLWithPath: arguments[1])
let timelineData = try Data(contentsOf: folder.appendingPathComponent("timeline.json"))
let timeline = try JSONSerialization.jsonObject(with: timelineData) as! [String: Any]
guard let micStart = timeline["mic_first_host_seconds"] as? Double,
      let systemStart = timeline["system_first_host_seconds"] as? Double else {
    print("timeline.json is missing a start time")
    exit(1)
}

let mic = try load(folder.appendingPathComponent("mic.caf"))
let system = try load(folder.appendingPathComponent("system.caf"))
let micLength = Double(mic.samples.count) / mic.sampleRate
let systemLength = Double(system.samples.count) / system.sampleRate
print(String(format: "Mic: %.1f s at %.0f Hz. System: %.1f s at %.0f Hz.", micLength, mic.sampleRate,
             systemLength, system.sampleRate))
print(String(format: "System audio started %.3f s after the mic.", systemStart - micStart))

let shared = min(micLength, systemLength)
for (name, range) in [("First half", (0.0, shared / 2)), ("Second half", (shared / 2, shared))] {
    let micClap = micStart + peakTime(mic, from: range.0, to: range.1)
    let systemClap = systemStart + peakTime(system, from: range.0 - (systemStart - micStart),
                                            to: range.1 - (systemStart - micStart))
    print(String(format: "%@: loudest moment differs by %.1f ms between tracks", name, (systemClap - micClap) * 1000))
}
print("Pass: under 50 ms in each half, and the two numbers within 20 ms of each other (drift).")
