import CoreGraphics
import Foundation

public enum MenuBarMarquee {

    public static func scrollOffset(
        elapsed: Double, maxOffset: CGFloat, pointsPerSecond: CGFloat,
        headHoldSeconds: Double, tailHoldSeconds: Double
    ) -> CGFloat {

        guard maxOffset > 0, pointsPerSecond > 0 else { return 0 }
        let head = max(0, headHoldSeconds)
        let tail = max(0, tailHoldSeconds)
        let travel = Double(maxOffset / pointsPerSecond)
        let cycle = head + travel + tail

        var t = elapsed.truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle }
        if t < head { return 0 }
        if t < head + travel {

            return min(maxOffset, CGFloat(t - head) * pointsPerSecond)
        }
        return maxOffset
    }

    public static func scrollOffset(
        elapsed: Double, maxOffset: CGFloat, pointsPerSecond: CGFloat, holdSeconds: Double
    ) -> CGFloat {
        scrollOffset(elapsed: elapsed, maxOffset: maxOffset, pointsPerSecond: pointsPerSecond,
                     headHoldSeconds: holdSeconds, tailHoldSeconds: holdSeconds)
    }

    public struct ScrollKeyframes: Equatable, Sendable {

        public let duration: Double

        public let keyTimes: [Double]

        public let offsets: [CGFloat]
    }

    public static func scrollKeyframes(
        maxOffset: CGFloat, pointsPerSecond: CGFloat,
        headHoldSeconds: Double, tailHoldSeconds: Double
    ) -> ScrollKeyframes? {
        guard maxOffset > 0, pointsPerSecond > 0 else { return nil }
        let head = max(0, headHoldSeconds)
        let tail = max(0, tailHoldSeconds)
        let travel = Double(maxOffset / pointsPerSecond)
        let cycle = head + travel + tail

        return ScrollKeyframes(
            duration: cycle,
            keyTimes: [0, head / cycle, (head + travel) / cycle, 1],
            offsets: [0, 0, maxOffset, maxOffset]
        )
    }

    public static func scrollKeyframes(
        maxOffset: CGFloat, pointsPerSecond: CGFloat, holdSeconds: Double
    ) -> ScrollKeyframes? {
        scrollKeyframes(maxOffset: maxOffset, pointsPerSecond: pointsPerSecond,
                        headHoldSeconds: holdSeconds, tailHoldSeconds: holdSeconds)
    }

    public struct ScrollPacing: Equatable, Sendable {
        public let pointsPerSecond: CGFloat
        public let headHoldSeconds: Double
        public let tailHoldSeconds: Double
    }

    public static let baseCharsPerSecond: CGFloat = 4

    public static let maxCharsPerSecond: CGFloat = 12

    public static let baseHoldSeconds: Double = 1.5

    public static let headHoldMaxFraction: Double = 0.25

    public static let tailReadSeconds: Double = 1.0

    public static let tailHoldMaxFraction: Double = 0.2

    public static let loopGuardSeconds: Double = 0.5

    public struct KaraokeFillPoint: Equatable, Sendable {
        public let ms: Int
        public let x: CGFloat

        public init(ms: Int, x: CGFloat) {
            self.ms = ms
            self.x = x
        }
    }

    public static func karaokeFillPath(
        words: [SyncedLyricWord], wordEndXs: [CGFloat]
    ) -> [KaraokeFillPoint] {
        guard !words.isEmpty, words.count == wordEndXs.count else { return [] }
        var points: [KaraokeFillPoint] = []
        points.reserveCapacity(words.count * 2)
        var prevMs = Int.min
        var prevX: CGFloat = 0
        func append(ms rawMs: Int, x rawX: CGFloat) {
            let ms = prevMs == Int.min ? rawMs : max(rawMs, prevMs + 1)
            let x = max(rawX, prevX)
            points.append(KaraokeFillPoint(ms: ms, x: x))
            prevMs = ms
            prevX = x
        }
        var startX: CGFloat = 0
        for (i, w) in words.enumerated() {

            append(ms: w.startMs, x: startX)
            append(ms: w.startMs + max(1, w.durationMs), x: wordEndXs[i])
            startX = wordEndXs[i]
        }
        return points
    }

    public static func karaokeFillX(atMs ms: Int, path: [KaraokeFillPoint]) -> CGFloat {
        guard let first = path.first, let last = path.last else { return 0 }
        if ms <= first.ms { return first.x }
        if ms >= last.ms { return last.x }
        for i in 1..<path.count where ms < path[i].ms {
            let a = path[i - 1], b = path[i]
            let t = Double(ms - a.ms) / Double(b.ms - a.ms)
            return a.x + CGFloat(t) * (b.x - a.x)
        }
        return last.x
    }

    public struct KaraokeFillFrames: Equatable, Sendable {

        public let widths: [CGFloat]

        public let keyTimes: [Double]

        public let duration: Double
    }

    public static func karaokeFillKeyframes(
        path: [KaraokeFillPoint], nowMs: Int, rate: Double
    ) -> KaraokeFillFrames? {
        guard rate > 0, let last = path.last, nowMs < last.ms else { return nil }
        let total = Double(last.ms - nowMs)
        var widths: [CGFloat] = [karaokeFillX(atMs: nowMs, path: path)]
        var keyTimes: [Double] = [0]
        for p in path where p.ms > nowMs {
            widths.append(p.x)
            keyTimes.append(Double(p.ms - nowMs) / total)
        }
        return KaraokeFillFrames(widths: widths, keyTimes: keyTimes,
                                 duration: total / 1000 / rate)
    }

    public static func pacing(
        maxOffset: CGFloat, averageCharWidth: CGFloat, dwellSeconds: Double?,
        leadInSeconds: Double = 0
    ) -> ScrollPacing {

        let base = max(1, baseCharsPerSecond * averageCharWidth)

        let lead = min(max(0, leadInSeconds), Double(CompactLyricLead.revealMs) / 1000)
        guard let dwell = dwellSeconds, dwell > 0, maxOffset > 0 else {
            return ScrollPacing(pointsPerSecond: base,
                                headHoldSeconds: max(baseHoldSeconds, lead),
                                tailHoldSeconds: baseHoldSeconds)
        }
        let cap = max(1, maxCharsPerSecond * averageCharWidth)

        let travelAtBase = Double(maxOffset / base)
        let travelAtCap = Double(maxOffset / cap)

        let head = max(lead, min(baseHoldSeconds, dwell * headHoldMaxFraction,
                                 max(0, dwell - travelAtCap)))

        let tailReserve = min(tailReadSeconds, dwell * tailHoldMaxFraction,
                              max(0, dwell - head - travelAtCap))

        let travel = min(max(dwell - head - tailReserve, travelAtCap), travelAtBase)
        let pointsPerSecond = min(cap, max(base, maxOffset / CGFloat(travel)))

        let tail = max(0, dwell - head - travel) + loopGuardSeconds
        return ScrollPacing(pointsPerSecond: pointsPerSecond,
                            headHoldSeconds: head, tailHoldSeconds: tail)
    }

    public static let followAnchorFraction: CGFloat = 0.45

    public static func followReadingPath(
        words: [SyncedLyricWord], wordEndXs: [CGFloat]
    ) -> [KaraokeFillPoint] {
        guard !words.isEmpty, words.count == wordEndXs.count else { return [] }
        var points: [KaraokeFillPoint] = []
        points.reserveCapacity(words.count + 1)
        var prevMs = Int.min
        var prevX: CGFloat = 0
        func append(ms rawMs: Int, x rawX: CGFloat) {
            let ms = prevMs == Int.min ? rawMs : max(rawMs, prevMs + 1)
            let x = max(rawX, prevX)
            points.append(KaraokeFillPoint(ms: ms, x: x))
            prevMs = ms
            prevX = x
        }
        for (i, w) in words.enumerated() {

            append(ms: w.startMs, x: i == 0 ? 0 : wordEndXs[i - 1])
        }

        if let last = words.last {
            append(ms: last.startMs + max(1, last.durationMs), x: wordEndXs[wordEndXs.count - 1])
        }
        return points
    }

    public static func followScrollPath(
        reading: [KaraokeFillPoint], windowWidth: CGFloat, textWidth: CGFloat,
        anchorFraction: CGFloat = followAnchorFraction
    ) -> [KaraokeFillPoint] {
        let maxOffset = textWidth - windowWidth
        guard windowWidth > 0, maxOffset > 0, !reading.isEmpty else { return [] }
        let anchor = windowWidth * min(1, max(0, anchorFraction))

        let lo = anchor
        let hi = anchor + maxOffset
        func offset(_ x: CGFloat) -> CGFloat { min(maxOffset, max(0, x - anchor)) }

        var raw: [KaraokeFillPoint] = []
        raw.reserveCapacity(reading.count + 2)
        for (i, p) in reading.enumerated() {
            raw.append(KaraokeFillPoint(ms: p.ms, x: offset(p.x)))
            guard i + 1 < reading.count else { break }
            let q = reading[i + 1]

            for bound in [lo, hi] where p.x < bound && bound < q.x {
                let t = Double((bound - p.x) / (q.x - p.x))
                let ms = Int((Double(p.ms) + t * Double(q.ms - p.ms)).rounded())
                raw.append(KaraokeFillPoint(ms: ms, x: offset(bound)))
            }
        }

        var points: [KaraokeFillPoint] = []
        points.reserveCapacity(raw.count)
        var prevMs = Int.min
        for p in raw {
            let ms = prevMs == Int.min ? p.ms : max(p.ms, prevMs + 1)
            prevMs = ms
            let n = points.count
            if n >= 2, points[n - 1].x == p.x, points[n - 2].x == p.x {
                points[n - 1] = KaraokeFillPoint(ms: ms, x: p.x)
            } else {
                points.append(KaraokeFillPoint(ms: ms, x: p.x))
            }
        }
        return points
    }

    public static func followScrollOffset(atMs ms: Int, path: [KaraokeFillPoint]) -> CGFloat {
        karaokeFillX(atMs: ms, path: path)
    }

    public static func followScrollKeyframes(
        path: [KaraokeFillPoint], nowMs: Int, rate: Double
    ) -> KaraokeFillFrames? {
        karaokeFillKeyframes(path: path, nowMs: nowMs, rate: rate)
    }

    public static func progressFillLength(
        positionMs: Int, durationMs: Int, fullLength: CGFloat
    ) -> CGFloat {
        guard durationMs > 0, fullLength > 0 else { return 0 }
        let t = Double(positionMs) / Double(durationMs)
        return fullLength * CGFloat(min(1, max(0, t)))
    }

    public struct ProgressFillRamp: Equatable, Sendable {

        public let from: CGFloat

        public let to: CGFloat

        public let duration: Double
    }

    public static func progressFillRamp(
        positionMs: Int, durationMs: Int, rate: Double, fullLength: CGFloat
    ) -> ProgressFillRamp? {
        guard rate > 0, durationMs > 0, fullLength > 0, positionMs < durationMs else { return nil }
        let remainMs = Double(durationMs - max(0, positionMs))
        return ProgressFillRamp(
            from: progressFillLength(positionMs: positionMs, durationMs: durationMs,
                                     fullLength: fullLength),
            to: fullLength,
            duration: remainMs / 1000 / rate)
    }
}
