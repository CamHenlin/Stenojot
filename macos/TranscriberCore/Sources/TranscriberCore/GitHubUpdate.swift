import Foundation

/// A newer GitHub release the app can send the user to.
public struct GitHubReleaseOffer: Equatable, Sendable {
    public var version: AppVersion
    public var pageURL: URL

    public init(version: AppVersion, pageURL: URL) {
        self.version = version
        self.pageURL = pageURL
    }
}

/// Latest-release lookup for CamHenlin/Stenojot.
public enum GitHubUpdate {
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/CamHenlin/Stenojot/releases/latest")!
    public static let latestReleasePage = URL(string: "https://github.com/CamHenlin/Stenojot/releases/latest")!

    /// The release page when `data` is a GitHub latest-release payload newer than `current`.
    public static func offer(parsing data: Data, newerThan current: AppVersion) -> GitHubReleaseOffer? {
        guard let payload = try? JSONDecoder().decode(LatestRelease.self, from: data),
              let version = AppVersion(payload.tagName),
              version > current else {
            return nil
        }
        let page = URL(string: payload.htmlURL) ?? latestReleasePage
        return GitHubReleaseOffer(version: version, pageURL: page)
    }

    private struct LatestRelease: Decodable {
        var tagName: String
        var htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}

/// Wall-clock times for the in-app update check. The first check is one day after this process started.
public enum UpdateCheckSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60

    /// When the next check is due. With no previous check, that is `interval` after `startedAt`.
    public static func nextCheck(startedAt: Date, lastCheck: Date?) -> Date {
        let anchor = lastCheck ?? startedAt
        return anchor.addingTimeInterval(interval)
    }
}
