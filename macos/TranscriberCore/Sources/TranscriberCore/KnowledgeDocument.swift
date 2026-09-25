import Foundation
import GRDB

/// A document the user writes and keeps beside transcripts and summaries.
public struct KnowledgeDocument: Codable, FetchableRecord, Equatable, Identifiable, Sendable {
    public var id: Int64
    public var title: String
    public var description: String
    public var text: String
    public var createdAt: String
    public var updatedAt: String
    /// When true, a finished summary or action-item pass may revise this document.
    public var allowsLLMUpdates: Bool

    public init(
        id: Int64,
        title: String,
        description: String,
        text: String,
        createdAt: String,
        updatedAt: String,
        allowsLLMUpdates: Bool = false
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.allowsLLMUpdates = allowsLLMUpdates
    }

    /// Title shown in the sidebar. A blank title still needs a label in the list.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// Day label for the sidebar, using the same Today / Yesterday wording as the transcript list.
    public func lastEditedLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = Timestamp.parse(updatedAt) else { return updatedAt }
        let day = Timestamp.localDay(date, calendar: calendar)
        return Timestamp.formatDateLabel(day, now: now, calendar: calendar)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case text
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case allowsLLMUpdates = "allow_llm_updates"
    }
}

/// The title, description, and text of a knowledge document at one point in time.
public struct KnowledgeRevision: Equatable, Sendable {
    public var title: String
    public var description: String
    public var text: String

    public init(title: String, description: String, text: String) {
        self.title = title
        self.description = description
        self.text = text
    }
}

extension KnowledgeDocument {
    public var revision: KnowledgeRevision {
        KnowledgeRevision(title: title, description: description, text: text)
    }
}

/// A previous save of a knowledge document, kept when a newer save replaces it.
public struct KnowledgeDocumentVersion: Codable, FetchableRecord, Equatable, Identifiable, Sendable {
    public var id: Int64
    public var documentId: Int64
    public var title: String
    public var description: String
    public var text: String
    /// When this content was saved, before the newer save replaced it.
    public var savedAt: String

    public init(
        id: Int64,
        documentId: Int64,
        title: String,
        description: String,
        text: String,
        savedAt: String
    ) {
        self.id = id
        self.documentId = documentId
        self.title = title
        self.description = description
        self.text = text
        self.savedAt = savedAt
    }

    public var revision: KnowledgeRevision {
        KnowledgeRevision(title: title, description: description, text: text)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case text
        case documentId = "document_id"
        case savedAt = "saved_at"
    }
}

public enum KnowledgeDocumentUpdate: Equatable, Sendable {
    /// The stored document already matches this edit, or the document is gone.
    case unchanged
    /// The previous content was archived, then the document was updated.
    case saved(KnowledgeDocumentVersion)
}
