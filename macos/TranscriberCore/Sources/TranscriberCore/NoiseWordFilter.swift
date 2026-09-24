import Foundation

/// Drops a lone "Yeah" or "Okay" that Parakeet hears in dings and other background noise.
public enum NoiseWordFilter {
    /// One of these words, arriving after more than this much silence, is treated as noise.
    public static let pauseThreshold: TimeInterval = 30

    public static func shouldDrop(
        text: String,
        previousText: String?,
        previousTimestamp: String?,
        timestamp: String
    ) -> Bool {
        guard let word = noiseWord(text) else { return false }
        if let previousText, noiseWord(previousText) == word {
            return true
        }
        guard let previousTimestamp,
              let previous = Timestamp.parse(previousTimestamp),
              let current = Timestamp.parse(timestamp) else {
            return false
        }
        return current.timeIntervalSince(previous) > pauseThreshold
    }

    /// "Yeah" and "Okay" (including "OK"), ignoring case and surrounding punctuation.
    static func noiseWord(_ text: String) -> String? {
        let core = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            .lowercased()
        switch core {
        case "yeah":
            return "yeah"
        case "okay", "ok":
            return "okay"
        default:
            return nil
        }
    }
}
