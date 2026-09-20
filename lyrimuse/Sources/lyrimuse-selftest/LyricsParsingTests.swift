import LyrimuseCore
import Foundation

@MainActor
func runLyricsParsingTests() {

    expectEqual(
        LRCParser.parse("[00:01.50]la la la\n[00:03.00]la la\n"),
        [LyricLine(timeMs: 1500, text: "la la la"), LyricLine(timeMs: 3000, text: "la la")]
    )

    expectEqual(
        LRCParser.parse("[00:01.5]a\n[00:02.50]b\n[00:03.500]c\n").map(\.timeMs),
        [1500, 2500, 3500]
    )

    expectEqual(
        LRCParser.parse("[00:01:25]x\n"),
        [LyricLine(timeMs: 1250, text: "x")]
    )

    expectEqual(
        LRCParser.parse("[00:10.00][00:40.00]repeat me\n"),
        [LyricLine(timeMs: 10000, text: "repeat me"), LyricLine(timeMs: 40000, text: "repeat me")]
    )

    do {
        var probe = FrameRateProbe()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        expectEqual(probe.fps == nil, true)
        probe.tick(at: t0)
        expectEqual(probe.fps == nil, true)

        var t = t0
        for _ in 0..<200 {
            t = t.addingTimeInterval(1.0 / 30)
            probe.tick(at: t)
        }
        let fps = probe.fps ?? 0
        expectEqual(abs(fps - 30) < 0.5, true)

        probe.tick(at: t.addingTimeInterval(5))
        expectEqual(probe.fps == nil, true)

        var probe2 = FrameRateProbe()
        let s0 = Date(timeIntervalSinceReferenceDate: 2000)
        probe2.tick(at: s0)
        probe2.tick(at: s0)
        expectEqual(probe2.fps == nil, true)
        probe2.tick(at: s0.addingTimeInterval(-1))
        expectEqual(probe2.fps == nil, true)
    }

    expectEqual(LRCParser.parseOffsetMs("[offset:242]\n[00:01.00]x\n"), 242)
    expectEqual(LRCParser.parseOffsetMs("[offset:+500]\n"), 500)
    expectEqual(LRCParser.parseOffsetMs("[offset:-300]\n"), -300)
    expectEqual(LRCParser.parseOffsetMs("[offset: 600 ]\n"), 600)
    expectEqual(LRCParser.parseOffsetMs("[offset:0]\n"), 0)
    expectEqual(LRCParser.parseOffsetMs("[ti:x]\n[00:01.00]y\n"), 0)

    expectEqual(LRCParser.parseOffsetMs("[offset:99999]\n"), 0)
    expectEqual(LRCParser.parseOffsetMs("[offset:-99999]\n"), 0)
    expectEqual(LRCParser.parseOffsetMs("[offset:10000]\n"), 10000)

    expectEqual(LRCParser.parseOffsetMs("[offset:100]\n[offset:900]\n"), 100)

    expectEqual(
        LRCParser.parse("[offset:242]\n[00:01.00]x\n"),
        [LyricLine(timeMs: 1000, text: "x")]
    )

    do {
        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: "[offset:400]\n[00:10.00]a\n[00:20.00]b\n",
                        lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.lrcOffsetMs, 400)
        expectEqual(engine.effectiveOffsetMs, 400)
        engine.offsetMs = 250
        expectEqual(engine.effectiveOffsetMs, 650)

        expectEqual(engine.activeLine(atMs: 19400)?.plainText, "b")
        expectEqual(engine.activeLine(atMs: 19300)?.plainText, "a")

        _ = engine.load(lyrics: "[00:10.00]c\n", lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.lrcOffsetMs, 0)
        expectEqual(engine.effectiveOffsetMs, 250)
    }

    do {
        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "",
                        lyricsYRC: "[offset:600]\n[10000,2000](10000,2000,0)a\n")
        expectEqual(engine.lrcOffsetMs, 600)
    }

    expectEqual(
        LRCParser.parse("[ti:Test Song]\n[by:Someone]\n[00:00.00]actual line\n"),
        [LyricLine(timeMs: 0, text: "actual line")]
    )

    expectEqual(LRCParser.parse("just plain text\n"), [])
    expectEqual(LRCParser.parse(""), [])

    expectEqual(
        LRCParser.parse("[00:05.00]second\n[00:01.00]first\n").map(\.timeMs),
        [1000, 5000]
    )

    expectEqual(
        LRCParser.parse("[00:01.00]first\r\n[00:02.00]second\r\n[00:03.00]third\r\n"),
        [LyricLine(timeMs: 1000, text: "first"), LyricLine(timeMs: 2000, text: "second"), LyricLine(timeMs: 3000, text: "third")]
    )

    do {
        let text = "[1000,2000](1000,500,0)la (1500,500,0)la (2000,500,0)la "
        let lines = YRCParser.parse(text)
        expectEqual(lines.count, 1)
        expectEqual(lines.first?.timeMs, 1000)
        expectEqual(lines.first?.words ?? [], [
            LyricWord(startMs: 1000, durationMs: 500, text: "la "),
            LyricWord(startMs: 1500, durationMs: 500, text: "la "),
            LyricWord(startMs: 2000, durationMs: 500, text: "la "),
        ])
    }

    do {
        let text = "[0,1000](0,0,0)(500,500,0)word"
        let lines = YRCParser.parse(text)
        expectEqual(lines.first?.words ?? [], [LyricWord(startMs: 500, durationMs: 500, text: "word")])
    }

    expectEqual(YRCParser.parse("[0,1000](0,0,0)(100,0,0)"), [])
    expectEqual(YRCParser.parse("no header here (1,2,0)x"), [])

    do {

        let text = "[0,3000](0,500,0)Hello(1600,400,0)(oh)(2100,300,0)world"
        let lines = YRCParser.parse(text)
        expectEqual(lines.first?.words ?? [], [
            LyricWord(startMs: 0, durationMs: 500, text: "Hello"),
            LyricWord(startMs: 1600, durationMs: 400, text: "(oh)"),
            LyricWord(startMs: 2100, durationMs: 300, text: "world"),
        ])
    }

    do {

        let text = "[0,3000](0,500,0)Jackson(1600,500,0) ((1000,500)(2100,300,0)word(2400,300,0)(2700,300)"
        let lines = YRCParser.parse(text)
        expectEqual(lines.first?.words ?? [], [
            LyricWord(startMs: 0, durationMs: 500, text: "Jackson"),
            LyricWord(startMs: 1600, durationMs: 500, text: " ("),
            LyricWord(startMs: 2100, durationMs: 300, text: "word"),
        ])
    }

    expectEqual(
        YRCParser.parse("[5000,1000](5000,500,0)second\n[1000,1000](1000,500,0)first\n").map(\.timeMs),
        [1000, 5000]
    )

    expectEqual(YRCParser.parse(""), [])

    expectEqual(
        YRCParser.parse("[1000,500](1000,500,0)la \r\n[2000,500](2000,500,0)la \r\n"),
        [
            LyricLineWords(timeMs: 1000, words: [LyricWord(startMs: 1000, durationMs: 500, text: "la ")]),
            LyricLineWords(timeMs: 2000, words: [LyricWord(startMs: 2000, durationMs: 500, text: "la ")]),
        ]
    )

    do {
        let W = LyricTimelineNormalizer.tailWindowMs
        func line(_ t: Int, _ ws: [(Int, Int, String)]) -> LyricLineWords {
            LyricLineWords(timeMs: t, words: ws.map { LyricWord(startMs: $0.0, durationMs: $0.1, text: $0.2) })
        }
        expectEqual(W, KaraokeFill.lineTailLeadMs + KaraokeFill.minTailFillMs)

        let ok = [line(1000, [(1000, 300, "a"), (1300, 300, "b")]), line(2000, [(2000, 500, "c")])]
        let r0 = LyricTimelineNormalizer.normalize(ok)
        expectEqual(r0.lines, ok)
        expectEqual(r0.report.isEmpty, true)

        let before = [line(1000, [(900, 400, "a"), (1300, 300, "b")]), line(2000, [(2000, 500, "c")])]
        let r1 = LyricTimelineNormalizer.normalize(before)
        expectEqual(r1.lines[0].words[0], LyricWord(startMs: 1000, durationMs: 300, text: "a"))
        expectEqual(r1.lines[0].words[1], LyricWord(startMs: 1300, durationMs: 300, text: "b"))
        expectEqual(r1.report.clampedToLineStart, 1)

        let far = [line(1000, [(600, 400, "a"), (1300, 300, "b")]), line(2000, [(2000, 500, "c")])]
        let r2 = LyricTimelineNormalizer.normalize(far)
        expectEqual(r2.lines[0].words, [LyricWord(startMs: 1000, durationMs: 1000, text: "ab")])
        expectEqual(r2.report.degradedLines[.wordBeforeLine], 1)
        expectEqual(r2.lines[1], far[1])

        let punct = [line(1000, [(1000, 300, "a"), (2000, 0, "?")]), line(2000, [(2000, 500, "c")])]
        let r3 = LyricTimelineNormalizer.normalize(punct)
        expectEqual(r3.lines[0].words[1], LyricWord(startMs: 2000 - W, durationMs: W, text: "?"))
        expectEqual(r3.report.clampedBeforeNextLine, 1)

        let late = [line(1000, [(1000, 300, "a"), (2100, 200, "b")]), line(2000, [(2000, 500, "c")])]
        let r4 = LyricTimelineNormalizer.normalize(late)
        expectEqual(r4.lines[0].words[1], LyricWord(startMs: 2000 - W, durationMs: 2300 - (2000 - W), text: "b"))

        let veryLate = [line(1000, [(1000, 300, "a"), (2400, 200, "b")]), line(2000, [(2000, 500, "c")])]
        let r5 = LyricTimelineNormalizer.normalize(veryLate)
        expectEqual(r5.report.degradedLines[.wordAfterNextLine], 1)
        expectEqual(r5.lines[0].words, [LyricWord(startMs: 1000, durationMs: 1000, text: "ab")])

        let dec = [line(1000, [(1000, 300, "a"), (1500, 300, "b"), (1200, 300, "c")]), line(3000, [(3000, 500, "d")])]
        let r6 = LyricTimelineNormalizer.normalize(dec)
        expectEqual(r6.lines[0].words, [LyricWord(startMs: 1000, durationMs: 2000, text: "abc")])
        expectEqual(r6.report.degradedLines[.wordStartDecreased], 1)

        let last = [line(1000, [(1000, 300, "a"), (9000, 200, "b")])]
        expectEqual(LyricTimelineNormalizer.normalize(last).lines, last)
        let lastDec = [line(1000, [(1000, 300, "a"), (1500, 300, "b"), (1200, 800, "c")])]
        expectEqual(LyricTimelineNormalizer.normalize(lastDec).lines[0].words,
                    [LyricWord(startMs: 1000, durationMs: 1000, text: "abc")])

        let same = [line(1000, [(1000, 300, "a"), (1300, 300, "b")]), line(1000, [(1000, 300, "c")]), line(2000, [(2000, 100, "d")])]
        let r7 = LyricTimelineNormalizer.normalize(same)
        expectEqual(r7.lines[0].words, same[0].words)
        expectEqual(r7.report.isEmpty, true)

        let crowd = [line(1000, [(1000, 300, "a"), (1900, 50, "b"), (2000, 50, "c")]), line(2000, [(2000, 500, "d")])]
        let r8 = LyricTimelineNormalizer.normalize(crowd)
        expectEqual(r8.lines[0].words[2].startMs, 1900)
        let short = [line(1900, [(2000, 50, "a")]), line(2000, [(2000, 500, "b")])]
        let r9 = LyricTimelineNormalizer.normalize(short)
        expectEqual(r9.lines[0].words[0].startMs, 1900)

        expectEqual(LyricTimelineNormalizer.normalize([]).lines, [])
    }

    do {
        let head = "[ti:]\n[ar:]\n[al:]\n[by:krc转qrc工具]\n[offset:0]\n[00:20.50]One more card\n"
        expectEqual(
            LyricsPreviewText.forPreview(head),
            "[00:20.50]One more card"
        )

        expectEqual(
            LyricsPreviewText.forPreview("[00:00.00] 作词 : Prince\n[00:01.00] 作曲 : Prince\n[00:02.00] 制作人 : Prince\n[00:20.50]One more card\n"),
            "[00:20.50]One more card"
        )

        expectEqual(
            LyricsPreviewText.forPreview("[00:20.50]a\n[00:24.25]b\n"),
            "[00:20.50]a\n[00:24.25]b"
        )

        expectEqual(
            LyricsPreviewText.forPreview("[00:20.50]\n[00:24.25]b\n"),
            "[00:24.25]b"
        )

        expectEqual(
            LyricsPreviewText.forPreview("[ti:]\r\n[00:20.50]a\r\n"),
            "[00:20.50]a"
        )

        let duet = "[00:10.00]周杰伦：我送你离开\n[00:12.00]周杰伦：千里之外\n[00:14.00]周杰伦：醉解千愁\n"
        expectEqual(
            LyricsPreviewText.forPreview(duet),
            duet.trimmingCharacters(in: .newlines)
        )

        expectEqual(
            LyricsPreviewText.forPreview("first verse\n\nsecond verse\n"),
            "first verse\n\nsecond verse"
        )

        expectEqual(LyricsPreviewText.forPreview(""), "")
        expectEqual(LyricsPreviewText.forPreview("[ti:]\n[ar:]\n"), "")
    }

    do {
        let raw = "[id:$00000000]\n[ar:宇多田光 (宇多田ヒカル)]\n[ti:One Last Kiss (最后一吻)]\n[by:]\n[hash:]\n[al:One Last Kiss]\n[sign:]\n[qq:]\n[total:0]\n[offset:0]\n[00:00.00]One Last Kiss - 宇多田光 (宇多田ヒカル)\n[00:09.57]词: 宇多田ヒカル\n[00:14.67]曲: 宇多田ヒカル\n[00:20.69]初めてのルーブルは\n[00:23.01]なんてことはなかったわ\n[03:00.00]词: 宇多田ヒカル\n"
        let edit = LyricsBodyEdit(lyrics: raw, title: "One Last Kiss", artist: "宇多田光")
        expectEqual(edit.body, "[00:20.69]初めてのルーブルは\n[00:23.01]なんてことはなかったわ")
        expectEqual(edit.hiddenPrefix.count, 13)
        expectEqual(edit.hiddenPrefix.first ?? "", "[id:$00000000]")
        expectEqual(edit.hiddenPrefix.last ?? "", "[00:14.67]曲: 宇多田ヒカル")
        expectEqual(edit.hiddenSuffix, ["[03:00.00]词: 宇多田ヒカル"])
        expectEqual(edit.reassembled(body: edit.body), raw)
        expectEqual(
            edit.reassembled(body: "[00:20.69]改过的第一句\n[00:23.01]なんてことはなかったわ"),
            "[id:$00000000]\n[ar:宇多田光 (宇多田ヒカル)]\n[ti:One Last Kiss (最后一吻)]\n[by:]\n[hash:]\n[al:One Last Kiss]\n[sign:]\n[qq:]\n[total:0]\n[offset:0]\n[00:00.00]One Last Kiss - 宇多田光 (宇多田ヒカル)\n[00:09.57]词: 宇多田ヒカル\n[00:14.67]曲: 宇多田ヒカル\n[00:20.69]改过的第一句\n[00:23.01]なんてことはなかったわ\n[03:00.00]词: 宇多田ヒカル\n"
        )

        expectEqual(
            LyricsBodyEdit(lyrics: "[offset:0]\n[00:01.00]a\n[00:02.00]b").reassembled(body: "[00:01.00]a\n\n[00:02.00]b"),
            "[offset:0]\n[00:01.00]a\n\n[00:02.00]b"
        )
        expectEqual(LyricsBodyEdit(lyrics: "").body, "")
        expectEqual(LyricsBodyEdit(lyrics: "").reassembled(body: ""), "")
        expectEqual(LyricsBodyEdit(lyrics: "[00:20.50]a\n[00:24.25]b").body, "[00:20.50]a\n[00:24.25]b")

        expectEqual(LyricsPreviewText.forPreview(raw, title: "One Last Kiss", artist: "宇多田光"), edit.body)

        let metaOnly = LyricsBodyEdit(lyrics: "[ti:]\n[ar:]\n")
        expectEqual(metaOnly.body, "")
        expectEqual(metaOnly.reassembled(body: ""), "[ti:]\n[ar:]\n")
    }

    do {

        let roomy = LyricsQueryFieldLayout.widths(desired: [100, 90, 170], available: 390, minWidth: 88)
        expectEqual(roomy, [110, 100, 180])
        expectEqual(roomy.reduce(0, +), 390)

        expectEqual(
            LyricsQueryFieldLayout.widths(desired: [10, 10, 10], available: 300, minWidth: 88),
            [100, 100, 100]
        )

        let tight = LyricsQueryFieldLayout.widths(desired: [400, 40, 400], available: 500, minWidth: 88)
        expectEqual(tight[1], 88)
        expectEqual(tight[0], tight[2])
        expectEqual(tight.reduce(0, +), 500)
        expectEqual(tight[0] > 88, true)

        expectEqual(
            LyricsQueryFieldLayout.widths(desired: [400, 40, 400], available: 120, minWidth: 88),
            [40, 40, 40]
        )

        expectEqual(LyricsQueryFieldLayout.widths(desired: [], available: 400, minWidth: 88), [])
        expectEqual(LyricsQueryFieldLayout.widths(desired: [100, 100], available: 0, minWidth: 88), [0, 0])
        expectEqual(
            LyricsQueryFieldLayout.widths(desired: [0, 0, 0], available: 600, minWidth: 88),
            [200, 200, 200]
        )
    }
}
