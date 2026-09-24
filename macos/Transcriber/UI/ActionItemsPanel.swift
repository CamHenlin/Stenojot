import SwiftUI
import TranscriberCore

struct ActionItemsPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notice = noticeText {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            if let error = model.actionItemError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            composer
            Theme.line.frame(height: 1)
            itemList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Action items")
                .font(.headline)
            Spacer()
            Button {
                model.actionItemsOpen = false
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Hide action items")
        }
        .padding(12)
    }

    private var noticeText: String? {
        if !model.llmAvailable {
            return "Add a language model to pull action items from pauses in the transcript. You can still add them here."
        }
        if model.actionItemsExtracting {
            return "Checking the latest transcript for action items…"
        }
        return nil
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("Add an action item", text: $model.actionItemDraft)
                .textFieldStyle(.plain)
                .onSubmit { model.addActionItem() }
            Button("Add") { model.addActionItem() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.actionItemDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var itemList: some View {
        List {
            if model.actionItems.isEmpty {
                Text("No action items yet")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(sections, id: \.day) { section in
                Section(Timestamp.formatDateLabel(section.day)) {
                    ForEach(section.items) { item in
                        ActionItemRow(item: item, model: model)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sections: [(day: String, items: [ActionItem])] {
        var order: [String] = []
        var groups: [String: [ActionItem]] = [:]
        for item in model.actionItems {
            let day = actionItemDay(item)
            if groups[day] == nil {
                order.append(day)
            }
            groups[day, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func actionItemDay(_ item: ActionItem) -> String {
        guard let date = Timestamp.parse(item.timestamp) else {
            return String(item.timestamp.prefix(10))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct ActionItemRow: View {
    var item: ActionItem
    @Bindable var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                model.toggleActionItem(item)
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Theme.accent : Theme.muted)
            }
            .buttonStyle(.plain)
            .help(item.done ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? Theme.muted : Color(white: 0.92))
                    .fixedSize(horizontal: false, vertical: true)
                Text(Timestamp.formatTime(item.timestamp))
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if hovering {
                Button {
                    model.deleteActionItem(item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Delete action item")
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu {
            Button("Delete", role: .destructive) {
                model.deleteActionItem(item.id)
            }
        }
    }
}
