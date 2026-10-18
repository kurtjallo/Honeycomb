import FluidAudio

public enum LiveUpdate: Sendable, Equatable {
    /// Replaces the grey line still being spoken on that channel.
    case partial(TranscriptLine)
    case final(TranscriptLine)
    /// Transcription fell too far behind, so this stretch was skipped. The final pass fills it.
    case gap(channel: Channel, startMs: Int64, endMs: Int64)
}

/// Turns live audio into transcript lines within a few seconds. Each channel gets voice detection
/// and an utterance cutter. One queue feeds the engine, finished utterances first, so partials
/// never delay real lines. When the queue is more than 10 seconds behind, the oldest work is dropped.
public actor LiveTranscriber {
    public nonisolated let updates: AsyncStream<LiveUpdate>
    private let continuation: AsyncStream<LiveUpdate>.Continuation
    private let engine: any TranscriptionEngine
    private let detector: VoiceDetector
    private let maxLagMs: Int64

    private struct Pending {
        let channel: Channel
        let startMs: Int64
        let samples: [Float]
        var endMs: Int64 { startMs + Int64(samples.count) / 16 }
    }

    private var builders: [Channel: UtteranceBuilder] = [:]
    private var frames: [Channel: (startMs: Int64, samples: [Float])] = [:]
    private var vadStates: [Channel: VadStreamState] = [:]
    private var finals: [Pending] = []
    private var partials: [Channel: Pending] = [:]
    private var latestMs: Int64 = 0
    private var worker: Task<Void, Never>?

    public init(engine: any TranscriptionEngine, detector: VoiceDetector, maxLagMs: Int64 = 10_000) {
        self.engine = engine
        self.detector = detector
        self.maxLagMs = maxLagMs
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(500))
    }

    /// Consumes audio until the stream ends, then finishes the queued work.
    public func run(_ audio: AsyncStream<AudioChunk>) async {
        for await chunk in audio { await consume(chunk) }
        for channel in Channel.allCases {
            for output in builders[channel]?.flush() ?? [] { handle(output, channel: channel) }
        }
        partials = [:]
        await worker?.value
        await drain()
        continuation.finish()
    }

    private func consume(_ chunk: AudioChunk) async {
        let channel = chunk.channel
        latestMs = max(latestMs, chunk.endMs)
        var pending = frames[channel] ?? (chunk.startMs, [])
        let expected = pending.startMs + Int64(pending.samples.count) / 16
        if abs(chunk.startMs - expected) > 100 {
            // Capture restarted, so a new segment begins here.
            pending = (chunk.startMs, [])
        }
        pending.samples += chunk.samples
        while pending.samples.count >= VoiceDetector.frameSize {
            let frame = Array(pending.samples.prefix(VoiceDetector.frameSize))
            pending.samples.removeFirst(VoiceDetector.frameSize)
            let frameStart = pending.startMs
            pending.startMs += Int64(VoiceDetector.frameSize) / 16
            var state = vadStates[channel] ?? VadStreamState.initial()
            let probability = (try? await detector.probability(frame, state: &state)) ?? 0
            vadStates[channel] = state
            var builder = builders[channel] ?? UtteranceBuilder()
            let outputs = builder.push(frame: frame, startMs: frameStart, probability: probability)
            builders[channel] = builder
            for output in outputs { handle(output, channel: channel) }
        }
        frames[channel] = pending
    }

    private func handle(_ output: UtteranceBuilder.Output, channel: Channel) {
        switch output {
        case .final(let start, let samples):
            finals.append(Pending(channel: channel, startMs: start, samples: samples))
            partials[channel] = nil
        case .partial(let start, let samples):
            partials[channel] = Pending(channel: channel, startMs: start, samples: samples)
        }
        if worker == nil {
            worker = Task { await self.drain() }
        }
    }

    private func drain() async {
        while let next = nextWork() {
            guard let piece = try? await engine.transcribe(next.work.samples), !piece.text.isEmpty else { continue }
            let line = TranscriptLine(channel: next.work.channel, startMs: next.work.startMs,
                                      endMs: next.work.endMs, text: piece.text)
            continuation.yield(next.isFinal ? .final(line) : .partial(line))
        }
        worker = nil
    }

    private func nextWork() -> (work: Pending, isFinal: Bool)? {
        while let first = finals.first, latestMs - first.endMs > maxLagMs {
            finals.removeFirst()
            continuation.yield(.gap(channel: first.channel, startMs: first.startMs, endMs: first.endMs))
        }
        if !finals.isEmpty { return (finals.removeFirst(), true) }
        if let channel = partials.keys.sorted(by: { $0.rawValue < $1.rawValue }).first, let partial = partials[channel] {
            partials[channel] = nil
            return (partial, false)
        }
        return nil
    }
}
