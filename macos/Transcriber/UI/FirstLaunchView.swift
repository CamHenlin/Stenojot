import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FirstLaunchView: View {
    var model: AppModel
    @State private var databaseURL: URL?
    @State private var configURL: URL?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import your transcripts")
                .font(.title2.weight(.semibold))
            Text("Parakeet Transcriber keeps its own copy of the database. Import the existing transcriptions.db, and optionally config.json, or start with an empty database.")
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            fileRow("Database", url: databaseURL) {
                databaseURL = choose(title: "Choose transcriptions.db", extension: "db")
            }
            fileRow("Settings", url: configURL) {
                configURL = choose(title: "Choose config.json", extension: "json")
            }

            HStack {
                Button("Start Empty") {
                    finish(empty: true)
                }
                .disabled(busy)
                Spacer()
                Button("Import Database") {
                    finish(empty: false)
                }
                .disabled(databaseURL == nil || busy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func fileRow(_ title: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                Text(url?.lastPathComponent ?? "Not selected")
                    .lineLimit(1)
            }
            Spacer()
            Button("Choose…", action: action)
        }
    }

    private func choose(title: String, extension ext: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func finish(empty: Bool) {
        busy = true
        let database = databaseURL
        let config = configURL
        Task {
            await model.completeFirstLaunch(databaseURL: database, configURL: config, empty: empty)
            busy = false
        }
    }
}
