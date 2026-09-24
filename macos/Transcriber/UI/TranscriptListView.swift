import SwiftUI
import TranscriberCore

struct TranscriptDetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let setupError = model.setupError {
                setupBanner(setupError)
            }
            ZStack {
                Theme.background
                if model.items.isEmpty {
                    Text(model.isLoading ? "Loading…" : "No transcriptions found.")
                        .foregroundStyle(Theme.muted)
                } else {
                    transcriptList
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(model.toolbarTitle)
        .navigationSubtitle(statusSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text(messageCountLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
            .plainToolbarBackground()
            if showRestart {
                ToolbarItem(placement: .primaryAction) {
                    Button("Restart") { model.restartTranscriber() }
                }
            }
            if model.isDatabaseReady {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.actionItemsOpen.toggle()
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .buttonStyle(.borderless)
                    .help(model.actionItemsOpen ? "Hide action items" : "Show action items")
                }
                .plainToolbarBackground()
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsButton(model: model)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.showsLLMPanel {
                    LLMPanel(model: model)
                }
                bottomComposer
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.copyToast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, model.showsLLMPanel ? 220 : 90)
            }
        }
        .onKeyPress(.escape) {
            model.handleEscape() ? .handled : .ignored
        }
    }

    private var messageCountLabel: String {
        let count = model.transcriptionCount
        return "\(count) message\(count == 1 ? "" : "s")"
    }

    private var statusSubtitle: Text {
        Text(statusLine)
            .foregroundStyle(model.isListening ? Color.green : Theme.muted)
    }

    private var showRestart: Bool {
        guard model.isDatabaseReady, !model.isListening else { return false }
        let status = model.statusText
        return model.setupError != nil
            || status.contains("exited")
            || status.contains("failed")
            || status.contains("Microphone")
            || status.contains("not available")
    }

    private var statusLine: String {
        if let detail = model.activityDetail, !model.isListening {
            return detail
        }
        return model.statusText
    }

    private func setupBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.callout)
                .foregroundStyle(.white)
            Spacer()
            Button("Retry") { model.restartTranscriber() }
        }
        .padding(10)
        .background(Color.red.opacity(0.85))
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    TranscriptRow(
                        model: model,
                        item: item,
                        showsLeadingInsert: index == 0 && item.kind == .transcription
                    )
                    .id(item.id)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                Color.clear
                    .frame(height: 1)
                    .id("bottom-marker")
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear { model.pinnedToBottom = true }
                    .onDisappear { model.pinnedToBottom = false }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear {
                if let id = model.scrollToItemId {
                    scrollRevealedItemToTop(id, proxy: proxy)
                } else {
                    proxy.scrollTo("bottom-marker", anchor: .bottom)
                }
            }
            .onChange(of: model.scrollToken) { _, _ in
                guard model.scrollToItemId == nil else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom-marker", anchor: .bottom)
                }
            }
            .id(model.transcriptListID)
        }
    }

    /// Runs from the rebuilt list's appearance, after the full day is what the list is showing.
    private func scrollRevealedItemToTop(_ id: String, proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(id, anchor: .top)
            try? await Task.sleep(nanoseconds: 32_000_000)
            guard model.scrollToItemId == id else { return }
            proxy.scrollTo(id, anchor: .top)
            model.scrollToItemId = nil
        }
    }

    private var bottomComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add Note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
            HStack(alignment: .bottom, spacing: 8) {
                NoteTextEditor(text: $model.bottomNoteText, onCommandReturn: { model.saveBottomNote() })
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                Button("Save") { model.saveBottomNote() }
                    .disabled(model.bottomNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
}

private struct SettingsButton: View {
    @Bindable var model: AppModel
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("Text replacements")
        .sheet(isPresented: $open) {
            SettingsView(model: model)
        }
    }
}

struct TranscriptRow: View {
    @Bindable var model: AppModel
    var item: TimelineItem
    var showsLeadingInsert: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLeadingInsert {
                insertZone(.beforeFirst)
            }
            if item.kind == .annotation {
                annotationBody
            } else {
                messageBody
                insertZone(.after(item.sourceId))
            }
        }
        .onHover { hovering = $0 }
    }

    private var annotationBody: some View {
        let kind = item.annotationKind ?? .note
        let tint = kind == .llm ? Theme.accent : Theme.note
        return HStack(alignment: .top, spacing: 8) {
            Text(kind.label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.7)))
            if model.editingAnnotationId == item.sourceId {
                VStack(alignment: .leading, spacing: 6) {
                    NoteTextEditor(text: $model.editingText, onCommandReturn: { model.saveEdit() })
                        .frame(minHeight: 44)
                    HStack {
                        Button("Save") { model.saveEdit() }
                            .disabled(model.editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") {
                            model.editingAnnotationId = nil
                            model.editingText = ""
                        }
                    }
                }
            } else {
                Text(highlightedText(item.text, search: model.appliedSearch))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.beginEdit(item) }
                if hovering {
                    if showsShowInTranscript {
                        showInTranscriptButton
                    }
                    Button {
                        model.deleteAnnotation(item.sourceId)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete annotation")
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var messageBody: some View {
        messageText
            .overlay(alignment: .trailing) {
                if showsMessageActions {
                    messageActions
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.background.opacity(0.92))
                }
            }
            .overlay(alignment: .leading) {
                if model.isRangeEndpoint(item.sourceId) {
                    Theme.accent.frame(width: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var messageLabel: some View {
        let text = Text(highlightedText(item.text, search: model.appliedSearch))
            .frame(maxWidth: .infinity, alignment: .leading)
        if model.rangeSelecting {
            text.textSelection(.disabled)
        } else {
            text.textSelection(.enabled)
        }
    }

    private var messageText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Timestamp.formatTime(item.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .frame(width: 72, alignment: .leading)
            Text(Speaker.label(for: item.speaker))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.speaker == Speaker.you.rawValue ? Theme.accent : Theme.muted)
                .frame(width: 52, alignment: .leading)
            messageLabel
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(messageBackground)
        .contentShape(Rectangle())
        .modifier(RangeClickModifier(enabled: model.rangeSelecting) {
            model.completeRange(at: item.sourceId)
        })
        .onHover { inside in
            if inside {
                model.previewRangeEnd(item.sourceId)
            }
        }
    }

    private var showsMessageActions: Bool {
        showsSelectMessageButton || showsRangeActions || showsShowInTranscript
    }

    private var showsShowInTranscript: Bool {
        hovering && hasSearchHit
    }

    private var hasSearchHit: Bool {
        let search = model.appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return !Timeline.searchRanges(in: item.text, search: search).isEmpty
    }

    private var showsSelectMessageButton: Bool {
        hovering && !model.rangeSelecting && !isInsideSelectedRange
    }

    private var showsRangeActions: Bool {
        guard model.hasRange, let from = model.rangeFromId, let to = model.rangeToId else { return false }
        return item.sourceId == min(from, to)
    }

    private var isInsideSelectedRange: Bool {
        model.hasRange && model.isInRange(item.sourceId)
    }

    private var messageBackground: Color {
        if model.isInRange(item.sourceId) {
            return Theme.accent.opacity(0.16)
        }
        if model.isInRangePreview(item.sourceId) {
            return Theme.accent.opacity(0.1)
        }
        return Color.clear
    }

    private var messageActions: some View {
        HStack(spacing: 6) {
            if showsShowInTranscript {
                showInTranscriptButton
            }
            if showsSelectMessageButton {
                Button("Select message") { model.beginRangeSelection(at: item.sourceId) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Start a message range. Click another message to set the end. The range is the LLM context.")
            }
            if showsRangeActions {
                Button("Copy") { model.copySelectedRange() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy the selected messages")
                Button("Clear selection") { model.clearRange() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Clear the selected range")
            }
        }
    }

    private var showInTranscriptButton: some View {
        Button("Show in transcript") { model.showInTranscript(item) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Clear search and show this message with the surrounding transcript")
    }

    @ViewBuilder
    private func insertZone(_ insert: InlineInsert) -> some View {
        if model.inlineInsert == insert {
            HStack(alignment: .bottom, spacing: 8) {
                NoteTextEditor(text: $model.inlineText, onCommandReturn: { model.saveInlineNote() })
                    .frame(height: 44)
                Button("Save") { model.saveInlineNote() }
                    .disabled(model.inlineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") {
                    model.inlineInsert = nil
                    model.inlineText = ""
                }
            }
            .padding(.vertical, 4)
        } else {
            Button {
                model.inlineInsert = insert
                model.inlineText = ""
            } label: {
                Text(hovering ? "Add note" : " ")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 10, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func plainToolbarBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Row clicks set the end of a range. The gesture stays off the message until selection
/// is in progress, so it does not steal the Select message button or normal text selection.
private struct RangeClickModifier: ViewModifier {
    var enabled: Bool
    var action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}
