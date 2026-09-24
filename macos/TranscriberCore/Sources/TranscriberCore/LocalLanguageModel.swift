import Foundation

/// An MLX model the Mac app can download and run on its own.
public struct LocalLanguageModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    /// Memory the weights need while loaded, before a long transcript adds more.
    public var memory: String
    public var downloadSize: String
    public var recommended: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        memory: String,
        downloadSize: String,
        recommended: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.memory = memory
        self.downloadSize = downloadSize
        self.recommended = recommended
    }

    public var requirementLine: String {
        "\(memory) of memory · \(downloadSize) download"
    }
}

public enum LocalLanguageModelCatalog {
    public static let models: [LocalLanguageModel] = [
        LocalLanguageModel(
            id: "mlx-community/gemma-3-1b-it-qat-4bit",
            name: "Gemma 3 1B",
            summary: "Fast on an 8 GB Mac. Fine for a short summary or a simple question. A full day of conversation is more than it handles well.",
            memory: "About 2 GB",
            downloadSize: "0.8 GB"
        ),
        LocalLanguageModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            name: "Llama 3.2 3B",
            summary: "A practical choice on an 8 GB Mac. Writes clear summaries and action items for a few hours of conversation.",
            memory: "About 4 GB",
            downloadSize: "1.8 GB"
        ),
        LocalLanguageModel(
            id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            name: "Qwen 2.5 7B",
            summary: "Best fit for a full day of transcript. Follows the system prompt closely. Comfortable on a 16 GB Mac.",
            memory: "About 7 GB",
            downloadSize: "4.3 GB",
            recommended: true
        ),
        LocalLanguageModel(
            id: "mlx-community/Qwen3-8B-4bit",
            name: "Qwen 3 8B",
            summary: "Stronger reasoning than the 7B, and slower to start an answer. Prefers a 16 GB Mac, with more room on 24 GB.",
            memory: "About 8 GB",
            downloadSize: "4.6 GB"
        ),
    ]

    public static func model(id: String) -> LocalLanguageModel? {
        models.first { $0.id == id }
    }
}
