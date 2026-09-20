import CoreGraphics

public enum LyricsQueryFieldLayout {

    public static func widths(desired: [CGFloat], available: CGFloat, minWidth: CGFloat) -> [CGFloat] {
        let n = desired.count
        guard n > 0 else { return [] }
        guard available > 0 else { return Array(repeating: 0, count: n) }

        if available <= minWidth * CGFloat(n) {
            return Array(repeating: available / CGFloat(n), count: n)
        }

        let base = desired.map { max($0, minWidth) }
        let baseSum = base.reduce(0, +)
        if baseSum <= available {
            let bonus = (available - baseSum) / CGFloat(n)
            return base.map { $0 + bonus }
        }

        var fixed = Array(repeating: false, count: n)
        var out = Array(repeating: CGFloat(0), count: n)
        while true {
            let free = (0..<n).filter { !fixed[$0] }
            guard !free.isEmpty else { break }
            let taken = (0..<n).filter { fixed[$0] }.reduce(CGFloat(0)) { $0 + out[$1] }
            let remaining = available - taken

            let weightSum = free.reduce(CGFloat(0)) { $0 + max(desired[$1], 1) }
            var clampedAny = false
            for i in free {
                let share = remaining * max(desired[i], 1) / weightSum
                if share < minWidth {
                    out[i] = minWidth
                    fixed[i] = true
                    clampedAny = true
                } else {
                    out[i] = share
                }
            }
            if !clampedAny { break }
        }
        return out
    }
}
