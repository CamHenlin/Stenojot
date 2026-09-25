import Foundation

public struct KnowledgeDocumentChange: Equatable, Sendable, Identifiable {
    public enum Section: String, Equatable, Sendable {
        case title
        case description
        case body

        public var label: String {
            switch self {
            case .title: return "Title"
            case .description: return "Description"
            case .body: return "Text"
            }
        }
    }

    public var section: Section
    public var lines: [TextDiffLine]

    public var id: String { section.rawValue }

    public init(section: Section, lines: [TextDiffLine]) {
        self.section = section
        self.lines = lines
    }
}

public struct KnowledgeVersionSuccessor: Equatable, Sendable {
    public var revision: KnowledgeRevision
    public var savedAt: String

    public init(revision: KnowledgeRevision, savedAt: String) {
        self.revision = revision
        self.savedAt = savedAt
    }
}

public enum KnowledgeDocumentDiff {
    /// Sections whose title, description, or text changed. Unchanged sections are left out.
    public static func changes(from older: KnowledgeRevision, to newer: KnowledgeRevision) -> [KnowledgeDocumentChange] {
        var changes: [KnowledgeDocumentChange] = []
        if older.title != newer.title {
            changes.append(KnowledgeDocumentChange(
                section: .title,
                lines: TextDiff.lines(before: older.title, after: newer.title)
            ))
        }
        if older.description != newer.description {
            changes.append(KnowledgeDocumentChange(
                section: .description,
                lines: TextDiff.lines(before: older.description, after: newer.description)
            ))
        }
        if older.text != newer.text {
            changes.append(KnowledgeDocumentChange(
                section: .body,
                lines: TextDiff.lines(before: older.text, after: newer.text)
            ))
        }
        return changes
    }
}

public enum KnowledgeHistory {
    /// The save that replaced this archived version. `versions` is newest first.
    /// The newest archived version was replaced by the current document. Each older one was replaced by the version saved after it.
    public static func successor(
        of versionID: Int64,
        versions: [KnowledgeDocumentVersion],
        current: KnowledgeRevision,
        currentSavedAt: String
    ) -> KnowledgeVersionSuccessor? {
        guard let index = versions.firstIndex(where: { $0.id == versionID }) else { return nil }
        if index == 0 {
            return KnowledgeVersionSuccessor(revision: current, savedAt: currentSavedAt)
        }
        let newer = versions[index - 1]
        return KnowledgeVersionSuccessor(revision: newer.revision, savedAt: newer.savedAt)
    }
}
