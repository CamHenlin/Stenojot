import SwiftUI
import TranscriberCore

struct SummarySystemPromptView: View {
    @Bindable var model: AppModel
    @State private var text: String
    @State private var savedText: String

    init(model: AppModel) {
        self.model = model
        let prompt = model.summarySystemPromptText
        _text = State(initialValue: prompt)
        _savedText = State(initialValue: prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Summary")
                    .font(.headline)
                Text("This instruction is sent with each stretch of a day when a daily summary is generated.")
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
                    text = DailySummaryDocument.chunkSystemPrompt
                }
                .disabled(text == DailySummaryDocument.chunkSystemPrompt)
                Spacer()
                if model.summarySystemPromptSaved && text == savedText {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                Button("Save") {
                    model.saveSummarySystemPrompt(text)
                    guard model.summarySystemPromptSaved else { return }
                    savedText = model.summarySystemPromptText
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
}
