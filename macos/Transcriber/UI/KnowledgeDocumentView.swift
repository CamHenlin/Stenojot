import SwiftUI
import TranscriberCore

struct KnowledgeDocumentView: View {
    @Bindable var model: AppModel
    var documentID: Int64
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var title = ""
    @State private var documentDescription = ""
    @State private var text = ""
    @State private var savedTitle = ""
    @State private var savedDescription = ""
    @State private var savedText = ""
    @State private var didFocusNewDocument = false
    @State private var hasSeenDocument = false
    @State private var confirmDelete = false
    @State private var selectedVersionID: Int64?
    @State private var allowsLLMUpdates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.knowledgeDocument(id: documentID) == nil {
                missingBody
            } else if let comparison = historyComparison {
                historyHeader(comparison)
                Theme.line.frame(height: 1)
                KnowledgeDocumentDiffView(
                    changes: KnowledgeDocumentDiff.changes(
                        from: comparison.older.revision,
                        to: comparison.newer.revision
                    )
                )
            } else {
                header
                Theme.line.frame(height: 1)
                editor
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Theme.background)
        .navigationTitle(navigationTitle)
        .onAppear {
            if model.knowledgeDocument(id: documentID) != nil {
                hasSeenDocument = true
            }
            pullDocument()
            pullAllowsLLMUpdates()
            model.loadKnowledgeVersions(documentID: documentID)
        }
        .onChange(of: model.knowledgeRevision) { _, _ in
            guard model.knowledgeDocument(id: documentID) != nil else {
                if hasSeenDocument {
                    dismiss()
                }
                return
            }
            hasSeenDocument = true
            pullDocument()
            pullAllowsLLMUpdates()
        }
        .onKeyPress(.escape) {
            guard selectedVersionID != nil else { return .ignored }
            selectedVersionID = nil
            return .handled
        }
        .confirmationDialog(
            "Delete this document?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model.deleteKnowledgeDocument(id: documentID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(displayTitle) is removed from the knowledge base.")
        }
    }

    private var versions: [KnowledgeDocumentVersion] {
        model.knowledgeVersions(for: documentID)
    }

    private var historyComparison: (older: KnowledgeDocumentVersion, newer: KnowledgeVersionSuccessor)? {
        guard let selectedVersionID,
              let older = versions.first(where: { $0.id == selectedVersionID }),
              let document = model.knowledgeDocument(id: documentID),
              let newer = KnowledgeHistory.successor(
                of: older.id,
                versions: versions,
                current: document.revision,
                currentSavedAt: document.updatedAt
              ) else {
            return nil
        }
        return (older, newer)
    }

    private var navigationTitle: String {
        model.knowledgeDocument(id: documentID)?.displayTitle ?? "Knowledge"
    }

    private var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private var isDirty: Bool {
        title != savedTitle || documentDescription != savedDescription || text != savedText
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .focused($titleFocused)
                TextField("Description", text: $documentDescription, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...4)
                llmUpdatesToggle
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !versions.isEmpty {
                historyMenu(label: "History")
            }
            Button("Delete") {
                confirmDelete = true
            }
            if isDirty {
                Button("Save") {
                    model.saveKnowledgeDocument(
                        id: documentID,
                        title: title,
                        description: documentDescription,
                        text: text
                    )
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(16)
    }

    private func historyHeader(_ comparison: (older: KnowledgeDocumentVersion, newer: KnowledgeVersionSuccessor)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Changes")
                    .font(.headline)
                Text("\(Timestamp.formatDateTime(comparison.older.savedAt)) → \(Timestamp.formatDateTime(comparison.newer.savedAt))")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                if isDirty {
                    Text("Unsaved edits stay in the editor and are not part of this diff.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                llmUpdatesToggle
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            historyMenu(label: Timestamp.formatDateTime(comparison.older.savedAt))
            Button("Back") {
                selectedVersionID = nil
            }
            Button("Delete") {
                confirmDelete = true
            }
        }
        .padding(16)
    }

    private var llmUpdatesToggle: some View {
        Toggle("Allow LLM updates", isOn: $allowsLLMUpdates)
            .toggleStyle(.checkbox)
            .onChange(of: allowsLLMUpdates) { _, allowed in
                guard model.knowledgeDocument(id: documentID)?.allowsLLMUpdates != allowed else { return }
                model.setKnowledgeAllowsLLMUpdates(id: documentID, allowed: allowed)
            }
            .help("After a daily summary or an action-item pass, the model may update this document.")
    }

    private func pullAllowsLLMUpdates() {
        guard let stored = model.knowledgeDocument(id: documentID) else { return }
        guard allowsLLMUpdates != stored.allowsLLMUpdates else { return }
        allowsLLMUpdates = stored.allowsLLMUpdates
    }

    private func historyMenu(label: String) -> some View {
        Menu(label) {
            ForEach(versions) { version in
                Button {
                    selectedVersionID = version.id
                } label: {
                    if version.id == selectedVersionID {
                        Label(Timestamp.formatDateTime(version.savedAt), systemImage: "checkmark")
                    } else {
                        Text(Timestamp.formatDateTime(version.savedAt))
                    }
                }
            }
        }
        .fixedSize()
    }

    private var editor: some View {
        NoteTextEditor(text: $text)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingBody: some View {
        Text("This document is no longer available.")
            .foregroundStyle(Theme.muted)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Keeps unsaved edits. A finished save refreshes the baseline the Save button compares against.
    private func pullDocument() {
        guard let stored = model.knowledgeDocument(id: documentID) else { return }
        let matchesStored = title == stored.title
            && documentDescription == stored.description
            && text == stored.text
        if matchesStored {
            savedTitle = stored.title
            savedDescription = stored.description
            savedText = stored.text
            focusNewDocumentIfNeeded(stored)
            return
        }
        if !isDirty {
            title = stored.title
            documentDescription = stored.description
            text = stored.text
            savedTitle = stored.title
            savedDescription = stored.description
            savedText = stored.text
            focusNewDocumentIfNeeded(stored)
        }
    }

    private func focusNewDocumentIfNeeded(_ document: KnowledgeDocument) {
        guard !didFocusNewDocument else { return }
        guard document.title.isEmpty, document.description.isEmpty, document.text.isEmpty else { return }
        didFocusNewDocument = true
        titleFocused = true
    }
}
