import AppKit
import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [EditableRule] = []
    @State private var saved = false
    @State private var confirmApply = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Text Replacements")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if rules.isEmpty {
                        Text("No replacement rules yet. Click Add Rule to get started.")
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach($rules) { $rule in
                        HStack(spacing: 8) {
                            TextField("Find text...", text: $rule.from)
                                .textFieldStyle(.roundedBorder)
                            Text("→")
                                .foregroundStyle(Theme.muted)
                            TextField("Replace with... (empty = delete)", text: $rule.to)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                rules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("+ Add Rule") {
                        rules.append(EditableRule(from: "", to: ""))
                    }
                    .buttonStyle(.borderless)
                }
                .padding()
            }

            Divider()

            HStack {
                Button(saved ? "Saved" : "Save") { save() }
                if !model.applyAllResult.isEmpty {
                    Text(model.applyAllResult)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Button(model.applyingAll ? "Applying…" : "Apply to All Past Transcripts") {
                    confirmApply = true
                }
                .disabled(model.applyingAll)
            }
            .padding()
        }
        .frame(width: 640, height: 420)
        .onAppear { load() }
        .confirmationDialog(
            "Apply these rules to every saved transcript?",
            isPresented: $confirmApply,
            titleVisibility: .visible
        ) {
            Button("Apply", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rules are saved first. Transcripts that become empty are deleted, along with notes attached to them.")
        }
    }

    private func load() {
        rules = model.config.replacements.map { EditableRule(from: $0.from, to: $0.to) }
    }

    private func save() {
        do {
            let cleaned = try model.saveReplacements(rules.map { ReplacementRule(from: $0.from, to: $0.to) })
            rules = cleaned.map { EditableRule(from: $0.from, to: $0.to) }
            saved = true
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    private func apply() {
        model.applyAllReplacements(rules.map { ReplacementRule(from: $0.from, to: $0.to) })
        load()
        saved = true
    }
}

struct EditableRule: Identifiable {
    var id = UUID()
    var from: String
    var to: String
}

struct IgnoredAppsView: View {
    @Bindable var model: AppModel
    @State private var rows: [IgnoredAppRow] = []
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ignored Apps")
                    .font(.headline)
                Text("Checked apps are left out of call audio, so their sound is not transcribed. On speakers, the microphone can still hear them.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Divider()

            TextField("Filter apps", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if visibleRows.isEmpty {
                        Text(query.isEmpty ? "No apps are running." : "No apps match.")
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(visibleRows) { row in
                        appRow(row)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .frame(width: 480, height: 560)
        .background(Theme.background)
        .onAppear { reload() }
        .onChange(of: model.config.ignoredAudioBundleIDs) { _, _ in
            reload()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            reload()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            reload()
        }
    }

    private var visibleRows: [IgnoredAppRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter {
            $0.name.localizedStandardContains(trimmed) || $0.bundleID.localizedStandardContains(trimmed)
        }
    }

    private func appRow(_ row: IgnoredAppRow) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                if !row.running {
                    Text("Not running")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            Toggle(
                "Block audio",
                isOn: Binding(
                    get: { model.config.ignoredAudioBundleIDs.contains(row.bundleID) },
                    set: { model.setAudioCaptureIgnored(bundleID: row.bundleID, ignored: $0) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("Block audio from \(row.name)")
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        rows = IgnoredAppCatalog.rows(blockedBundleIDs: model.config.ignoredAudioBundleIDs)
    }
}

struct IgnoredAppRow: Identifiable {
    let bundleID: String
    var id: String { bundleID }
    let name: String
    let icon: NSImage
    let running: Bool
}

enum IgnoredAppCatalog {
    static func rows(blockedBundleIDs: [String]) -> [IgnoredAppRow] {
        let own = Bundle.main.bundleIdentifier
        var runningByID: [String: IgnoredAppRow] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, bundleID != own else { continue }
            guard app.activationPolicy == .regular || app.activationPolicy == .accessory else { continue }
            if runningByID[bundleID] != nil { continue }
            runningByID[bundleID] = IgnoredAppRow(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                icon: app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(),
                running: true
            )
        }

        var rows = runningByID.values.sorted(by: compareNames)
        let runningIDs = Set(runningByID.keys)
        let missing = blockedBundleIDs.filter { $0 != own && !runningIDs.contains($0) }
        rows.append(contentsOf: missing.map(installedRow).sorted(by: compareNames))
        return rows
    }

    private static func installedRow(bundleID: String) -> IgnoredAppRow {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return IgnoredAppRow(
                bundleID: bundleID,
                name: FileManager.default.displayName(atPath: url.path),
                icon: NSWorkspace.shared.icon(forFile: url.path),
                running: false
            )
        }
        return IgnoredAppRow(
            bundleID: bundleID,
            name: bundleID,
            icon: NSImage(named: NSImage.applicationIconName) ?? NSImage(),
            running: false
        )
    }

    private static func compareNames(_ lhs: IgnoredAppRow, _ rhs: IgnoredAppRow) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
