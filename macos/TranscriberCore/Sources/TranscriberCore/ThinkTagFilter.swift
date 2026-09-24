import Foundation

/// Drops Qwen-style `<think>…</think>` spans from streamed model text.
public struct ThinkTagFilter: Sendable {
    private var pending = ""
    private var skipping = false
    private let openTag = "<think>"
    private let closeTag = "</think>"

    public init() {}

    public mutating func consume(_ chunk: String) -> String {
        pending.append(contentsOf: chunk)
        var output = ""
        while true {
            if skipping {
                guard let range = pending.range(of: closeTag) else {
                    pending = Self.tail(pending, maxLength: closeTag.count - 1)
                    return output
                }
                pending.removeSubrange(..<range.upperBound)
                skipping = false
                continue
            }
            if let range = pending.range(of: openTag) {
                output.append(contentsOf: pending[..<range.lowerBound])
                pending.removeSubrange(..<range.upperBound)
                skipping = true
                continue
            }
            let hold = Self.prefixLength(of: openTag, matchingSuffixOf: pending)
            output.append(contentsOf: pending.dropLast(hold))
            pending = String(pending.suffix(hold))
            return output
        }
    }

    /// Flushes text still held back. An unclosed think span is discarded.
    public mutating func finish() -> String {
        defer {
            pending = ""
            skipping = false
        }
        guard !skipping else { return "" }
        return pending
    }

    private static func tail(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.suffix(maxLength))
    }

    private static func prefixLength(of tag: String, matchingSuffixOf text: String) -> Int {
        let limit = min(tag.count - 1, text.count)
        guard limit > 0 else { return 0 }
        for length in stride(from: limit, through: 1, by: -1) {
            if tag.hasPrefix(text.suffix(length)) {
                return length
            }
        }
        return 0
    }
}
