import Foundation

/// 逐字卡拉OK填色的纯数值计算：当前播放位置落在一个字内部的百分比，以及由它推出的渐变分段。
public enum KaraokeFill {
    /// 逐字时长下限——只影响单个词自身的填色速度，不改动 startMs 与后续词起始点。
    public static let minWordDurationMs = 80

    /// 一行的最后一个字在换行前填满的提前量。
    public static let lineTailLeadMs = 140

    /// 尾字填色的最小保留时长，避免过快跳满。
    public static let minTailFillMs = 120

    /// 让一行的最后一个字在换行前填满。
    /// 压缩尾字时长至 `nextLineStartMs - lineTailLeadMs`，并保留 `minTailFillMs` 最小扫色时间。
    /// 仅缩减尾字时长，不改动 startMs 和其他词的时间戳。
    public static func tailClamped(_ words: [SyncedLyricWord], nextLineStartMs: Int?) -> [SyncedLyricWord] {
        // 没有下一行(整首最后一句)= 没有换行这回事,原样返回。
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

    /// 过渡带半宽(fraction 单位)。
    public static let wordEdgeSoftenBand = 0.08

    /// 计算当前播放毫秒在指定词内的百分比进度。不截断在 [0, 1]，供渐变过渡带计算。
    public static func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        fillFraction(startMs: w.startMs, durationMs: w.durationMs, atMs: ms)
    }

    /// 纯起止毫秒版本，供逐词罗马音等场景直接复用，避免结构体分配。
    public static func fillFraction(startMs: Int, durationMs: Int, atMs ms: Int) -> Double {
        let effectiveDuration = max(durationMs, minWordDurationMs)
        return Double(ms - startMs) / Double(effectiveDuration)
    }

    /// 计算该行填色完全定格的时刻(毫秒)。
    /// 当所有词及罗马音词组的过渡带均越过 1.0 时定格，用于通知视图暂停逐帧驱动以节省电量。
    public static func lineFillSettledMs(words: [SyncedLyricWord], groups: [SyncedLyricWordGroup]?) -> Int {
        var settled = 0
        for w in words {
            let eff = Double(max(w.durationMs, minWordDurationMs))
            settled = max(settled, w.startMs + Int((eff * (1 + wordEdgeSoftenBand)).rounded(.up)))
        }
        for g in groups ?? [] {
            // 跟 LyricsOverlayView.romaText 构造伪词的口径一致:duration = max(1, end-start)。
            let eff = Double(max(g.endMs - g.startMs, 1, minWordDurationMs))
            settled = max(settled, g.startMs + Int((eff * (1 + wordEdgeSoftenBand)).rounded(.up)))
        }
        return settled
    }

    /// 渐变上的一个分段点。`intensity` 是"唱过的程度":1 = 前景色全强度,0 = 未唱到的暗色。
    public struct Stop: Equatable, Sendable {
        public let location: Double
        public let intensity: Double

        public init(location: Double, intensity: Double) {
            self.location = location
            self.intensity = intensity
        }
    }

    /// 纯色快路径的常量分段，供完全未唱(right <= 0)或完全已唱(left >= 1)的词复用。
    public static let allUnsungStops: [Stop] = [
        Stop(location: 0, intensity: 0), Stop(location: 1, intensity: 0),
    ]
    public static let allSungStops: [Stop] = [
        Stop(location: 0, intensity: 1), Stop(location: 1, intensity: 1),
    ]

    public static func stops(left: Double, right: Double) -> [Stop] {
        if right <= 0 { return allUnsungStops }
        if left >= 1 { return allSungStops }
        // 过渡带内某个位置的强度:从 left 处的 1 线性降到 right 处的 0。
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
