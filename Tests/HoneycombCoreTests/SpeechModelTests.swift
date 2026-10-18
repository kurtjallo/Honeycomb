import AVFoundation
import Foundation
import Testing
@testable import HoneycombCore

/// Real speech models on real (synthesized) speech. Needs the models from InstallModels.
/// Run with HONEYCOMB_MODEL_TESTS=1.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HONEYCOMB_MODEL_TESTS"] == "1"))
struct SpeechModelTests {
    static func folder(_ id: String) throws -> URL {
        let spec = try #require(ModelCatalog.spec(id))
        return Paths.standard.models.appendingPathComponent(spec.folderName)
    }

    /// Speaks `text` with macOS's built-in voice into 16 kHz mono samples.
    static func speak(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0 == " " }
    }

    @Test func parakeetTranscribesSpeech() async throws {
        let engine = ParakeetEngine(folder: try Self.folder(ModelCatalog.parakeet))
        let started = ContinuousClock.now
        try await engine.prepare()
        print("prepare took", ContinuousClock.now - started)
        let samples = try Self.speak("We would renew the contract if single sign on lands by the end of the first quarter.")
        let piece = try await engine.transcribe(samples)
        print("TRANSCRIPT:", piece.text)
        let text = Self.normalized(piece.text)
        #expect(text.contains("renew the contract"))
        #expect(text.contains("first quarter"))
        let words = try #require(piece.words.last)
        #expect(abs(words.endMs - Int64(samples.count) / 16) < 1_000)
        await engine.release()
    }

    @Test func voiceDetectorFindsSpeech() async throws {
        let detector = try VoiceDetector(folder: try Self.folder(ModelCatalog.vad))
        let speech = try Self.speak("Hello there. This is a test of the voice detector.")
        let silence = [Float](repeating: 0, count: 32_000)
        let ranges = try await detector.speechRanges(silence + speech + silence)
        print("RANGES:", ranges)
        #expect(!ranges.isEmpty)
        let first = try #require(ranges.first)
        #expect(abs(first.startMs - 2_000) < 600)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["HONEYCOMB_MODEL_TESTS"] == "1"))
struct AppleSpeechTests {
    @Test func appleEngineTranscribes() async throws {
        let engine = AppleSpeechEngine()
        try await engine.prepare()
        let piece = try await engine.transcribe(try SpeechModelTests.speak("Please send the pricing deck to Acme by Friday."))
        print("APPLE:", piece.text, piece.words.count)
        #expect(SpeechModelTests.normalized(piece.text).contains("pricing deck"))
    }
}
