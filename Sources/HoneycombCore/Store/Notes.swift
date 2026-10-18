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

    public func saveProvider(_ provider: ProviderRecord) throws {
        try writer.write { try provider.save($0) }
    }

    public func providers() throws -> [ProviderRecord] {
        try reader.read { try ProviderRecord.order(Column("name")).fetchAll($0) }
    }

    public func provider(_ id: String) throws -> ProviderRecord? {
        try reader.read { try ProviderRecord.fetchOne($0, key: id) }
    }

    /// Its routes and cloud consent go with it. The built-in provider is never deleted.
    public func deleteProvider(_ id: String) throws {
        _ = try writer.write { db in
            try ProviderRecord.filter(Column("id") == id && Column("kind") != ProviderKind.builtin.rawValue).deleteAll(db)
        }
    }

    public func route(_ task: AITask) throws -> Route? {
        try reader.read { try Route.fetchOne($0, key: task.rawValue) }
    }

    public func routes() throws -> [Route] {
        try reader.read { try Route.fetchAll($0) }
    }

    public func saveRoute(_ route: Route) throws {
        try writer.write { try route.save($0) }
    }

    public func hasCloudConsent(_ provider: String) throws -> Bool {
        try reader.read { try CloudConsent.fetchOne($0, key: provider) != nil }
    }

    public func grantCloudConsent(_ provider: String) throws {
        try writer.write { try CloudConsent(providerId: provider).save($0) }
    }
}
