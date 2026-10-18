import Testing
@testable import HoneycombCore

struct UtteranceBuilderTests {
    let frame = [Float](repeating: 0.1, count: 4_096)

    func run(_ probabilities: [Float]) -> [UtteranceBuilder.Output] {
        var builder = UtteranceBuilder()
        var outputs: [UtteranceBuilder.Output] = []
        for (index, probability) in probabilities.enumerated() {
            outputs += builder.push(frame: frame, startMs: Int64(index) * 256, probability: probability)
        }
        return outputs + builder.flush()
    }

    func finals(_ outputs: [UtteranceBuilder.Output]) -> [(Int64, Int)] {
        outputs.compactMap { if case .final(let start, let samples) = $0 { (start, samples.count) } else { nil } }
    }

    @Test func silenceProducesNothing() {
        #expect(run([0.1, 0.2, 0.1, 0.0]).isEmpty)
    }

    @Test func oneUtteranceWithPrerollAndSilenceTrimmed() {
        let outputs = run([0.1, 0.9, 0.9, 0.9, 0.1, 0.1, 0.1, 0.1, 0.1])
        let finals = finals(outputs)
        #expect(finals.count == 1)
        #expect(finals[0].0 == 0)
        #expect(finals[0].1 == 4_096 * 5)
    }

    @Test func longSpeechIsCutAtEightSeconds() {
        let outputs = run([Float](repeating: 0.9, count: 70))
        let finals = finals(outputs)
        #expect(finals.count == 3)
        #expect(finals.allSatisfy { $0.1 <= 4_096 * 33 })
        #expect(finals[1].0 > finals[0].0)
    }

    @Test func partialsComeAboutOnceASecond() {
        let outputs = run([Float](repeating: 0.9, count: 20))
        let partials = outputs.filter { if case .partial = $0 { true } else { false } }
        #expect(partials.count >= 3 && partials.count <= 5)
    }

    @Test func shortPauseKeepsOneUtterance() {
        let finals = finals(run([0.9, 0.9, 0.1, 0.1, 0.9, 0.9, 0.1, 0.1, 0.1, 0.1]))
        #expect(finals.count == 1)
    }
}

struct LineBuilderTests {
    @Test func breaksOnSentencesAndPauses() {
        let words = [
            TimedWord("We'd", 0, 200), TimedWord("renew", 200, 500), TimedWord("if", 500, 600),
            TimedWord("SSO", 600, 900), TimedWord("lands.", 900, 1_200),
            TimedWord("Okay", 3_000, 3_300), TimedWord("great", 3_300, 3_600),
        ]
        let lines = LineBuilder.lines(from: words, channel: .them, offsetMs: 10_000)
        #expect(lines.map(\.text) == ["We'd renew if SSO lands.", "Okay great"])
        #expect(lines[0].startMs == 10_000)
        #expect(lines[1].endMs == 13_600)
    }

    @Test func wordsFromTokens() {
        let tokens = [(" We", 0.0, 0.1), ("'d", 0.1, 0.2), (" re", 0.3, 0.4), ("new", 0.4, 0.5)]
        let words = ParakeetEngine.words(from: tokens.map {
            .init(token: $0.0, tokenId: 0, startTime: $0.1, endTime: $0.2, confidence: 1)
        })
        #expect(words == [TimedWord("We'd", 0, 200), TimedWord("renew", 300, 500)])
    }
}

struct DedupeTests {
    @Test func echoOnTheMicIsMarked() {
        let lines = [
            TranscriptLine(channel: .them, startMs: 1_000, endMs: 4_000, text: "We'd renew if SSO lands by end of Q1."),
            TranscriptLine(channel: .me, startMs: 1_200, endMs: 4_100, text: "renew if SSO lands by end of Q1"),
            TranscriptLine(channel: .me, startMs: 5_000, endMs: 7_000, text: "Great, I'll check with the team."),
        ]
        #expect(Dedupe.duplicateMeLines(lines) == [1])
    }

    @Test func realRepliesThatRepeatTheirWordsAreKept() {
        let lines = [
            TranscriptLine(channel: .them, startMs: 1_000, endMs: 3_000, text: "Can you ship on Friday?"),
            TranscriptLine(channel: .me, startMs: 3_200, endMs: 4_500, text: "Yes, ship on Friday."),
            TranscriptLine(channel: .them, startMs: 10_000, endMs: 12_000, text: "We can't ship on Friday, right?"),
            TranscriptLine(channel: .me, startMs: 12_200, endMs: 14_000, text: "Right, we can ship on Friday."),
        ]
        #expect(Dedupe.duplicateMeLines(lines).isEmpty)
    }

    @Test func farApartLinesAreKept() {
        let lines = [
            TranscriptLine(channel: .them, startMs: 1_000, endMs: 2_000, text: "Sounds good to me"),
            TranscriptLine(channel: .me, startMs: 60_000, endMs: 61_000, text: "Sounds good to me"),
        ]
        #expect(Dedupe.duplicateMeLines(lines).isEmpty)
    }
}

struct DictionaryCorrectorTests {
    @Test func fixesCloseSpellings() {
        #expect(DictionaryCorrector.correct("I spoke with Dana Leigh today.", terms: ["Dana Lee"]) == "I spoke with Dana Lee today.")
        #expect(DictionaryCorrector.correct("the Kubernetis cluster", terms: ["Kubernetes"]) == "the Kubernetes cluster")
        #expect(DictionaryCorrector.correct("open Honeycom now", terms: ["Honeycomb"]) == "open Honeycomb now")
    }

    @Test func leavesCommonWordsThatSoundLikeShortNamesAlone() {
        let text = "It has been a long time, same as when we join calls."
        #expect(DictionaryCorrector.correct(text, terms: ["Ben", "Tim", "Sam", "Jon"]) == text)
    }

    @Test func leavesOtherWordsAlone() {
        #expect(DictionaryCorrector.correct("Data is late", terms: ["Dana Lee"]) == "Data is late")
        #expect(DictionaryCorrector.correct("the cat sat", terms: ["Acme"]) == "the cat sat")
    }
}

struct ModelPolicyTests {
    typealias M = ModelPolicy.Model

    @Test func oneLargeModelAtATime() {
        #expect(ModelPolicy.decide(adding: .llm("qwen3.5-4b"), loaded: [.speech], recording: false, ramGB: 16)
            == .load(evicting: [.speech]))
        #expect(ModelPolicy.decide(adding: .speech, loaded: [.llm("qwen3.5-9b")], recording: false, ramGB: 16)
            == .load(evicting: [.llm("qwen3.5-9b")]))
    }

    @Test func fourBSitsBesideSpeechDuringACallOn16GB() {
        #expect(ModelPolicy.decide(adding: .llm("qwen3.5-4b"), loaded: [.speech], recording: true, ramGB: 16)
            == .load(evicting: []))
        #expect(ModelPolicy.decide(adding: .speech, loaded: [.llm("qwen3.5-4b")], recording: true, ramGB: 16)
            == .load(evicting: []))
        #expect(ModelPolicy.decide(adding: .llm("qwen3.5-4b"), loaded: [.speech], recording: true, ramGB: 8) == .refuse)
    }

    @Test func nineBNeverLoadsDuringARecording() {
        #expect(ModelPolicy.decide(adding: .llm("qwen3.5-9b"), loaded: [.speech], recording: true, ramGB: 32) == .refuse)
    }

    @Test func embedderRules() {
        #expect(ModelPolicy.decide(adding: .embedder, loaded: [.speech], recording: true, ramGB: 32) == .refuse)
        #expect(ModelPolicy.decide(adding: .embedder, loaded: [.llm("qwen3.5-4b")], recording: false, ramGB: 16)
            == .load(evicting: []))
        #expect(ModelPolicy.decide(adding: .embedder, loaded: [.llm("qwen3.5-4b")], recording: false, ramGB: 8)
            == .load(evicting: [.llm("qwen3.5-4b")]))
        #expect(ModelPolicy.decide(adding: .speech, loaded: [.embedder], recording: true, ramGB: 16)
            == .load(evicting: [.embedder]))
    }
}
