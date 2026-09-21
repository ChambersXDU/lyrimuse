import Foundation
import LyrimuseCore

private func testOrdinaryLRC() {
    let ordinary = LRCParser.parse("""
    [ar:Simon & Garfunkel]
    [00:00.00]Hello darkness, my old friend
    [00:04.00]I've come to talk with you again
    """)

    expectEqual(ordinary.count, 2, "普通 LRC 保留歌词行")
    expectEqual(ordinary.map(\.timeMs), [0, 4000])
    expectEqual(ordinary.map(\.text), [
        "Hello darkness, my old friend",
        "I've come to talk with you again",
    ])
}

private func testRepeatedTimestamps() {
    let repeated = LRCParser.parse(
        "[00:01.00][00:10.00]repeat\n"
            + "[00:02.50]next\n"
    )

    expectEqual(
        repeated,
        [
            LyricLine(timeMs: 1000, text: "repeat"),
            LyricLine(timeMs: 2500, text: "next"),
            LyricLine(timeMs: 10000, text: "repeat"),
        ],
        "一行多个时间标签"
    )
}

private func testMetadataAndOffsets() {
    expectEqual(
        LRCParser.parse("[ti:Only metadata]\nplain text\n"),
        [],
        "非时间行不进入时间轴"
    )
    expectEqual(
        LRCParser.parse("[00:01.00]\n[broken\n"),
        [],
        "空歌词与坏标签不产生行"
    )

    expectEqual(LRCParser.parseOffsetMs("[offset:-240]\n[00:01.00]a\n"), -240)
    expectEqual(LRCParser.parseOffsetMs("[offset:+500]\n"), 500)
    expectEqual(LRCParser.parseOffsetMs("[ti:no offset]\n"), 0)
}

private func testBasicYRC() {
    let yrc = YRCParser.parse(
        "[1000,2000](1000,600,0)one (1600,400,0)two\n"
            + "[3000,500](3000,500,0)end\n"
    )

    expectEqual(yrc.count, 2, "基本 YRC 行数")
    expectEqual(yrc.first?.timeMs, 1000)
    expectEqual(yrc.first?.words ?? [], [
        LyricWord(startMs: 1000, durationMs: 600, text: "one "),
        LyricWord(startMs: 1600, durationMs: 400, text: "two"),
    ])
    expectEqual(yrc.map { $0.words.map(\.text) }, [["one ", "two"], ["end"]])
    expectEqual(yrc.last?.words.last?.durationMs, 500)
}

private func testMalformedYRC() {
    expectEqual(
        YRCParser.parse("[0,1000](0,0,0)"),
        [],
        "没有文字的 YRC 元组被忽略"
    )
    expectEqual(
        YRCParser.parse("[0,1000](0,0,0)(500,500,0)word").first?.words ?? [],
        [LyricWord(startMs: 500, durationMs: 500, text: "word")],
        "可恢复的坏元组不污染后续文字"
    )
}

private func testNormalizedTimeline() {
    let raw = [
        LyricLineWords(timeMs: 1000, words: [
            LyricWord(startMs: 900, durationMs: 400, text: "a"),
            LyricWord(startMs: 1300, durationMs: 300, text: "b"),
        ]),
        LyricLineWords(timeMs: 2000, words: [
            LyricWord(startMs: 2000, durationMs: 500, text: "c"),
        ]),
    ]
    let normalized = LyricTimelineNormalizer.normalize(raw)

    expectEqual(normalized.report.clampedToLineStart, 1, "坏时间被夹回行首")
    expectEqual(normalized.lines[0].words[0].startMs, 1000)
    let validTimeline = normalized.lines.allSatisfy { line in
        line.words.allSatisfy { word in
            word.startMs >= line.timeMs && word.durationMs >= 0
        }
    }
    expectEqual(validTimeline, true, "归一化结果没有负时间或负时长")
}

private func testRealFragmentsAndOrdering() {
    let chinese = LRCParser.parse("""
    [00:20.00]我送你离开
    [00:24.00]千里之外
    """)
    expectEqual(chinese.count, 2, "真实歌词片段仍按普通 LRC 解析")
    expectEqual(chinese.map(\.text), ["我送你离开", "千里之外"])

    let reordered = LRCParser.parse(
        "[00:05.00]later\r\n"
            + "[00:01.00]first\r\n"
    )
    expectEqual(
        reordered,
        [
            LyricLine(timeMs: 1000, text: "first"),
            LyricLine(timeMs: 5000, text: "later"),
        ],
        "普通 LRC 的乱序时间与换行仍得到稳定时间轴"
    )
}

func runLyricsParsingTests() {
    testOrdinaryLRC()
    testRepeatedTimestamps()
    testMetadataAndOffsets()
    testBasicYRC()
    testMalformedYRC()
    testNormalizedTimeline()
    testRealFragmentsAndOrdering()
}
