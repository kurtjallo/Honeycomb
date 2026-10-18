import Foundation
import GRDB

extension AppDatabase {
    @discardableResult
    public func enqueue(_ kind: JobKind, meeting: UUID?, args: [String: String]? = nil, notBefore: Date? = nil) throws -> Job {
        try writer.write { db in
            var job = Job(meetingId: meeting, kind: kind, args: args)
            job.notBefore = notBefore
            try job.insert(db)
            return job
        }
    }

    /// Takes the oldest job that is due and marks it running.
    public func claimNextJob(now: Date = Date(), skipping kinds: Set<JobKind> = []) throws -> Job? {
        try writer.write { db in
            var request = Job.filter(Column("status") == JobStatus.queued.rawValue)
                .filter(Column("not_before") == nil || Column("not_before") <= now)
            if !kinds.isEmpty { request = request.filter(!kinds.map(\.rawValue).contains(Column("kind"))) }
            guard var job = try request.order(Column("id")).fetchOne(db) else { return nil }
            job.status = .running
            job.attempt += 1
            job.updatedAt = now
            try job.update(db)
            return job
        }
    }

    public func finishJob(_ job: Job) throws {
        try setJob(job, status: .done, errorCode: nil, notBefore: nil)
    }

    /// Puts a job back in the queue, for example to wait for a recording to end, without using up an attempt.
    public func deferJob(_ job: Job, until date: Date) throws {
        var job = job
        job.attempt = max(0, job.attempt - 1)
        try setJob(job, status: .queued, errorCode: nil, notBefore: date)
    }

    public func retryJob(_ job: Job, errorCode: String, at date: Date) throws {
        try setJob(job, status: .queued, errorCode: errorCode, notBefore: date)
    }

    public func failJob(_ job: Job, errorCode: String) throws {
        try setJob(job, status: .failed, errorCode: errorCode, notBefore: nil)
    }

    private func setJob(_ job: Job, status: JobStatus, errorCode: String?, notBefore: Date?) throws {
        var job = job
        job.status = status
        job.errorCode = errorCode
        job.notBefore = notBefore
        job.updatedAt = Date()
        try writer.write { [job] db in try job.update(db) }
    }

    /// Launch recovery: a job that was running when Honeycomb quit goes back in the queue. That run
    /// used an attempt, so a job that crashes the app every time fails, with its meeting, after its last.
    public func requeueRunningJobs(maxAttempts: Int) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: """
                UPDATE meeting SET state = 'failed', state_detail = 'crashed', updated_at = ?
                WHERE id IN (SELECT meeting_id FROM job WHERE status = 'running' AND attempt >= ?)
                """, arguments: [now, maxAttempts])
            try db.execute(sql: """
                UPDATE job SET status = 'failed', error_code = 'crashed', updated_at = ? WHERE status = 'running' AND attempt >= ?
                """, arguments: [now, maxAttempts])
            try db.execute(sql: "UPDATE job SET status = 'queued' WHERE status = 'running'")
        }
    }

    public func jobs(for meeting: UUID) throws -> [Job] {
        try reader.read { try Job.filter(Column("meeting_id") == meeting).order(Column("id")).fetchAll($0) }
    }

    public func hasOpenJob(_ kind: JobKind, meeting: UUID) throws -> Bool {
        try reader.read { db in
            try Job.filter(Column("meeting_id") == meeting && Column("kind") == kind.rawValue
                && [JobStatus.queued.rawValue, JobStatus.running.rawValue].contains(Column("status"))).fetchCount(db) > 0
        }
    }
}
