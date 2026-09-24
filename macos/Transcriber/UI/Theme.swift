import SwiftUI
import TranscriberCore

enum Theme {
    static let background = Color(red: 0.059, green: 0.059, blue: 0.059)
    static let sidebar = Color(red: 0.102, green: 0.102, blue: 0.102)
    static let panel = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let line = Color(white: 0.16)
    static let muted = Color(white: 0.62)
    static let accent = Color(red: 0.357, green: 0.553, blue: 0.937)
    static let note = Color(red: 0.83, green: 0.63, blue: 0.29)
}

func highlightedText(_ text: String, search: String) -> AttributedString {
    var attributed = AttributedString(text)
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    for range in Timeline.searchRanges(in: text, search: trimmed) {
        guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.Index(range.upperBound, within: attributed) else {
            continue
        }
        attributed[lower..<upper].backgroundColor = .yellow.opacity(0.45)
        attributed[lower..<upper].foregroundColor = .black
    }
    return attributed
}
