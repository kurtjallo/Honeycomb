import Foundation

/// The two sides of a call. The mic is "Me". Everything the Mac plays is "Them".
public enum Channel: String, Codable, Sendable, CaseIterable {
    case me
    case them

    /// File name stem for this channel's audio segments.
    public var fileStem: String { self == .me ? "mic" : "system" }

    public func segmentFileName(index: Int) -> String {
        index == 1 ? "\(fileStem).aac" : String(format: "%@-%03d.aac", fileStem, index)
    }
}

public enum TrackStatus: String, Codable, Sendable, Comparable {
    case complete
    case recovered
    case incomplete

    private var rank: Int {
        switch self {
        case .complete: 0
        case .recovered: 1
        case .incomplete: 2
        }
    }

    public static func < (lhs: TrackStatus, rhs: TrackStatus) -> Bool { lhs.rank < rhs.rank }
}

public enum InterruptionReason: String, Codable, Sendable {
    case stalled
    case routeChanged = "route_changed"
    case writeFailed = "write_failed"
}

/// `meta.json` in each meeting's audio folder. It lists every audio segment with its offset on the
/// session clock, so tracks line up even after a restart. Written atomically after every change.
public struct SessionMeta: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var meetingID: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var durationMs: Int64?
    public var tracks: [TrackMeta]
    public var pauses: [TimeSpan]

    // The snake_case key strategies turn "meeting_id" back into "meetingId", not "meetingID".
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, startedAt, endedAt, durationMs, tracks, pauses
        case meetingID = "meetingId"
    }

    public init(meetingID: UUID, startedAt: Date) {
        schemaVersion = Self.currentSchema
        self.meetingID = meetingID
        self.startedAt = startedAt
        tracks = Channel.allCases.map { TrackMeta(channel: $0) }
        pauses = []
    }

    /// The meeting's status is its worst track's. Nil while recording.
    public var status: TrackStatus? {
        let statuses = tracks.compactMap(\.status)
        guard statuses.count == tracks.count else { return nil }
        return statuses.max()
    }

    public subscript(channel: Channel) -> TrackMeta {
        get { tracks.first { $0.channel == channel } ?? TrackMeta(channel: channel) }
        set {
            if let index = tracks.firstIndex(where: { $0.channel == channel }) {
                tracks[index] = newValue
            } else {
                tracks.append(newValue)
            }
        }
    }
}

public struct TrackMeta: Codable, Equatable, Sendable {
    public var channel: Channel
    public var segments: [SegmentMeta] = []
    public var interruptions: [InterruptionMeta] = []
    public var status: TrackStatus?

    public init(channel: Channel) {
        self.channel = channel
    }
}

public struct SegmentMeta: Codable, Equatable, Sendable {
    public var file: String
    public var startOffsetMs: Int64
    public var endOffsetMs: Int64?
    public var frames: Int64
    public var sampleRate: Double
    /// Decoded frames to skip before the first recorded sample (AAC encoder lead-in).
    public var primingFrames: Int64

    public init(file: String, startOffsetMs: Int64, endOffsetMs: Int64? = nil, frames: Int64 = 0,
                sampleRate: Double, primingFrames: Int64 = 0) {
        self.file = file
        self.startOffsetMs = startOffsetMs
        self.endOffsetMs = endOffsetMs
        self.frames = frames
        self.sampleRate = sampleRate
        self.primingFrames = primingFrames
    }
}

public struct InterruptionMeta: Codable, Equatable, Sendable {
    public var startedAtMs: Int64
    public var recoveredAtMs: Int64?
    public var reason: InterruptionReason
    public var attempts: Int

    public init(startedAtMs: Int64, reason: InterruptionReason, recoveredAtMs: Int64? = nil, attempts: Int = 0) {
        self.startedAtMs = startedAtMs
        self.reason = reason
        self.recoveredAtMs = recoveredAtMs
        self.attempts = attempts
    }
}

public struct TimeSpan: Codable, Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64?

    public init(startMs: Int64, endMs: Int64? = nil) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

extension SessionMeta {
    public static let fileName = "meta.json"

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public enum ReadError: Error, Equatable {
        case unreadable
        case newerSchema(Int)
    }

    public func write(to folder: URL) throws {
        let data = try Self.encoder.encode(self)
        try data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func read(from folder: URL) throws -> SessionMeta {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else {
            throw ReadError.unreadable
        }
        struct Version: Decodable { var schemaVersion: Int }
        guard let version = try? decoder.decode(Version.self, from: data) else { throw ReadError.unreadable }
        guard version.schemaVersion <= currentSchema else { throw ReadError.newerSchema(version.schemaVersion) }
        guard let meta = try? decoder.decode(SessionMeta.self, from: data) else { throw ReadError.unreadable }
        return meta
    }
}
