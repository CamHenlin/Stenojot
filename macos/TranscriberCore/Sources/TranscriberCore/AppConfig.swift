import Foundation

public struct OllamaSettings: Codable, Equatable {
    public var baseUrl: String
    public var model: String

    public init(baseUrl: String, model: String) {
        self.baseUrl = baseUrl
        self.model = model
    }
}

public struct ReplacementRule: Codable, Equatable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decodeIfPresent(String.self, forKey: .to) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
    }

    private enum CodingKeys: String, CodingKey {
        case from
        case to
    }
}

public struct AppConfig: Codable, Equatable {
    public var ollama: OllamaSettings
    public var systemPrompt: String
    public var replacements: [ReplacementRule]
    /// Hugging Face id of the MLX model selected in the Mac app. Nil until the user picks one.
    public var localModelId: String?
    /// Daily-summary instruction. Empty uses the built-in prompt.
    public var summarySystemPrompt: String
    /// Cleanup pass over a finished daily summary. Empty uses the built-in prompt.
    public var summaryPass2SystemPrompt: String
    /// Action-item extraction. Empty uses the built-in prompt.
    public var actionItemsSystemPrompt: String
    /// Bundle ids whose played audio is left out of system-audio capture.
    public var ignoredAudioBundleIDs: [String]

    public init(
        ollama: OllamaSettings = OllamaSettings(baseUrl: "http://localhost:11434", model: "gpt-oss:20b"),
        systemPrompt: String = "",
        replacements: [ReplacementRule] = [],
        localModelId: String? = nil,
        summarySystemPrompt: String = "",
        summaryPass2SystemPrompt: String = "",
        actionItemsSystemPrompt: String = "",
        ignoredAudioBundleIDs: [String] = []
    ) {
        self.ollama = ollama
        self.systemPrompt = systemPrompt
        self.replacements = replacements
        self.localModelId = localModelId
        self.summarySystemPrompt = summarySystemPrompt
        self.summaryPass2SystemPrompt = summaryPass2SystemPrompt
        self.actionItemsSystemPrompt = actionItemsSystemPrompt
        self.ignoredAudioBundleIDs = ignoredAudioBundleIDs
    }
}
