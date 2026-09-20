import Foundation

public enum OnThisDayPlanner {
    public enum Span: Int, Equatable, Codable, Sendable {
        case day = 1
        case week = 7
    }

    public struct Window: Equatable {
        public let yearsAgo: Int
        public let span: Span

        public let from: Date

        public let to: Date

        public let expected: Int?
    }

    public static let weekHalfWidth = 3

    public static func plan(
        today: Date, years: Int, dailyCounts: [String: Int], synced: Bool,
        calendar: Calendar = .current, dayKey: (Date) -> String
    ) -> [Window] {
        guard years >= 1 else { return [] }
        var out: [Window] = []
        for yearsAgo in 1 ... years {
            guard let anchor = calendar.date(byAdding: .year, value: -yearsAgo, to: today) else { continue }
            let dayStart = calendar.startOfDay(for: anchor)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            if !synced {

                out.append(Window(yearsAgo: yearsAgo, span: .day, from: dayStart, to: dayEnd, expected: nil))
                continue
            }
            let dayCount = dailyCounts[dayKey(dayStart)] ?? 0
            if dayCount > 0 {
                out.append(Window(yearsAgo: yearsAgo, span: .day, from: dayStart, to: dayEnd, expected: dayCount))
                continue
            }
            guard let weekStart = calendar.date(byAdding: .day, value: -weekHalfWidth, to: dayStart),
                  let weekEnd = calendar.date(byAdding: .day, value: weekHalfWidth + 1, to: dayStart)
            else { continue }
            var weekCount = 0
            var cursor = weekStart
            while cursor < weekEnd {
                weekCount += dailyCounts[dayKey(cursor)] ?? 0
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            if weekCount > 0 {
                out.append(Window(yearsAgo: yearsAgo, span: .week, from: weekStart, to: weekEnd, expected: weekCount))
            }
        }
        return out
    }
}

public enum ListeningMilestones {
    public struct DayCount: Equatable {
        public let day: String
        public let count: Int
        public init(day: String, count: Int) { self.day = day; self.count = count }
    }

    public struct Summary: Equatable {

        public let firstDay: String?

        public let daysSinceFirst: Int?

        public let recordedDays: Int

        public let peak: DayCount?

        public let currentStreak: Int

        public let longestStreak: Int
        public let longestStreakEnd: String?

        public let yearToDate: Int

        public let priorYearSameSpan: (year: Int, count: Int)?

        public init(firstDay: String?, daysSinceFirst: Int?, recordedDays: Int, peak: DayCount?,
                    currentStreak: Int, longestStreak: Int, longestStreakEnd: String?,
                    yearToDate: Int, priorYearSameSpan: (year: Int, count: Int)?) {
            self.firstDay = firstDay
            self.daysSinceFirst = daysSinceFirst
            self.recordedDays = recordedDays
            self.peak = peak
            self.currentStreak = currentStreak
            self.longestStreak = longestStreak
            self.longestStreakEnd = longestStreakEnd
            self.yearToDate = yearToDate
            self.priorYearSameSpan = priorYearSameSpan
        }

        public static func == (a: Summary, b: Summary) -> Bool {
            a.firstDay == b.firstDay && a.daysSinceFirst == b.daysSinceFirst && a.recordedDays == b.recordedDays
                && a.peak == b.peak && a.currentStreak == b.currentStreak && a.longestStreak == b.longestStreak
                && a.longestStreakEnd == b.longestStreakEnd && a.yearToDate == b.yearToDate
                && a.priorYearSameSpan?.year == b.priorYearSameSpan?.year && a.priorYearSameSpan?.count == b.priorYearSameSpan?.count
        }
    }

    static func parseDay(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar.date(from: comps)
    }

    public static func summarize(
        dailyCounts: [String: Int], today: Date,
        calendar: Calendar = .current, dayKey: (Date) -> String
    ) -> Summary {
        let nonZero = dailyCounts.filter { $0.value > 0 }
        let keys = nonZero.keys.sorted()
        let todayStart = calendar.startOfDay(for: today)
        let todayKey = dayKey(todayStart)

        var daysSinceFirst: Int?
        if let first = keys.first, let firstDate = parseDay(first, calendar: calendar) {
            daysSinceFirst = (calendar.dateComponents([.day], from: firstDate, to: todayStart).day ?? 0) + 1
        }

        var peak: DayCount?
        for k in keys {
            let v = nonZero[k]!
            if peak == nil || v > peak!.count { peak = DayCount(day: k, count: v) }
        }

        var longest = 0, longestEnd: String?
        var run = 0
        var prev: Date?
        for k in keys {
            guard let d = parseDay(k, calendar: calendar) else { continue }
            if let p = prev, let diff = calendar.dateComponents([.day], from: p, to: d).day, diff == 1 {
                run += 1
            } else {
                run = 1
            }
            if run > longest { longest = run; longestEnd = k }
            prev = d
        }

        var current = 0
        var cursor = todayStart
        if (nonZero[todayKey] ?? 0) == 0, let y = calendar.date(byAdding: .day, value: -1, to: todayStart) {
            cursor = y
        }
        while (nonZero[dayKey(cursor)] ?? 0) > 0 {
            current += 1
            guard let prevDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prevDay
        }

        let year = calendar.component(.year, from: todayStart)
        let monthDay = String(todayKey.dropFirst(5))
        func spanTotal(_ y: Int) -> Int {
            let prefix = String(format: "%04d-", y)
            return nonZero.reduce(0) { acc, kv in
                guard kv.key.hasPrefix(prefix), String(kv.key.dropFirst(5)) <= monthDay else { return acc }
                return acc + kv.value
            }
        }
        let ytd = spanTotal(year)
        var prior: (year: Int, count: Int)?
        if let first = keys.first, let firstYear = Int(first.prefix(4)) {
            var y = year - 1
            while y >= firstYear {
                let t = spanTotal(y)
                if t > 0 { prior = (y, t); break }
                y -= 1
            }
        }
        return Summary(firstDay: keys.first, daysSinceFirst: daysSinceFirst, recordedDays: keys.count,
                       peak: peak, currentStreak: current, longestStreak: longest, longestStreakEnd: longestEnd,
                       yearToDate: ytd, priorYearSameSpan: prior)
    }

    public static func nextMilestone(total: Int) -> (target: Int, remaining: Int) {
        let step = total < 1_000 ? 100 : (total < 10_000 ? 500 : 1_000)
        let target = (total / step + 1) * step
        return (target, target - total)
    }
}
