import SwiftUI
import TranscriberCore

struct KnowledgeDocumentDiffView: View {
    var changes: [KnowledgeDocumentChange]

    var body: some View {
        ScrollView {
            if changes.isEmpty {
                Text("No differences.")
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(changes) { change in
                        section(change)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func section(_ change: KnowledgeDocumentChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(change.section.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(change.lines.enumerated()), id: \.offset) { _, line in
                    diffLine(line)
                }
            }
        }
    }

    @ViewBuilder
    private func diffLine(_ line: TextDiffLine) -> some View {
        switch line.kind {
        case .skipped(let count):
            Text("\(count) unchanged \(count == 1 ? "line" : "lines")")
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        case .same, .added, .removed:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker(for: line.kind))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(markerColor(for: line.kind))
                    .frame(width: 12, alignment: .center)
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color(white: 0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(lineBackground(for: line.kind))
        }
    }

    private func marker(for kind: TextDiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .same, .skipped: return ""
        }
    }

    private func markerColor(for kind: TextDiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color(red: 0.55, green: 0.82, blue: 0.58)
        case .removed: return Color(red: 0.93, green: 0.48, blue: 0.45)
        case .same, .skipped: return Theme.muted
        }
    }

    private func lineBackground(for kind: TextDiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color(red: 0.25, green: 0.48, blue: 0.32).opacity(0.45)
        case .removed: return Color(red: 0.55, green: 0.22, blue: 0.22).opacity(0.45)
        case .same, .skipped: return Color.clear
        }
    }
}
