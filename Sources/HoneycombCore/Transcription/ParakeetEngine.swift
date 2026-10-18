@preconcurrency import CoreML
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B v2 on the Neural Engine, through FluidAudio, loaded only from the
/// folder ModelStore verified.
public actor ParakeetEngine: TranscriptionEngine {
    public nonisolated let engineID = "parakeet-v2"
    private let folder: URL
    private var manager: AsrManager?

    public init(folder: URL) {
        self.folder = folder
    }

    public func prepare() async throws {
        guard manager == nil else { return }
        let started = ContinuousClock.now
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let models = try AsrModels.loadLocal(from: folder, version: .v2, configuration: configuration)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        Log.info("speech.parakeet_loaded", ["seconds": .seconds(ContinuousClock.now - started)])
    }

    public func transcribe(_ samples: [Float]) async throws -> TranscriptPiece {
        guard let manager else { throw ASRError.notInitialized }
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let padded = samples.count >= minimum ? samples : samples + [Float](repeating: 0, count: minimum - samples.count)
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(padded, decoderState: &state)
        let words = Self.words(from: result.tokenTimings ?? [])
        return TranscriptPiece(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), words: words)
    }

    public func release() async {
        await manager?.cleanup()
        manager = nil
    }

    /// Tokens that start with a space begin a new word.
    static func words(from tokens: [TokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        for token in tokens {
            let text = token.token
            let startMs = Int64(token.startTime * 1000)
            let endMs = Int64(token.endTime * 1000)
            if text.hasPrefix(" ") || words.isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                words.append(TimedWord(trimmed, startMs, endMs))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].endMs = endMs
            }
        }
        return words
    }
}

/// Silero voice detection on the Neural Engine. Finds where speech starts and stops.
public actor VoiceDetector: SpeechRangeDetector {
    public static let frameSize = VadManager.chunkSize
    static let maxSpeechSeconds: Double = 14
    private let manager: VadManager

    public init(folder: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: folder.appendingPathComponent(ModelNames.VAD.sileroVadFile),
                                configuration: configuration)
        manager = VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)
    }

    /// Speech probability for one 256 ms frame, carrying the model state between calls.
    public func probability(_ frame: [Float], state: inout VadStreamState) async throws -> Float {
        let result = try await manager.processStreamingChunk(frame, state: state)
        state = result.state
        return result.probability
    }

    public func newState() async -> VadStreamState {
        await manager.makeStreamState()
    }

    /// Speech ranges in a whole recording, in milliseconds.
    public func speechRanges(_ samples: [Float]) async throws -> [(startMs: Int64, endMs: Int64)] {
        var config = VadSegmentationConfig.default
        config.maxSpeechDuration = Self.maxSpeechSeconds
        config.speechPadding = 0.2
        let segments = try await manager.segmentSpeech(samples, config: config)
        return segments.map { (Int64($0.startTime * 1000), Int64($0.endTime * 1000)) }
    }
}
