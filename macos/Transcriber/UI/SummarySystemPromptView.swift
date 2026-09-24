import SwiftUI
import TranscriberCore

struct SummarySystemPromptView: View {
    enum Pass {
        case stretch
        case cleanup
    }

    @Bindable var model: AppModel
    var pass: Pass
    @State private var text: String
    @State private var savedText: String

    init(model: AppModel, pass: Pass) {
        self.model = model
        self.pass = pass
        let prompt = Self.storedText(model: model, pass: pass)
        _text = State(initialValue: prompt)
        _savedText = State(initialValue: prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Divider()

            NoteTextEditor(text: $text)
                .padding(12)

            HStack {
                Button("Reset") {
                    text = builtIn
                }
                .disabled(text == builtIn)
                Spacer()
                if promptSaved && text == savedText {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                Button("Save") {
                    save()
                    guard promptSaved else { return }
                    savedText = Self.storedText(model: model, pass: pass)
                    text = savedText
                }
                .disabled(text == savedText)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Theme.background)
    }

    private var title: String {
        switch pass {
        case .stretch: "Summary"
        case .cleanup: "Summary Pass 2"
        }
    }

    private var detail: String {
        switch pass {
        case .stretch:
            "This instruction is sent with each stretch of a day when a daily summary is generated."
        case .cleanup:
            "This instruction is sent with the full daily summary so the model can drop passages that add no information."
        }
    }

    private var builtIn: String {
        switch pass {
        case .stretch: DailySummaryDocument.chunkSystemPrompt
        case .cleanup: DailySummaryDocument.cleanupSystemPrompt
        }
    }

    private var promptSaved: Bool {
        switch pass {
        case .stretch: model.summarySystemPromptSaved
        case .cleanup: model.summaryPass2SystemPromptSaved
        }
    }

    private func save() {
        switch pass {
        case .stretch: model.saveSummarySystemPrompt(text)
        case .cleanup: model.saveSummaryPass2SystemPrompt(text)
        }
    }

    private static func storedText(model: AppModel, pass: Pass) -> String {
        switch pass {
        case .stretch: model.summarySystemPromptText
        case .cleanup: model.summaryPass2SystemPromptText
        }
    }
}
