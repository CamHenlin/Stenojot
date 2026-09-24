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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search", text: $model.searchInput)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.searchInput) { _, _ in
                    model.searchChanged()
                }
            List {
                if model.dates.isEmpty && !model.appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(model.dates, id: \.self) { date in
                    dateRow(date)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(Theme.sidebar)
        .navigationTitle("Transcriptions")
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }

    private func dateRow(_ date: String) -> some View {
        let selected = model.selectedDate == date
        return HStack(spacing: 6) {
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
            summaryButton(for: date)
                .layoutPriority(1)
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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
