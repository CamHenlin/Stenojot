import SwiftUI
import TranscriberCore

struct KnowledgeBasePanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var hoveringDocumentID: Int64?
    @State private var pendingDelete: KnowledgeDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            documentList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Delete this document?",
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    model.deleteKnowledgeDocument(id: pendingDelete.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(pendingDelete?.displayTitle ?? "This document") is removed from the knowledge base.")
        }
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Knowledge base")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Button("Add") {
                model.addKnowledgeDocument { id in
                    openWindow(id: AppWindow.knowledgeDocument, value: id)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.isDatabaseReady || model.knowledgeCreateInFlight)
            .help("Add a document")
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Wide enough for "Last edited" and a date such as "Wed, Sep 23".
    private let editedColumnWidth: CGFloat = 96

    private var documentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader
            ScrollView {
                if model.knowledgeDocuments.isEmpty {
                    Text("No documents yet")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.knowledgeDocuments) { document in
                            documentRow(document)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Last edited")
                .frame(width: editedColumnWidth, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Theme.line.frame(height: 1)
        }
    }

    private func documentRow(_ document: KnowledgeDocument) -> some View {
        let hovering = hoveringDocumentID == document.id
        return Button {
            openWindow(id: AppWindow.knowledgeDocument, value: document.id)
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if document.allowsLLMUpdates {
                        Image(systemName: "sparkles")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel("LLM updates on")
                            .help("Allow LLM updates is on")
                    }
                    Text(document.displayTitle)
                        .lineLimit(1)
                        .foregroundStyle(Color(white: 0.9))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(document.lastEditedLabel())
                    .lineLimit(1)
                    .foregroundStyle(Theme.muted)
                    .frame(width: editedColumnWidth, alignment: .leading)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Button {
                pendingDelete = document
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .padding(4)
            .background(Theme.sidebar)
            .padding(.trailing, editedColumnWidth + 8)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityHidden(!hovering)
            .help("Delete document")
        }
        .onHover { inside in
            hoveringDocumentID = inside ? document.id : (hoveringDocumentID == document.id ? nil : hoveringDocumentID)
        }
    }
}
