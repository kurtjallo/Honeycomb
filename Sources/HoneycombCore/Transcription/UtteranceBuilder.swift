/// Cuts one channel's live audio into utterances, from the voice detector's speech probability
/// for each 256 ms frame. Finished utterances get a final transcription. While someone is still
/// talking, the utterance so far is offered about once a second for a grey partial line.
public struct UtteranceBuilder: Sendable {
    public struct Policy: Sendable {
        public var startThreshold: Float = 0.5
        public var endThreshold: Float = 0.35
        public var minSilenceMs: Int64 = 750
        public var maxUtteranceMs: Int64 = 8_000
        public var partialEveryMs: Int64 = 1_000

        public init() {}
    }

    public enum Output: Sendable, Equatable {
        case partial(startMs: Int64, samples: [Float])
        case final(startMs: Int64, samples: [Float])
    }

    public let policy: Policy
    private var preroll: (startMs: Int64, samples: [Float])?
    private var speaking = false
    private var buffer: [Float] = []
    private var startMs: Int64 = 0
    private var silenceMs: Int64 = 0
    private var trailingSilenceSamples = 0
    private var lastPartialMs: Int64 = 0

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    public mutating func push(frame: [Float], startMs frameStart: Int64, probability: Float) -> [Output] {
        let frameMs = Int64(frame.count) * 1000 / 16_000
        guard speaking else {
            if probability >= policy.startThreshold {
                speaking = true
                buffer = (preroll?.samples ?? []) + frame
                startMs = preroll?.startMs ?? frameStart
                silenceMs = 0
                trailingSilenceSamples = 0
                lastPartialMs = frameStart + frameMs
            } else {
                preroll = (frameStart, frame)
            }
            return []
        }

        buffer += frame
        if probability < policy.endThreshold {
            silenceMs += frameMs
            trailingSilenceSamples += frame.count
        } else {
            silenceMs = 0
            trailingSilenceSamples = 0
        }
        let now = frameStart + frameMs
        if silenceMs >= policy.minSilenceMs {
            // Keep one frame of the silence so the last word isn't clipped.
            let keep = buffer.count - max(0, trailingSilenceSamples - frame.count)
            let output = Output.final(startMs: startMs, samples: Array(buffer.prefix(keep)))
            speaking = false
            buffer = []
            preroll = (frameStart, frame)
            return [output]
        }
        if now - startMs >= policy.maxUtteranceMs {
            let output = Output.final(startMs: startMs, samples: buffer)
            buffer = []
            startMs = now
            lastPartialMs = now
            return [output]
        }
        if now - lastPartialMs >= policy.partialEveryMs {
            lastPartialMs = now
            return [.partial(startMs: startMs, samples: buffer)]
        }
        return []
    }

    /// Ends the open utterance, for example when recording stops.
    public mutating func flush() -> [Output] {
        guard speaking, !buffer.isEmpty else { return [] }
        speaking = false
        defer { buffer = [] }
        return [.final(startMs: startMs, samples: buffer)]
    }
}
