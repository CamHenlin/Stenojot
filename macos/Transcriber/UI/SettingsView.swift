import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [EditableRule] = []
    @State private var saved = false
    @State private var confirmApply = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Text Replacements")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if rules.isEmpty {
                        Text("No replacement rules yet. Click Add Rule to get started.")
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach($rules) { $rule in
                        HStack(spacing: 8) {
                            TextField("Find text...", text: $rule.from)
                                .textFieldStyle(.roundedBorder)
                            Text("→")
                                .foregroundStyle(Theme.muted)
                            TextField("Replace with... (empty = delete)", text: $rule.to)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                rules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("+ Add Rule") {
                        rules.append(EditableRule(from: "", to: ""))
                    }
                    .buttonStyle(.borderless)
                }
                .padding()
            }

            Divider()

            HStack {
                Button(saved ? "Saved" : "Save") { save() }
                if !model.applyAllResult.isEmpty {
                    Text(model.applyAllResult)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Button(model.applyingAll ? "Applying…" : "Apply to All Past Transcripts") {
                    confirmApply = true
                }
                .disabled(model.applyingAll)
            }
            .padding()
        }
        .frame(width: 640, height: 420)
        .onAppear { load() }
        .confirmationDialog(
            "Apply these rules to every saved transcript?",
            isPresented: $confirmApply,
            titleVisibility: .visible
        ) {
            Button("Apply", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rules are saved first. Transcripts that become empty are deleted, along with notes attached to them.")
        }
    }

    private func load() {
        rules = model.config.replacements.map { EditableRule(from: $0.from, to: $0.to) }
    }

    private func save() {
        do {
            let cleaned = try model.saveReplacements(rules.map { ReplacementRule(from: $0.from, to: $0.to) })
            rules = cleaned.map { EditableRule(from: $0.from, to: $0.to) }
            saved = true
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    private func apply() {
        model.applyAllReplacements(rules.map { ReplacementRule(from: $0.from, to: $0.to) })
        load()
        saved = true
    }
}

struct EditableRule: Identifiable {
    var id = UUID()
    var from: String
    var to: String
}
