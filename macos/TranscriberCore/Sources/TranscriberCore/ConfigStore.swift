import Foundation

public enum ConfigStore {
    public static func load(from url: URL) throws -> AppConfig {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(FileConfig.self, from: data)
        return AppConfig(
            ollama: file.ollama ?? OllamaSettings(baseUrl: "http://localhost:11434", model: "gpt-oss:20b"),
            systemPrompt: file.systemPrompt ?? "",
            replacements: file.replacements ?? [],
            localModelId: file.localModelId,
            summarySystemPrompt: file.summarySystemPrompt ?? "",
            summaryPass2SystemPrompt: file.summaryPass2SystemPrompt ?? "",
            actionItemsSystemPrompt: file.actionItemsSystemPrompt ?? ""
        )
    }

    public static func save(_ config: AppConfig, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(config)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}

private struct FileConfig: Codable {
    var ollama: OllamaSettings?
    var systemPrompt: String?
    var replacements: [ReplacementRule]?
    var localModelId: String?
    var summarySystemPrompt: String?
    var summaryPass2SystemPrompt: String?
    var actionItemsSystemPrompt: String?
}
