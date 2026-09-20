import Foundation

public enum KaraokeFill {

    public static let minWordDurationMs = 80

    public static let lineTailLeadMs = 140

    public static let minTailFillMs = 120

    public static func tailClamped(_ words: [SyncedLyricWord], nextLineStartMs: Int?) -> [SyncedLyricWord] {

        guard let nextLineStartMs, let last = words.last else { return words }
        let rawDuration = max(last.durationMs, minWordDurationMs)
        let room = nextLineStartMs - lineTailLeadMs - last.startMs
        let clamped = max(min(rawDuration, room), minTailFillMs)
        guard clamped < rawDuration else { return words }
        var out = words
        out[out.count - 1] = SyncedLyricWord(text: last.text, startMs: last.startMs,
                                             durationMs: clamped)
        return out
    }

    public static let wordEdgeSoftenBand = 0.08

    public static func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        fillFraction(startMs: w.startMs, durationMs: w.durationMs, atMs: ms)
    }

    public static func fillFraction(startMs: Int, durationMs: Int, atMs ms: Int) -> Double {
        let effectiveDuration = max(durationMs, minWordDurationMs)
        return Double(ms - startMs) / Double(effectiveDuration)
    }

    public static func lineFillSettledMs(words: [SyncedLyricWord], groups: [SyncedLyricWordGroup]?) -> Int {
        var settled = 0
        for w in words {
            let eff = Double(max(w.durationMs, minWordDurationMs))
            settled = max(settled, w.startMs + Int((eff * (1 + wordEdgeSoftenBand)).rounded(.up)))
        }
        for g in groups ?? [] {

            let eff = Double(max(g.endMs - g.startMs, 1, minWordDurationMs))
            settled = max(settled, g.startMs + Int((eff * (1 + wordEdgeSoftenBand)).rounded(.up)))
        }
        return settled
    }

    public struct Stop: Equatable, Sendable {
        public let location: Double
        public let intensity: Double

        public init(location: Double, intensity: Double) {
            self.location = location
            self.intensity = intensity
        }
    }

    public static let allUnsungStops: [Stop] = [
        Stop(location: 0, intensity: 0), Stop(location: 1, intensity: 0),
    ]
    public static let allSungStops: [Stop] = [
        Stop(location: 0, intensity: 1), Stop(location: 1, intensity: 1),
    ]

    public static func stops(left: Double, right: Double) -> [Stop] {
        if right <= 0 { return allUnsungStops }
        if left >= 1 { return allSungStops }

        func intensity(at x: Double) -> Double {
            let t = min(1, max(0, (x - left) / (right - left)))
            return 1 - t
        }
        var result: [Stop] = []
        result.reserveCapacity(4)
        if left > 0 {
            result.append(Stop(location: 0, intensity: 1))
            result.append(Stop(location: left, intensity: 1))
        } else {
            result.append(Stop(location: 0, intensity: intensity(at: 0)))
        }
        if right < 1 {
            result.append(Stop(location: right, intensity: 0))
            result.append(Stop(location: 1, intensity: 0))
        } else {
            result.append(Stop(location: 1, intensity: intensity(at: 1)))
        }
        return result
    }
}
