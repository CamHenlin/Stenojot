import SwiftUI

struct LLMPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.llmOpen.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text("LLM")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(model.llmModelTitle)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(.plain)
                if model.llmOpen && model.llmAvailable {
                    Button("Change…") { openWindow(id: AppWindow.llmSettings) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    model.llmOpen.toggle()
                } label: {
                    Image(systemName: model.llmOpen ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }

            if model.llmOpen && !model.llmAvailable {
                Text("Choose a model to ask about this transcript. It downloads once and stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LLMModelList(model: model)
                }
                .frame(maxHeight: 280)
            } else if model.llmOpen {
                rangeBar
                HStack(alignment: .bottom, spacing: 8) {
                    NoteTextEditor(text: $model.llmPrompt, onCommandReturn: { model.sendLLM() })
                        .frame(height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                    Button(sendTitle) {
                        model.sendLLM()
                    }
                    .disabled(
                        model.llmStreaming
                            || model.llmPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                if !model.llmResponse.isEmpty || model.llmStreaming {
                    ScrollView {
                        Text(responseText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                }
                if !model.llmResponse.isEmpty && !model.llmStreaming {
                    Button("Clear") { model.llmResponse = "" }
                        .buttonStyle(.borderless)
                }
                DisclosureGroup("System Prompt", isExpanded: $model.llmShowSystemPrompt) {
                    NoteTextEditor(text: $model.llmSystemPrompt)
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                    HStack {
                        Button("Save") { model.saveSystemPrompt() }
                        if model.systemPromptSaved {
                            Text("Saved")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private var responseText: String {
        if model.llmLoadingModel && model.llmResponse.isEmpty {
            return "Loading the model…"
        }
        return model.llmResponse + (model.llmStreaming ? " ▍" : "")
    }

    private var sendTitle: String {
        if model.llmLoadingModel { return "Loading…" }
        if model.llmStreaming { return "Thinking…" }
        return "Send"
    }

    private var rangeBar: some View {
        HStack(spacing: 8) {
            Text("Context:")
                .font(.caption)
                .foregroundStyle(Theme.muted)
            Text(rangeLabel)
                .font(.caption)
            Spacer()
            if model.hasRange {
                Button("Copy") { model.copySelectedRange() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy the selected messages")
            }
            if model.rangeFromId != nil {
                Button("Clear selection") { model.clearRange() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Clear the selected range")
            }
        }
    }

    private var rangeLabel: String {
        if !model.hasRange {
            return "Full day (\(model.transcriptionCount) messages)"
        }
        let count = model.rangeCount
        let selected = "\(count) message\(count == 1 ? "" : "s") selected"
        if model.rangeSelecting {
            let preview = model.previewCount
            if preview > count {
                return "\(selected). Click to extend to \(preview) messages"
            }
            return "\(selected). Click another message to extend the range"
        }
        return selected
    }
}
