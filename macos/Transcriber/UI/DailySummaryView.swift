import SwiftUI
import TranscriberCore

struct DailySummaryView: View {
    @Bindable var model: AppModel
    var day: String
    @State private var text = ""
    @State private var savedText = ""
    @State private var confirmRegenerate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Theme.line.frame(height: 1)
            content
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Theme.background)
        .onAppear { pullSummary() }
        .onChange(of: model.dailySummaryRevision) { _, _ in
            pullSummary()
        }
        .onChange(of: model.generatingSummaryDay) { _, generating in
            if generating == day {
                text = ""
                savedText = ""
            } else if !isGenerating {
                pullSummary()
            }
        }
        .confirmationDialog(
            "Regenerate this summary?",
            isPresented: $confirmRegenerate,
            titleVisibility: .visible
        ) {
            Button("Regenerate", role: .destructive) {
                model.regenerateDailySummary(day: day)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The summary for this day is replaced, including any unsaved edits. Change the system prompt first if you want a different result.")
        }
    }

    private var isGenerating: Bool {
        model.generatingSummaryDay == day
    }

    private var showsSave: Bool {
        !isGenerating && model.hasDailySummary(day) && text != savedText
    }

    private var showsRegenerate: Bool {
        model.hasDailySummary(day) && !model.isDailySummaryBusy(day)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily summary")
                        .font(.headline)
                    Text(Timestamp.formatLongDate(day))
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                if showsRegenerate {
                    Button("Regenerate") {
                        confirmRegenerate = true
                    }
                    .disabled(model.isDailySummaryBusy(day))
                }
                if showsSave {
                    Button("Save") {
                        model.saveDailySummary(day: day, text: text)
                    }
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
            if let progress = generationProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
            } else if let status = failureStatus {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .padding(16)
    }

    /// Status for this day's generation. Other days in the queue keep their own waiting state.
    private var generationProgress: String? {
        guard isGenerating, let progress = model.summaryProgress, !progress.isEmpty else { return nil }
        return progress
    }

    /// Shown when a regenerate fails and the previous summary is still on screen.
    private var failureStatus: String? {
        guard model.summaryStatusDay == day, let status = model.summaryStatus, !status.isEmpty else { return nil }
        return status
    }

    @ViewBuilder
    private var content: some View {
        if isGenerating {
            streamingBody
        } else if model.isDailySummaryQueued(day) {
            waitingBody
        } else if model.hasDailySummary(day) {
            editor
        } else {
            emptyBody
        }
    }

    private var streamingBody: some View {
        ScrollView {
            Text(streamText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var streamText: String {
        guard !model.summaryStreamText.isEmpty else { return "" }
        return model.summaryStreamText + " ▍"
    }

    private var waitingBody: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Waiting for the current summary to finish…")
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        NoteTextEditor(text: $text)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusMessage)
                .foregroundStyle(model.summaryStatusDay == day && model.summaryStatus != nil ? Color.red : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Generate") {
                model.generateDailySummary(day: day)
            }
            .disabled(model.isDailySummaryBusy(day))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusMessage: String {
        if model.summaryStatusDay == day, let status = model.summaryStatus, !status.isEmpty {
            return status
        }
        return "No summary for this day yet."
    }

    /// Keeps unsaved edits. A generation or a finished save refreshes the baseline the Save button compares against.
    private func pullSummary() {
        let stored = model.dailySummaryText(for: day) ?? ""
        if text == stored {
            savedText = stored
            return
        }
        if text == savedText {
            text = stored
            savedText = stored
        }
    }
}
