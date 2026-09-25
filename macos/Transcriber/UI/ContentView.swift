import SwiftUI
import TranscriberCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            TranscriptDetailView(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: actionItemsPresented) {
            ActionItemsPanel(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbarBackground(Theme.panel, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .frame(minWidth: 1180, minHeight: 640)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showFirstLaunch) {
            FirstLaunchView(model: model)
                .interactiveDismissDisabled()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onAppear { model.start() }
    }

    private var actionItemsPresented: Binding<Bool> {
        Binding(
            get: { model.isDatabaseReady && model.actionItemsOpen },
            set: { isPresented in
                if model.isDatabaseReady {
                    model.actionItemsOpen = isPresented
                }
            }
        )
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// Space from the divider to the Summary title.
    private let summaryColumnInset: CGFloat = 14
    /// Same gap on both sides of a Generate button, the widest control in the column.
    private let summaryButtonInset: CGFloat = 16
    @State private var summaryColumnWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search", text: $model.searchInput)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.searchInput) { _, _ in
                        model.searchChanged()
                    }
                dateList
            }
            .frame(maxHeight: .infinity)

            Theme.line
                .frame(height: 1)
                .padding(.top, 8)

            KnowledgeBasePanel(model: model)
                .frame(height: 240)
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .navigationTitle("Transcriptions")
        .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 420)
    }

    private var dateList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                columnHeader
                if model.dates.isEmpty && !model.appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.dates, id: \.self) { date in
                        dateRow(date)
                    }
                }
            }
            .background(alignment: .trailing) {
                Theme.line
                    .frame(width: 1)
                    .padding(.trailing, summaryColumnWidth)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(SummaryColumnWidthKey.self) { summaryColumnWidth = $0 }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Transcript")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
            summaryColumn {
                Text("Summary")
                    .padding(.leading, summaryColumnInset)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.muted)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Theme.line.frame(height: 1)
        }
    }

    private func dateRow(_ date: String) -> some View {
        let selected = model.selectedDate == date
        return HStack(spacing: 0) {
            Button {
                model.selectDate(date)
            } label: {
                Text(Timestamp.formatDateLabel(date))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color(white: 0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(selected ? Theme.accent.opacity(0.28) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            summaryColumn(for: date)
        }
    }

    /// Width comes from a Generate button plus the same inset on each side.
    /// The visible control stays left-aligned, so narrower buttons share Generate's left edge.
    private func summaryColumn(for date: String) -> some View {
        summaryColumn {
            summaryButton(for: date)
                .padding(.leading, summaryButtonInset)
        }
    }

    /// The hidden Generate button is the width source for every row and the header,
    /// so the divider lands on the same edge in both.
    private func summaryColumn<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: summaryButtonInset)
            Button("Generate") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Color.clear.frame(width: summaryButtonInset)
        }
        .overlay(alignment: .leading) { content() }
        .fixedSize()
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: SummaryColumnWidthKey.self, value: proxy.size.width)
            }
        }
    }

    @ViewBuilder
    private func summaryButton(for date: String) -> some View {
        if model.isDailySummaryBusy(date) {
            Button {
                openWindow(id: AppWindow.dailySummary, value: date)
            } label: {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Generating daily summary")
        } else if model.hasDailySummary(date) {
            Button("View") {
                openWindow(id: AppWindow.dailySummary, value: date)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("View daily summary")
        } else {
            Button("Generate") {
                openWindow(id: AppWindow.dailySummary, value: date)
                model.generateDailySummary(day: date)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Generate daily summary")
        }
    }
}

private struct SummaryColumnWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
