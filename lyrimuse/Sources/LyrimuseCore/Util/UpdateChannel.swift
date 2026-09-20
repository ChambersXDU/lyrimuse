import Foundation

public enum UpdateChannel {
    public static let repository = "Yudaotor/lyrimuse"

    public static let releasesAPIURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!

    public static func releasePageURL(displayVersion: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(displayVersion)")
            ?? URL(string: "https://github.com/\(repository)/releases")!
    }

    public static let refreshTTL: TimeInterval = 3600

    public static let failureBackoff: TimeInterval = 15 * 60

    public static let betaChannelName = "beta"

    public struct Release: Equatable {
        public let tag: String
        public let prerelease: Bool
        public let draft: Bool
        public init(tag: String, prerelease: Bool, draft: Bool) {
            self.tag = tag
            self.prerelease = prerelease
            self.draft = draft
        }
    }

    public static func parseReleases(_ data: Data) -> [Release]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var out: [Release] = []
        for item in array {
            guard let tag = item["tag_name"] as? String else { return nil }
            out.append(Release(tag: tag,
                               prerelease: item["prerelease"] as? Bool ?? false,
                               draft: item["draft"] as? Bool ?? false))
        }
        return out
    }

    public static func newestRelease(_ releases: [Release]) -> Release? {
        releases
            .filter { !$0.draft }
            .compactMap { release in ReleaseVersion(tag: release.tag).map { (release, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    public static func appcastURL(forTag tag: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(tag)/appcast.xml")!
    }

    public static func betaFeedURL(releases: [Release]) -> URL? {
        newestRelease(releases).map { appcastURL(forTag: $0.tag) }
    }

    public static func shouldRefresh(now: Date, fetchedAt: Date?, retryNotBefore: Date?) -> Bool {
        if let retryNotBefore, now < retryNotBefore { return false }
        guard let fetchedAt else { return true }
        let age = now.timeIntervalSince(fetchedAt)
        if age < 0 { return true }
        return age >= refreshTTL
    }
}
