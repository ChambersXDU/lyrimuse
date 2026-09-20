import SwiftUI

struct LastfmHeatmapView: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var year = 0

    private static let lightLevels = ["#9be9a8", "#40c463", "#30a14e", "#216e39"]
    private static let darkLevels = ["#0e4429", "#006d32", "#26a641", "#39d353"]

    private var availableYears: [Int] {
        let ys = Set(stats.dailyCounts.keys.compactMap { Int($0.prefix(4)) })
        let current = Calendar.current.component(.year, from: Date())
        return ys.union([current]).sorted(by: >)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.t("播放热力图")).font(.headline)
                Spacer()
                Picker("", selection: $year) {
                    ForEach(availableYears, id: \.self) { y in
                        Text(verbatim: "\(y)").tag(y)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            grid
            HStack(spacing: 10) {
                if stats.dailySyncing {
                    ProgressView().controlSize(.small)
                    Text(stats.dailySyncProgress ?? L10n.t("正在同步…"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if stats.dailySyncFailed {
                    Text(L10n.t("同步失败")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.t("重试")) { stats.refreshDailyCounts() }
                        .controlSize(.small)
                } else {
                    Text(String(format: L10n.t("%1$@ 年共 %2$@ 次"), "\(year)", yearTotal.formatted()))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Text(L10n.t("少")).font(.caption2).foregroundStyle(.tertiary)
                HStack(spacing: 3) {
                    cellShape(fill: emptyColor)
                    ForEach(levelColors, id: \.self) { c in cellShape(fill: c) }
                }
                Text(L10n.t("多")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .onAppear {
            if year == 0 {

                year = availableYears.first(where: { yearHasData($0) }) ?? availableYears.first ?? 2026
            }
            stats.refreshDailyCounts()
        }
    }

    private static let cellSize: CGFloat = 11
    private static let cellGap: CGFloat = 3

    private var grid: some View {
        let weeks = weekColumns(year: year)
        let thresholds = levelThresholds(year: year)
        return VStack(alignment: .leading, spacing: 3) {

            HStack(spacing: Self.cellGap) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    Text(week.monthLabel ?? " ")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: Self.cellSize, alignment: .leading)
                }
            }
            .frame(height: 10)
            HStack(alignment: .top, spacing: Self.cellGap) {

                VStack(spacing: Self.cellGap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(row == 0 ? L10n.t("一") : row == 2 ? L10n.t("三") : row == 4 ? L10n.t("五") : " ")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12, height: Self.cellSize)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: Self.cellGap) {
                        ForEach(0..<7, id: \.self) { row in
                            if let day = week.days[row] {
                                let n = stats.dailyCounts[day.key] ?? 0
                                cellShape(fill: color(for: n, thresholds: thresholds))
                                    .help("\(day.label) · \(n.formatted()) \(L10n.t("次"))")
                            } else {

                                cellShape(fill: .clear)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cellShape(fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill)
            .frame(width: Self.cellSize, height: Self.cellSize)
    }

    private struct WeekColumn {
        var days: [DayCell?]
        var monthLabel: String?
    }
    private struct DayCell {
        var key: String
        var label: String
    }

    private func weekColumns(year: Int) -> [WeekColumn] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        guard let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let dec31 = cal.date(from: DateComponents(year: year, month: 12, day: 31))
        else { return [] }
        let today = cal.startOfDay(for: Date())
        let end = min(dec31, today)

        var cursor = cal.startOfDay(for: jan1)
        let weekdayRow = { (d: Date) -> Int in (cal.component(.weekday, from: d) + 5) % 7 }
        cursor = cal.date(byAdding: .day, value: -weekdayRow(cursor), to: cursor) ?? cursor
        var weeks: [WeekColumn] = []
        var lastLabeledMonth = 0
        while cursor <= end {
            var days: [DayCell?] = Array(repeating: nil, count: 7)
            var label: String?
            for row in 0..<7 {
                guard let d = cal.date(byAdding: .day, value: row, to: cursor) else { continue }
                let comps = cal.dateComponents([.year, .month, .day], from: d)
                guard comps.year == year, d <= end else { continue }
                days[row] = DayCell(
                    key: LastfmStatsService.dayKey(d),
                    label: String(format: L10n.t("%1$@ 年 %2$@ 月 %3$@ 日"),
                                  "\(comps.year!)", "\(comps.month!)", "\(comps.day!)"))
                if comps.day! <= 7, comps.month! != lastLabeledMonth {
                    label = String(format: L10n.t("%@ 月"), "\(comps.month!)")
                    lastLabeledMonth = comps.month!
                }
            }
            weeks.append(WeekColumn(days: days, monthLabel: label))
            cursor = cal.date(byAdding: .day, value: 7, to: cursor) ?? end.addingTimeInterval(1)
        }
        return weeks
    }

    private func levelThresholds(year: Int) -> [Int] {
        let prefix = "\(year)-"
        let values = stats.dailyCounts.filter { $0.key.hasPrefix(prefix) && $0.value > 0 }
            .map(\.value).sorted()
        guard !values.isEmpty else { return [1, 2, 3] }
        func q(_ p: Double) -> Int { values[min(values.count - 1, Int(Double(values.count) * p))] }
        var t = [q(0.25), q(0.5), q(0.75)]
        for i in 1..<3 where t[i] <= t[i - 1] { t[i] = t[i - 1] + 1 }
        return t
    }

    private var levelColors: [Color] {
        (colorScheme == .dark ? Self.darkLevels : Self.lightLevels)
            .compactMap { NSColor(hexStringWithAlpha: $0 + "FF").map(Color.init) }
    }
    private var emptyColor: Color { Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07) }

    private func color(for count: Int, thresholds: [Int]) -> Color {
        guard count > 0 else { return emptyColor }
        let levels = levelColors
        if count <= thresholds[0] { return levels[0] }
        if count <= thresholds[1] { return levels[1] }
        if count <= thresholds[2] { return levels[2] }
        return levels[3]
    }

    private var yearTotal: Int {
        let prefix = "\(year)-"
        return stats.dailyCounts.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
    }

    private func yearHasData(_ y: Int) -> Bool {
        let prefix = "\(y)-"
        return stats.dailyCounts.contains { $0.key.hasPrefix(prefix) && $0.value > 0 }
    }
}
