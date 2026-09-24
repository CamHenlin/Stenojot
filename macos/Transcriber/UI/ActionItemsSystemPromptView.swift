import SwiftUI
import TranscriberCore

struct ActionItemsSystemPromptView: View {
    @Bindable var model: AppModel
    @State private var text: String
    @State private var savedText: String

    init(model: AppModel) {
        self.model = model
        let prompt = model.actionItemsSystemPromptText
        _text = State(initialValue: prompt)
        _savedText = State(initialValue: prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Action Items")
                    .font(.headline)
                Text("This instruction is sent with each finished stretch of transcript when action items are extracted.")
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
                    text = ActionItems.systemPrompt
                }
                .disabled(text == ActionItems.systemPrompt)
                Spacer()
                if model.actionItemsSystemPromptSaved && text == savedText {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                Button("Save") {
                    model.saveActionItemsSystemPrompt(text)
                    guard model.actionItemsSystemPromptSaved else { return }
                    savedText = model.actionItemsSystemPromptText
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
