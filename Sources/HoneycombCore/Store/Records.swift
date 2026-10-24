import Foundation
import GRDB

/// Columns are snake_case. Swift names use "Id" so the automatic key conversion round-trips.
public protocol HoneycombRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}

extension HoneycombRecord {
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
}

public enum MeetingState: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case draft
    case recording
    case paused
    case interrupted
    case transcribing
    case tooShort = "too_short"
    case waiting
    case writingNotes = "writing_notes"
    case indexing
    case ready
    case failed

    public var isCapturing: Bool { self == .recording || self == .paused }
}

/// Why a meeting is `waiting`, stored as its `state_detail`.
public enum WaitReason: String, Sendable {
    case modelMissing = "model_missing"
    /// A local model can't load while a call is being recorded.
    case modelBusy = "model_busy"
}

public enum TitleSource: String, Codable, Sendable {
    case `default`
    case ai
    case user
}

public struct Meeting: HoneycombRecord, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "meeting"
    public var id: UUID
    public var title: String
    public var titleSource: TitleSource
    public var callAppId: String?
    public var startAt: Date?
    public var endAt: Date?
    public var durationMs: Int64?
    public var state: MeetingState
    public var stateDetail: String?
    public var templateId: String?
    public var currentEnhancedId: UUID?
    public var audioDir: String?
    public var mdPath: String?
    public var mdHash: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var waitReason: WaitReason? {
        state == .waiting ? stateDetail.flatMap(WaitReason.init) : nil
    }

    public init(id: UUID = UUID(), title: String, titleSource: TitleSource = .default, callAppId: String? = nil,
                state: MeetingState, templateId: String? = nil, now: Date = Date()) {
        self.id = id
        self.title = title
        self.titleSource = titleSource
        self.callAppId = callAppId
        self.state = state
        self.templateId = templateId
        createdAt = now
        updatedAt = now
    }
}

public enum Pass: String, Codable, Sendable, DatabaseValueConvertible {
    case live
    case final
}

public struct TranscriptSegment: HoneycombRecord, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "segment"
    public var id: Int64?
    public var meetingId: UUID
    public var channel: Channel
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    public var pass: Pass
    public var engine: String
    public var isDuplicate: Bool

    public init(meetingId: UUID, channel: Channel, startMs: Int64, endMs: Int64, text: String, pass: Pass,
                engine: String, isDuplicate: Bool = false) {
        self.meetingId = meetingId
        self.channel = channel
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.pass = pass
        self.engine = engine
        self.isDuplicate = isDuplicate
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Channel: DatabaseValueConvertible {}

public enum GapReason: String, Codable, Sendable {
    case paused
    case captureLost = "capture_lost"
    case asrBehind = "asr_behind"
}

public struct Gap: HoneycombRecord, Equatable {
    public static let databaseTableName = "gap"
    public var id: Int64?
    public var meetingId: UUID
    public var startMs: Int64
    public var endMs: Int64
    public var reason: GapReason

    public init(meetingId: UUID, startMs: Int64, endMs: Int64, reason: GapReason) {
        self.meetingId = meetingId
        self.startMs = startMs
        self.endMs = endMs
        self.reason = reason
    }
}

public struct UserNote: HoneycombRecord, Equatable {
    public static let databaseTableName = "user_note"
    public var meetingId: UUID
    /// ProseMirror JSON from the editor.
    public var doc: String?
    public var markdown: String
    public var schemaVersion: Int
    public var updatedAt: Date

    public init(meetingId: UUID, doc: String?, markdown: String, schemaVersion: Int = 1, updatedAt: Date = Date()) {
        self.meetingId = meetingId
        self.doc = doc
        self.markdown = markdown
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
    }
}

public enum EnhancedStatus: String, Codable, Sendable {
    case generating
    case done
    case failed
    case canceled
}

/// One version of the AI notes. Regenerating adds a version and never replaces one.
public struct EnhancedNote: HoneycombRecord, Identifiable, Equatable {
    public static let databaseTableName = "enhanced"
    public var id: UUID
    public var meetingId: UUID
    public var templateId: String?
    public var model: String?
    public var doc: String?
    public var markdown: String
    public var schemaVersion: Int
    public var status: EnhancedStatus
    public var errorCode: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), meetingId: UUID, templateId: String?, model: String?,
                status: EnhancedStatus = .generating, now: Date = Date()) {
        self.id = id
        self.meetingId = meetingId
        self.templateId = templateId
        self.model = model
        markdown = ""
        schemaVersion = 1
        self.status = status
        createdAt = now
        updatedAt = now
    }
}

public struct TemplateRecord: HoneycombRecord, Identifiable, Equatable {
    public static let databaseTableName = "template"
    public var id: String
    public var name: String
    public var instructions: String
    public var sections: [String]
    public var builtIn: Bool
    public var updatedAt: Date

    public init(id: String, name: String, instructions: String, sections: [String], builtIn: Bool, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.sections = sections
        self.builtIn = builtIn
        self.updatedAt = updatedAt
    }
}

public enum RecipeScope: String, Codable, Sendable {
    case one
    case many
}

public struct Recipe: HoneycombRecord, Identifiable, Equatable {
    public static let databaseTableName = "recipe"
    public var id: String
    public var name: String
    public var prompt: String
    public var scope: RecipeScope
    public var builtIn: Bool
    public var updatedAt: Date

    public init(id: String, name: String, prompt: String, scope: RecipeScope, builtIn: Bool, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.scope = scope
        self.builtIn = builtIn
        self.updatedAt = updatedAt
    }
}

public enum TermKind: String, Codable, Sendable {
    case name
    case jargon
}

public struct DictionaryTerm: HoneycombRecord, Equatable, Identifiable {
    public static let databaseTableName = "dictionary_term"
    public var term: String
    public var kind: TermKind
    public var createdAt: Date
    public var id: String { term }

    public init(term: String, kind: TermKind, createdAt: Date = Date()) {
        self.term = term
        self.kind = kind
        self.createdAt = createdAt
    }
}

public struct NoteSource: HoneycombRecord, Equatable {
    public static let databaseTableName = "note_source"
    public var enhancedId: UUID
    public var blockId: String
    public var segmentId: Int64
    public var score: Double

    public init(enhancedId: UUID, blockId: String, segmentId: Int64, score: Double) {
        self.enhancedId = enhancedId
        self.blockId = blockId
        self.segmentId = segmentId
        self.score = score
    }
}

public enum CallAppKind: String, Codable, Sendable {
    case app
    case browser
}

public enum AddedBy: String, Codable, Sendable {
    case builtin
    case user
}

public struct CallApp: HoneycombRecord, Equatable, Identifiable {
    public static let databaseTableName = "call_app"
    public var bundleId: String
    public var name: String
    public var kind: CallAppKind
    public var ask: Bool
    public var addedBy: AddedBy
    public var id: String { bundleId }

    public init(bundleId: String, name: String, kind: CallAppKind, ask: Bool = true, addedBy: AddedBy = .builtin) {
        self.bundleId = bundleId
        self.name = name
        self.kind = kind
        self.ask = ask
        self.addedBy = addedBy
    }
}

public enum ChunkSource: String, Codable, Sendable {
    case transcript
    case userNote = "user_note"
    case enhanced
}

public struct Chunk: HoneycombRecord, Equatable {
    public static let databaseTableName = "chunk"
    public var id: Int64?
    public var meetingId: UUID
    public var source: ChunkSource
    public var text: String
    public var startMs: Int64?
    public var endMs: Int64?
    public var vector: Data?
    public var dims: Int?
    public var embedModel: String?

    public init(meetingId: UUID, source: ChunkSource, text: String, startMs: Int64? = nil, endMs: Int64? = nil) {
        self.meetingId = meetingId
        self.source = source
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum ModelKind: String, Codable, Sendable {
    case asr
    case vad
    case llm
    case embed
}

public enum ModelStatus: String, Codable, Sendable {
    case downloading
    case ready
    case failed
}

public struct ModelRecord: HoneycombRecord, Equatable, Identifiable {
    public static let databaseTableName = "model"
    public var id: String
    public var kind: ModelKind
    public var revision: String
    public var path: String
    public var sizeBytes: Int64
    public var sha256: String?
    public var status: ModelStatus
    public var lastUsedAt: Date?

    public init(id: String, kind: ModelKind, revision: String, path: String, sizeBytes: Int64, sha256: String?,
                status: ModelStatus, lastUsedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.status = status
        self.lastUsedAt = lastUsedAt
    }
}

public enum JobKind: String, Codable, Sendable, CaseIterable {
    case finalizeAudio = "finalize_audio"
    case transcribeFinal = "transcribe_final"
    case enhance
    case index
    case sourceLink = "source_link"
    case mirrorMarkdown = "mirror_markdown"
}

public enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case done
    case failed
    case canceled
}

public struct Job: HoneycombRecord, Identifiable, Equatable {
    public static let databaseTableName = "job"
    public var id: Int64?
    public var meetingId: UUID?
    public var kind: JobKind
    public var args: [String: String]?
    public var status: JobStatus
    public var attempt: Int
    public var notBefore: Date?
    public var errorCode: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(meetingId: UUID?, kind: JobKind, args: [String: String]? = nil, now: Date = Date()) {
        self.meetingId = meetingId
        self.kind = kind
        self.args = args
        status = .queued
        attempt = 0
        createdAt = now
        updatedAt = now
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
