import AppKit
import Darwin
import Foundation
import Observation
import TranscriberCore
import UniformTypeIdentifiers

enum InlineInsert: Equatable {
    case beforeFirst
    case after(Int64)
}

private struct DailySummaryJob {
    var existing: DailySummary?
    var transcriptions: [TranscriptionRow]
    var annotations: [AnnotationRow]
    var actionItems: [ActionItem]
    var dayIsListed: Bool
}

@MainActor
@Observable
final class AppModel {
    var config = AppConfig()
    var dates: [String] = []
    var items: [TimelineItem] = []
    var selectedDate: String?
    var searchInput = ""
    var appliedSearch = ""
    /// Set after the full transcript loads so the list can scroll to a search hit.
    var scrollToItemId: String?
    /// Bumped once the full day is in memory, so the list rebuilds before scrolling.
    var transcriptListID = 0
    var statusText = "Starting…"
    var activityDetail: String?
    var setupError: String?
    var isListening = false
    /// True while the engine is being prepared or the sidecar is launching.
    var isPreparingTranscription = false
    /// User preference for this launch. Starts on so transcription begins with the app.
    private var transcriptionEnabled = true
    var isDatabaseReady = false
    var isLoading = false
    var showFirstLaunch = false
    var alertMessage: String?

    var inlineInsert: InlineInsert?
    var inlineText = ""
    var editingAnnotationId: Int64?
    var editingText = ""
    var bottomNoteText = ""

    var copyToast: String?

    /// True after Select message, until a click sets the end of the range.
    var rangeSelecting = false
    var rangeFromId: Int64?
    var rangeToId: Int64?
    /// Hover target while choosing the end. Draws a preview only; the LLM range updates on click.
    var rangeHoverId: Int64?

    var llmAvailable = false
    var llmOpen = false
    var llmPrompt = ""
    var llmResponse = ""
    var llmStreaming = false
    var llmLoadingModel = false
    var systemPromptSaved = false
    var summarySystemPromptSaved = false
    var summaryPass2SystemPromptSaved = false
    var actionItemsSystemPromptSaved = false
    var knowledgeSystemPromptSaved = false
    var llmDownloadingId: String?
    var llmDownloadFraction: Double?
    var llmDownloadError: String?

    var actionItems: [ActionItem] = []
    var actionItemsOpen = true
    var actionItemDraft = ""
    var actionItemsExtracting = false
    var actionItemError: String?

    var generatingSummaryDay: String?
    var summaryStreamText = ""
    var summaryLoadingModel = false
    /// Live line for the open summary window: which stretch is in progress, or that the second pass is running.
    var summaryProgress: String?
    var summaryStatusDay: String?
    var summaryStatus: String?
    /// Bumped when a day's saved summary text changes, so an open summary window can refresh.
    var dailySummaryRevision = 0

    /// Documents in the knowledge base, newest edit first.
    var knowledgeDocuments: [KnowledgeDocument] = []
    /// Previous saves for each document, newest archived save first.
    var knowledgeVersionsByDocument: [Int64: [KnowledgeDocumentVersion]] = [:]
    /// Bumped when a document is saved or removed, so an open document window can refresh or close.
    var knowledgeRevision = 0
    var knowledgeCreateInFlight = false

    var applyAllResult = ""
    var applyingAll = false

    var pinnedToBottom = true
    var scrollToken = 0
    /// GitHub release page when a newer version has been found. Nil hides the toolbar button.
    var updateReleaseURL: URL?
    /// True while the Music app is playing and the pause setting is on.
    var musicHoldingTranscription = false

    private var store: TranscriptStore?
    private let pythonEnvironment = PythonEnvironment()
    private let transcriber = TranscriberService()
    private let dbQueue = DispatchQueue(label: "transcriber.database")
    private var didStart = false
    private var reloadGeneration = 0
    private var setupGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var suppressNextSearchChange = false
    private var pendingScrollItemId: String?
    private let localLLM = LocalLLMService()
    private var llmTask: Task<Void, Never>?
    private var llmGeneration = 0
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration = 0
    private var toastTask: Task<Void, Never>?
    private var savedTask: Task<Void, Never>?
    private var summaryPromptSavedTask: Task<Void, Never>?
    private var summaryPass2PromptSavedTask: Task<Void, Never>?
    private var actionItemsPromptSavedTask: Task<Void, Never>?
    private var knowledgePromptSavedTask: Task<Void, Never>?
    private var gapTask: Task<Void, Never>?
    private var extractTask: Task<Void, Never>?
    private var extractGeneration = 0
    private var actionItemExtractionQueued = false
    private var actionItemScanInFlight = false
    private var dailySummaryTextByDay: [String: String] = [:]
    private var summaryQueue: [String] = []
    private var summaryManual: Set<String> = []
    /// Days whose next run should replace a summary that is already saved.
    private var summaryReplace: Set<String> = []
    private var summaryPump: Task<Void, Never>?
    private var summaryGeneration = 0
    private var midnightTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var observedLocalDay: String?
    private let updateChecker = UpdateChecker()
    private let musicMonitor = MusicPlaybackMonitor()

    var transcriptionCount: Int {
        items.reduce(0) { $0 + ($1.kind == .transcription ? 1 : 0) }
    }

    var toolbarTitle: String {
        let label = selectedDate.map { Timestamp.formatDateLabel($0) } ?? "Transcriptions"
        if !searchInput.isEmpty {
            return "Search: \"\(searchInput)\" in \(label)"
        }
        return label
    }

    var showsLLMPanel: Bool {
        isDatabaseReady && selectedDate != nil
    }

    var llmModelTitle: String {
        guard let id = config.localModelId, let languageModel = LocalLanguageModelCatalog.model(id: id) else {
            return "No model"
        }
        return languageModel.name
    }

    var hasRange: Bool {
        rangeFromId != nil && rangeToId != nil
    }

    var rangeCount: Int {
        guard let from = rangeFromId, let to = rangeToId else { return 0 }
        return transcriptionCount(from: from, to: to)
    }

    /// Messages the next click will include while the end of the range is still being chosen.
    var previewCount: Int {
        guard rangeSelecting, let from = rangeFromId, let hover = rangeHoverId else { return rangeCount }
        return transcriptionCount(from: from, to: hover)
    }

    private func transcriptionCount(from: Int64, to: Int64) -> Int {
        let low = min(from, to)
        let high = max(from, to)
        return items.reduce(0) { count, item in
            guard item.kind == .transcription, item.sourceId >= low, item.sourceId <= high else { return count }
            return count + 1
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        signal(SIGPIPE, SIG_IGN)
        startUpdateChecks()
        wireTranscriber()
        do {
            try AppSupport.ensureDirectory()
            if FileManager.default.fileExists(atPath: AppSupport.configURL.path) {
                config = try ConfigStore.load(from: AppSupport.configURL)
            }
            applyIgnoredAudioApps()
            applyMusicPauseSetting()
            refreshLocalModel()
        } catch {
            alertMessage = error.localizedDescription
        }
        guard FileManager.default.fileExists(atPath: AppSupport.databaseURL.path) else {
            showFirstLaunch = true
            statusText = "Import a database to begin"
            return
        }
        do {
            try openStore()
        } catch {
            alertMessage = error.localizedDescription
            showFirstLaunch = true
            return
        }
        isLoading = true
        reload(scrollToBottom: true)
        setupPythonAndListen()
    }

    func shutdown() {
        updateChecker.stop()
        musicMonitor.stop()
        setupGeneration += 1
        pythonEnvironment.cancel()
        searchTask?.cancel()
        llmTask?.cancel()
        downloadTask?.cancel()
        gapTask?.cancel()
        extractTask?.cancel()
        extractGeneration += 1
        stopDailySummaryClock()
        cancelDailySummaryWork()
        transcriber.stop()
        reloadGeneration += 1
        dbQueue.sync {}
        store = nil
    }

    func checkForUpdates() {
        updateChecker.checkForUpdates()
    }

    func openUpdate() {
        guard let updateReleaseURL else { return }
        NSWorkspace.shared.open(updateReleaseURL)
    }

    private func startUpdateChecks() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        updateChecker.start(currentVersion: version) { [weak self] url in
            self?.updateReleaseURL = url
        }
    }

    func selectDate(_ date: String) {
        guard date != selectedDate else { return }
        selectedDate = date
        clearTransientState()
        reload(scrollToBottom: true)
    }

    func searchChanged() {
        if suppressNextSearchChange {
            suppressNextSearchChange = false
            return
        }
        pendingScrollItemId = nil
        searchTask?.cancel()
        let snapshot = searchInput
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            appliedSearch = snapshot
            reload(scrollToBottom: true)
        }
    }

    /// Leaves search and opens the full day scrolled to this item.
    func showInTranscript(_ item: TimelineItem) {
        searchTask?.cancel()
        suppressNextSearchChange = true
        searchInput = ""
        appliedSearch = ""
        pinnedToBottom = false
        pendingScrollItemId = item.id
        reload(scrollToBottom: false)
    }

    func handleEscape() -> Bool {
        if rangeSelecting {
            clearRange()
            return true
        }
        if inlineInsert != nil {
            inlineInsert = nil
            inlineText = ""
            return true
        }
        if editingAnnotationId != nil {
            editingAnnotationId = nil
            editingText = ""
            return true
        }
        return false
    }

    func isInRange(_ id: Int64) -> Bool {
        guard let from = rangeFromId, let to = rangeToId else { return false }
        return id >= min(from, to) && id <= max(from, to)
    }

    func isInRangePreview(_ id: Int64) -> Bool {
        guard rangeSelecting, let from = rangeFromId, let hover = rangeHoverId else { return false }
        return id >= min(from, hover) && id <= max(from, hover)
    }

    func isRangeEndpoint(_ id: Int64) -> Bool {
        if id == rangeFromId || id == rangeToId { return true }
        return rangeSelecting && id == rangeHoverId
    }

    /// Selects this message as the LLM context. The next click extends the range.
    func beginRangeSelection(at id: Int64) {
        rangeSelecting = true
        rangeFromId = id
        rangeToId = id
        rangeHoverId = id
    }

    func previewRangeEnd(_ id: Int64) {
        guard rangeSelecting else { return }
        rangeHoverId = id
    }

    func completeRange(at id: Int64) {
        guard rangeSelecting, let from = rangeFromId else { return }
        if from > id {
            rangeFromId = id
            rangeToId = from
        } else {
            rangeToId = id
        }
        rangeSelecting = false
        rangeHoverId = nil
    }

    func clearRange() {
        rangeFromId = nil
        rangeToId = nil
        rangeHoverId = nil
        rangeSelecting = false
    }

    func copySelectedRange() {
        guard hasRange, let from = rangeFromId, let to = rangeToId else { return }
        guard let built = Timeline.copyText(items: items, fromId: from, toId: to) else {
            showToast("Could not build selection")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(built.text, forType: .string)
        let count = built.count
        showToast("Copied \(count) message\(count == 1 ? "" : "s")")
    }

    func saveInlineNote() {
        let text = inlineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let after: Int64?
        switch inlineInsert {
        case .beforeFirst:
            after = nil
        case .after(let id):
            after = id
        case nil:
            return
        }
        insertNote(after: after, text: text, scrollToBottom: false)
        inlineInsert = nil
        inlineText = ""
    }

    func saveBottomNote() {
        let text = bottomNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let last = items.last { $0.kind == .transcription }?.sourceId
        insertNote(after: last, text: text, scrollToBottom: true)
        bottomNoteText = ""
    }

    func beginEdit(_ item: TimelineItem) {
        editingAnnotationId = item.sourceId
        editingText = item.text
    }

    func saveEdit() {
        guard let id = editingAnnotationId else { return }
        let text = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store else { return }
        dbQueue.async {
            do {
                try store.updateAnnotation(id: id, text: text)
                DispatchQueue.main.async {
                    self.editingAnnotationId = nil
                    self.editingText = ""
                    self.reload(scrollToBottom: false)
                }
            } catch {
                DispatchQueue.main.async { self.alertMessage = error.localizedDescription }
            }
        }
    }

    func deleteAnnotation(_ id: Int64) {
        guard let store else { return }
        dbQueue.async {
            do {
                try store.deleteAnnotation(id: id)
                DispatchQueue.main.async { self.reload(scrollToBottom: false) }
            } catch {
                DispatchQueue.main.async { self.alertMessage = error.localizedDescription }
            }
        }
    }

    /// Prompt shown in the transcript editor. Empty means no extra instruction is sent.
    var transcriptSystemPromptText: String {
        config.systemPrompt
    }

    func saveTranscriptSystemPrompt(_ text: String) {
        config.systemPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AppSupport.ensureDirectory()
            try ConfigStore.save(config, to: AppSupport.configURL)
            systemPromptSaved = true
            savedTask?.cancel()
            savedTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                systemPromptSaved = false
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Prompt shown in the summary editor. A blank stored value is the built-in prompt.
    var summarySystemPromptText: String {
        DailySummaryDocument.chunkSystemPrompt(stored: config.summarySystemPrompt)
    }

    func saveSummarySystemPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        config.summarySystemPrompt = trimmed == DailySummaryDocument.chunkSystemPrompt ? "" : trimmed
        do {
            try AppSupport.ensureDirectory()
            try ConfigStore.save(config, to: AppSupport.configURL)
            summarySystemPromptSaved = true
            summaryPromptSavedTask?.cancel()
            summaryPromptSavedTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                summarySystemPromptSaved = false
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Prompt shown in the Summary Pass 2 editor. A blank stored value is the built-in prompt.
    var summaryPass2SystemPromptText: String {
        DailySummaryDocument.cleanupSystemPrompt(stored: config.summaryPass2SystemPrompt)
    }

    func saveSummaryPass2SystemPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        config.summaryPass2SystemPrompt = trimmed == DailySummaryDocument.cleanupSystemPrompt ? "" : trimmed
        do {
            try AppSupport.ensureDirectory()
            try ConfigStore.save(config, to: AppSupport.configURL)
            summaryPass2SystemPromptSaved = true
            summaryPass2PromptSavedTask?.cancel()
            summaryPass2PromptSavedTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                summaryPass2SystemPromptSaved = false
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Prompt shown in the action-item editor. A blank stored value is the built-in prompt.
    var actionItemsSystemPromptText: String {
        ActionItems.systemPrompt(stored: config.actionItemsSystemPrompt)
    }

    func saveActionItemsSystemPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        config.actionItemsSystemPrompt = trimmed == ActionItems.systemPrompt ? "" : trimmed
        do {
            try AppSupport.ensureDirectory()
            try ConfigStore.save(config, to: AppSupport.configURL)
            actionItemsSystemPromptSaved = true
            actionItemsPromptSavedTask?.cancel()
            actionItemsPromptSavedTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                actionItemsSystemPromptSaved = false
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Prompt shown in the knowledge update editor. A blank stored value is the built-in prompt.
    var knowledgeSystemPromptText: String {
        KnowledgeUpdates.systemPrompt(stored: config.knowledgeSystemPrompt)
    }

    func saveKnowledgeSystemPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        config.knowledgeSystemPrompt = trimmed == KnowledgeUpdates.systemPrompt ? "" : trimmed
        do {
            try AppSupport.ensureDirectory()
            try ConfigStore.save(config, to: AppSupport.configURL)
            knowledgeSystemPromptSaved = true
            knowledgePromptSavedTask?.cancel()
            knowledgePromptSavedTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                knowledgeSystemPromptSaved = false
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func setAudioCaptureIgnored(bundleID: String, ignored: Bool) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var ids = config.ignoredAudioBundleIDs
        if ignored {
            guard !ids.contains(trimmed) else { return }
            ids.append(trimmed)
        } else {
            guard ids.contains(trimmed) else { return }
            ids.removeAll { $0 == trimmed }
        }
        config.ignoredAudioBundleIDs = ids
        do {
            try AppSupport.ensureDirectory()
            try ConfigStore.save(config, to: AppSupport.configURL)
            applyIgnoredAudioApps()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func applyIgnoredAudioApps() {
        transcriber.setExcludedAudioBundleIDs(Set(config.ignoredAudioBundleIDs))
    }

    func setPauseWhileMusicPlaying(_ enabled: Bool) {
        guard config.pauseWhileMusicPlaying != enabled else { return }
        config.pauseWhileMusicPlaying = enabled
        do {
            try AppSupport.ensureDirectory()
            try ConfigStore.save(config, to: AppSupport.configURL)
        } catch {
            alertMessage = error.localizedDescription
        }
        applyMusicPauseSetting()
    }

    private func applyMusicPauseSetting() {
        guard config.pauseWhileMusicPlaying else {
            musicMonitor.stop()
            setMusicHold(false)
            return
        }
        musicMonitor.onPlayingChanged = { [weak self] playing in
            self?.setMusicHold(playing)
        }
        musicMonitor.start()
    }

    private func setMusicHold(_ playing: Bool) {
        let hold = config.pauseWhileMusicPlaying && playing
        guard musicHoldingTranscription != hold else { return }
        musicHoldingTranscription = hold
        transcriber.setHoldForMusic(hold)
        if hold {
            TranscriptionLog.info("Pausing transcription while Music is playing.")
        } else if config.pauseWhileMusicPlaying {
            TranscriptionLog.info("Resuming transcription. Music is paused or stopped.")
        }
    }

    @discardableResult
    func saveReplacements(_ rules: [ReplacementRule]) throws -> [ReplacementRule] {
        let cleaned = ReplacementEngine.sanitized(rules)
        config.replacements = cleaned
        try AppSupport.ensureDirectory()
        try ConfigStore.save(config, to: AppSupport.configURL)
        return cleaned
    }

    func applyAllReplacements(_ rules: [ReplacementRule]) {
        do {
            _ = try saveReplacements(rules)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        let saved = config.replacements
        guard !saved.isEmpty else {
            applyAllResult = "No replacement rules configured"
            return
        }
        guard let store else { return }
        applyingAll = true
        applyAllResult = ""
        dbQueue.async {
            do {
                let result = try store.applyReplacements(saved)
                DispatchQueue.main.async {
                    self.applyingAll = false
                    var parts = ["Updated \(result.updated) of \(result.total)"]
                    if result.deleted > 0 {
                        parts.append("removed \(result.deleted) empty")
                    }
                    self.applyAllResult = parts.joined(separator: ", ")
                    self.reload(scrollToBottom: false)
                }
            } catch {
                DispatchQueue.main.async {
                    self.applyingAll = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func sendLLM() {
        let prompt = llmPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !llmStreaming, let store else { return }
        llmGeneration += 1
        let generation = llmGeneration
        llmTask?.cancel()
        llmStreaming = true
        llmResponse = ""
        let date = selectedDate
        let hasRange = rangeFromId != nil && rangeToId != nil
        let fromId = hasRange ? min(rangeFromId!, rangeToId!) : nil
        let toId = hasRange ? max(rangeFromId!, rangeToId!) : nil
        let system = config.systemPrompt
        guard llmAvailable, let modelId = config.localModelId else {
            llmOpen = true
            llmStreaming = false
            llmLoadingModel = false
            llmResponse = "Choose a language model from LLM Settings in the menu bar."
            return
        }
        llmLoadingModel = !localLLM.isLoaded(modelId)
        dbQueue.async {
            do {
                let context = try store.fetchModelContext(
                    date: hasRange ? nil : date,
                    fromId: fromId,
                    toId: toId
                )
                if context.transcriptions.isEmpty && context.annotations.isEmpty {
                    DispatchQueue.main.async {
                        guard generation == self.llmGeneration else { return }
                        self.llmResponse = "Error: No transcriptions found for this selection"
                        self.llmStreaming = false
                        self.llmLoadingModel = false
                    }
                    return
                }
                let user = LLMPrompt.userContent(
                    transcriptions: context.transcriptions,
                    annotations: context.annotations,
                    prompt: prompt,
                    date: date,
                    hasRange: hasRange
                )
                let afterTranscriptionId = context.transcriptions.last?.id
                DispatchQueue.main.async {
                    self.streamLLM(
                        modelId: modelId,
                        system: system,
                        user: user,
                        generation: generation,
                        afterTranscriptionId: afterTranscriptionId,
                        day: date
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.llmGeneration else { return }
                    self.llmResponse = "Error: \(error.localizedDescription)"
                    self.llmStreaming = false
                    self.llmLoadingModel = false
                }
            }
        }
    }

    func refreshLocalModel() {
        guard let id = config.localModelId, LocalLanguageModelCatalog.model(id: id) != nil else {
            llmAvailable = false
            return
        }
        llmAvailable = localLLM.isDownloaded(id)
    }

    func isLocalModelDownloaded(_ id: String) -> Bool {
        localLLM.isDownloaded(id)
    }

    func downloadLocalModel(_ id: String) {
        guard LocalLanguageModelCatalog.model(id: id) != nil else { return }
        if localLLM.isDownloaded(id) {
            useLocalModel(id)
            return
        }
        guard llmDownloadingId != id else { return }
        downloadTask?.cancel()
        downloadGeneration += 1
        let generation = downloadGeneration
        llmDownloadingId = id
        llmDownloadFraction = 0
        llmDownloadError = nil
        downloadTask = Task {
            do {
                try await localLLM.download(id: id) { fraction in
                    guard generation == self.downloadGeneration else { return }
                    self.llmDownloadFraction = fraction
                }
                guard generation == self.downloadGeneration else { return }
                try self.activateLocalModel(id)
                self.llmDownloadingId = nil
                self.llmDownloadFraction = nil
            } catch is CancellationError {
                guard generation == self.downloadGeneration else { return }
                self.llmDownloadingId = nil
                self.llmDownloadFraction = nil
            } catch {
                guard generation == self.downloadGeneration else { return }
                self.llmDownloadingId = nil
                self.llmDownloadFraction = nil
                self.llmDownloadError = error.localizedDescription
            }
        }
    }

    func useLocalModel(_ id: String) {
        guard localLLM.isDownloaded(id) else { return }
        downloadGeneration += 1
        downloadTask?.cancel()
        llmDownloadingId = nil
        llmDownloadFraction = nil
        do {
            try activateLocalModel(id)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func activateLocalModel(_ id: String) throws {
        if config.localModelId != id {
            llmTask?.cancel()
            llmGeneration += 1
            llmStreaming = false
            llmLoadingModel = false
            extractTask?.cancel()
            extractGeneration += 1
            actionItemsExtracting = false
            actionItemScanInFlight = false
            actionItemExtractionQueued = false
        }
        config.localModelId = id
        try AppSupport.ensureDirectory()
        try ConfigStore.save(config, to: AppSupport.configURL)
        localLLM.unloadIfNeeded(keeping: id)
        llmAvailable = true
        llmDownloadError = nil
        extractActionItemsIfNeeded()
    }

    var transcriptionRunning: Bool {
        isListening || isPreparingTranscription
    }

    func startTranscription() {
        transcriptionEnabled = true
        setupError = nil
        setupPythonAndListen()
    }

    func stopTranscription() {
        transcriptionEnabled = false
        setupGeneration += 1
        pythonEnvironment.cancel()
        transcriber.stop()
        isPreparingTranscription = false
        isListening = false
        activityDetail = nil
        setupError = nil
        statusText = "Transcription stopped"
    }

    func restartTranscriber() {
        startTranscription()
    }

    func promptImportDatabase() {
        guard let url = chooseFile(title: "Import Transcription Database", extension: "db") else { return }
        Task { await importDatabase(from: url) }
    }

    func promptImportConfig() {
        guard let url = chooseFile(title: "Import Settings", extension: "json") else { return }
        do {
            try importConfig(from: url)
            refreshLocalModel()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func completeFirstLaunch(databaseURL: URL?, configURL: URL?, empty: Bool) async {
        do {
            if let configURL {
                try importConfig(from: configURL)
            }
            if empty {
                if !FileManager.default.fileExists(atPath: AppSupport.configURL.path) {
                    try AppSupport.ensureDirectory()
                    try ConfigStore.save(config, to: AppSupport.configURL)
                }
                prepareForDatabaseSwap()
                try await Task.detached {
                    try DatabaseImporter.createEmptyDatabase(at: AppSupport.databaseURL)
                }.value
                try openStore()
                showFirstLaunch = false
                isLoading = true
                reload(scrollToBottom: true)
                refreshLocalModel()
                setupPythonAndListen()
            } else if let databaseURL {
                await importDatabase(from: databaseURL)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func importDatabase(from url: URL) async {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        prepareForDatabaseSwap()
        do {
            try await Task.detached {
                try DatabaseImporter.importDatabase(from: url, to: AppSupport.databaseURL)
            }.value
            try openStore()
            showFirstLaunch = false
            isLoading = true
            reload(scrollToBottom: true)
            refreshLocalModel()
            setupPythonAndListen()
        } catch {
            alertMessage = error.localizedDescription
            if FileManager.default.fileExists(atPath: AppSupport.databaseURL.path) {
                try? openStore()
                reload(scrollToBottom: true)
                setupPythonAndListen()
            } else {
                showFirstLaunch = true
            }
        }
    }

    private func importConfig(from url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let loaded = try ConfigStore.load(from: url)
        try AppSupport.ensureDirectory()
        try ConfigStore.save(loaded, to: AppSupport.configURL)
        config = loaded
        applyIgnoredAudioApps()
        applyMusicPauseSetting()
        refreshLocalModel()
    }

    private func chooseFile(title: String, extension ext: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func openStore() throws {
        store = try TranscriptStore(path: AppSupport.databaseURL.path)
        isDatabaseReady = true
        loadActionItems()
        loadDailySummaries()
        loadKnowledgeDocuments()
        startDailySummaryClock()
    }

    private func prepareForDatabaseSwap() {
        setupGeneration += 1
        pythonEnvironment.cancel()
        transcriber.stop()
        gapTask?.cancel()
        extractTask?.cancel()
        extractGeneration += 1
        stopDailySummaryClock()
        cancelDailySummaryWork()
        dailySummaryTextByDay = [:]
        dailySummaryRevision += 1
        knowledgeDocuments = []
        knowledgeVersionsByDocument = [:]
        knowledgeRevision += 1
        knowledgeCreateInFlight = false
        actionItemsExtracting = false
        actionItemScanInFlight = false
        actionItemExtractionQueued = false
        actionItems = []
        actionItemError = nil
        reloadGeneration += 1
        dbQueue.sync {}
        store = nil
        isDatabaseReady = false
        isListening = false
        isPreparingTranscription = false
    }

    private func setupPythonAndListen() {
        guard transcriptionEnabled else {
            isPreparingTranscription = false
            isListening = false
            statusText = "Transcription stopped"
            return
        }
        pythonEnvironment.cancel()
        setupGeneration += 1
        let generation = setupGeneration
        setupError = nil
        isPreparingTranscription = true
        statusText = "Preparing transcription engine…"
        Task {
            do {
                try await pythonEnvironment.ensureReady { [weak self] line in
                    TranscriptionLog.info(line)
                    guard let self, generation == self.setupGeneration else { return }
                    self.activityDetail = line
                }
                guard generation == setupGeneration, transcriptionEnabled else { return }
                self.activityDetail = nil
                self.statusText = "Starting transcriber…"
                await transcriber.start(python: BundledRuntime.venvPython, script: BundledRuntime.sidecarScript)
                guard generation == setupGeneration, transcriptionEnabled else { return }
            } catch {
                guard generation == setupGeneration, transcriptionEnabled else { return }
                TranscriptionLog.error(error.localizedDescription)
                setupError = error.localizedDescription
                statusText = "Transcription engine failed"
                isListening = false
                isPreparingTranscription = false
            }
        }
    }

    private func wireTranscriber() {
        transcriber.onStatus = { [weak self] text in
            self?.statusText = text
            let listening = text.hasPrefix("Listening")
            self?.isListening = listening
            if listening {
                self?.isPreparingTranscription = false
                self?.activityDetail = nil
                self?.setupError = nil
            }
        }
        transcriber.onStderr = { [weak self] line in
            guard let self, !self.isListening else { return }
            self.activityDetail = line
        }
        transcriber.onFailure = { [weak self] message in
            self?.statusText = message
            self?.isListening = false
            self?.isPreparingTranscription = false
        }
        transcriber.onTranscription = { [weak self] text, raw, timestamp, speaker in
            self?.ingest(text: text, rawOutput: raw, timestamp: timestamp, speaker: speaker)
        }
    }

    private func ingest(text: String, rawOutput: String, timestamp: String, speaker: String) {
        let cleaned = ReplacementEngine.apply(config.replacements, to: text)
        guard !cleaned.isEmpty, let store else { return }
        let search = appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        dbQueue.async {
            do {
                let previous = try store.latestTranscription()
                if NoiseWordFilter.shouldDrop(
                    text: cleaned,
                    previousText: previous?.text,
                    previousTimestamp: previous?.timestamp,
                    timestamp: timestamp
                ) {
                    TranscriptionLog.info("Dropped a lone \(cleaned)")
                    return
                }
                let row = try store.insertTranscription(
                    timestamp: timestamp,
                    text: cleaned,
                    rawOutput: rawOutput,
                    speaker: speaker
                )
                let day = try store.localDay(of: timestamp)
                let dates = try store.fetchDates(matching: search.isEmpty ? nil : search)
                DispatchQueue.main.async {
                    self.scheduleActionItemGapCheck()
                    if self.dates != dates {
                        self.dates = dates
                    }
                    if self.selectedDate == nil {
                        self.selectedDate = day ?? dates.first
                    }
                    guard self.rowBelongsInView(row, day: day) else { return }
                    let item = TimelineItem(
                        kind: .transcription,
                        sourceId: row.id,
                        timestamp: row.timestamp,
                        text: row.text,
                        speaker: row.speaker
                    )
                    if !self.items.contains(where: { $0.kind == .transcription && $0.sourceId == row.id }) {
                        self.items.append(item)
                    }
                    if self.pinnedToBottom {
                        self.scrollToken += 1
                    }
                }
            } catch {
                DispatchQueue.main.async { self.statusText = error.localizedDescription }
            }
        }
    }

    private func rowBelongsInView(_ row: TranscriptionRow, day: String?) -> Bool {
        guard day == selectedDate else { return false }
        let search = appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if search.isEmpty { return true }
        return row.text.range(of: search, options: [.caseInsensitive]) != nil
    }

    private func insertNote(
        after: Int64?,
        text: String,
        kind: AnnotationKind = .note,
        timestamp: String? = nil,
        scrollToBottom: Bool,
        scrollToInserted: Bool = false
    ) {
        guard let store else { return }
        let timestamp = timestamp ?? Timestamp.nowISO8601()
        dbQueue.async {
            do {
                let row = try store.insertAnnotation(
                    afterTranscriptionId: after,
                    text: text,
                    timestamp: timestamp,
                    kind: kind
                )
                DispatchQueue.main.async {
                    if scrollToInserted {
                        self.pendingScrollItemId = "annotation-\(row.id)"
                        self.showToast("Added LLM note")
                    } else if scrollToBottom {
                        self.pinnedToBottom = true
                    }
                    self.reload(scrollToBottom: scrollToBottom)
                }
            } catch {
                DispatchQueue.main.async { self.alertMessage = error.localizedDescription }
            }
        }
    }

    private func reload(scrollToBottom: Bool) {
        guard let store else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        let requestedDate = selectedDate
        let search = appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        dbQueue.async {
            do {
                let dates = try store.fetchDates(matching: search.isEmpty ? nil : search)
                let date = Self.resolvedDate(requested: requestedDate, dates: dates)
                let items = try Self.timeline(store: store, date: date, search: search)
                DispatchQueue.main.async {
                    guard generation == self.reloadGeneration else { return }
                    if self.dates != dates {
                        self.dates = dates
                    }
                    if let date, self.selectedDate != date {
                        self.selectedDate = date
                        self.clearTransientState()
                    }
                    if self.items != items {
                        self.items = items
                    }
                    if let id = self.pendingScrollItemId {
                        self.pendingScrollItemId = nil
                        if !scrollToBottom, items.contains(where: { $0.id == id }) {
                            self.scrollToItemId = id
                            self.transcriptListID += 1
                        }
                    }
                    self.isLoading = false
                    if scrollToBottom {
                        self.pinnedToBottom = true
                        self.scrollToken += 1
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    /// Keeps the open day when it still exists. Otherwise opens the newest day.
    private nonisolated static func resolvedDate(requested: String?, dates: [String]) -> String? {
        if let requested, dates.contains(requested) {
            return requested
        }
        return dates.first
    }

    private nonisolated static func timeline(store: TranscriptStore, date: String?, search: String) throws -> [TimelineItem] {
        guard let date else { return [] }
        return try store.fetchTimeline(date: date, search: search.isEmpty ? nil : search)
    }

    private func showToast(_ message: String) {
        copyToast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if copyToast == message {
                copyToast = nil
            }
        }
    }

    private func streamLLM(
        modelId: String,
        system: String,
        user: String,
        generation: Int,
        afterTranscriptionId: Int64?,
        day: String?
    ) {
        llmTask?.cancel()
        llmTask = Task {
            guard generation == llmGeneration else { return }
            var output = ""
            do {
                for try await chunk in localLLM.stream(modelId: modelId, system: system, user: user) {
                    if Task.isCancelled || generation != llmGeneration { return }
                    llmLoadingModel = false
                    output += chunk
                    llmResponse = output
                }
                guard generation == llmGeneration, !Task.isCancelled else { return }
                llmStreaming = false
                llmLoadingModel = false
                let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                insertNote(
                    after: afterTranscriptionId,
                    text: text,
                    kind: .llm,
                    timestamp: Timestamp.noteTimestamp(onDay: day),
                    scrollToBottom: false,
                    scrollToInserted: true
                )
            } catch {
                guard generation == llmGeneration, !Task.isCancelled else { return }
                llmResponse += "\nError: \(error.localizedDescription)"
                llmStreaming = false
                llmLoadingModel = false
            }
        }
    }

    func addActionItem() {
        let text = actionItemDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store else { return }
        let timestamp = Timestamp.nowISO8601()
        actionItemDraft = ""
        dbQueue.async {
            do {
                let item = try store.insertActionItem(text: text, timestamp: timestamp)
                DispatchQueue.main.async {
                    self.mergeActionItems([item])
                }
            } catch {
                DispatchQueue.main.async {
                    if self.actionItemDraft.isEmpty {
                        self.actionItemDraft = text
                    }
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func toggleActionItem(_ item: ActionItem) {
        guard let index = actionItems.firstIndex(where: { $0.id == item.id }) else { return }
        actionItems[index].done.toggle()
        let done = actionItems[index].done
        let id = item.id
        guard let store else { return }
        dbQueue.async {
            do {
                try store.setActionItemDone(id: id, done: done)
            } catch {
                DispatchQueue.main.async {
                    if let index = self.actionItems.firstIndex(where: { $0.id == id }) {
                        self.actionItems[index].done = !done
                    }
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func deleteActionItem(_ id: Int64) {
        let removed = actionItems
        actionItems.removeAll { $0.id == id }
        guard let store else { return }
        dbQueue.async {
            do {
                try store.deleteActionItem(id: id)
            } catch {
                DispatchQueue.main.async {
                    self.actionItems = removed
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadActionItems() {
        guard let store else { return }
        dbQueue.async {
            do {
                try store.prepareActionExtractor()
                let items = try store.fetchActionItems()
                DispatchQueue.main.async {
                    self.actionItems = items
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func scheduleActionItemGapCheck() {
        gapTask?.cancel()
        gapTask = Task {
            let nanoseconds = UInt64(ActionItems.gap * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self.extractActionItemsIfNeeded()
        }
    }

    /// Sends each finished run since the last pass to the model. A pass with no new lines does nothing.
    /// Without a downloaded model, the watermark stays put and only manual items can be added.
    private func extractActionItemsIfNeeded() {
        guard llmAvailable, let modelId = config.localModelId, let store else { return }
        if actionItemScanInFlight || actionItemsExtracting {
            actionItemExtractionQueued = true
            return
        }
        actionItemScanInFlight = true
        actionItemError = nil
        extractGeneration += 1
        let generation = extractGeneration
        dbQueue.async {
            do {
                let watermark = try store.actionExtractorWatermark()
                let rows = try store.fetchTranscriptions(afterId: watermark)
                let closed = ActionItems.closedSegments(rows, now: Date())
                DispatchQueue.main.async {
                    guard generation == self.extractGeneration else { return }
                    self.actionItemScanInFlight = false
                    guard !closed.segments.isEmpty else {
                        self.finishActionItemExtraction(generation: generation)
                        return
                    }
                    self.actionItemsExtracting = true
                    self.runActionItemExtraction(
                        segments: closed.segments,
                        modelId: modelId,
                        generation: generation
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.extractGeneration else { return }
                    self.actionItemScanInFlight = false
                    self.actionItemError = error.localizedDescription
                    self.finishActionItemExtraction(generation: generation)
                }
            }
        }
    }

    private func runActionItemExtraction(
        segments: [[TranscriptionRow]],
        modelId: String,
        generation: Int
    ) {
        extractTask?.cancel()
        extractTask = Task {
            for segment in segments {
                guard actionItemExtractionIsCurrent(generation) else { return }
                var output = ""
                let user = ActionItems.userPrompt(transcriptions: segment)
                do {
                    for try await chunk in localLLM.stream(
                        modelId: modelId,
                        system: ActionItems.systemPrompt(stored: config.actionItemsSystemPrompt),
                        user: user
                    ) {
                        guard actionItemExtractionIsCurrent(generation) else { return }
                        output += chunk
                    }
                } catch {
                    guard actionItemExtractionIsCurrent(generation) else { return }
                    actionItemError = error.localizedDescription
                    finishActionItemExtraction(generation: generation)
                    return
                }
                guard actionItemExtractionIsCurrent(generation) else { return }
                let texts = ActionItems.parse(modelOutput: output)
                let stamp = segment.last?.timestamp ?? Timestamp.nowISO8601()
                let through = segment.map(\.id).max() ?? 0
                do {
                    let saved = try await saveExtractedActionItems(texts, timestamp: stamp, watermark: through)
                    guard actionItemExtractionIsCurrent(generation) else { return }
                    mergeActionItems(saved)
                } catch {
                    guard actionItemExtractionIsCurrent(generation) else { return }
                    actionItemError = error.localizedDescription
                    finishActionItemExtraction(generation: generation)
                    return
                }
                await updateOptedInKnowledgeDocuments(
                    material: user,
                    source: .actionItemTranscript,
                    modelId: modelId,
                    isCurrent: { self.actionItemExtractionIsCurrent(generation) }
                )
                guard actionItemExtractionIsCurrent(generation) else { return }
            }
            finishActionItemExtraction(generation: generation)
        }
    }

    private func actionItemExtractionIsCurrent(_ generation: Int) -> Bool {
        generation == extractGeneration && !Task.isCancelled
    }

    private func finishActionItemExtraction(generation: Int) {
        guard generation == extractGeneration else { return }
        actionItemsExtracting = false
        actionItemScanInFlight = false
        guard actionItemExtractionQueued else { return }
        actionItemExtractionQueued = false
        extractActionItemsIfNeeded()
    }

    private func saveExtractedActionItems(
        _ texts: [String],
        timestamp: String,
        watermark: Int64
    ) async throws -> [ActionItem] {
        guard let store else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            dbQueue.async {
                do {
                    let saved = try store.saveExtractedActionItems(
                        texts,
                        timestamp: timestamp,
                        watermark: watermark
                    )
                    continuation.resume(returning: saved)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func mergeActionItems(_ items: [ActionItem]) {
        guard !items.isEmpty else { return }
        var merged = actionItems
        let ids = Set(merged.map(\.id))
        merged.append(contentsOf: items.filter { !ids.contains($0.id) })
        actionItems = merged.sorted { lhs, rhs in
            let left = Timestamp.parse(lhs.timestamp) ?? .distantPast
            let right = Timestamp.parse(rhs.timestamp) ?? .distantPast
            if left != right { return left > right }
            return lhs.id > rhs.id
        }
    }

    func hasDailySummary(_ day: String) -> Bool {
        dailySummaryTextByDay[day] != nil
    }

    func dailySummaryText(for day: String) -> String? {
        dailySummaryTextByDay[day]
    }

    func isDailySummaryBusy(_ day: String) -> Bool {
        generatingSummaryDay == day || summaryQueue.contains(day)
    }

    func isDailySummaryQueued(_ day: String) -> Bool {
        summaryQueue.contains(day)
    }

    func generateDailySummary(day: String) {
        enqueueDailySummary(day: day, manual: true)
    }

    /// Runs the summary again and replaces the one already saved for this day.
    func regenerateDailySummary(day: String) {
        enqueueDailySummary(day: day, manual: true, replace: true)
    }

    func knowledgeDocument(id: Int64) -> KnowledgeDocument? {
        knowledgeDocuments.first { $0.id == id }
    }

    func knowledgeVersions(for documentID: Int64) -> [KnowledgeDocumentVersion] {
        knowledgeVersionsByDocument[documentID] ?? []
    }

    func addKnowledgeDocument(onCreated: @escaping (Int64) -> Void) {
        guard let store, !knowledgeCreateInFlight else { return }
        knowledgeCreateInFlight = true
        let timestamp = Timestamp.nowISO8601()
        dbQueue.async {
            do {
                let document = try store.insertKnowledgeDocument(
                    title: "",
                    description: "",
                    text: "",
                    timestamp: timestamp
                )
                DispatchQueue.main.async {
                    self.knowledgeCreateInFlight = false
                    self.upsertKnowledgeDocument(document)
                    onCreated(document.id)
                }
            } catch {
                DispatchQueue.main.async {
                    self.knowledgeCreateInFlight = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func saveKnowledgeDocument(id: Int64, title: String, description: String, text: String) {
        guard let store else { return }
        let timestamp = Timestamp.nowISO8601()
        dbQueue.async {
            do {
                let update = try store.updateKnowledgeDocument(
                    id: id,
                    title: title,
                    description: description,
                    text: text,
                    timestamp: timestamp
                )
                DispatchQueue.main.async {
                    guard case .saved = update, var document = self.knowledgeDocument(id: id) else { return }
                    document.title = title
                    document.description = description
                    document.text = text
                    document.updatedAt = timestamp
                    self.upsertKnowledgeDocument(document)
                    self.loadKnowledgeVersions(documentID: id)
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func setKnowledgeAllowsLLMUpdates(id: Int64, allowed: Bool) {
        guard let store, let document = knowledgeDocument(id: id), document.allowsLLMUpdates != allowed else { return }
        dbQueue.async {
            do {
                try store.setKnowledgeDocumentAllowsLLMUpdates(id: id, allowed: allowed)
                DispatchQueue.main.async {
                    guard let index = self.knowledgeDocuments.firstIndex(where: { $0.id == id }) else { return }
                    self.knowledgeDocuments[index].allowsLLMUpdates = allowed
                    self.knowledgeRevision += 1
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                    self.knowledgeRevision += 1
                }
            }
        }
    }

    /// Asks the model about each opted-in document. A reply that changes the document is saved as a new version.
    private func updateOptedInKnowledgeDocuments(
        material: String,
        source: KnowledgeUpdateSource,
        modelId: String,
        isCurrent: @MainActor () -> Bool,
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async {
        guard isCurrent() else { return }
        let documents: [KnowledgeDocument]
        do {
            documents = try await fetchKnowledgeDocumentsAllowingLLMUpdates()
        } catch {
            guard isCurrent() else { return }
            alertMessage = error.localizedDescription
            return
        }
        guard !documents.isEmpty else { return }
        for (offset, document) in documents.enumerated() {
            guard isCurrent() else { return }
            onProgress?(offset + 1, documents.count)
            do {
                try await proposeKnowledgeUpdate(
                    document: document,
                    material: material,
                    source: source,
                    modelId: modelId,
                    isCurrent: isCurrent
                )
            } catch {
                guard isCurrent() else { return }
                alertMessage = error.localizedDescription
            }
        }
    }

    private func proposeKnowledgeUpdate(
        document: KnowledgeDocument,
        material: String,
        source: KnowledgeUpdateSource,
        modelId: String,
        isCurrent: @MainActor () -> Bool
    ) async throws {
        var output = ""
        let user = KnowledgeUpdates.userPrompt(
            document: document.revision,
            material: material,
            source: source,
            heardAt: Timestamp.nowISO8601()
        )
        for try await chunk in localLLM.stream(
            modelId: modelId,
            system: KnowledgeUpdates.systemPrompt(stored: config.knowledgeSystemPrompt),
            user: user,
            maxTokens: KnowledgeUpdates.maxTokens(for: document.revision)
        ) {
            guard isCurrent() else { return }
            output += chunk
        }
        guard isCurrent() else { return }
        guard case .update(let revision) = KnowledgeUpdates.parse(modelOutput: output) else { return }
        try await applyKnowledgeModelRevision(document: document, revision: revision)
    }

    private func applyKnowledgeModelRevision(document: KnowledgeDocument, revision: KnowledgeRevision) async throws {
        guard let store else { return }
        let timestamp = Timestamp.nowISO8601()
        let update = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<KnowledgeDocumentUpdate, Error>) in
            dbQueue.async {
                do {
                    let result = try store.updateKnowledgeDocument(
                        id: document.id,
                        title: revision.title,
                        description: revision.description,
                        text: revision.text,
                        timestamp: timestamp,
                        expectedUpdatedAt: document.updatedAt
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard case .saved = update else { return }
        guard var stored = knowledgeDocument(id: document.id) else { return }
        stored.title = revision.title
        stored.description = revision.description
        stored.text = revision.text
        stored.updatedAt = timestamp
        upsertKnowledgeDocument(stored)
        loadKnowledgeVersions(documentID: document.id)
        TranscriptionLog.info("Updated knowledge document \(stored.displayTitle)")
    }

    private func fetchKnowledgeDocumentsAllowingLLMUpdates() async throws -> [KnowledgeDocument] {
        guard let store else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            dbQueue.async {
                do {
                    continuation.resume(returning: try store.fetchKnowledgeDocumentsAllowingLLMUpdates())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deleteKnowledgeDocument(id: Int64) {
        guard let store else { return }
        dbQueue.async {
            do {
                try store.deleteKnowledgeDocument(id: id)
                DispatchQueue.main.async {
                    self.knowledgeDocuments.removeAll { $0.id == id }
                    self.knowledgeVersionsByDocument[id] = nil
                    self.knowledgeRevision += 1
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func loadKnowledgeVersions(documentID: Int64) {
        guard let store else { return }
        dbQueue.async {
            do {
                let versions = try store.fetchKnowledgeVersions(documentID: documentID)
                DispatchQueue.main.async {
                    self.knowledgeVersionsByDocument[documentID] = versions
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadKnowledgeDocuments() {
        guard let store else { return }
        dbQueue.async {
            do {
                let documents = try store.fetchKnowledgeDocuments()
                DispatchQueue.main.async {
                    self.knowledgeDocuments = documents
                    self.knowledgeRevision += 1
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    /// Replaces one document and keeps the list ordered by the newest edit.
    private func upsertKnowledgeDocument(_ document: KnowledgeDocument) {
        knowledgeDocuments.removeAll { $0.id == document.id }
        knowledgeDocuments.append(document)
        knowledgeDocuments.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id > rhs.id
        }
        knowledgeRevision += 1
    }

    func saveDailySummary(day: String, text: String) {
        guard let store else { return }
        let timestamp = Timestamp.nowISO8601()
        dbQueue.async {
            do {
                try store.updateDailySummary(day: day, text: text, timestamp: timestamp)
                DispatchQueue.main.async {
                    self.rememberDailySummary(day: day, text: text)
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadDailySummaries() {
        guard let store else { return }
        dbQueue.async {
            do {
                let rows = try store.fetchDailySummaries()
                let texts = Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0.text) })
                DispatchQueue.main.async {
                    self.dailySummaryTextByDay = texts
                    self.dailySummaryRevision += 1
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func startDailySummaryClock() {
        stopDailySummaryClock()
        observedLocalDay = Timestamp.localDay()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.generateDueDailySummaries()
            }
        }
        scheduleNextDailySummaryMidnight()
    }

    private func stopDailySummaryClock() {
        midnightTask?.cancel()
        midnightTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Fires just after each local midnight and summarizes the days that ended while this process stayed running.
    private func scheduleNextDailySummaryMidnight() {
        let fire = DailySummarySchedule.nextMidnight(after: Date()).addingTimeInterval(1)
        let delay = max(0, fire.timeIntervalSinceNow)
        let nanoseconds = UInt64(delay * 1_000_000_000)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.generateDueDailySummaries()
            self?.scheduleNextDailySummaryMidnight()
        }
        let previous = midnightTask
        midnightTask = task
        previous?.cancel()
    }

    private func generateDueDailySummaries() {
        let now = Date()
        let today = Timestamp.localDay(now)
        let since = observedLocalDay ?? today
        observedLocalDay = today
        for day in DailySummarySchedule.completedDays(since: since, now: now) {
            enqueueDailySummary(day: day, manual: false)
        }
    }

    private func enqueueDailySummary(day: String, manual: Bool, replace: Bool = false) {
        if !replace && dailySummaryTextByDay[day] != nil { return }
        if summaryQueue.contains(day) || generatingSummaryDay == day {
            if manual { summaryManual.insert(day) }
            if replace { summaryReplace.insert(day) }
            return
        }
        if manual && !llmAvailable {
            failDailySummary(
                day: day,
                message: "Choose a language model from LLM Settings in the menu bar."
            )
            return
        }
        if !manual && !llmAvailable { return }
        if manual { summaryManual.insert(day) }
        if replace { summaryReplace.insert(day) }
        summaryQueue.append(day)
        if manual && summaryQueue.count == 1 && generatingSummaryDay == nil {
            let loading = config.localModelId.map { !localLLM.isLoaded($0) } ?? false
            beginDailySummaryUI(day: day, loadingModel: loading)
        }
        startSummaryPump()
    }

    private func startSummaryPump() {
        guard summaryPump == nil else { return }
        summaryPump = Task { @MainActor [weak self] in
            await self?.drainSummaryQueue()
        }
    }

    private func drainSummaryQueue() async {
        while !Task.isCancelled, !summaryQueue.isEmpty {
            let day = summaryQueue.removeFirst()
            let manual = summaryManual.remove(day) != nil
            let replace = summaryReplace.remove(day) != nil
            await performDailySummary(day: day, manual: manual, replace: replace)
        }
        if !Task.isCancelled {
            summaryPump = nil
        }
    }

    private func performDailySummary(day: String, manual: Bool, replace: Bool) async {
        let generation = summaryGeneration
        guard summaryIsCurrent(generation) else { return }
        guard llmAvailable, let modelId = config.localModelId else {
            if manual {
                failDailySummary(
                    day: day,
                    message: "Choose a language model from LLM Settings in the menu bar."
                )
            }
            return
        }

        beginDailySummaryUI(day: day, loadingModel: !localLLM.isLoaded(modelId))
        let job: DailySummaryJob
        do {
            job = try await loadDailySummaryJob(day: day)
        } catch {
            guard summaryIsCurrent(generation) else {
                endDailySummaryUI(generation)
                return
            }
            endDailySummaryUI(generation)
            reportDailySummaryFailure(day: day, manual: manual, message: error.localizedDescription)
            return
        }
        guard summaryIsCurrent(generation) else {
            endDailySummaryUI(generation)
            return
        }
        if let existing = job.existing, !replace {
            rememberDailySummary(day: existing.day, text: existing.text)
            endDailySummaryUI(generation)
            return
        }
        guard job.dayIsListed, DailySummaryDocument.hasMaterial(
            transcriptions: job.transcriptions,
            annotations: job.annotations,
            actionItems: job.actionItems
        ) else {
            endDailySummaryUI(generation)
            if manual {
                failDailySummary(day: day, message: "Nothing from this day to summarize.")
            }
            return
        }

        let stretches = DailySummaryDocument.chunks(
            transcriptions: job.transcriptions,
            annotations: job.annotations
        )
        let sections: [String]
        do {
            sections = try await summarizeStretches(
                stretches,
                modelId: modelId,
                generation: generation
            )
        } catch {
            guard summaryIsCurrent(generation) else {
                endDailySummaryUI(generation)
                return
            }
            endDailySummaryUI(generation)
            reportDailySummaryFailure(day: day, manual: manual, message: error.localizedDescription)
            return
        }
        guard summaryIsCurrent(generation) else {
            endDailySummaryUI(generation)
            return
        }
        guard stretches.isEmpty || sections.count == stretches.count else {
            endDailySummaryUI(generation)
            return
        }

        let draft = DailySummaryDocument.assemble(
            day: day,
            sections: sections,
            actionItems: job.actionItems
        )
        summaryStreamText = draft
        let text: String
        do {
            guard let cleaned = try await cleanDailySummary(
                draft,
                modelId: modelId,
                generation: generation
            ) else {
                endDailySummaryUI(generation)
                return
            }
            text = cleaned
        } catch {
            guard summaryIsCurrent(generation) else {
                endDailySummaryUI(generation)
                return
            }
            endDailySummaryUI(generation)
            reportDailySummaryFailure(day: day, manual: manual, message: error.localizedDescription)
            return
        }
        guard summaryIsCurrent(generation) else {
            endDailySummaryUI(generation)
            return
        }
        do {
            let timestamp = Timestamp.nowISO8601()
            let inserted = replace
                ? try await replaceGeneratedDailySummary(day: day, text: text, timestamp: timestamp)
                : try await insertGeneratedDailySummary(day: day, text: text, timestamp: timestamp)
            guard summaryIsCurrent(generation) else {
                endDailySummaryUI(generation)
                return
            }
            if inserted {
                rememberDailySummary(day: day, text: text)
            } else if let stored = try await fetchStoredDailySummary(day: day) {
                guard summaryIsCurrent(generation) else {
                    endDailySummaryUI(generation)
                    return
                }
                rememberDailySummary(day: stored.day, text: stored.text)
            }
        } catch {
            guard summaryIsCurrent(generation) else {
                endDailySummaryUI(generation)
                return
            }
            endDailySummaryUI(generation)
            reportDailySummaryFailure(day: day, manual: manual, message: error.localizedDescription)
            return
        }
        guard summaryIsCurrent(generation) else {
            endDailySummaryUI(generation)
            return
        }
        await updateOptedInKnowledgeDocuments(
            material: text,
            source: .dailySummary,
            modelId: modelId,
            isCurrent: { self.summaryIsCurrent(generation) },
            onProgress: { index, count in
                if count > 1 {
                    self.summaryProgress = "Checking for knowledge base updates (\(index) of \(count))"
                } else {
                    self.summaryProgress = "Checking for knowledge base updates"
                }
            }
        )
        endDailySummaryUI(generation)
    }

    private func summarizeStretches(
        _ stretches: [DailySummaryChunk],
        modelId: String,
        generation: Int
    ) async throws -> [String] {
        var sections: [String] = []
        for (offset, stretch) in stretches.enumerated() {
            guard summaryIsCurrent(generation) else { return sections }
            let index = offset + 1
            let count = stretches.count
            if !summaryLoadingModel {
                summaryProgress = stretchProgress(index: index, count: count)
            }
            let heading = DailySummaryDocument.heading(for: stretch)
            let user = DailySummaryDocument.chunkPrompt(stretch, index: index, count: count)
            var piece = ""
            for try await token in localLLM.stream(
                modelId: modelId,
                system: DailySummaryDocument.chunkSystemPrompt(stored: config.summarySystemPrompt),
                user: user,
                maxTokens: 1024
            ) {
                guard summaryIsCurrent(generation) else { return sections }
                summaryLoadingModel = false
                summaryProgress = stretchProgress(index: index, count: count)
                piece += token
                summaryStreamText = liveSummary(
                    finished: sections,
                    heading: heading,
                    partial: piece
                )
            }
            let summary = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                throw LocalLLMError(message: "The model returned an empty summary.")
            }
            sections.append(DailySummaryDocument.section(heading: heading, summary: summary))
        }
        return sections
    }

    /// Nil when this generation was cancelled. Throws when the model fails or returns nothing.
    private func cleanDailySummary(
        _ draft: String,
        modelId: String,
        generation: Int
    ) async throws -> String? {
        guard summaryIsCurrent(generation) else { return nil }
        summaryProgress = "Second pass"
        var piece = ""
        for try await token in localLLM.stream(
            modelId: modelId,
            system: DailySummaryDocument.cleanupSystemPrompt(stored: config.summaryPass2SystemPrompt),
            user: DailySummaryDocument.cleanupPrompt(draft),
            maxTokens: DailySummaryDocument.cleanupMaxTokens(for: draft)
        ) {
            guard summaryIsCurrent(generation) else { return nil }
            summaryLoadingModel = false
            piece += token
            summaryStreamText = piece
        }
        guard summaryIsCurrent(generation) else { return nil }
        let cleaned = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw LocalLLMError(message: "The cleanup pass returned an empty summary.")
        }
        return cleaned
    }

    private func stretchProgress(index: Int, count: Int) -> String {
        "Summarizing stretch \(index) of \(count)"
    }

    private func liveSummary(
        finished: [String],
        heading: String,
        partial: String
    ) -> String {
        var text = ""
        if !finished.isEmpty {
            text += finished.joined(separator: "\n\n")
            text += "\n\n"
        }
        text += "\(heading)\n\(partial)"
        return text
    }

    private func beginDailySummaryUI(day: String, loadingModel: Bool) {
        summaryStatus = nil
        summaryStatusDay = nil
        generatingSummaryDay = day
        summaryStreamText = ""
        summaryLoadingModel = loadingModel
        summaryProgress = loadingModel ? "Loading the model…" : "Reading the day's transcripts…"
    }

    private func endDailySummaryUI(_ generation: Int) {
        guard generation == summaryGeneration else { return }
        generatingSummaryDay = nil
        summaryStreamText = ""
        summaryLoadingModel = false
        summaryProgress = nil
    }

    private func failDailySummary(day: String, message: String) {
        summaryStatusDay = day
        summaryStatus = message
    }

    private func reportDailySummaryFailure(day: String, manual: Bool, message: String) {
        if manual {
            failDailySummary(day: day, message: message)
        } else {
            TranscriptionLog.error("Daily summary failed for \(day): \(message)")
        }
    }

    private func summaryIsCurrent(_ generation: Int) -> Bool {
        generation == summaryGeneration && !Task.isCancelled
    }

    private func cancelDailySummaryWork() {
        summaryGeneration += 1
        summaryPump?.cancel()
        summaryPump = nil
        summaryQueue.removeAll()
        summaryManual.removeAll()
        summaryReplace.removeAll()
        generatingSummaryDay = nil
        summaryStreamText = ""
        summaryLoadingModel = false
        summaryProgress = nil
        summaryStatus = nil
        summaryStatusDay = nil
    }

    private func rememberDailySummary(day: String, text: String) {
        var texts = dailySummaryTextByDay
        texts[day] = text
        dailySummaryTextByDay = texts
        dailySummaryRevision += 1
    }

    private func loadDailySummaryJob(day: String) async throws -> DailySummaryJob {
        guard let store else {
            return DailySummaryJob(existing: nil, transcriptions: [], annotations: [], actionItems: [], dayIsListed: false)
        }
        return try await withCheckedThrowingContinuation { continuation in
            dbQueue.async {
                do {
                    let existing = try store.fetchDailySummary(day: day)
                    let context = try store.fetchModelContext(date: day, fromId: nil, toId: nil)
                    let actionItems = try store.fetchActionItems(onDay: day)
                    let listed = try store.fetchDates().contains(day)
                    continuation.resume(returning: DailySummaryJob(
                        existing: existing,
                        transcriptions: context.transcriptions,
                        annotations: context.annotations,
                        actionItems: actionItems,
                        dayIsListed: listed
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func insertGeneratedDailySummary(day: String, text: String, timestamp: String) async throws -> Bool {
        guard let store else { return false }
        return try await withCheckedThrowingContinuation { continuation in
            dbQueue.async {
                do {
                    let inserted = try store.insertDailySummaryIfAbsent(day: day, text: text, timestamp: timestamp)
                    continuation.resume(returning: inserted)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// True when the replacement was written. A missing store leaves the previous summary in place.
    private func replaceGeneratedDailySummary(day: String, text: String, timestamp: String) async throws -> Bool {
        guard let store else { return false }
        return try await withCheckedThrowingContinuation { continuation in
            dbQueue.async {
                do {
                    try store.replaceDailySummary(day: day, text: text, timestamp: timestamp)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchStoredDailySummary(day: String) async throws -> DailySummary? {
        guard let store else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            dbQueue.async {
                do {
                    continuation.resume(returning: try store.fetchDailySummary(day: day))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func clearTransientState() {
        clearRange()
        inlineInsert = nil
        inlineText = ""
        editingAnnotationId = nil
        editingText = ""
    }
}
