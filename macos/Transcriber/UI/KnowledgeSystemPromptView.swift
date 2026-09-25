import SwiftUI
import TranscriberCore

struct KnowledgeSystemPromptView: View {
    @Bindable var model: AppModel
    @State private var text: String
    @State private var savedText: String

    init(model: AppModel) {
        self.model = model
        let prompt = model.knowledgeSystemPromptText
        _text = State(initialValue: prompt)
        _savedText = State(initialValue: prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Knowledge")
                    .font(.headline)
                Text("This instruction is sent for each knowledge document that allows model updates, after a daily summary is saved and after each action-item pass.")
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
                    text = KnowledgeUpdates.systemPrompt
                }
                .disabled(text == KnowledgeUpdates.systemPrompt)
                Spacer()
                if model.knowledgeSystemPromptSaved && text == savedText {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                Button("Save") {
                    model.saveKnowledgeSystemPrompt(text)
                    guard model.knowledgeSystemPromptSaved else { return }
                    savedText = model.knowledgeSystemPromptText
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
