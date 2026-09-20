import Foundation

public enum ProportionBar {
    public static func widths(values: [Int], available: Double, gap: Double, minWidth: Double) -> [Double] {
        guard !values.isEmpty, available > 0 else { return values.map { _ in 0 } }
        let usable = max(available - gap * Double(values.count - 1), 0)
        let total = Double(values.reduce(0, +))
        guard total > 0, usable > 0 else { return values.map { _ in 0 } }
        var widths = values.map { usable * Double($0) / total }
        let floor = min(minWidth, usable / Double(values.count))
        var deficit = 0.0
        for index in widths.indices where values[index] > 0 && widths[index] < floor {
            deficit += floor - widths[index]
            widths[index] = floor
        }
        guard deficit > 0 else { return widths }

        var remaining = deficit
        var candidates = widths.indices.sorted { widths[$0] > widths[$1] }
        while remaining > 0, let index = candidates.first {
            candidates.removeFirst()
            let room = widths[index] - floor
            guard room > 0 else { continue }
            let take = min(room, remaining)
            widths[index] -= take
            remaining -= take
        }
        return widths
    }
}
