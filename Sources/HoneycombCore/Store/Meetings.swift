import Foundation
import GRDB

extension AppDatabase {
    public func insert(_ meeting: Meeting) throws {
        try writer.write { try meeting.insert($0) }
    }

    public func save(_ meeting: Meeting) throws {
        var meeting = meeting
        meeting.updatedAt = Date()
        try writer.write { [meeting] in try meeting.save($0) }
    }

    public func meeting(_ id: UUID) throws -> Meeting? {
        try reader.read { try Meeting.fetchOne($0, key: id) }
    }

    /// Writes only a change, so a job that retries in place doesn't wake every meeting observer.
    public func setState(_ id: UUID, _ state: MeetingState, detail: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE meeting SET state = ?, state_detail = ?, updated_at = ?
                WHERE id = ? AND (state IS NOT ? OR state_detail IS NOT ?)
                """, arguments: [state, detail, Date(), id, state, detail])
        }
    }

    public func meetings(in states: [MeetingState]) throws -> [Meeting] {
        try reader.read { db in
            try Meeting.filter(states.contains(Column("state"))).fetchAll(db)
        }
    }

    public func deleteMeeting(_ id: UUID) throws {
        _ = try writer.write { try Meeting.deleteOne($0, key: id) }
    }

    /// Every meeting, newest first, updated whenever the table changes.
    public func meetingList() -> AsyncThrowingStream<[Meeting], Error> {
        let observation = ValueObservation.tracking { db in
            try Meeting.order(Column("created_at").desc).fetchAll(db)
        }
        return stream(observation)
    }

    public func meetingUpdates(_ id: UUID) -> AsyncThrowingStream<Meeting?, Error> {
        stream(ValueObservation.tracking { try Meeting.fetchOne($0, key: id) })
    }

    func stream<Value: Sendable>(_ observation: ValueObservation<ValueReducers.Fetch<Value>>) -> AsyncThrowingStream<Value, Error> {
        let values = observation.values(in: reader)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Meeting {
    /// "Zoom call, Oct 17 2:05 PM", or "Meeting, Oct 17 2:05 PM" without a call app.
    public static func defaultTitle(appName: String?, at date: Date) -> String {
        let when = date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        if let appName { return "\(appName) call, \(when)" }
        return "Meeting, \(when)"
    }
}
