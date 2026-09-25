import AppKit
import CoreServices
import Darwin
import ObjectiveC
import SwiftUI

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var model = AppModel()

    init() {
        // Xcode runs the binary directly, so Launch Services has no record.
        // TCC will not list the app for screen recording without one.
        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        TableViewClickFix.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates") { model.checkForUpdates() }
            }
            InspectorCommands()
            CommandGroup(after: .appSettings) {
                Button("LLM Settings…") { openWindow(id: AppWindow.llmSettings) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Text Replacement Settings…") { openWindow(id: AppWindow.textReplacements) }
                Button("Ignored Apps…") { openWindow(id: AppWindow.ignoredApps) }
                Toggle("Pause While Music Plays", isOn: Binding(
                    get: { model.config.pauseWhileMusicPlaying },
                    set: { model.setPauseWhileMusicPlaying($0) }
                ))
                Menu("System Prompt") {
                    Button("Transcript…") { openWindow(id: AppWindow.transcriptPrompt) }
                    Button("Action Items…") { openWindow(id: AppWindow.actionItemsPrompt) }
                    Button("Summary…") { openWindow(id: AppWindow.summaryPrompt) }
                    Button("Summary Pass 2…") { openWindow(id: AppWindow.summaryPass2Prompt) }
                    Button("Knowledge…") { openWindow(id: AppWindow.knowledgePrompt) }
                }
            }
            CommandGroup(after: .importExport) {
                Button("Import Database…") { model.promptImportDatabase() }
                Button("Import Settings…") { model.promptImportConfig() }
            }
        }

        Window("LLM Settings", id: AppWindow.llmSettings) {
            LLMSettingsView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 560)

        Window("Text Replacement Settings", id: AppWindow.textReplacements) {
            SettingsView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 420)

        Window("Ignored Apps", id: AppWindow.ignoredApps) {
            IgnoredAppsView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 480, height: 560)

        Window("Transcript System Prompt", id: AppWindow.transcriptPrompt) {
            TranscriptSystemPromptView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 480)

        Window("Action Items System Prompt", id: AppWindow.actionItemsPrompt) {
            ActionItemsSystemPromptView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 480)

        Window("Summary System Prompt", id: AppWindow.summaryPrompt) {
            SummarySystemPromptView(model: model, pass: .stretch)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 480)

        Window("Summary Pass 2", id: AppWindow.summaryPass2Prompt) {
            SummarySystemPromptView(model: model, pass: .cleanup)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 480)

        Window("Knowledge System Prompt", id: AppWindow.knowledgePrompt) {
            KnowledgeSystemPromptView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 480)

        WindowGroup("Daily Summary", id: AppWindow.dailySummary, for: String.self) { $day in
            if let day, !day.isEmpty {
                DailySummaryView(model: model, day: day)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 720, height: 680)

        WindowGroup("Knowledge", id: AppWindow.knowledgeDocument, for: Int64.self) { $documentID in
            if let documentID {
                KnowledgeDocumentView(model: model, documentID: documentID)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 720, height: 680)
    }
}

enum AppWindow {
    static let llmSettings = "llm-settings"
    static let textReplacements = "text-replacements"
    static let ignoredApps = "ignored-apps"
    static let transcriptPrompt = "transcript-system-prompt"
    static let actionItemsPrompt = "action-items-system-prompt"
    static let summaryPrompt = "summary-system-prompt"
    static let summaryPass2Prompt = "summary-pass-2-system-prompt"
    static let knowledgePrompt = "knowledge-system-prompt"
    static let dailySummary = "daily-summary"
    static let knowledgeDocument = "knowledge-document"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}

/// SwiftUI lists are AppKit table views. Their double-click recognizer stays in
/// the `.possible` phase when a click redraws the row, and AppKit beachballs the
/// app about 24 seconds later.
private enum TableViewClickFix {
    fileprivate static let recognizerName = "NSTableView.doubleTapGestureRecognizer"
    private static var installed = false

    fileprivate static func isDoubleTap(_ recognizer: NSGestureRecognizer) -> Bool {
        recognizer.description.contains(recognizerName)
    }

    static func install() {
        guard !installed else { return }
        installed = true
        exchange(
            NSTableView.self,
            #selector(NSView.addGestureRecognizer(_:)),
            #selector(NSTableView.transcriber_addGestureRecognizer(_:))
        )
        exchange(
            NSTableView.self,
            #selector(NSView.viewDidMoveToWindow),
            #selector(NSTableView.transcriber_viewDidMoveToWindow)
        )
        exchange(
            NSTableView.self,
            #selector(NSView.layout),
            #selector(NSTableView.transcriber_layout)
        )
    }

    private static func exchange(_ cls: AnyClass, _ original: Selector, _ swizzled: Selector) {
        guard let swizzledMethod = class_getInstanceMethod(cls, swizzled),
              let originalMethod = class_getInstanceMethod(cls, original) else { return }
        let added = class_addMethod(
            cls,
            original,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )
        if added {
            class_replaceMethod(
                cls,
                swizzled,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }
}

extension NSTableView {
    @objc func transcriber_addGestureRecognizer(_ gestureRecognizer: NSGestureRecognizer) {
        if TableViewClickFix.isDoubleTap(gestureRecognizer) {
            return
        }
        transcriber_addGestureRecognizer(gestureRecognizer)
    }

    @objc func transcriber_viewDidMoveToWindow() {
        transcriber_viewDidMoveToWindow()
        stripDoubleTapRecognizer()
    }

    @objc func transcriber_layout() {
        transcriber_layout()
        stripDoubleTapRecognizer()
    }

    private func stripDoubleTapRecognizer() {
        guard gestureRecognizers.contains(where: TableViewClickFix.isDoubleTap) else { return }
        gestureRecognizers.removeAll(where: TableViewClickFix.isDoubleTap)
    }
}
