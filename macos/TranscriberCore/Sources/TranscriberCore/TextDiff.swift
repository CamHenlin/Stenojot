import Foundation

public struct TextDiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case same
        case added
        case removed
        /// Unchanged lines omitted between the lines kept around an edit.
        case skipped(Int)
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum TextDiff {
    /// Line diff of two texts. An empty string has no lines, so the first write of a blank document shows only additions.
    /// `contextLines` keeps that many unchanged lines on either side of an edit and collapses the rest.
    public static func lines(before: String, after: String, contextLines: Int? = 3) -> [TextDiffLine] {
        let diff = lineDiff(lines(of: before), lines(of: after))
        guard let contextLines else { return diff }
        return collapsingUnchanged(diff, context: contextLines)
    }

    /// Empty text is no lines. A trailing newline still produces a final empty line.
    private static func lines(of text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.components(separatedBy: "\n")
    }

    private static func lineDiff(_ old: [String], _ new: [String]) -> [TextDiffLine] {
        let rowCount = old.count
        let columnCount = new.count
        if rowCount * columnCount > 1_000_000 {
            return old.map { TextDiffLine(kind: .removed, text: $0) }
                + new.map { TextDiffLine(kind: .added, text: $0) }
        }
        var lengths = Array(repeating: Array(repeating: 0, count: columnCount + 1), count: rowCount + 1)
        if rowCount > 0 && columnCount > 0 {
            for row in 1...rowCount {
                for column in 1...columnCount {
                    if old[row - 1] == new[column - 1] {
                        lengths[row][column] = lengths[row - 1][column - 1] + 1
                    } else {
                        lengths[row][column] = max(lengths[row - 1][column], lengths[row][column - 1])
                    }
                }
            }
        }
        var reversed: [TextDiffLine] = []
        var row = rowCount
        var column = columnCount
        while row > 0 || column > 0 {
            if row > 0 && column > 0 && old[row - 1] == new[column - 1] {
                reversed.append(TextDiffLine(kind: .same, text: old[row - 1]))
                row -= 1
                column -= 1
            } else if column > 0 && (row == 0 || lengths[row][column - 1] >= lengths[row - 1][column]) {
                reversed.append(TextDiffLine(kind: .added, text: new[column - 1]))
                column -= 1
            } else if row > 0 {
                reversed.append(TextDiffLine(kind: .removed, text: old[row - 1]))
                row -= 1
            }
        }
        return reversed.reversed()
    }

    /// Drops unchanged lines that sit farther than `context` from an added or removed line.
    private static func collapsingUnchanged(_ lines: [TextDiffLine], context: Int) -> [TextDiffLine] {
        let changed = lines.indices.filter { lines[$0].kind == .added || lines[$0].kind == .removed }
        if changed.isEmpty { return lines }
        var keep = Array(repeating: false, count: lines.count)
        for index in changed {
            let lower = max(0, index - context)
            let upper = min(lines.count - 1, index + context)
            for kept in lower...upper {
                keep[kept] = true
            }
        }
        var result: [TextDiffLine] = []
        var skipped = 0
        for (index, line) in lines.enumerated() {
            if keep[index] {
                if skipped > 0 {
                    result.append(TextDiffLine(kind: .skipped(skipped), text: ""))
                    skipped = 0
                }
                result.append(line)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            result.append(TextDiffLine(kind: .skipped(skipped), text: ""))
        }
        return result
    }
}
