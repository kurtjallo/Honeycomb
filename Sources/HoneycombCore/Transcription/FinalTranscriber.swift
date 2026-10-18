import Foundation

/// The full-file pass after a call. It re-reads both tracks from disk, so it fills any gaps the
/// live view skipped and gives better line breaks from word timings.
public struct FinalTranscriber: Sendable {
    let engine: any TranscriptionEngine
    let detector: VoiceDetector

    public init(engine: any TranscriptionEngine, detector: VoiceDetector) {
        self.engine = engine
        self.detector = detector
    }

    public func transcribe(meta: SessionMeta, folder: URL) async throws -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        for track in meta.tracks {
            for segment in track.segments {
                try Task.checkCancellation()
                guard let samples = try AudioSegmentReader.samples(of: segment, in: folder), samples.count > 16_000 else {
                    continue
                }
                for range in try await detector.speechRanges(samples) {
                    let start = max(0, Int(range.startMs * 16))
                    let end = min(samples.count, Int(range.endMs * 16))
                    guard end - start > 4_000 else { continue }
                    let piece = try await engine.transcribe(Array(samples[start..<end]))
                    let words = piece.words.isEmpty
                        ? [TimedWord(piece.text, 0, Int64(end - start) / 16)]
                        : piece.words
                    lines += LineBuilder.lines(from: words, channel: track.channel,
                                               offsetMs: segment.startOffsetMs + range.startMs)
                }
            }
        }
        return lines.sorted { $0.startMs < $1.startMs }
    }
}

/// On laptop speakers, the mic also hears the other side, so their words show up twice.
/// A "Me" line near a "Them" line is marked duplicate when nearly all its words appear in theirs,
/// in the same order. A real reply often repeats a few of their words ("Yes, ship on Friday.").
public enum Dedupe {
    public static func duplicateMeLines(_ lines: [TranscriptLine], windowMs: Int64 = 1_500,
                                        threshold: Double = 0.8) -> Set<Int> {
        let them = lines.filter { $0.channel == .them }
        var duplicates = Set<Int>()
        for (index, line) in lines.enumerated() where line.channel == .me {
            let mine = words(line.text)
            guard mine.count >= 2 else { continue }
            let heard = them.filter { $0.startMs <= line.endMs + windowMs && $0.endMs >= line.startMs - windowMs }
                .flatMap { words($0.text) }
            let shared = Double(commonInOrder(mine, heard)) / Double(mine.count)
            if shared >= threshold { duplicates.insert(index) }
        }
        return duplicates
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    /// The longest run of words both share in the same order, gaps allowed.
    static func commonInOrder(_ a: [String], _ b: [String]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        for word in a {
            var current = [0]
            for (j, other) in b.enumerated() {
                current.append(word == other ? previous[j] + 1 : max(previous[j + 1], current[j]))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Fixes the spelling of names and jargon the user added to the Dictionary, such as
/// "Dana Leigh" → "Dana Lee", when a run of words sounds and looks close enough.
public enum DictionaryCorrector {
    public static func correct(_ text: String, terms: [String], minSimilarity: Double = 0.8) -> String {
        guard !terms.isEmpty else { return text }
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for term in terms.sorted(by: { $0.count > $1.count }) {
            let termWords = term.split(separator: " ").map(String.init)
            let n = termWords.count
            guard n > 0, words.count >= n else { continue }
            let target = normalize(term)
            var index = 0
            while index + n <= words.count {
                let window = words[index..<index + n]
                let (core, trailing) = splitPunctuation(window.joined(separator: " "))
                let candidate = normalize(core)
                if candidate != target, !candidate.isEmpty, candidate.first == target.first,
                   matches(candidate, target, minSimilarity: minSimilarity) {
                    words.replaceSubrange(index..<index + n, with: [term + trailing])
                    index += 1
                } else {
                    index += 1
                }
            }
        }
        return words.joined(separator: " ")
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Close spelling, before or after common spelling swaps ("leigh" and "lee"). Vowels still
    /// count, so a common word never becomes a short name that shares its consonants ("been", "Ben").
    static func matches(_ candidate: String, _ target: String, minSimilarity: Double) -> Bool {
        similarity(candidate, target) >= minSimilarity
            || similarity(soundSpelling(candidate), soundSpelling(target)) >= minSimilarity
    }

    static func soundSpelling(_ word: String) -> String {
        var text = word
        for (from, to) in [("gh", ""), ("ph", "f"), ("ck", "k"), ("q", "k"), ("x", "ks"), ("z", "s")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
    }

    static func splitPunctuation(_ text: String) -> (String, String) {
        let trailing = String(text.reversed().prefix { ".,!?;:".contains($0) }.reversed())
        return (String(text.dropLast(trailing.count)), trailing)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
