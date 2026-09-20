import Foundation

public enum PlayCountRecency {

    public static func newest(_ items: [(key: String, date: Date?)]) -> [String: Date] {
        var out: [String: Date] = [:]
        for item in items {
            guard let d = item.date else { continue }
            if let cur = out[item.key], cur >= d { continue }
            out[item.key] = d
        }
        return out
    }

    public static func contradicted(onPage: Int, cachedTotal: Int,
                                    lastFetched: Date?, now: Date,
                                    recheckAfter: TimeInterval) -> Bool {
        guard onPage > cachedTotal else { return false }
        guard let lastFetched else { return true }
        return now.timeIntervalSince(lastFetched) >= recheckAfter
    }

    public static func stale(lastFetched: Date?, now: Date, maxAge: TimeInterval) -> Bool {
        guard let lastFetched else { return true }
        return now.timeIntervalSince(lastFetched) >= maxAge
    }

    public static func reconciledNowPlayingCount(
        current: Int?, freshTotal: Int, currentPlayCounted: Bool
    ) -> Int? {
        let candidate = freshTotal + (currentPlayCounted ? 0 : 1)
        guard candidate > 0 else { return nil }
        if candidate > (current ?? 0) { return candidate }
        if currentPlayCounted, let current, candidate == current - 1 { return candidate }
        return nil
    }

    public static func currentPlayIsScrobbled(
        newestScrobbleAt: Date?, playStart: Date?, tolerance: TimeInterval = 120
    ) -> Bool {
        guard let newestScrobbleAt, let playStart else { return false }
        return abs(newestScrobbleAt.timeIntervalSince(playStart)) < tolerance
    }
}
