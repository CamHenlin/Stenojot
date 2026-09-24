import SwiftUI
import TranscriberCore

struct LLMSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LLM Settings")
                    .font(.headline)
                Text("The model runs inside the app. A download is kept on this Mac and reused after you quit. A long transcript needs more memory than the model alone.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Divider()

            ScrollView {
                LLMModelList(model: model)
                    .padding()
            }
        }
        .frame(width: 640, height: 560)
        .background(Theme.background)
    }
}

struct LLMModelList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(LocalLanguageModelCatalog.models) { languageModel in
                modelRow(languageModel)
            }
            if let error = model.llmDownloadError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func modelRow(_ languageModel: LocalLanguageModel) -> some View {
        let downloaded = model.isLocalModelDownloaded(languageModel.id)
        let selected = model.config.localModelId == languageModel.id && downloaded
        let downloading = model.llmDownloadingId == languageModel.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(languageModel.name)
                    .font(.body.weight(.semibold))
                if languageModel.recommended {
                    Text("Recommended")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                rowAction(
                    languageModel: languageModel,
                    downloaded: downloaded,
                    selected: selected,
                    downloading: downloading
                )
            }
            Text(languageModel.requirementLine)
                .font(.caption)
                .foregroundStyle(Theme.muted)
            Text(languageModel.summary)
                .font(.caption)
                .foregroundStyle(Color(white: 0.82))
                .fixedSize(horizontal: false, vertical: true)
            if downloading, let fraction = model.llmDownloadFraction {
                ProgressView(value: fraction)
                    .tint(Theme.accent)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .background(selected ? Theme.accent.opacity(0.12) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Theme.accent.opacity(0.7) : Theme.line)
        )
    }

    @ViewBuilder
    private func rowAction(
        languageModel: LocalLanguageModel,
        downloaded: Bool,
        selected: Bool,
        downloading: Bool
    ) -> some View {
        if downloading {
            Text("Downloading…")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        } else if selected {
            Text("In use")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
        } else if downloaded {
            Button("Use") { model.useLocalModel(languageModel.id) }
                .controlSize(.small)
        } else {
            Button("Download") { model.downloadLocalModel(languageModel.id) }
                .controlSize(.small)
                .disabled(model.llmDownloadingId != nil)
        }
    }
}
