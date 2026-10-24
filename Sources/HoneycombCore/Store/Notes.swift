import Foundation
import GRDB

extension AppDatabase {
    public func userNote(_ meeting: UUID) throws -> UserNote? {
        try reader.read { try UserNote.fetchOne($0, key: meeting) }
    }

    public func saveUserNote(_ note: UserNote) throws {
        try writer.write { try note.save($0) }
    }

    public func saveEnhanced(_ note: EnhancedNote) throws {
        var note = note
        note.updatedAt = Date()
        try writer.write { [note] db in try note.save(db) }
    }

    /// Saves the finished version, makes it current, and applies the AI title unless you renamed the meeting.
    public func finishEnhanced(_ note: EnhancedNote, suggestedTitle: String?) throws {
        try writer.write { db in
            var note = note
            note.updatedAt = Date()
            try note.save(db)
            guard var meeting = try Meeting.fetchOne(db, key: note.meetingId) else { return }
            meeting.currentEnhancedId = note.id
            if let suggestedTitle, meeting.titleSource == .default {
                meeting.title = suggestedTitle
                meeting.titleSource = .ai
            }
            meeting.updatedAt = Date()
            try meeting.update(db)
        }
    }

    /// Launch recovery: a version still generating when Honeycomb quit will never finish.
    public func cancelGeneratingNotes() throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE enhanced SET status = 'canceled', updated_at = ? WHERE status = 'generating'",
                           arguments: [Date()])
        }
    }

    public func enhancedNotes(_ meeting: UUID) throws -> [EnhancedNote] {
        try reader.read { try EnhancedNote.filter(Column("meeting_id") == meeting).order(Column("created_at").desc).fetchAll($0) }
    }

    public func enhancedUpdates(_ meeting: UUID) -> AsyncThrowingStream<[EnhancedNote], Error> {
        stream(ValueObservation.tracking { db in
            try EnhancedNote.filter(Column("meeting_id") == meeting).order(Column("created_at").desc).fetchAll(db)
        })
    }

    public func setCurrentEnhanced(_ meeting: UUID, _ enhanced: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE meeting SET current_enhanced_id = ?, updated_at = ? WHERE id = ?",
                           arguments: [enhanced, Date(), meeting])
        }
    }
}
