import Foundation

public enum TimelineKind: String, Equatable {
    case transcription
    case annotation
}

public struct TimelineItem: Equatable, Identifiable {
    public var kind: TimelineKind
    public var sourceId: Int64
    public var timestamp: String
    public var text: String
    public var afterTranscriptionId: Int64?
    public var speaker: String?
    public var annotationKind: AnnotationKind?

    public var id: String { "\(kind.rawValue)-\(sourceId)" }

    public init(
        kind: TimelineKind,
        sourceId: Int64,
        timestamp: String,
        text: String,
        afterTranscriptionId: Int64? = nil,
        speaker: String? = nil,
        annotationKind: AnnotationKind? = nil
    ) {
        self.kind = kind
        self.sourceId = sourceId
        self.timestamp = timestamp
        self.text = text
        self.afterTranscriptionId = afterTranscriptionId
        self.speaker = speaker
        self.annotationKind = annotationKind
    }
}

public struct CopyText: Equatable {
    public var text: String
    public var count: Int

    public init(text: String, count: Int) {
        self.text = text
        self.count = count
    }
}

public enum Timeline {
    public static func merge(
        transcriptions: [TranscriptionRow],
        annotations: [AnnotationRow]
    ) -> [TimelineItem] {
        var byAnchor: [Int64: [AnnotationRow]] = [:]
        var leading: [AnnotationRow] = []
        for annotation in annotations {
            if let anchor = annotation.afterTranscriptionId {
                byAnchor[anchor, default: []].append(annotation)
            } else {
                leading.append(annotation)
            }
        }

        var result: [TimelineItem] = leading.map(item(from:))
        for transcription in transcriptions {
            result.append(item(from: transcription))
            if let notes = byAnchor[transcription.id] {
                result.append(contentsOf: notes.map(item(from:)))
            }
        }
        return result
    }

    /// Plain text for the inclusive span between two transcription ids, notes included.
    public static func copyText(items: [TimelineItem], fromId: Int64, toId: Int64) -> CopyText? {
        let low = min(fromId, toId)
        let high = max(fromId, toId)
        var lowIndex: Int?
        var highIndex: Int?
        for (index, item) in items.enumerated() where item.kind == .transcription {
            if item.sourceId == low { lowIndex = index }
            if item.sourceId == high { highIndex = index }
        }
        guard let lowIndex, let highIndex else { return nil }
        let start = min(lowIndex, highIndex)
        let end = max(lowIndex, highIndex)

        var lines: [String] = []
        var count = 0
        for item in items[start...end] {
            if item.kind == .transcription {
                let label = Speaker.label(for: item.speaker)
                lines.append("\(Timestamp.formatTime(item.timestamp))  \(label): \(item.text)")
                count += 1
            } else {
                let label = item.annotationKind?.label ?? AnnotationKind.note.label
                lines.append("[\(label)] \(item.text)")
            }
        }
        return CopyText(text: lines.joined(separator: "\n"), count: count)
    }

    public static func searchRanges(in text: String, search: String) -> [Range<String.Index>] {
        guard !search.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: search, options: [.caseInsensitive], range: start..<text.endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }

    private static func item(from row: TranscriptionRow) -> TimelineItem {
        TimelineItem(
            kind: .transcription,
            sourceId: row.id,
            timestamp: row.timestamp,
            text: row.text,
            speaker: row.speaker
        )
    }

    private static func item(from row: AnnotationRow) -> TimelineItem {
        TimelineItem(
            kind: .annotation,
            sourceId: row.id,
            timestamp: row.timestamp,
            text: row.text,
            afterTranscriptionId: row.afterTranscriptionId,
            annotationKind: row.kind
        )
    }
}
