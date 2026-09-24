import XCTest
@testable import TranscriberCore

final class LocalLanguageModelTests: XCTestCase {
    func testCatalogListsDistinctInstallableModels() {
        let models = LocalLanguageModelCatalog.models
        XCTAssertEqual(models.count, 4)
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        XCTAssertEqual(models.filter(\.recommended).map(\.name), ["Qwen 2.5 7B"])
        for model in models {
            XCTAssertFalse(model.name.isEmpty)
            XCTAssertFalse(model.summary.isEmpty)
            XCTAssertTrue(model.memory.contains("GB"))
            XCTAssertTrue(model.downloadSize.contains("GB"))
            XCTAssertTrue(model.id.hasPrefix("mlx-community/"))
            XCTAssertEqual(LocalLanguageModelCatalog.model(id: model.id), model)
        }
    }

    func testThinkTagFilterDropsHiddenReasoning() {
        var filter = ThinkTagFilter()
        XCTAssertEqual(filter.consume("Hello "), "Hello ")
        XCTAssertEqual(filter.consume("<thi"), "")
        XCTAssertEqual(filter.consume("nk>secret"), "")
        XCTAssertEqual(filter.consume("</think>there"), "there")
        XCTAssertEqual(filter.finish(), "")
    }

    func testThinkTagFilterKeepsTextWhenNoTagCloses() {
        var filter = ThinkTagFilter()
        XCTAssertEqual(filter.consume("Answer"), "Answer")
        XCTAssertEqual(filter.consume("<think>hidden"), "")
        XCTAssertEqual(filter.finish(), "")
    }

    func testConfigRoundTripKeepsTheSelectedModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        let modelId = LocalLanguageModelCatalog.models[2].id
        let config = AppConfig(
            systemPrompt: "Be brief.",
            replacements: [],
            localModelId: modelId
        )
        try ConfigStore.save(config, to: url)
        let loaded = try ConfigStore.load(from: url)
        XCTAssertEqual(loaded.localModelId, modelId)
        XCTAssertEqual(loaded.systemPrompt, "Be brief.")

        let legacy = """
        {"systemPrompt":"Hi","replacements":[]}
        """
        let legacyURL = directory.appendingPathComponent("legacy.json")
        try Data(legacy.utf8).write(to: legacyURL)
        let legacyConfig = try ConfigStore.load(from: legacyURL)
        XCTAssertNil(legacyConfig.localModelId)
        XCTAssertEqual(legacyConfig.systemPrompt, "Hi")
        XCTAssertEqual(legacyConfig.summarySystemPrompt, "")
        XCTAssertEqual(legacyConfig.summaryPass2SystemPrompt, "")
        XCTAssertEqual(legacyConfig.actionItemsSystemPrompt, "")
    }
}
