import Foundation

public enum LLMPrompt {
    public static func userContent(
        transcriptions: [TranscriptionRow],
        annotations: [AnnotationRow],
        prompt: String,
        date: String?,
        hasRange: Bool
    ) -> String {
        var transcript = ""
        for row in transcriptions {
            let label = Speaker.label(for: row.speaker)
            transcript += "[\(Timestamp.formatTime(row.timestamp))] \(label): \(row.text)\n"
        }
        if !annotations.isEmpty {
            transcript += "\n--- User Notes ---\n"
            for note in annotations {
                transcript += "[\(note.kind.label)] \(note.text)\n"
            }
        }

        let contextLabel: String
        if hasRange {
            let count = transcriptions.count
            contextLabel = "a selected range of \(count) message\(count == 1 ? "" : "s")"
        } else if let date {
            contextLabel = date
        } else {
            contextLabel = "all time"
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Here is the transcript for \(contextLabel):\n\n\(transcript)\n\n\(trimmed)"
    }
}
