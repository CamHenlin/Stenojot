import Foundation

/// One stretch of a day sent to the model for a summary. A new stretch starts only after more than a minute with no transcript.
public struct DailySummaryChunk: Equatable {
    public var transcriptions: [TranscriptionRow]
    public var notes: [AnnotationRow]

    public init(transcriptions: [TranscriptionRow], notes: [AnnotationRow]) {
        self.transcriptions = transcriptions
        self.notes = notes
    }
}

/// Which local days are ready for an automatic summary.
public enum DailySummarySchedule {
    /// Days that finished while the app was still running, from `observedDay` through the day before `now`.
    /// Today is never included. When `observedDay` is already today, the result is empty, so opening the
    /// app after midnight does not summarize a day the app missed.
    public static func completedDays(
        since observedDay: String,
        now: Date,
        calendar: Calendar = .current
    ) -> [String] {
        guard let observed = Timestamp.startOfCalendarDay(observedDay, calendar: calendar) else { return [] }
        let today = calendar.startOfDay(for: now)
        guard observed < today else { return [] }
        var days: [String] = []
        var cursor = observed
        while cursor < today {
            days.append(Timestamp.localDay(cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// The next local midnight strictly after `date`.
    public static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
        if next > date { return next }
        return calendar.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(86_400)
    }
}

/// Builds the prompts and the saved document for one local day.
public enum DailySummaryDocument {
    /// Silence longer than this starts a new stretch. Shorter gaps stay in one stretch, because
    /// two meetings can follow each other with less than a minute between them.
    public static let chunkGap: TimeInterval = 60

    public static let chunkSystemPrompt = """
    You summarize a stretch of a transcribed day. The user will keep your summary and may edit it.

    Write a short summary of what was discussed. Do not reproduce the transcript, quote it line by line, or list every turn.

    This stretch was cut only where more than a minute passed with no transcript. Someone can leave one meeting and join another with less than a minute between them, so this stretch may contain more than one conversation. When you can tell those apart, summarize each conversation on its own. When it is one conversation, write one summary.

    Include the user's notes when they add something the transcript does not. Do not list action items; those are added separately. Do not add a time heading or a preamble.
    """

    /// The instruction sent with each stretch. A blank stored prompt uses the built-in one.
    public static func chunkSystemPrompt(stored: String) -> String {
        storedPrompt(stored, fallback: chunkSystemPrompt)
    }

    /// Instruction for the cleanup pass over a finished daily summary.
    public static let cleanupSystemPrompt = """
    You clean a daily summary the user will keep. The summary includes a date heading, time headings for each stretch, and an Action items section.

    Remove passages that add no information. Drop a sentence or paragraph that only reports a bare acknowledgement, such as someone saying "Yeah", or that only says a person responded without adding context. Use the rest of the summary to decide: keep a short reply when it confirms a decision, answers a question, or otherwise changes what the summary says.

    Leave useful facts, decisions, names, and topics as written. Keep the date heading, the time headings, and the Action items section unchanged. Do not add content. Return only the cleaned summary.
    """

    /// The instruction sent with the full summary. A blank stored prompt uses the built-in one.
    public static func cleanupSystemPrompt(stored: String) -> String {
        storedPrompt(stored, fallback: cleanupSystemPrompt)
    }

    /// Output budget for the cleanup pass. The reply is the summary with passages removed, so the budget tracks the draft length.
    public static func cleanupMaxTokens(for summary: String) -> Int {
        let estimated = max(1, summary.utf8.count / 3)
        return min(16_384, max(2_048, estimated))
    }

    /// The user message for the cleanup pass: the first-pass summary and nothing else.
    public static func cleanupPrompt(_ summary: String) -> String {
        summary
    }

    private static func storedPrompt(_ stored: String, fallback: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed
    }

    public static func hasMaterial(
        transcriptions: [TranscriptionRow],
        annotations: [AnnotationRow],
        actionItems: [ActionItem]
    ) -> Bool {
        !transcriptions.isEmpty || !annotations.isEmpty || !actionItems.isEmpty
    }

    /// Stretches in time order. A gap of one minute stays in the same stretch. A longer gap starts another.
    /// Notes anchored to a transcript stay with that stretch. Notes with no anchor join the stretch already
    /// in progress, or the first stretch when they come before everything else.
    public static func chunks(
        transcriptions: [TranscriptionRow],
        annotations: [AnnotationRow]
    ) -> [DailySummaryChunk] {
        let segments = stretches(transcriptions, gap: chunkGap)
        let knownIds = Set(transcriptions.map(\.id))
        var attached: [Int64: [AnnotationRow]] = [:]
        var loose: [AnnotationRow] = []
        for note in annotations {
            if let anchor = note.afterTranscriptionId, knownIds.contains(anchor) {
                attached[anchor, default: []].append(note)
            } else {
                loose.append(note)
            }
        }

        if segments.isEmpty {
            let notes = annotations.sorted(by: noteIsBefore)
            guard !notes.isEmpty else { return [] }
            return [DailySummaryChunk(transcriptions: [], notes: notes)]
        }

        var grouped = segments.map { rows in
            let notes = rows.flatMap { attached[$0.id] ?? [] }
            return DailySummaryChunk(transcriptions: rows, notes: notes)
        }
        for note in loose {
            placeLoose(note, in: &grouped)
        }
        for index in grouped.indices {
            grouped[index].notes.sort(by: noteIsBefore)
        }
        return grouped
    }

    public static func chunkPrompt(_ chunk: DailySummaryChunk, index: Int, count: Int) -> String {
        var text = "Stretch \(index) of \(count) (\(heading(for: chunk))).\n\n"
        text += """
        A new stretch starts only after more than a minute with no transcript. This stretch may contain more than one conversation if one ended and the next began sooner than that. Summarize each conversation you can tell apart. Do not copy the transcript.

        """
        if chunk.transcriptions.isEmpty {
            text += "There is no transcript in this stretch, only notes.\n"
        } else {
            for row in chunk.transcriptions {
                let label = Speaker.label(for: row.speaker)
                text += "[\(Timestamp.formatTime(row.timestamp))] \(label): \(row.text)\n"
            }
        }
        if !chunk.notes.isEmpty {
            text += "Notes:\n"
            for note in chunk.notes {
                text += "- [\(note.kind.label)] \(note.text)\n"
            }
        }
        text += "\nWrite the summary.\n"
        return text
    }

    public static func heading(for chunk: DailySummaryChunk) -> String {
        let times = chunk.transcriptions.map { Timestamp.formatTime($0.timestamp) }
        if let first = times.first {
            guard let last = times.last, last != first else { return first }
            return "\(first)–\(last)"
        }
        return "Notes"
    }

    /// The saved document: one summary per stretch, then the action items already extracted that day.
    public static func assemble(day: String, sections: [String], actionItems: [ActionItem]) -> String {
        var text = "\(Timestamp.formatLongDate(day))\n"
        if !sections.isEmpty {
            text += "\n" + sections.joined(separator: "\n\n") + "\n"
        }
        text += "\nAction items\n"
        text += actionItemBlock(actionItems)
        return text
    }

    public static func section(heading: String, summary: String) -> String {
        "\(heading)\n\(summary)"
    }

    private static func stretches(
        _ rows: [TranscriptionRow],
        gap: TimeInterval
    ) -> [[TranscriptionRow]] {
        let ordered = rows.sorted(by: transcriptionIsBefore)
        var result: [[TranscriptionRow]] = []
        var current: [TranscriptionRow] = []
        var previous: Date?
        for row in ordered {
            let date = Timestamp.parse(row.timestamp)
            if let previous, let date, date.timeIntervalSince(previous) > gap, !current.isEmpty {
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

    private static func placeLoose(_ note: AnnotationRow, in chunks: inout [DailySummaryChunk]) {
        guard !chunks.isEmpty else { return }
        var target = 0
        if let noteDate = Timestamp.parse(note.timestamp) {
            for (index, chunk) in chunks.enumerated() {
                guard let first = chunk.transcriptions.first,
                      let start = Timestamp.parse(first.timestamp) else { continue }
                if start <= noteDate {
                    target = index
                }
            }
        }
        chunks[target].notes.append(note)
    }

    private static func actionItemBlock(_ items: [ActionItem]) -> String {
        let ordered = items.sorted(by: actionItemIsBefore)
        if ordered.isEmpty { return "- (none)\n" }
        return ordered.map { item in
            let state = item.done ? "done" : "open"
            return "- [\(state)] [\(Timestamp.formatTime(item.timestamp))] \(item.text)\n"
        }.joined()
    }

    private static func transcriptionIsBefore(_ lhs: TranscriptionRow, _ rhs: TranscriptionRow) -> Bool {
        switch (Timestamp.parse(lhs.timestamp), Timestamp.parse(rhs.timestamp)) {
        case let (left?, right?) where left != right:
            return left < right
        default:
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
    }

    private static func noteIsBefore(_ lhs: AnnotationRow, _ rhs: AnnotationRow) -> Bool {
        switch (Timestamp.parse(lhs.timestamp), Timestamp.parse(rhs.timestamp)) {
        case let (left?, right?) where left != right:
            return left < right
        default:
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
    }

    private static func actionItemIsBefore(_ lhs: ActionItem, _ rhs: ActionItem) -> Bool {
        switch (Timestamp.parse(lhs.timestamp), Timestamp.parse(rhs.timestamp)) {
        case let (left?, right?) where left != right:
            return left < right
        default:
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
    }
}
