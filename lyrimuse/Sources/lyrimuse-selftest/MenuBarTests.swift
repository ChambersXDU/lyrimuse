import LyrimuseCore
import Foundation

@MainActor
func runMenuBarTests() {

    do {

        func offset(_ elapsed: Double) -> CGFloat {
            MenuBarMarquee.scrollOffset(
                elapsed: elapsed, maxOffset: 100, pointsPerSecond: 50, holdSeconds: 1)
        }

        expectEqual(
            MenuBarMarquee.scrollOffset(
                elapsed: 5, maxOffset: 0, pointsPerSecond: 50, holdSeconds: 1), 0)
        expectEqual(
            MenuBarMarquee.scrollOffset(
                elapsed: 5, maxOffset: -10, pointsPerSecond: 50, holdSeconds: 1), 0)

        expectEqual(
            MenuBarMarquee.scrollOffset(
                elapsed: 5, maxOffset: 100, pointsPerSecond: 0, holdSeconds: 1), 0)

        expectEqual(offset(0), 0)
        expectEqual(offset(0.99), 0)

        expectEqual(offset(1.5), 25)
        expectEqual(offset(2.0), 50)

        expectEqual(offset(3.0), 100)
        expectEqual(offset(3.5), 100)

        expectEqual(offset(4.0), 0)
        expectEqual(offset(5.5), 25)

        var offsetOutOfRange = 0
        for i in -80 ... 400 {
            let v = offset(Double(i) / 20)
            if v < 0 || v > 100 { offsetOutOfRange += 1 }
        }
        expectEqual(offsetOutOfRange, 0)

        expectEqual(offset(2.0), offset(2.0))
    }

    do {
        let maxOffset: CGFloat = 100
        let pps: CGFloat = 50
        let hold = 1.0

        func offsetReference(_ elapsed: Double) -> CGFloat {
            MenuBarMarquee.scrollOffset(
                elapsed: elapsed, maxOffset: maxOffset, pointsPerSecond: pps, holdSeconds: hold)
        }

        guard let frames = MenuBarMarquee.scrollKeyframes(
            maxOffset: maxOffset, pointsPerSecond: pps, holdSeconds: hold) else {
            expectEqual(true, false)
            fatalError("unreachable")
        }

        expectEqual(frames.duration, 4.0)
        expectEqual(frames.keyTimes.count, frames.offsets.count)
        expectEqual(frames.keyTimes[0], 0)
        expectEqual(frames.keyTimes[frames.keyTimes.count - 1], 1)

        var monotonic = true
        for i in 1 ..< frames.keyTimes.count where frames.keyTimes[i] < frames.keyTimes[i - 1] {
            monotonic = false
        }
        expectEqual(monotonic, true)

        func interpolate(_ elapsed: Double) -> CGFloat {
            var t = elapsed.truncatingRemainder(dividingBy: frames.duration)
            if t < 0 { t += frames.duration }
            let normalized = t / frames.duration
            for i in 1 ..< frames.keyTimes.count {
                let t0 = frames.keyTimes[i - 1], t1 = frames.keyTimes[i]
                guard normalized <= t1 else { continue }
                guard t1 > t0 else { return frames.offsets[i] }
                let ratio = (normalized - t0) / (t1 - t0)
                return frames.offsets[i - 1]
                    + (frames.offsets[i] - frames.offsets[i - 1]) * CGFloat(ratio)
            }
            return frames.offsets[frames.offsets.count - 1]
        }

        var worstGap = 0.0
        var worstAt = 0.0
        for i in 0 ... 160 {
            let elapsed = Double(i) / 20
            let gap = abs(Double(interpolate(elapsed) - offsetReference(elapsed)))
            if gap > worstGap { worstGap = gap; worstAt = elapsed }
        }

        expectEqual(worstGap < 0.001, true)

        expectEqual(
            MenuBarMarquee.scrollKeyframes(maxOffset: 0, pointsPerSecond: 50, holdSeconds: 1) == nil,
            true)
        expectEqual(
            MenuBarMarquee.scrollKeyframes(maxOffset: 100, pointsPerSecond: 0, holdSeconds: 1) == nil,
            true)

        guard let noHold = MenuBarMarquee.scrollKeyframes(
            maxOffset: 100, pointsPerSecond: 50, holdSeconds: 0) else {
            expectEqual(true, false)
            fatalError("unreachable")
        }
        expectEqual(noHold.keyTimes, [0, 0, 1, 1])
        expectEqual(noHold.duration, 2.0)
    }

    do {

        let words = [
            SyncedLyricWord(text: "甲", startMs: 0, durationMs: 500),
            SyncedLyricWord(text: "乙", startMs: 500, durationMs: 500),
            SyncedLyricWord(text: "丙", startMs: 1200, durationMs: 300),
        ]
        let path = MenuBarMarquee.karaokeFillPath(words: words, wordEndXs: [10, 30, 60])
        expectEqual(path.isEmpty, false)
        var msMonotonic = true
        var xMonotonic = true
        for i in 1 ..< path.count {
            if path[i].ms <= path[i - 1].ms { msMonotonic = false }
            if path[i].x < path[i - 1].x { xMonotonic = false }
        }
        expectEqual(msMonotonic, true)
        expectEqual(xMonotonic, true)
        expectEqual(path[path.count - 1].x, 60)

        expectEqual(MenuBarMarquee.karaokeFillX(atMs: -100, path: path), 0)
        expectEqual(MenuBarMarquee.karaokeFillX(atMs: 250, path: path), 5)
        expectEqual(MenuBarMarquee.karaokeFillX(atMs: 1100, path: path), 30)
        expectEqual(MenuBarMarquee.karaokeFillX(atMs: 9999, path: path), 60)

        guard let frames = MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 250, rate: 1) else {
            expectEqual(true, false)
            fatalError("unreachable")
        }
        expectEqual(frames.widths[0], 5)
        expectEqual(frames.keyTimes[0], 0)
        expectEqual(frames.keyTimes[frames.keyTimes.count - 1], 1)
        expectEqual(frames.duration, 1.25)
        var ktMonotonic = true
        for i in 1 ..< frames.keyTimes.count where frames.keyTimes[i] <= frames.keyTimes[i - 1] {
            ktMonotonic = false
        }
        expectEqual(ktMonotonic, true)
        expectEqual(frames.widths[frames.widths.count - 1], 60)

        expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 250, rate: 2)?.duration,
                    0.625)

        expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 1500, rate: 1) == nil,
                    true)
        expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 250, rate: 0) == nil,
                    true)
        expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: [], nowMs: 0, rate: 1) == nil,
                    true)

        let dirty = [
            SyncedLyricWord(text: "a", startMs: 300, durationMs: 400),
            SyncedLyricWord(text: "b", startMs: 200, durationMs: 100),
        ]
        let dirtyPath = MenuBarMarquee.karaokeFillPath(words: dirty, wordEndXs: [20, 15])
        var dirtyOK = true
        for i in 1 ..< dirtyPath.count {
            if dirtyPath[i].ms <= dirtyPath[i - 1].ms || dirtyPath[i].x < dirtyPath[i - 1].x {
                dirtyOK = false
            }
        }
        expectEqual(dirtyOK, true)

        expectEqual(MenuBarMarquee.karaokeFillPath(words: words, wordEndXs: [10]).isEmpty, true)
    }

    do {
        let words = [
            SyncedLyricWord(text: "甲", startMs: 0, durationMs: 500),
            SyncedLyricWord(text: "乙", startMs: 500, durationMs: 500),
            SyncedLyricWord(text: "丙", startMs: 1200, durationMs: 300),
        ]
        let reading = MenuBarMarquee.followReadingPath(words: words, wordEndXs: [10, 30, 60])
        expectEqual(reading.count, 4)
        expectEqual(reading[0].ms, 0)
        expectEqual(reading[0].x, 0)
        expectEqual(reading[1].x, 10)
        expectEqual(reading[2].ms, 1200)
        expectEqual(reading[2].x, 30)
        expectEqual(reading[3].ms, 1500)
        expectEqual(reading[3].x, 60)

        let midGap = MenuBarMarquee.karaokeFillX(atMs: 1100, path: reading)
        expectEqual(midGap > 10 && midGap < 30, true)
        expectEqual(abs(midGap - (10 + 20 * 600 / 700)) < 0.01, true)
        expectEqual(MenuBarMarquee.followReadingPath(words: words, wordEndXs: [10]).isEmpty, true)

        let path = MenuBarMarquee.followScrollPath(reading: reading, windowWidth: 40, textWidth: 60)
        expectEqual(path.isEmpty, false)
        expectEqual(path[0].ms, 0)
        expectEqual(path[0].x, 0)
        expectEqual(path[path.count - 1].x, 20)
        var pathMonotonic = true
        for i in 1 ..< path.count where path[i].ms <= path[i - 1].ms || path[i].x < path[i - 1].x {
            pathMonotonic = false
        }
        expectEqual(pathMonotonic, true)

        expectEqual(path.contains { $0.ms == 780 && $0.x == 0 }, true)
        expectEqual(path.contains { $0.ms == 1280 && $0.x == 20 }, true)
        var worst: CGFloat = 0
        for ms in stride(from: -100, through: 1700, by: 10) {
            let expected = min(20, max(0, MenuBarMarquee.karaokeFillX(atMs: ms, path: reading) - 18))
            worst = max(worst, abs(MenuBarMarquee.followScrollOffset(atMs: ms, path: path) - expected))
        }
        expectEqual(worst < 0.05, true)

        expectEqual(path.filter { $0.x == 0 }.count, 2)
        expectEqual(MenuBarMarquee.followScrollOffset(atMs: 1000, path: path) > 0, true)

        expectEqual(MenuBarMarquee.followScrollPath(reading: reading, windowWidth: 60, textWidth: 60).isEmpty,
                    true)
        expectEqual(MenuBarMarquee.followScrollPath(reading: reading, windowWidth: 0, textWidth: 60).isEmpty,
                    true)
        expectEqual(MenuBarMarquee.followScrollPath(reading: [], windowWidth: 40, textWidth: 60).isEmpty,
                    true)

        let farAnchor = MenuBarMarquee.followScrollPath(reading: reading, windowWidth: 40, textWidth: 60,
                                                        anchorFraction: 5)
        expectEqual(MenuBarMarquee.followScrollOffset(atMs: 1200, path: farAnchor), 0)

        guard let frames = MenuBarMarquee.followScrollKeyframes(path: path, nowMs: 1000, rate: 1) else {
            expectEqual(true, false)
            fatalError("unreachable")
        }
        expectEqual(frames.widths[0], MenuBarMarquee.followScrollOffset(atMs: 1000, path: path))
        expectEqual(frames.widths[frames.widths.count - 1], 20)
        expectEqual(frames.duration, 0.5)
        expectEqual(MenuBarMarquee.followScrollKeyframes(path: path, nowMs: 1500, rate: 1) == nil, true)
        expectEqual(MenuBarMarquee.followScrollKeyframes(path: path, nowMs: 1000, rate: 0) == nil, true)
    }

    do {
        let h: CGFloat = 15

        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 0, durationMs: 200_000,
                                                      fullLength: h),
                    0)
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 100_000, durationMs: 200_000,
                                                      fullLength: h),
                    h / 2)
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 200_000, durationMs: 200_000,
                                                      fullLength: h),
                    h)

        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 260_000, durationMs: 200_000,
                                                      fullLength: h),
                    h)
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: -5_000, durationMs: 200_000,
                                                      fullLength: h),
                    0)

        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 50_000, durationMs: 0,
                                                      fullLength: h),
                    0)
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 50_000, durationMs: -1,
                                                      fullLength: h),
                    0)

        guard let ramp = MenuBarMarquee.progressFillRamp(
            positionMs: 60_000, durationMs: 180_000, rate: 1, fullLength: h) else {
            expectEqual(true, false)
            fatalError("unreachable")
        }
        expectEqual(ramp.from, h / 3)
        expectEqual(ramp.to, h)
        expectEqual(ramp.duration, 120)

        expectEqual(MenuBarMarquee.progressFillRamp(positionMs: 60_000, durationMs: 180_000,
                                                    rate: 2, fullLength: h)?.duration,
                    60)

        expectEqual(ramp.from,
                    MenuBarMarquee.progressFillLength(positionMs: 60_000, durationMs: 180_000,
                                                      fullLength: h))

        expectEqual(MenuBarMarquee.progressFillRamp(positionMs: 60_000, durationMs: 180_000,
                                                    rate: 0, fullLength: h) == nil,
                    true)
        expectEqual(MenuBarMarquee.progressFillRamp(positionMs: 180_000, durationMs: 180_000,
                                                    rate: 1, fullLength: h) == nil,
                    true)
        expectEqual(MenuBarMarquee.progressFillRamp(positionMs: 60_000, durationMs: 0,
                                                    rate: 1, fullLength: h) == nil,
                    true)
        expectEqual(MenuBarMarquee.progressFillRamp(positionMs: 60_000, durationMs: 180_000,
                                                    rate: 1, fullLength: 0) == nil,
                    true)
    }

    do {

        let charWidth: CGFloat = 13

        let windowWidth: CGFloat = 80

        func maxOffset(chars: Int) -> CGFloat { CGFloat(chars) * charWidth - windowWidth }

        func finishTime(chars: Int, dwell: Double?) -> Double {
            let offset = maxOffset(chars: chars)
            let p = MenuBarMarquee.pacing(
                maxOffset: offset, averageCharWidth: charWidth, dwellSeconds: dwell)
            return p.headHoldSeconds + Double(offset / p.pointsPerSecond)
        }

        func travelAtCap(chars: Int) -> Double {
            Double(maxOffset(chars: chars) / (MenuBarMarquee.maxCharsPerSecond * charWidth))
        }

        let unknown = MenuBarMarquee.pacing(
            maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: nil)
        expectEqual(unknown.pointsPerSecond, MenuBarMarquee.baseCharsPerSecond * charWidth)
        expectEqual(unknown.headHoldSeconds, MenuBarMarquee.baseHoldSeconds)
        expectEqual(unknown.tailHoldSeconds, MenuBarMarquee.baseHoldSeconds)

        expectEqual(finishTime(chars: 30, dwell: nil) > 4.0, true)
        expectEqual(finishTime(chars: 30, dwell: 4.0) <= 4.0 + 0.001, true)

        var missed: [String] = []
        for chars in [12, 18, 24, 30, 40, 60] {
            for dwell in [2.0, 2.5, 3.0, 4.0, 5.0, 8.0, 12.0] {
                guard travelAtCap(chars: chars) <= dwell else { continue }
                if finishTime(chars: chars, dwell: dwell) > dwell + 0.001 {
                    missed.append("\(chars)字/\(dwell)秒")
                }
            }
        }
        expectEqual(missed, [])

        expectEqual(finishTime(chars: 30, dwell: 6.0)
                        <= 6.0 - MenuBarMarquee.tailReadSeconds + 0.001, true)

        expectEqual(finishTime(chars: 30, dwell: 2.1) <= 2.1 + 0.001, true)

        let roomy = MenuBarMarquee.pacing(
            maxOffset: maxOffset(chars: 14), averageCharWidth: charWidth, dwellSeconds: 20)
        expectEqual(roomy.pointsPerSecond, MenuBarMarquee.baseCharsPerSecond * charWidth)

        expectEqual(roomy.headHoldSeconds + Double(maxOffset(chars: 14) / roomy.pointsPerSecond)
                        + roomy.tailHoldSeconds >= 20, true)

        let tight = MenuBarMarquee.pacing(
            maxOffset: maxOffset(chars: 30), averageCharWidth: charWidth, dwellSeconds: 2.0)
        expectEqual(tight.headHoldSeconds < 2.0, true)

        let absurd = MenuBarMarquee.pacing(
            maxOffset: maxOffset(chars: 120), averageCharWidth: charWidth, dwellSeconds: 2.0)
        expectEqual(absurd.pointsPerSecond <= MenuBarMarquee.maxCharsPerSecond * charWidth,
                    true)

        expectEqual(finishTime(chars: 120, dwell: 2.0) > 2.0, true)

        expectEqual(absurd.headHoldSeconds, 0)

        let sliver = MenuBarMarquee.pacing(
            maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: 0.06)
        expectEqual(sliver.pointsPerSecond.isFinite && sliver.pointsPerSecond > 0, true)

        let pacing = MenuBarMarquee.pacing(
            maxOffset: maxOffset(chars: 30), averageCharWidth: charWidth, dwellSeconds: 4.0)
        let offset = maxOffset(chars: 30)
        guard let frames = MenuBarMarquee.scrollKeyframes(
            maxOffset: offset, pointsPerSecond: pacing.pointsPerSecond,
            headHoldSeconds: pacing.headHoldSeconds, tailHoldSeconds: pacing.tailHoldSeconds) else {
            expectEqual(true, false)
            fatalError("unreachable")
        }
        func interpolate(_ elapsed: Double) -> CGFloat {
            var t = elapsed.truncatingRemainder(dividingBy: frames.duration)
            if t < 0 { t += frames.duration }
            let normalized = t / frames.duration
            for i in 1 ..< frames.keyTimes.count {
                let t0 = frames.keyTimes[i - 1], t1 = frames.keyTimes[i]
                guard normalized <= t1 else { continue }
                guard t1 > t0 else { return frames.offsets[i] }
                let ratio = (normalized - t0) / (t1 - t0)
                return frames.offsets[i - 1] + (frames.offsets[i] - frames.offsets[i - 1]) * CGFloat(ratio)
            }
            return frames.offsets[frames.offsets.count - 1]
        }
        var worst = 0.0
        for i in 0 ... 200 {
            let elapsed = Double(i) / 25
            let reference = MenuBarMarquee.scrollOffset(
                elapsed: elapsed, maxOffset: offset, pointsPerSecond: pacing.pointsPerSecond,
                headHoldSeconds: pacing.headHoldSeconds, tailHoldSeconds: pacing.tailHoldSeconds)
            worst = max(worst, abs(Double(interpolate(elapsed) - reference)))
        }
        expectEqual(worst < 0.001, true)

        func finishTimeLed(chars: Int, dwell: Double?, lead: Double) -> Double {
            let offset = maxOffset(chars: chars)
            let p = MenuBarMarquee.pacing(
                maxOffset: offset, averageCharWidth: charWidth, dwellSeconds: dwell,
                leadInSeconds: lead)
            return p.headHoldSeconds + Double(offset / p.pointsPerSecond)
        }

        var scrolledTooEarly: [String] = []
        var loopedTooSoon: [String] = []
        for lead in [0.0, 0.22, 0.9, 1.75, 3.03, 5.0] {
            for dwell in [2.0, 3.0, 4.0, 6.0, 12.0, 30.0] where dwell > lead {
                for chars in [12, 30, 60, 120] {
                    let p = MenuBarMarquee.pacing(
                        maxOffset: maxOffset(chars: chars), averageCharWidth: charWidth,
                        dwellSeconds: dwell, leadInSeconds: lead)
                    if p.headHoldSeconds + 1e-9 < lead {
                        scrolledTooEarly.append("\(chars)字/\(dwell)秒/提前\(lead)秒"
                            + "→首停\(p.headHoldSeconds)")
                    }

                    let cycle = p.headHoldSeconds
                        + Double(maxOffset(chars: chars) / p.pointsPerSecond) + p.tailHoldSeconds
                    if cycle + 1e-9 < dwell + MenuBarMarquee.loopGuardSeconds {
                        loopedTooSoon.append("\(chars)字/\(dwell)秒/提前\(lead)秒→周期\(cycle)")
                    }
                }
            }
        }
        expectEqual(scrolledTooEarly, [])
        expectEqual(loopedTooSoon, [])

        var drifted: [String] = []
        for chars in [12, 30, 60] {
            for dwell in [nil, 2.0, 4.0, 8.0, 20.0] as [Double?] {
                let before = MenuBarMarquee.pacing(
                    maxOffset: maxOffset(chars: chars), averageCharWidth: charWidth,
                    dwellSeconds: dwell)
                let after = MenuBarMarquee.pacing(
                    maxOffset: maxOffset(chars: chars), averageCharWidth: charWidth,
                    dwellSeconds: dwell, leadInSeconds: 0)
                if before != after { drifted.append("\(chars)字/\(String(describing: dwell))") }
            }
        }
        expectEqual(drifted, [])

        var missedWithLead: [String] = []
        for chars in [12, 18, 24, 30, 40] {
            for lead in [0.22, 0.9, 1.75, 3.0] {
                for dwell in [3.0, 4.0, 6.0, 8.0, 12.0] {
                    guard lead + travelAtCap(chars: chars) <= dwell else { continue }
                    if finishTimeLed(chars: chars, dwell: dwell, lead: lead) > dwell + 0.001 {
                        missedWithLead.append("\(chars)字/\(dwell)秒/提前\(lead)秒")
                    }
                }
            }
        }
        expectEqual(missedWithLead, [])

        let led = MenuBarMarquee.pacing(
            maxOffset: maxOffset(chars: 30), averageCharWidth: charWidth,
            dwellSeconds: 8.0, leadInSeconds: 5.0)
        expectEqual(led.headHoldSeconds, 5.0)
        expectEqual(led.headHoldSeconds + Double(maxOffset(chars: 30) / led.pointsPerSecond)
                        + led.tailHoldSeconds >= 8.0, true)

        let unknownLed = MenuBarMarquee.pacing(
            maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: nil, leadInSeconds: 3.0)
        expectEqual(unknownLed.headHoldSeconds, 3.0)

        let overlong = MenuBarMarquee.pacing(
            maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: 2.0, leadInSeconds: 9.0)
        expectEqual(overlong.headHoldSeconds, Double(CompactLyricLead.revealMs) / 1000)
        expectEqual(overlong.pointsPerSecond.isFinite && overlong.pointsPerSecond > 0
                        && overlong.tailHoldSeconds >= 0, true)

        expectEqual(MenuBarMarquee.pacing(maxOffset: 300, averageCharWidth: charWidth,
                                          dwellSeconds: 4.0, leadInSeconds: -3.0),
                    MenuBarMarquee.pacing(maxOffset: 300, averageCharWidth: charWidth,
                                          dwellSeconds: 4.0))

        func interpolateLed(_ frames: MenuBarMarquee.ScrollKeyframes, _ elapsed: Double) -> CGFloat {
            var t = elapsed.truncatingRemainder(dividingBy: frames.duration)
            if t < 0 { t += frames.duration }
            let normalized = t / frames.duration
            for i in 1 ..< frames.keyTimes.count {
                let t0 = frames.keyTimes[i - 1], t1 = frames.keyTimes[i]
                guard normalized <= t1 else { continue }
                guard t1 > t0 else { return frames.offsets[i] }
                let ratio = (normalized - t0) / (t1 - t0)
                return frames.offsets[i - 1] + (frames.offsets[i] - frames.offsets[i - 1]) * CGFloat(ratio)
            }
            return frames.offsets[frames.offsets.count - 1]
        }
        guard let ledFrames = MenuBarMarquee.scrollKeyframes(
            maxOffset: maxOffset(chars: 30), pointsPerSecond: led.pointsPerSecond,
            headHoldSeconds: led.headHoldSeconds, tailHoldSeconds: led.tailHoldSeconds) else {
            expectEqual(true, false)
            fatalError("unreachable")
        }
        var ledWorst = 0.0
        for i in 0 ... 400 {
            let elapsed = Double(i) / 25
            let reference = MenuBarMarquee.scrollOffset(
                elapsed: elapsed, maxOffset: maxOffset(chars: 30),
                pointsPerSecond: led.pointsPerSecond,
                headHoldSeconds: led.headHoldSeconds, tailHoldSeconds: led.tailHoldSeconds)
            ledWorst = max(ledWorst, abs(Double(interpolateLed(ledFrames, elapsed) - reference)))
        }
        expectEqual(ledWorst < 0.001, true)

        var movedEarly: [String] = []
        for i in 0 ... 50 {
            let elapsed = 5.0 * Double(i) / 50
            let offset = MenuBarMarquee.scrollOffset(
                elapsed: elapsed, maxOffset: maxOffset(chars: 30),
                pointsPerSecond: led.pointsPerSecond,
                headHoldSeconds: led.headHoldSeconds, tailHoldSeconds: led.tailHoldSeconds)
            if offset != 0 { movedEarly.append("\(elapsed)s→\(offset)") }
        }
        expectEqual(movedEarly, [])
    }

    do {
        typealias M = MarqueeMath

        expectEqual(M.overflow(contentWidth: 400, containerWidth: 286), 114)
        expectEqual(M.overflow(contentWidth: 200, containerWidth: 286), -86)
        expectEqual(M.isOverflowing(contentWidth: 400, containerWidth: 286), true)
        expectEqual(M.isOverflowing(contentWidth: 200, containerWidth: 286), false)
        expectEqual(M.isOverflowing(contentWidth: 290, containerWidth: 286), false)
        expectEqual(M.isOverflowing(contentWidth: 290.5, containerWidth: 286), true)
        expectEqual(M.isOverflowing(contentWidth: 400, containerWidth: 0), false)

        let fade: CGFloat = 10
        let lyricRow: CGFloat = 286
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                        containerWidth: lyricRow, offset: 0), 10)
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                        containerWidth: lyricRow, offset: 114), 0)
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                        containerWidth: lyricRow, offset: 50), 0)
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 200,
                                        containerWidth: lyricRow, offset: 0), 0)
        expectEqual(M.trailingFadeWidth(configured: 0, contentWidth: 400,
                                        containerWidth: lyricRow, offset: 0), 0)

        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                        containerWidth: 14, offset: 0), 7)
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                        containerWidth: 30, offset: 0), 10)
    }

    do {
        typealias H = MenuBarHoverControls

        let minimumFixedSlot = CGRect(x: 0, y: 0, width: 98, height: 22)

        expectEqual(H.minimumWidth, 72)

        expectEqual(H.layout(in: CGRect(x: 0, y: 0, width: 71.9, height: 22)) == nil, true)
        expectEqual(H.layout(in: CGRect(x: 0, y: 0, width: 72, height: 22)) == nil, false)

        expectEqual(H.layout(in: CGRect(x: 0, y: 0, width: 24.5, height: 22)) == nil, true)
        expectEqual(H.layout(in: CGRect(x: 0, y: 0, width: 38.5, height: 22)) == nil, true)
        expectEqual(H.layout(in: CGRect(x: 0, y: 0, width: 200, height: 0)) == nil, true)
        expectEqual(H.layout(in: minimumFixedSlot) == nil, false)

        if let rects = H.layout(in: minimumFixedSlot),
           let prev = rects[.previous], let mid = rects[.playPause], let nxt = rects[.next] {

            expectEqual(rects.count, 3)
            expectEqual(prev.width, 24)
            expectEqual(mid.height, 22)
            expectEqual(prev.minX, 13)
            expectEqual(nxt.maxX, 85)

            expectEqual(prev.minX < mid.minX && mid.minX < nxt.minX, true)

            expectEqual(H.control(at: CGPoint(x: 13, y: 11), in: rects), .previous)
            expectEqual(H.control(at: CGPoint(x: 36.9, y: 11), in: rects), .previous)
            expectEqual(H.control(at: CGPoint(x: 37, y: 11), in: rects), .playPause)
            expectEqual(H.control(at: CGPoint(x: 61, y: 11), in: rects), .next)
            expectEqual(H.control(at: CGPoint(x: 84.9, y: 11), in: rects), .next)

            expectEqual(H.control(at: CGPoint(x: 12.9, y: 11), in: rects) == nil, true)
            expectEqual(H.control(at: CGPoint(x: 85, y: 11), in: rects) == nil, true)
            expectEqual(H.control(at: CGPoint(x: 40, y: 22), in: rects) == nil, true)

            var seen = Set<MenuBarTransportControl?>()
            for _ in 1...50 { seen.insert(H.control(at: CGPoint(x: 37, y: 11), in: rects)) }
            expectEqual(seen.count, 1)

            expectEqual(H.glyphRect(in: prev, side: 12),
                        CGRect(x: 19, y: 5, width: 12, height: 12))
        } else {
            expectEqual(true, false)
        }

        let lyricsSlot = CGRect(x: 98.5, y: 0, width: 100, height: 22)
        if let rects = H.layout(in: lyricsSlot), let prev = rects[.previous], let nxt = rects[.next] {
            expectEqual(prev.minX, 112.5)
            expectEqual(nxt.maxX, 184.5)
            expectEqual(prev.minX >= lyricsSlot.minX && nxt.maxX <= lyricsSlot.maxX, true)
            expectEqual(H.control(at: CGPoint(x: 10, y: 11), in: rects) == nil, true)
            expectEqual(H.control(at: CGPoint(x: 98.5, y: 11), in: rects) == nil, true)
        } else {
            expectEqual(true, false)
        }

        expectEqual(H.layout(in: CGRect(x: 98.5, y: 0, width: 60, height: 22)) == nil, true)

        let iconReserved: CGFloat = 20.5 + 5
        if let slot = H.lyricsSlot(buttonWidth: 143.5, contentWidth: 143.5 - 18,
                                   reservedIconWidth: iconReserved, iconLeading: true) {
            expectEqual(slot.x, 34.5)
            expectEqual(slot.width, 100)

            if let viaLabel = H.lyricsSlot(buttonWidth: 143.5, contentWidth: 100 + iconReserved,
                                           reservedIconWidth: iconReserved, iconLeading: true) {
                expectEqual(viaLabel.x, slot.x)
                expectEqual(viaLabel.width, slot.width)
            } else {
                expectEqual(true, false)
            }

            if let rects = H.layout(in: CGRect(x: slot.x, y: 0, width: slot.width, height: 22)),
               let prev = rects[.previous], let mid = rects[.playPause], let nxt = rects[.next] {
                expectEqual(prev.minX, 48.5)
                expectEqual(mid.minX, 72.5)
                expectEqual(nxt.minX, 96.5)

                expectNotEqual(prev.minX, 36)
            } else {
                expectEqual(true, false)
            }
        } else {
            expectEqual(true, false)
        }

        if let slot = H.lyricsSlot(buttonWidth: 143.5, contentWidth: 143.5 - 18,
                                   reservedIconWidth: iconReserved, iconLeading: false) {
            expectEqual(slot.x, 9)
            expectEqual(slot.width, 100)
        } else {
            expectEqual(true, false)
        }

        expectEqual(H.lyricsSlot(buttonWidth: 118, contentWidth: 100,
                                 reservedIconWidth: 0, iconLeading: false)?.width, 100)

        expectEqual(H.lyricsSlot(buttonWidth: 143.5, contentWidth: 0,
                                 reservedIconWidth: 0, iconLeading: false) == nil, true)
        expectEqual(H.lyricsSlot(buttonWidth: 60, contentWidth: 25.5,
                                 reservedIconWidth: 25.5, iconLeading: true) == nil, true)
    }

    do {
        let P = MenuBarSlotPolicy.self
        let quiet: Double = 3

        expectEqual(P.skipsResize(currentLength: 121.19, targetLength: 56.70,
                                  dwellSeconds: 1.24, quietSecs: quiet), true)

        expectEqual(P.skipsResize(currentLength: 56.70, targetLength: 134.09,
                                  dwellSeconds: 0.5, quietSecs: quiet), true)

        expectEqual(P.skipsResize(currentLength: 200, targetLength: 100,
                                  dwellSeconds: 4.5, quietSecs: quiet), false)
        expectEqual(P.skipsResize(currentLength: 100, targetLength: 200,
                                  dwellSeconds: 4.5, quietSecs: quiet), false)

        expectEqual(P.skipsResize(currentLength: 200, targetLength: 100,
                                  dwellSeconds: quiet, quietSecs: quiet), false)
        expectEqual(P.skipsResize(currentLength: 100, targetLength: 200,
                                  dwellSeconds: quiet, quietSecs: quiet), false)
        expectEqual(P.skipsResize(currentLength: 200, targetLength: 100,
                                  dwellSeconds: quiet - 0.001, quietSecs: quiet), true)
        expectEqual(P.skipsResize(currentLength: 100, targetLength: 200,
                                  dwellSeconds: quiet - 0.001, quietSecs: quiet), true)

        expectEqual(P.skipsResize(currentLength: 200, targetLength: 100,
                                  dwellSeconds: nil, quietSecs: quiet), false)
        expectEqual(P.skipsResize(currentLength: 100, targetLength: 200,
                                  dwellSeconds: nil, quietSecs: quiet), false)

        expectEqual(P.skipsResize(currentLength: 150, targetLength: 150,
                                  dwellSeconds: 0.2, quietSecs: quiet), false)

        expectEqual(P.skipsResize(currentLength: 250.749512, targetLength: 250.438477,
                                  dwellSeconds: 12, quietSecs: quiet), true)
        expectEqual(P.skipsResize(currentLength: 200, targetLength: 200 - P.minimumShrinkPoints + 0.01,
                                  dwellSeconds: 12, quietSecs: quiet), true)
        expectEqual(P.skipsResize(currentLength: 200, targetLength: 200 - P.minimumShrinkPoints,
                                  dwellSeconds: 12, quietSecs: quiet), false)

        expectEqual(P.skipsResize(currentLength: 222.909180, targetLength: 223.5,
                                  dwellSeconds: 12, quietSecs: quiet), true)
        expectEqual(P.skipsResize(currentLength: 250.438477, targetLength: 250.749512,
                                  dwellSeconds: 0.5, quietSecs: quiet), true)
        expectEqual(P.skipsResize(currentLength: 200, targetLength: 200 + P.minimumWidenPoints - 0.01,
                                  dwellSeconds: 12, quietSecs: quiet), true)
        expectEqual(P.skipsResize(currentLength: 200, targetLength: 200 + P.minimumWidenPoints,
                                  dwellSeconds: 12, quietSecs: quiet), false)

        expectEqual(P.minimumWidenPoints == P.minimumShrinkPoints, true)

        expectEqual(P.skipsResize(currentLength: 200, targetLength: 185,
                                  dwellSeconds: 12, quietSecs: quiet), false)
    }

    do {
        let P = MenuBarSlotPolicy.self
        let maxW: CGFloat = 205.5

        expectEqual(P.slotWidth(naturalWidth: 94.42, upcomingWidth: 205.5,
                                isPlaceholder: true, maxWidth: maxW), 205.5)

        expectEqual(P.slotWidth(naturalWidth: 120, upcomingWidth: 60,
                                isPlaceholder: true, maxWidth: maxW), 120)

        expectEqual(P.slotWidth(naturalWidth: 94.42, upcomingWidth: 400,
                                isPlaceholder: true, maxWidth: maxW), maxW)

        expectEqual(P.slotWidth(naturalWidth: 94.42, upcomingWidth: 0,
                                isPlaceholder: true, maxWidth: maxW), 94.42)

        expectEqual(P.slotWidth(naturalWidth: 187.03, upcomingWidth: 400,
                                isPlaceholder: false, maxWidth: maxW), 187.03)
        expectEqual(P.slotWidth(naturalWidth: 300, upcomingWidth: 0,
                                isPlaceholder: false, maxWidth: maxW), 300)
    }

    do {
        typealias P = MenuBarSlotPolicy
        func t(_ lyric: String, _ title: String, playing: Bool = true, ad: Bool = false, on: Bool = true)
            -> (text: String, isFallback: Bool)? {
            P.displayText(lyricText: lyric, title: title, isPlaying: playing, isAdBreak: ad,
                          showsTitleWhenNoLyrics: on, placeholderGlyph: "♪")
        }
        expectEqual(t("对这个世界如果你有太多的抱怨", "稻香")?.text, "对这个世界如果你有太多的抱怨")
        expectEqual(t("对这个世界如果你有太多的抱怨", "稻香")?.isFallback, false)
        expectEqual(t("♪", "稻香")?.text, "♪")
        expectEqual(t("", "稻香")?.text, "♪ 稻香")
        expectEqual(t("", "稻香")?.isFallback, true)
        expectEqual(t("", "  稻香  ")?.text, "♪ 稻香")
        expectEqual(t("", "稻香", playing: false) == nil, true)
        expectEqual(t("有词", "稻香", playing: false) == nil, true)
        expectEqual(t("", "Ad Title", ad: true) == nil, true)
        expectEqual(t("", "") == nil, true)
        expectEqual(t("", "稻香", on: false) == nil, true)
    }

    do {
        let item = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/lyrimuse/MenuBar/MenuBarStatusItem.swift")
        if let text = try? String(contentsOfFile: item.path, encoding: .utf8) {
            expectEqual(text.contains("collapseDelay: settings.showLyricsInMenuBar ? Self.slotReleaseSecs : 0"), true)

            expectEqual(text.contains("static let slotReleaseSecs: TimeInterval = 8"), true)
            expectEqual(text.contains("static let iconContentHoldSecs: TimeInterval = 3"), true)
            expectEqual(text.contains("heldFor >= Self.iconContentHoldSecs { render(button) }"), true)
            expectEqual(text.contains("if observeRemaining <= 0 { render(button) }"), false)
            expectEqual(text.contains("static let rebuildQuietSecs: TimeInterval = 3"), true)

            if let start = text.range(of: "let delay = max(observeRemaining"),
               let end = text.range(of: "let work = DispatchWorkItem",
                                    range: start.upperBound..<text.endIndex) {
                let branch = String(text[start.lowerBound..<end.lowerBound])
                expectEqual(branch.contains("if cls == \"icon\" {\n                        render(button)"), false)
                expectEqual(branch.contains("if delay <= 0 { render(button) }"), false)
            } else {
                expectEqual(true, false)
            }
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let item = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/lyrimuse/MenuBar/MenuBarStatusItem.swift")
        if let text = try? String(contentsOfFile: item.path, encoding: .utf8) {
            expectEqual(text.contains("static let iconExitSettleSecs: TimeInterval = 0.12"), true)
            expectEqual(text.contains("displayClass == \"icon\" || targetIsProvisional"), true)

            expectEqual(text.contains("let provisional = placeholderNow || slotFloor.didResetOnLastCall"), true)
            let provisional = text.components(separatedBy: "targetIsProvisional: provisional").count - 1
            expectEqual(provisional, 2)

            expectEqual(text.contains("let settleOpen = iconExitSettleBegan != nil"), true)
            expectEqual(text.contains("|| targetIsProvisional || settleOpen"), true)

            expectEqual(text.contains("collapseDelay: settings.showLyricsInMenuBar ? Self.slotReleaseSecs : 0,\n                    targetIsProvisional"), false)

            expectEqual(text.contains("let began = iconExitSettleBegan ?? now"), true)
            expectEqual(text.contains("iconExitSettleBegan = now\n"), false)

            expectEqual(text.contains("lastRebuildAt = Date()"), true)

            expectEqual(text.contains("min(delay, max(0.01, Self.iconContentHoldSecs - heldFor))"), true)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        typealias F = MenuBarSlotFloor
        var prepared = F()
        expectEqual(prepared.width(target: 40, preparedWidth: 260, maxWidth: 200, trackKey: "song"), 200)
        expectEqual(prepared.width(target: 260, preparedWidth: 260, maxWidth: 200, trackKey: "song"), 200)
        expectEqual(prepared.width(target: 30, preparedWidth: 90, maxWidth: 200, trackKey: "next"), 90)
        expectEqual(prepared.width(target: 30, preparedWidth: 90, maxWidth: 60, trackKey: "next"), 60)
        var f = F()
        expectEqual(f.width(target: 100, trackKey: "A"), 100)
        expectEqual(f.width(target: 80, trackKey: "A"), 100)
        expectEqual(f.width(target: 130, trackKey: "A"), 130)
        expectEqual(f.width(target: 90, trackKey: "A"), 130)

        var pingpong = F()
        _ = pingpong.width(target: 106.1, trackKey: "S")
        _ = pingpong.width(target: 113.1, trackKey: "S")
        expectEqual(pingpong.width(target: 106.1, trackKey: "S"), 113.1)

        expectEqual(f.width(target: 70, trackKey: "B"), 70)
        expectEqual(f.width(target: 60, trackKey: "B"), 70)
        expectEqual(f.currentFloor, 70)

        var r = F()
        _ = r.width(target: 100, trackKey: "X")
        expectEqual(r.didResetOnLastCall, true)
        _ = r.width(target: 120, trackKey: "X")
        expectEqual(r.didResetOnLastCall, false)
        _ = r.width(target: 80, trackKey: "X")
        expectEqual(r.didResetOnLastCall, false)
        _ = r.width(target: 90, trackKey: "Y")
        expectEqual(r.didResetOnLastCall, true)

        var gap = F()
        _ = gap.width(target: 150, trackKey: "T")
        expectEqual(gap.width(target: 38.5, trackKey: "T"), 150)

        var resetFloor = F()
        _ = resetFloor.width(target: 120, trackKey: "T")
        expectEqual(resetFloor.currentFloor, 120)
        resetFloor.reset()
        expectEqual(resetFloor.currentFloor, 0)
        expectEqual(resetFloor.didResetOnLastCall, true)
        expectEqual(resetFloor.width(target: 95, trackKey: "T"), 95)
        expectEqual(resetFloor.didResetOnLastCall, true)

        var safeFloor = F()
        expectEqual(safeFloor.width(target: -20, trackKey: "N"), 0)
        expectEqual(safeFloor.width(target: .nan, trackKey: "N"), 0)

        let item = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/lyrimuse/MenuBar/MenuBarStatusItem.swift")
        if let text = try? String(contentsOfFile: item.path, encoding: .utf8) {
            expectEqual(text.contains("slotFloor.width("), true)
            expectEqual(text.contains("trackKey: coordinator.title"), true)
            let hits = text.components(separatedBy: "slotFloor.width(").count - 1
            expectEqual(hits, 1)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        typealias Rows = MenuBarLyricRows
        expectEqual(Rows.buttonHeight, 22)
        expectEqual(Rows.mainPointSize, 10)
        expectEqual(Rows.secondaryPointSize, 9)
        expectEqual(Rows.mainPointSize > Rows.secondaryPointSize, true)

        let tight = Rows.layout(mainHeight: 12, secondaryHeight: 11, buttonHeight: 22)
        expectEqual(tight.mainY + tight.mainHeight, 22)
        expectEqual(tight.secondaryY, 0)
        expectEqual((tight.secondaryY + tight.secondaryHeight) - tight.mainY, 1)

        let loose = Rows.layout(mainHeight: 10, secondaryHeight: 8, buttonHeight: 22)
        expectEqual(loose.secondaryY, 2)
        expectEqual(loose.mainY, loose.secondaryY + loose.secondaryHeight)
        expectEqual(loose.mainY, 10)
        expectEqual(loose.mainY + loose.mainHeight, 20)

        for (m, s): (CGFloat, CGFloat) in [(12, 11), (10, 8), (13, 12), (16, 9), (11, 11)] {
            let l = Rows.layout(mainHeight: m, secondaryHeight: s, buttonHeight: 22)
            expectEqual(l.mainY >= l.secondaryY, true)
            expectEqual(l.mainY + l.mainHeight <= 22, true)
            expectEqual(l.secondaryY >= 0, true)
            expectEqual(l.mainHeight, m)
            expectEqual(l.secondaryHeight, s)
        }

        expectEqual(Rows.secondaryOpacity(for: .off), 0)
        expectEqual(Rows.secondaryOpacity(for: .translation) > Rows.secondaryOpacity(for: .romanization), true)
        expectEqual(Rows.secondaryOpacity(for: .romanization) > Rows.secondaryOpacity(for: .nextLine), true)
        expectEqual(Rows.secondaryOpacity(for: .nextLine) > 0.5, true)
        expectEqual(Rows.tailFadeWidth > 0, true)

        let line = SyncedLyricLine(romanization: " yume naraba ", translation: "如果是梦该有多好",
                                   mainText: "夢ならば", words: nil, wordGroups: nil, side: nil)
        expectEqual(LyricSecondaryLine.off.secondaryText(currentLine: line, nextLineText: "next"), nil)
        expectEqual(LyricSecondaryLine.nextLine.secondaryText(currentLine: line, nextLineText: "next"), "next")
        expectEqual(LyricSecondaryLine.translation.secondaryText(currentLine: line, nextLineText: "next"),
                    "如果是梦该有多好")
        expectEqual(LyricSecondaryLine.romanization.secondaryText(currentLine: line, nextLineText: "next"),
                    "yume naraba")
        expectEqual(LyricSecondaryLine.nextLine.secondaryText(currentLine: line, nextLineText: "  \n"), nil)
        expectEqual(LyricSecondaryLine.translation.secondaryText(currentLine: nil, nextLineText: "next"), nil)
        expectEqual(LyricSecondaryLine.nextLine.secondaryText(currentLine: nil, nextLineText: "next"), "next")
    }
}
