import AppKit
import Foundation
import TranscriberCore

/// Remembers a newer release so the toolbar button survives quitting until this copy is that version or newer.
enum UpdateNotice {
    private static let versionKey = "updateNotice.version"
    private static let urlKey = "updateNotice.url"

    static func load() -> GitHubReleaseOffer? {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: versionKey),
              let version = AppVersion(raw),
              let urlString = defaults.string(forKey: urlKey),
              let pageURL = URL(string: urlString) else {
            return nil
        }
        return GitHubReleaseOffer(version: version, pageURL: pageURL)
    }

    static func save(_ offer: GitHubReleaseOffer) {
        let defaults = UserDefaults.standard
        defaults.set(offer.version.components.map(String.init).joined(separator: "."), forKey: versionKey)
        defaults.set(offer.pageURL.absoluteString, forKey: urlKey)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: urlKey)
    }
}

/// Checks GitHub one day after this process starts, then once a day, including after the Mac wakes.
@MainActor
final class UpdateChecker {
    private var startedAt = Date()
    private var lastCheck: Date?
    private var task: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var currentVersion: AppVersion?
    private var onChange: ((URL?) -> Void)?

    func start(currentVersion raw: String, onChange: @escaping (URL?) -> Void) {
        stop()
        self.onChange = onChange
        currentVersion = AppVersion(raw)
        startedAt = Date()
        lastCheck = nil
        publishSavedNotice()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.wake()
            }
        }
        arm()
    }

    /// Runs the same check the daily timer uses, then schedules the next one a day later.
    func checkForUpdates() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await self?.checkNow()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func publishSavedNotice() {
        guard let currentVersion, let saved = UpdateNotice.load(), saved.version > currentVersion else {
            UpdateNotice.clear()
            onChange?(nil)
            return
        }
        onChange?(saved.pageURL)
    }

    private func dueDate() -> Date {
        UpdateCheckSchedule.nextCheck(startedAt: startedAt, lastCheck: lastCheck)
    }

    private func arm() {
        task?.cancel()
        let delay = max(0, dueDate().timeIntervalSinceNow)
        let nanoseconds = UInt64(delay * 1_000_000_000)
        task = Task { @MainActor [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.checkNow()
        }
    }

    private func wake() {
        guard task != nil else { return }
        if dueDate().timeIntervalSinceNow <= 1 {
            task?.cancel()
            task = Task { @MainActor [weak self] in
                await self?.checkNow()
            }
        } else {
            arm()
        }
    }

    private func checkNow() async {
        lastCheck = Date()
        await fetch()
        arm()
    }

    private func fetch() async {
        guard let currentVersion else { return }
        var request = URLRequest(url: GitHubUpdate.latestReleaseAPI)
        request.setValue("Stenojot", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let offer = GitHubUpdate.offer(parsing: data, newerThan: currentVersion) else {
                UpdateNotice.clear()
                onChange?(nil)
                return
            }
            UpdateNotice.save(offer)
            onChange?(offer.pageURL)
        } catch {
            return
        }
    }
}
