import Foundation

public enum KnowledgeUpdateSource: Equatable, Sendable {
    case dailySummary
    case actionItemTranscript

    var materialLabel: String {
        switch self {
        case .dailySummary: return "Daily summary"
        case .actionItemTranscript: return "Transcript stretch sent for action items"
        }
    }
}

public enum KnowledgeUpdateDecision: Equatable, Sendable {
    case none
    case update(KnowledgeRevision)
}

public enum KnowledgeUpdates {
    public static let systemPrompt = """
    You update one knowledge base document the user keeps beside their transcripts. You receive the current document and new material: a finished daily summary, or a transcript stretch that was just reviewed for action items.

    Change the document only when the new material adds, corrects, or removes something this document should hold. If the material is irrelevant, already reflected, or too thin to add, leave the document unchanged.

    When you add or change a fact, put a datetime beside it for when that information was heard. Use the date and time in the material. A daily summary has a date heading and a time heading for each stretch. A transcript line has a clock time; pair it with the date given for when the material was heard. Write the stamp like [Sep 23, 2026, 3:04 PM], next to the fact it belongs to. Keep a datetime already written in the document. If the material does not say when something was heard, do not invent one.

    If no change is needed, reply with exactly:
    NO UPDATE

    If a change is needed, reply with only a JSON object holding the full document, not a patch and not a list of edits:
    {"title":"...","description":"...","text":"..."}

    Keep the title and description unless the new material gives a reason to change them. The text field is the complete document body. Do not add commentary, markdown, or keys beyond title, description, and text.
    """

    /// The instruction sent with one knowledge document. A blank stored prompt uses the built-in one.
    public static func systemPrompt(stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return systemPrompt }
        return trimmed
    }

    /// The document and the material that might change it. `material` is the finished summary, or the same text sent for action items.
    public static func userPrompt(
        document: KnowledgeRevision,
        material: String,
        source: KnowledgeUpdateSource,
        heardAt: String
    ) -> String {
        """
        Knowledge base entry:
        Title: \(document.title)
        Description: \(document.description)
        Text:
        \(document.text)

        Heard around: \(Timestamp.formatDateTime(heardAt))

        \(source.materialLabel):
        \(material)

        Reply with NO UPDATE, or the JSON object for the full updated entry.
        """
    }

    /// Output budget for a reply that may repeat the whole document.
    public static func maxTokens(for document: KnowledgeRevision) -> Int {
        let size = document.title.utf8.count + document.description.utf8.count + document.text.utf8.count
        let estimated = max(1, (size / 3) + 512)
        return min(16_384, max(2_048, estimated))
    }

    /// `NO UPDATE` leaves the document alone. A JSON object replaces it. Anything else is left unchanged.
    public static func parse(modelOutput: String) -> KnowledgeUpdateDecision {
        let stripped = stripFences(modelOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return .none }
        if isNoUpdate(stripped) { return .none }
        if let revision = jsonRevision(in: stripped) {
            return .update(revision)
        }
        return .none
    }

    private static func isNoUpdate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.compare("NO UPDATE", options: .caseInsensitive) == .orderedSame { return true }
        if trimmed.compare("NO UPDATE.", options: .caseInsensitive) == .orderedSame { return true }
        return false
    }

    private static func jsonRevision(in text: String) -> KnowledgeRevision? {
        if let revision = decode(text) { return revision }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return decode(String(text[start...end]))
    }

    private static func decode(_ text: String) -> KnowledgeRevision? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        return KnowledgeRevision(title: reply.title, description: reply.description, text: reply.text)
    }

    private static func stripFences(_ text: String) -> String {
        guard let start = text.range(of: "```") else { return text }
        var rest = text[start.upperBound...]
        if let newline = rest.firstIndex(of: "\n") {
            rest = rest[rest.index(after: newline)...]
        }
        if let end = rest.range(of: "```") {
            rest = rest[..<end.lowerBound]
        }
        return String(rest)
    }

    private struct Reply: Decodable {
        var title: String
        var description: String
        var text: String
    }
}
