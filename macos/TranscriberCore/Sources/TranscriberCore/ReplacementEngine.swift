import Foundation

public enum ReplacementEngine {
    /// Word-boundary, case-insensitive replacements, then punctuation and whitespace cleanup.
    public static func apply(_ rules: [ReplacementRule], to text: String) -> String {
        var result = text
        for rule in rules where !rule.from.isEmpty {
            let escaped = escapeRegex(rule.from)
            let prefix = isWordCharacter(rule.from.first) ? "\\b" : ""
            let suffix = isWordCharacter(rule.from.last) ? "\\b" : ""
            let pattern = prefix + escaped + suffix
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            result = replace(result, regex: regex, template: literalTemplate(rule.to))
        }

        result = replace(result, pattern: ",\\s*,", template: ",")
        result = replace(result, pattern: "\\s+([,.])", template: "$1")
        result = replace(result, pattern: "\\s{2,}", template: " ")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = replace(result, pattern: "^[,\\.\\-–—;:!?\\s]+", template: "")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.range(of: "[A-Za-z0-9]", options: .regularExpression) == nil {
            return ""
        }
        return result
    }

    public static func sanitized(_ rules: [ReplacementRule]) -> [ReplacementRule] {
        rules.compactMap { rule in
            let from = rule.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty else { return nil }
            let to = rule.to.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReplacementRule(from: from, to: to)
        }
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        return replace(text, regex: regex, template: template)
    }

    private static func replace(_ text: String, regex: NSRegularExpression, template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func escapeRegex(_ value: String) -> String {
        let special = CharacterSet(charactersIn: ".*+?^${}()|[]\\")
        return value.unicodeScalars.map { scalar in
            special.contains(scalar) ? "\\\(scalar)" : String(scalar)
        }.joined()
    }

    private static func literalTemplate(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "$$")
    }

    /// JavaScript `\w`: ASCII letters, digits, and underscore.
    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character, character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        let value = scalar.value
        if value == 95 { return true }
        return (value >= 48 && value <= 57)
            || (value >= 65 && value <= 90)
            || (value >= 97 && value <= 122)
    }
}
