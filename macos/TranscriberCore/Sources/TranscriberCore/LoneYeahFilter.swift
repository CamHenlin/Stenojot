import Foundation

/// Drops a lone "Yeah" that Parakeet hears in dings and other background noise.
public enum LoneYeahFilter {
    /// A "Yeah" that arrives after more than this much silence is treated as noise.
    public static let pauseThreshold: TimeInterval = 30

    public static func shouldDrop(
        text: String,
        previousText: String?,
        previousTimestamp: String?,
        timestamp: String
    ) -> Bool {
        guard isLoneYeah(text) else { return false }
        if let previousText, isLoneYeah(previousText) {
            return true
        }
        guard let previousTimestamp,
              let previous = Timestamp.parse(previousTimestamp),
              let current = Timestamp.parse(timestamp) else {
            return false
        }
        return current.timeIntervalSince(previous) > pauseThreshold
    }

    static func isLoneYeah(_ text: String) -> Bool {
        let core = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        return core.caseInsensitiveCompare("yeah") == .orderedSame
    }
}
