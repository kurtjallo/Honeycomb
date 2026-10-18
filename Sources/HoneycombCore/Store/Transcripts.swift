import Foundation
import GRDB

extension AppDatabase {
    /// Live lines are written in small batches during a call.
    public func appendLiveLines(_ lines: [TranscriptLine], meeting: UUID, engine: String) throws {
        guard !lines.isEmpty else { return }
        try writer.write { db in
            for line in lines {
                let row = TranscriptSegment(meetingId: meeting, channel: line.channel, startMs: line.startMs,
                                            endMs: line.endMs, text: line.text, pass: .live, engine: engine)
                try row.insert(db)
            }
        }
    }

    /// The final pass replaces every earlier line for the meeting in one transaction, so a
    /// re-run replaces exactly what it wrote before.
    public func replaceTranscript(_ lines: [TranscriptLine], duplicates: Set<Int>, meeting: UUID, engine: String) throws {
        try writer.write { db in
            try TranscriptSegment.filter(Column("meeting_id") == meeting).deleteAll(db)
            for (index, line) in lines.enumerated() {
                let row = TranscriptSegment(meetingId: meeting, channel: line.channel, startMs: line.startMs,
                                            endMs: line.endMs, text: line.text, pass: .final, engine: engine,
                                            isDuplicate: duplicates.contains(index))
                try row.insert(db)
            }
        }
    }

    public func transcript(_ meeting: UUID, includeDuplicates: Bool = false) throws -> [TranscriptSegment] {
        try reader.read { db in try Self.transcriptRequest(meeting, includeDuplicates).fetchAll(db) }
    }

    public func transcriptUpdates(_ meeting: UUID) -> AsyncThrowingStream<[TranscriptSegment], Error> {
        stream(ValueObservation.tracking { db in try Self.transcriptRequest(meeting, false).fetchAll(db) })
    }

    private static func transcriptRequest(_ meeting: UUID, _ includeDuplicates: Bool) -> QueryInterfaceRequest<TranscriptSegment> {
        var request = TranscriptSegment.filter(Column("meeting_id") == meeting)
        if !includeDuplicates { request = request.filter(Column("is_duplicate") == false) }
        return request.order(Column("start_ms"), Column("channel"))
    }

    public func replaceGaps(_ gaps: [Gap], meeting: UUID) throws {
        try writer.write { db in
            try Gap.filter(Column("meeting_id") == meeting).deleteAll(db)
            for gap in gaps { try gap.insert(db) }
        }
    }

    public func dictionaryTerms() throws -> [DictionaryTerm] {
        try reader.read { try DictionaryTerm.order(Column("term")).fetchAll($0) }
    }

    public func saveTerm(_ term: DictionaryTerm) throws {
        try writer.write { try term.save($0) }
    }

    public func deleteTerm(_ term: String) throws {
        _ = try writer.write { try DictionaryTerm.deleteOne($0, key: term) }
    }
}
