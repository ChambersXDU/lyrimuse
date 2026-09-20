import Foundation

public enum IdleListeningStats {

    public static func series(
        dailyCounts: [String: Int], endingAt today: Date, days: Int,
        calendar: Calendar = .current, dayKey: (Date) -> String
    ) -> [Int] {
        guard days > 0 else { return [] }
        let start = calendar.startOfDay(for: today)
        return (0 ..< days).compactMap { i -> Int? in
            guard let d = calendar.date(byAdding: .day, value: i - (days - 1), to: start) else { return nil }
            return dailyCounts[dayKey(d)] ?? 0
        }
    }

    public static func days(
        endingAt today: Date, days: Int, calendar: Calendar = .current
    ) -> [Date] {
        guard days > 0 else { return [] }
        let start = calendar.startOfDay(for: today)
        return (0 ..< days).compactMap {
            calendar.date(byAdding: .day, value: $0 - (days - 1), to: start)
        }
    }

    public static func lastSevenDays(
        dailyCounts: [String: Int], today: Date, todayCount: Int? = nil,
        calendar: Calendar = .current, dayKey: (Date) -> String
    ) -> Int {
        var s = series(dailyCounts: dailyCounts, endingAt: today, days: 7,
                       calendar: calendar, dayKey: dayKey)
        if let todayCount, let last = s.indices.last {
            s[last] = todayCount
        }
        return s.reduce(0, +)
    }

    public static func weekOverWeekDelta(
        dailyCounts: [String: Int], today: Date, todayCount: Int? = nil,
        calendar: Calendar = .current, dayKey: (Date) -> String
    ) -> Double? {
        var s = series(dailyCounts: dailyCounts, endingAt: today, days: 14,
                       calendar: calendar, dayKey: dayKey)

        if let todayCount, let last = s.indices.last {
            s[last] = todayCount
        }
        guard s.count == 14 else { return nil }
        let prev = s[0 ..< 7].reduce(0, +)
        let last = s[7 ..< 14].reduce(0, +)
        guard prev > 0 else { return nil }
        return (Double(last) - Double(prev)) / Double(prev)
    }

    public static func dailyAverage(dailyCounts: [String: Int]) -> (average: Int, days: Int)? {
        let days = dailyCounts.count
        guard days > 0 else { return nil }
        let total = dailyCounts.values.reduce(0, +)
        return (Int((Double(total) / Double(days)).rounded()), days)
    }
}
