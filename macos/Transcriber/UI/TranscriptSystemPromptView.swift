import SwiftUI

struct TranscriptSystemPromptView: View {
    @Bindable var model: AppModel
    @State private var text: String
    @State private var savedText: String

    init(model: AppModel) {
        self.model = model
        let prompt = model.transcriptSystemPromptText
        _text = State(initialValue: prompt)
        _savedText = State(initialValue: prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcript")
                    .font(.headline)
                Text("This instruction is sent with questions about the transcript. Leave it empty to send only the transcript and the question.")
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
                    text = ""
                }
                .disabled(text.isEmpty)
                Spacer()
                if model.systemPromptSaved && text == savedText {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                Button("Save") {
                    model.saveTranscriptSystemPrompt(text)
                    guard model.systemPromptSaved else { return }
                    savedText = model.transcriptSystemPromptText
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
