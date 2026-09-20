import Foundation

public enum DailyRefreshGate {

    public static func needsRefresh(
        lastFetchedAt: Date?, cachedDay: Date?, now: Date,
        ttl: TimeInterval, calendar: Calendar = .current
    ) -> Bool {

        guard let lastFetchedAt, let cachedDay else { return true }

        guard calendar.isDate(cachedDay, inSameDayAs: now) else { return true }
        return now.timeIntervalSince(lastFetchedAt) >= ttl
    }
}
