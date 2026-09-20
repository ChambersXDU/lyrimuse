import Foundation

public enum GitHubStars {

    public static let repoAPIURL = URL(string: "https://api.github.com/repos/Yudaotor/lyrimuse")!

    public static let refreshTTL: TimeInterval = 6 * 3600

    public static let failureBackoff: TimeInterval = 30 * 60

    public static func parseStarCount(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["stargazers_count"] as? Int,
              raw >= 0
        else { return nil }
        return raw
    }

    public static func shouldRefresh(now: Date, fetchedAt: Date?, retryNotBefore: Date?) -> Bool {

        if let retryNotBefore, now < retryNotBefore { return false }
        guard let fetchedAt else { return true }
        let age = now.timeIntervalSince(fetchedAt)

        if age < 0 { return true }
        return age >= refreshTTL
    }

    public static func retryDate(now: Date, rateLimitReset: String?) -> Date {
        let fallback = now.addingTimeInterval(failureBackoff)
        guard let rateLimitReset, let epoch = TimeInterval(rateLimitReset.trimmingCharacters(in: .whitespaces))
        else { return fallback }
        let reset = Date(timeIntervalSince1970: epoch)
        return reset > now ? reset : fallback
    }
}
