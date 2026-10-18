@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Apple's on-device speech engine, used while Parakeet is still downloading on first launch.
public actor AppleSpeechEngine: TranscriptionEngine {
    public nonisolated let engineID = "apple"
    private var locale = Locale(identifier: "en-US")
    private var format: AVAudioFormat?

    public init() {}

    public func prepare() async throws {
        locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) ?? locale
        let transcriber = makeTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    public func transcribe(_ samples: [Float]) async throws -> TranscriptPiece {
        guard !samples.isEmpty else { return TranscriptPiece(text: "", words: []) }
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let buffer = try convert(samples)
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        let collector = Task { () throws -> [SpeechTranscriber.Result] in
            var results: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results { results.append(result) }
            return results
        }
        _ = try await analyzer.analyzeSequence(input)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let results = try await collector.value

        var words: [TimedWord] = []
        var texts: [String] = []
        for result in results {
            texts.append(String(result.text.characters))
            for run in result.text.runs {
                guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
                let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                words.append(TimedWord(text, Int64(range.start.seconds * 1000), Int64(range.end.seconds * 1000)))
            }
        }
        let text = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptPiece(text: text, words: words)
    }

    public func release() async {}

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    private func convert(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let format, format != source, let converter = AVAudioConverter(from: source, to: format) else { return input }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16_000 + 1_024)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let pending = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return pending
        }
        if let error { throw error }
        return output
    }
}
