import AVFoundation

// Plays a 1 kHz tone for 1.5 seconds. It is a separate process because the tap excludes Honeycomb's own audio.
let sampleRate = 48_000.0
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
let frames = AVAudioFrameCount(sampleRate * 1.5)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
buffer.frameLength = frames
let samples = buffer.floatChannelData![0]
for i in 0..<Int(frames) {
    samples[i] = 0.2 * sin(2 * .pi * 1000 * Float(i) / Float(sampleRate))
}

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: format)
do {
    try engine.start()
} catch {
    FileHandle.standardError.write(Data("ToneHelper: could not start audio: \(error)\n".utf8))
    exit(1)
}
player.scheduleBuffer(buffer, at: nil)
player.play()
DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
dispatchMain()
