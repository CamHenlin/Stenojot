import AppKit
import Darwin
import ObjectiveC
import SwiftUI

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var model = AppModel()

    init() {
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
            InspectorCommands()
            CommandGroup(after: .appSettings) {
                Button("LLM Settings…") { openWindow(id: AppWindow.llmSettings) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Menu("System Prompt") {
                    Button("Summary…") { openWindow(id: AppWindow.summaryPrompt) }
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

        Window("Summary System Prompt", id: AppWindow.summaryPrompt) {
            SummarySystemPromptView(model: model)
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
    }
}

enum AppWindow {
    static let llmSettings = "llm-settings"
    static let summaryPrompt = "summary-system-prompt"
    static let dailySummary = "daily-summary"
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
