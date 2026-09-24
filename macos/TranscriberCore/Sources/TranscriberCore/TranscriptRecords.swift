import Foundation
import GRDB

public struct TranscriptionRow: Codable, FetchableRecord, Equatable, Identifiable {
    public var id: Int64
    public var timestamp: String
    public var text: String
    public var speaker: String

    public init(id: Int64, timestamp: String, text: String, speaker: String = Speaker.caller.rawValue) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.speaker = speaker
    }
}

public enum AnnotationKind: String, Codable, Equatable {
    case note
    case llm

    /// Badge shown beside the note, and the label used when the note is copied or sent to the model.
    public var label: String {
        switch self {
        case .note: return "note"
        case .llm: return "LLM note"
        }
    }
}

public struct AnnotationRow: Codable, FetchableRecord, Equatable, Identifiable {
    public var id: Int64
    public var afterTranscriptionId: Int64?
    public var timestamp: String
    public var text: String
    public var kind: AnnotationKind

    public init(
        id: Int64,
        afterTranscriptionId: Int64?,
        timestamp: String,
        text: String,
        kind: AnnotationKind = .note
    ) {
        self.id = id
        self.afterTranscriptionId = afterTranscriptionId
        self.timestamp = timestamp
        self.text = text
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case text
        case kind
        case afterTranscriptionId = "after_transcription_id"
    }
}

public struct ApplyReplacementsResult: Equatable {
    public var total: Int
    public var updated: Int
    public var deleted: Int

    public init(total: Int, updated: Int, deleted: Int) {
        self.total = total
        self.updated = updated
        self.deleted = deleted
    }
}

public struct ModelContext: Equatable {
    public var transcriptions: [TranscriptionRow]
    public var annotations: [AnnotationRow]

    public init(transcriptions: [TranscriptionRow], annotations: [AnnotationRow]) {
        self.transcriptions = transcriptions
        self.annotations = annotations
    }
}

public struct DailySummary: Codable, FetchableRecord, Equatable, Identifiable, Sendable {
    public var day: String
    public var text: String
    public var generatedAt: String
    public var updatedAt: String

    public var id: String { day }

    public init(day: String, text: String, generatedAt: String, updatedAt: String) {
        self.day = day
        self.text = text
        self.generatedAt = generatedAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case text
        case generatedAt = "generated_at"
        case updatedAt = "updated_at"
    }
}

public struct ActionItem: Codable, FetchableRecord, Equatable, Identifiable, Sendable {
    public var id: Int64
    public var timestamp: String
    public var text: String
    public var done: Bool

    public init(id: Int64, timestamp: String, text: String, done: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.done = done
    }
}
