import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import TranscriberCore

/// Downloads MLX weights into Application Support and runs them in-process.
@MainActor
final class LocalLLMService {
    private let cache: HubCache
    private let client: HubClient
    private var container: ModelContainer?
    private var loadedId: String?
    /// Chat and action-item extraction share one loaded model, so generations run one at a time.
    private var generationTail: Task<Void, Never>?

    init() {
        let cache = HubCache(cacheDirectory: AppSupport.modelsDirectory)
        self.cache = cache
        client = HubClient(cache: cache)
    }

    func isDownloaded(_ id: String) -> Bool {
        guard let repo = Repo.ID(rawValue: id),
              let commit = cache.resolveRevision(repo: repo, kind: .model, ref: "main"),
              !commit.isEmpty
        else { return false }
        let snapshot = cache.snapshotsDirectory(repo: repo, kind: .model)
            .appendingPathComponent(commit, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: snapshot,
            includingPropertiesForKeys: nil
        ) else { return false }
        let names = files.map(\.lastPathComponent)
        return names.contains("config.json") && names.contains { $0.hasSuffix(".safetensors") }
    }

    func isLoaded(_ id: String) -> Bool {
        loadedId == id && container != nil
    }

    func unloadIfNeeded(keeping id: String) {
        guard loadedId != id else { return }
        container = nil
        loadedId = nil
    }

    func download(
        id: String,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let repo = Repo.ID(rawValue: id) else {
            throw LocalLLMError(message: "That model id is invalid.")
        }
        try AppSupport.ensureDirectory()
        try FileManager.default.createDirectory(at: AppSupport.modelsDirectory, withIntermediateDirectories: true)
        _ = try await client.downloadSnapshot(of: repo, progressHandler: { progress in
            let fraction = progress.fractionCompleted
            guard fraction.isFinite else { return }
            onProgress(min(1, max(0, fraction)))
        })
    }

    func stream(
        modelId: String,
        system: String,
        user: String,
        maxTokens: Int = 2048
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let previous = generationTail
            let task = Task { @MainActor in
                await previous?.value
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                do {
                    let loaded = try await self.loadContainer(modelId: modelId)
                    let trimmed = system.trimmingCharacters(in: .whitespacesAndNewlines)
                    let session = ChatSession(
                        loaded,
                        instructions: trimmed.isEmpty ? nil : trimmed,
                        generateParameters: GenerateParameters(maxTokens: maxTokens),
                        additionalContext: modelId.contains("Qwen3") ? ["enable_thinking": false] : nil
                    )
                    var filter = ThinkTagFilter()
                    for try await chunk in session.streamResponse(to: user) {
                        if Task.isCancelled { break }
                        let visible = filter.consume(chunk)
                        if !visible.isEmpty {
                            continuation.yield(visible)
                        }
                    }
                    if !Task.isCancelled {
                        let tail = filter.finish()
                        if !tail.isEmpty {
                            continuation.yield(tail)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            generationTail = Task { @MainActor in
                await task.value
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func loadContainer(modelId: String) async throws -> ModelContainer {
        if let container, loadedId == modelId {
            return container
        }
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(client),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: modelId)
        )
        container = loaded
        loadedId = modelId
        return loaded
    }
}

struct LocalLLMError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
