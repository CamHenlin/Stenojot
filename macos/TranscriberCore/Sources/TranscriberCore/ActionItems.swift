import Foundation

/// Transcript runs that are finished, plus the last transcription id they cover.
public struct ClosedTranscriptSegments: Equatable {
    public var segments: [[TranscriptionRow]]
    public var throughId: Int64?

    public init(segments: [[TranscriptionRow]], throughId: Int64?) {
        self.segments = segments
        self.throughId = throughId
    }
}

public enum ActionItems {
    /// Silence this long ends a transcript run and can be sent for extraction.
    public static let gap: TimeInterval = 30

    public static let systemPrompt = """
    You extract action items from a transcript segment. An action item is a specific task someone committed to, was asked to do, or still needs to do. Ignore small talk, questions that were already answered, and vague intentions.

    Reply with a JSON array of short strings. Each string is one action item, written as a concrete task. If there are no action items, reply with [].

    Do not add commentary, markdown, or keys. Example: ["Send the revised deck", "Call Priya about the contract"]
    """

    /// The instruction sent with a finished transcript segment. A blank stored prompt uses the built-in one.
    public static func systemPrompt(stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return systemPrompt }
        return trimmed
    }

    /// Splits transcriptions into runs. A new run starts when consecutive timestamps are at least `gap` seconds apart.
    public static func segments(
        _ rows: [TranscriptionRow],
        gap: TimeInterval = ActionItems.gap
    ) -> [[TranscriptionRow]] {
        let ordered = rows.sorted(by: isOrderedBefore)
        var result: [[TranscriptionRow]] = []
        var current: [TranscriptionRow] = []
        var previous: Date?
        for row in ordered {
            let date = Timestamp.parse(row.timestamp)
            if let previous, let date, date.timeIntervalSince(previous) >= gap, !current.isEmpty {
                result.append(current)
                current = []
            }
            current.append(row)
            if let date {
                previous = date
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// Drops the trailing run when its last line is still inside the gap window.
    /// `closureSlack` lets the idle timer and the stored timestamps agree.
    public static func closedSegments(
        _ rows: [TranscriptionRow],
        now: Date,
        gap: TimeInterval = ActionItems.gap
    ) -> ClosedTranscriptSegments {
        let parts = segments(rows, gap: gap)
        guard !parts.isEmpty else {
            return ClosedTranscriptSegments(segments: [], throughId: nil)
        }
        var included = parts
        if let last = parts.last, let endRow = last.last, let end = Timestamp.parse(endRow.timestamp) {
            if now.timeIntervalSince(end) < gap - 1 {
                included = Array(parts.dropLast())
            }
        }
        let through = included.flatMap(\.self).map(\.id).max()
        return ClosedTranscriptSegments(segments: included, throughId: through)
    }

    public static func userPrompt(transcriptions: [TranscriptionRow]) -> String {
        var transcript = ""
        for row in transcriptions {
            let label = Speaker.label(for: row.speaker)
            transcript += "[\(Timestamp.formatTime(row.timestamp))] \(label): \(row.text)\n"
        }
        return "Transcript segment:\n\n\(transcript)\nJSON array of action items:"
    }

    /// Reads a JSON array, a fenced JSON array, or a bullet list. Anything else adds nothing.
    public static func parse(modelOutput: String) -> [String] {
        let stripped = stripFences(modelOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return [] }
        if let items = jsonItems(in: stripped) {
            return sanitize(items)
        }
        if isEmptySentinel(stripped) { return [] }
        return sanitize(bulletLines(stripped))
    }

    private static func isOrderedBefore(_ lhs: TranscriptionRow, _ rhs: TranscriptionRow) -> Bool {
        switch (Timestamp.parse(lhs.timestamp), Timestamp.parse(rhs.timestamp)) {
        case let (left?, right?) where left != right:
            return left < right
        default:
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id < rhs.id
        }
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

    private static func jsonItems(in text: String) -> [String]? {
        if let direct = decodeItems(text) { return direct }
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end
        else { return nil }
        return decodeItems(String(text[start...end]))
    }

    private static func decodeItems(_ text: String) -> [String]? {
        guard let data = text.data(using: .utf8) else { return nil }
        if let strings = try? JSONDecoder().decode([String].self, from: data) {
            return strings
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let array = json as? [String] { return array }
        if let array = json as? [[String: Any]] {
            let keys = ["text", "item", "action", "task"]
            return array.compactMap { object in
                keys.compactMap { object[$0] as? String }.first
            }
        }
        return nil
    }

    private static func bulletLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            bulletText(line.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func bulletText(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        if rest.hasPrefix(". ") { return String(rest.dropFirst(2)) }
        if rest.hasPrefix(") ") { return String(rest.dropFirst(2)) }
        return nil
    }

    private static func isEmptySentinel(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!\"'"))
        return ["none", "no action items", "n/a", "nothing", "[]"].contains(normalized)
    }

    private static func sanitize(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in items {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isEmptySentinel(text) else { continue }
            let key = text.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(text)
        }
        return result
    }
}
