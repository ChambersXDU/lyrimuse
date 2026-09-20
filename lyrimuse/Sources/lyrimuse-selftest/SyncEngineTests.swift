import LyrimuseCore
import Foundation

@MainActor
func runSyncEngineTests() {

    do {
        let engine = LyricsSyncEngine()

        let yrc = "[8000,1000](8000,500,0)aa (8500,500,0)bb \n"
            + "[25000,1000](25000,500,0)cc (25500,500,0)dd \n"
            + "[28000,1000](28000,500,0)ee (28500,500,0)ff \n"
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
        expectEqual(engine.gapMarkers().map(\.index), [-1, 0])
        expectEqual(engine.activeGapIndex(atMs: 3000), -1)
        expectEqual(engine.activeGapIndex(atMs: 8200), nil)
        expectEqual(engine.activeGapIndex(atMs: 15000), 0)
        expectEqual(engine.activeGapIndex(atMs: 24700), nil)

        let engine2 = LyricsSyncEngine()
        let lrc = "[00:01.00]aa\n[00:13.00]bb\n[00:40.00]cc\n"
        engine2.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine2.gapMarkers().map(\.index), [1])
    }

    do {

        let engine = LyricsSyncEngine()
        let yrc = "[8000,1000](8000,500,0)aa (8500,500,0)bb \n"
            + "[25000,1000](25000,500,0)cc (25500,500,0)dd \n"
            + "[28000,1000](28000,500,0)ee (28500,500,0)ff \n"
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
        expectEqual(engine.tickQuery(atMs: 3000).scrollIndex, nil)
        expectEqual(engine.tickQuery(atMs: 7500).scrollIndex, 0)
        expectEqual(engine.tickQuery(atMs: 8500).scrollIndex, 0)
        expectEqual(engine.tickQuery(atMs: 15000).scrollIndex, 0)
        expectEqual(engine.tickQuery(atMs: 24500).scrollIndex, 1)
        expectEqual(engine.tickQuery(atMs: 25500).scrollIndex, 1)
        expectEqual(engine.tickQuery(atMs: 26500).scrollIndex, 2)
        expectEqual(engine.tickQuery(atMs: 26500).index, 1)
        expectEqual(engine.tickQuery(atMs: 28500).scrollIndex, 2)

        let engine2 = LyricsSyncEngine()
        let lrc = "[00:01.00]aa\n[00:05.00]bb\n"
        engine2.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine2.tickQuery(atMs: 3000).scrollIndex, 0)
        expectEqual(engine2.tickQuery(atMs: 3000).index, 0)
    }

    do {
        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]第一句\n[00:20.00]第二句\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 15000)?.mainText, "第一句")
        engine.offsetMs = 6000
        expectEqual(engine.activeLine(atMs: 15000)?.mainText, "第二句")
        engine.offsetMs = -6000
        expectEqual(engine.activeLine(atMs: 15000)?.mainText, nil)
    }

    do {
        let engine = LyricsSyncEngine()
        let lrc = "[00:00.00]作词 : 甲\n[00:10.00]第一句\n[00:20.00]第二句\n[00:30.00]第三句\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        let lines = engine.allLines(idPrefix: "test")
        expectEqual(lines.count, 3)
        expectEqual(lines.map { $0.line.mainText }, ["第一句", "第二句", "第三句"])
        expectEqual(lines.map(\.id), ["test#0", "test#1", "test#2"])
    }

    do {
        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]第一句\n[00:20.00]第二句\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 12000)?.mainText, "第一句")
        expectEqual(engine.activeLine(atMs: 13000)?.mainText, "第一句")
        expectEqual(engine.activeLine(atMs: 21000)?.mainText, "第二句")
        expectEqual(engine.activeLine(atMs: 5000)?.mainText, nil)
        expectEqual(engine.upcomingLineText(afterMs: 12000), "第二句")
        expectEqual(engine.upcomingLineText(afterMs: 21000), nil)
        expectEqual(engine.upcomingLineText(afterMs: 12000), "第二句")
    }

    do {
        let engine = LyricsSyncEngine()
        engine.load(lyrics: "[00:10.00]旧歌词\n", lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 15000)?.mainText, "旧歌词")
        expectEqual(engine.upcomingLineText(afterMs: 5000), "旧歌词")
        engine.load(lyrics: "[00:10.00]新歌词\n", lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 15000)?.mainText, "新歌词")
        expectEqual(engine.upcomingLineText(afterMs: 5000), "新歌词")
    }

    do {
        let w1 = SyncedLyricWord(text: "aa", startMs: 1000, durationMs: 500)
        let w2 = SyncedLyricWord(text: "bb", startMs: 1500, durationMs: 500)
        expectEqual(KaraokeFill.lineFillSettledMs(words: [w1], groups: nil), 1540)
        expectEqual(KaraokeFill.lineFillSettledMs(words: [SyncedLyricWord(text: "a", startMs: 1000, durationMs: 10)], groups: nil), 1087)
        expectEqual(KaraokeFill.lineFillSettledMs(words: [w1, w2], groups: nil), 2040)
        let group = SyncedLyricWordGroup(id: 0, words: [w1, w2], romanization: "aabb")
        expectEqual(KaraokeFill.lineFillSettledMs(words: [w1, w2], groups: [group]), 2080)
    }

    do {
        let D = LyricDuet.self

        expectEqual(D.splitLabel("男：周末守着烤箱")?.label, "男")
        expectEqual(D.splitLabel("男：周末守着烤箱")?.rest, "周末守着烤箱")
        expectEqual(D.splitLabel("女: 偏爱年轻女伴")?.rest, "偏爱年轻女伴")
        expectEqual(D.splitLabel("合：何时想戒掉流浪")?.label, "合")
        expectEqual(D.splitLabel("男声：测试")?.rest, "测试")
        expectEqual(D.splitLabel("情人节也落单") == nil, true)

        expectEqual(D.splitLabel("Baby, I said: hello") == nil, true)
        expectEqual(D.splitLabel("Chris Tucker: Oh man") == nil, true)
        expectEqual(D.splitLabel("一二三四五六七八九十一：x") == nil, true)

        expectEqual(D.splitLabel("男：周末")?.prefixCount, 2)
        expectEqual(D.splitLabel("女: 偏爱")?.prefixCount, 3)

        expectEqual(D.speakers(in: ["男：一", "女：二"]), Set(["男", "女"]))

        expectEqual(D.speakers(in: ["词：葛大为", "曲：陶喆/蔡健雅", "真歌词"]).isEmpty, true)

        do {

            let s = D.speakers(in: ["周杰伦：", "一", "杨瑞代：", "二", "周杰伦：", "三"])
            expectEqual(s, Set(["周杰伦", "杨瑞代"]))
        }
        do {

            let s = D.speakers(in: ["Rap：", "一", "Rap2：", "二"])
            expectEqual(s.isEmpty, true)
        }
        do {

            let s = D.speakers(in: ["执行制作：甲", "录音师：乙", "混音师：丙", "录音室：丁", "混音室：戊", "歌词"])
            expectEqual(s.isEmpty, true)
        }
        do {

            let s = D.speakers(in: ["我说：是的", "然后她问我：好吗", "我说：好", "然后她问我：真的", "我说：真的"])
            expectEqual(s.isEmpty, true)
        }
        do {

            let s = D.speakers(in: ["小号：涂", "小打击乐器组：Joni", "小号：涂"])
            expectEqual(s.isEmpty, true)
        }
        do {

            let s = D.speakers(in: [
                "词：方文山", "曲：周杰伦", "歌词一",
                "词：方文山", "曲：周杰伦", "歌词二",
                "词：黄俊郎", "曲：周杰伦", "歌词三",
                "词：方文山", "曲：周杰伦", "歌词四",
            ])
            expectEqual(s.isEmpty, true)
        }
        do {

            let s = D.speakers(in: ["曲婉婷：一", "李健：二", "曲婉婷：三"])
            expectEqual(s, Set(["曲婉婷", "李健"]))
        }
        do {

            let s = D.speakers(in: [
                "周杰伦：", "一", "阿信：", "二", "周杰伦：", "三",
                "和声：陈某某", "监制：李某某", "母带处理：王某某",
            ])
            expectEqual(s, Set(["周杰伦", "阿信"]))
        }

        do {
            let markers: [String?] = [nil, "男", nil, nil, "女", nil, "合", nil, "男"]
            let sides = D.sides(for: markers)
            expectEqual(sides[0], nil)
            expectEqual(sides[1], .leading)
            expectEqual(sides[2], .leading)
            expectEqual(sides[3], .leading)
            expectEqual(sides[4], .trailing)
            expectEqual(sides[5], .trailing)
            expectEqual(sides[6], .center)
            expectEqual(sides[7], .center)
            expectEqual(sides[8], .leading)
        }

        do {
            let sides = D.sides(for: ["女", "男"])
            expectEqual(sides[0], .leading)
            expectEqual(sides[1], .trailing)
        }

        do {
            expectEqual(D.identity(of: "男声"), "男")
            expectEqual(D.identity(of: "男合"), "男")
            expectEqual(D.identity(of: "Female"), "女")
            expectEqual(D.identity(of: "周杰伦"), "周杰伦")
            let sides = D.sides(for: ["男", "男声", "女"])
            expectEqual(sides[0], .leading)
            expectEqual(sides[1], .leading)
            expectEqual(sides[2], .trailing)
        }

        do {
            let s = D.speakers(in: ["旁白：从前有座山", "男：一", "女：二", "口白：完"])
            expectEqual(s.contains("旁白"), true)
            expectEqual(s.contains("口白"), true)
            let sides = D.sides(for: ["旁白", "男", "女"])
            expectEqual(sides[0], .center)
            expectEqual(sides[1], .leading)
            expectEqual(sides[2], .trailing)
        }

        do {
            expectEqual(D.sides(for: ["合", nil, "合"]).compactMap { $0 }.isEmpty, true)
            expectEqual(D.sides(for: ["男", nil, "男"]).compactMap { $0 }.isEmpty, true)
            expectEqual(D.sides(for: ["男", "合", "男"]).compactMap { $0 }.isEmpty, true)
            expectEqual(D.sides(for: ["v1", nil, "v2"])[2], .trailing)
            expectEqual(D.speakers(in: ["v1：一", "v2：二"]), Set(["v1", "v2"]))
        }

        do {
            let plan = D.plan(lineTexts: ["合：", "何时想戒掉流浪", "普通一行"])
            expectEqual(plan.dropped, [true, false, false])
            expectEqual(plan.sides.compactMap { $0 }.isEmpty, true)
        }

        do {
            let sides = D.sides(for: ["男", "合", "女", "合", "男"])
            expectEqual(sides[0], .leading)
            expectEqual(sides[1], .center)
            expectEqual(sides[2], .trailing)
            expectEqual(sides[4], .leading)
        }

        do {
            let sides = D.sides(for: [nil, nil, nil])
            expectEqual(sides.compactMap { $0 }.isEmpty, true)
        }

        do {
            let plan = D.plan(lineTexts: ["男：周末守着烤箱", "情人节也落单", "女：偏爱年轻女伴"])
            expectEqual(plan.texts, ["周末守着烤箱", "情人节也落单", "偏爱年轻女伴"])
            expectEqual(plan.sides, [.leading, .leading, .trailing])
            expectEqual(plan.dropped, [false, false, false])
        }

        do {
            let plan = D.plan(lineTexts: ["周杰伦：", "没有了联络", "阿信：", "电话开始躲", "周杰伦：", "你什么都没有"])
            expectEqual(plan.dropped, [true, false, true, false, true, false])
            expectEqual(plan.sides, [.leading, .leading, .trailing, .trailing, .leading, .leading])
            expectEqual(plan.texts[1], "没有了联络")
        }

        func w(_ start: Int, _ dur: Int, _ t: String) -> LyricWord {
            LyricWord(startMs: start, durationMs: dur, text: t)
        }
        do {

            let lines = [
                LyricLineWords(timeMs: 881, words: [w(881, 30, "男"), w(911, 40, "："), w(951, 200, "我"), w(1151, 200, "爱")]),
                LyricLineWords(timeMs: 31038, words: [w(31038, 170, "女"), w(31208, 170, "："), w(31378, 200, "时"), w(31578, 200, "间")]),
            ]
            let plan = D.planWords(lines)
            expectEqual(plan.lines[0].words.map(\.text), ["我", "爱"])
            expectEqual(plan.lines[0].words[0].startMs, 951)
            expectEqual(plan.sides, [.leading, .trailing])
            expectEqual(plan.dropped, [false, false])
        }
        do {

            let lines = [
                LyricLineWords(timeMs: 21155, words: [w(21155, 180, "男：周"), w(21335, 320, "末")]),
                LyricLineWords(timeMs: 40310, words: [w(40310, 180, "女：偏"), w(40490, 320, "爱")]),
            ]
            let plan = D.planWords(lines)
            expectEqual(plan.lines[0].words.map(\.text), ["周", "末"])
            expectEqual(plan.lines[0].words[0].startMs, 21155)
            expectEqual(plan.lines[0].words[0].durationMs, 180)
        }
        do {

            let lines = [
                LyricLineWords(timeMs: 24838, words: [w(24838, 154, "周"), w(24992, 204, "杰"), w(25196, 205, "伦"), w(25401, 255, "：")]),
                LyricLineWords(timeMs: 26499, words: [w(26499, 203, "没"), w(26702, 255, "有")]),
                LyricLineWords(timeMs: 113700, words: [w(113700, 200, "阿"), w(113900, 200, "信"), w(114100, 200, "：")]),
                LyricLineWords(timeMs: 114800, words: [w(114800, 200, "电"), w(115000, 200, "话")]),
                LyricLineWords(timeMs: 172200, words: [w(172200, 154, "周"), w(172354, 204, "杰"), w(172558, 205, "伦"), w(172763, 255, "：")]),
                LyricLineWords(timeMs: 173500, words: [w(173500, 200, "你"), w(173700, 200, "什")]),
            ]
            let plan = D.planWords(lines)
            expectEqual(plan.dropped, [true, false, true, false, true, false])
            expectEqual(plan.sides, [.leading, .leading, .trailing, .trailing, .leading, .leading])
            expectEqual(plan.lines[1].words.map(\.text), ["没", "有"])
        }
        do {

            let lines = [
                LyricLineWords(timeMs: 1000, words: [w(1000, 200, "情"), w(1200, 200, "人")]),
                LyricLineWords(timeMs: 2000, words: [w(2000, 200, "节"), w(2200, 200, "也")]),
            ]
            let plan = D.planWords(lines)
            expectEqual(plan.lines.map { $0.words.map(\.text) }, [["情", "人"], ["节", "也"]])
            expectEqual(plan.dropped, [false, false])
            expectEqual(plan.sides.compactMap { $0 }.isEmpty, true)
        }
    }

    do {
        func word(_ start: Int, _ dur: Int) -> SyncedLyricWord {
            SyncedLyricWord(text: "x", startMs: start, durationMs: dur)
        }
        func rounded(_ stops: [KaraokeFill.Stop]) -> [[Double]] {
            stops.map { [($0.location * 10000).rounded() / 10000, ($0.intensity * 10000).rounded() / 10000] }
        }

        expectEqual(KaraokeFill.fillFraction(for: word(1000, 500), atMs: 0) < 0, true)
        expectEqual(KaraokeFill.fillFraction(for: word(1000, 500), atMs: 2000) > 1, true)
        expectEqual(KaraokeFill.fillFraction(for: word(1000, 500), atMs: 1250), 0.5)

        expectEqual(KaraokeFill.fillFraction(for: word(0, 0), atMs: 40), 0.5)

        expectEqual(rounded(KaraokeFill.stops(left: -0.5, right: -0.34)),
                    [[0, 0], [1, 0]])

        expectEqual(rounded(KaraokeFill.stops(left: 1.2, right: 1.36)),
                    [[0, 1], [1, 1]])

        expectEqual(rounded(KaraokeFill.stops(left: 0.2, right: 0.36)),
                    [[0, 1], [0.2, 1], [0.36, 0], [1, 0]])

        expectEqual(rounded(KaraokeFill.stops(left: -0.05, right: 0.11)),
                    [[0, 0.6875], [0.11, 0], [1, 0]])

        expectEqual(rounded(KaraokeFill.stops(left: 0.95, right: 1.11)),
                    [[0, 1], [0.95, 1], [1, 0.6875]])

        var monotonic = true, inRange = true, intensityOK = true, intensityDesc = true
        for step in -30...130 {
            let fraction = Double(step) / 100
            let s = KaraokeFill.stops(left: fraction - KaraokeFill.wordEdgeSoftenBand,
                                      right: fraction + KaraokeFill.wordEdgeSoftenBand)
            for (i, stop) in s.enumerated() {
                if stop.location < 0 || stop.location > 1 { inRange = false }
                if stop.intensity < 0 || stop.intensity > 1 { intensityOK = false }
                if i > 0 {
                    if stop.location < s[i - 1].location - 1e-12 { monotonic = false }
                    if stop.intensity > s[i - 1].intensity + 1e-12 { intensityDesc = false }
                }
            }
        }
        expectEqual(monotonic, true)
        expectEqual(inRange, true)
        expectEqual(intensityOK, true)
        expectEqual(intensityDesc, true)
    }

    do {
        let lead = KaraokeFill.lineTailLeadMs
        let floorMs = KaraokeFill.minTailFillMs
        func words(_ specs: [(String, Int, Int)]) -> [SyncedLyricWord] {
            specs.map { SyncedLyricWord(text: $0.0, startMs: $0.1, durationMs: $0.2) }
        }
        func tail(_ ws: [SyncedLyricWord], _ next: Int?) -> [Int] {
            KaraokeFill.tailClamped(ws, nextLineStartMs: next).map(\.durationMs)
        }

        expectEqual(tail(words([("a", 0, 500), ("b", 1000, 500)]), 1500), [500, 500 - lead])

        expectEqual(tail(words([("a", 1000, 1000)]), 1500), [1500 - lead - 1000])

        expectEqual(tail(words([("a", 1000, 1000)]), 1050), [floorMs])

        expectEqual(tail(words([("a", 1000, 300)]), 2000), [300])

        expectEqual(tail(words([("a", 1000, 5000)]), nil), [5000])

        expectEqual(tail(words([("a", 0, 900), ("b", 900, 900), ("c", 1800, 900)]), 2700),
                    [900, 900, 2700 - lead - 1800])

        expectEqual(tail(words([("a", 1000, 0)]), 9000), [0])

        expectEqual(tail([], 1000), [])

        let clamped = KaraokeFill.tailClamped(words([("a", 1000, 500)]), nextLineStartMs: 1500)
        let w = clamped[0]
        expectEqual(KaraokeFill.fillFraction(for: w, atMs: 1500 - lead) >= 1.0, true)
        expectEqual(KaraokeFill.fillFraction(for: w, atMs: 1500 - lead - 60) < 1.0, true)
    }

    do {
        func d(words: Bool = false, line: Bool = false, ad: Bool = false,
               inst: Bool = false, noLyrics: Bool = false, netDown: Bool = false, content: Bool = false,
               playing: Bool = true) -> LyricsLineDisplay {
            LyricsLineDisplay.resolve(
                hasWordTiming: words, hasCurrentLine: line, isAdBreak: ad,
                isInstrumental: inst, hasNoLyrics: noLyrics, networkDown: netDown,
                hasLyricsContent: content, isPlaying: playing)
        }

        expectEqual(d(words: true, line: true, content: true), .words)
        expectEqual(d(line: true, content: true), .plain)
        expectEqual(d(), .searching)
        expectEqual(d(playing: false), .idle)
        expectEqual(d(line: true, content: true, playing: false), .plain)

        expectEqual(d(inst: true), .instrumental)
        expectEqual(d(ad: true), .adBreak)

        expectEqual(d(noLyrics: true, netDown: true), .noLyrics)
        expectEqual(d(netDown: true), .networkDown)

        expectEqual(d(words: true, line: true, ad: true, inst: true, noLyrics: true), .words)

        expectEqual(d(line: true, netDown: true, content: true), .plain)
    }

    do {

        let engine = LyricsSyncEngine()
        let lrc = "[00:01.00] hello world\n[00:05.00] second line\n[00:09.00] third line"
        expectEqual(engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: ""),
                    true)
        expectEqual(engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: ""),
                    false)
        expectEqual(engine.hasContent, true)
        expectEqual(engine.load(lyrics: lrc, lyricsTr: "[00:01.00] 译文", lyricsRoma: "", lyricsYRC: ""),
                    true)
        expectEqual(engine.load(lyrics: lrc, lyricsTr: "[00:01.00] 译文", lyricsRoma: "", lyricsYRC: "",
                                trackTitle: "另一首"),
                    true)

        let engine2 = LyricsSyncEngine()
        engine2.load(
            lyrics: "[00:01.00] alpha\n[00:10.00] beta\n[00:30.00] gamma",
            lyricsTr: "", lyricsRoma: "", lyricsYRC: "")

        for ms in [0, 500, 1_500, 9_999, 12_000, 20_000, 31_000, 2_000, 500, 31_000, 1_500] {
            let r = engine2.tickQuery(atMs: ms)
            expectEqual(r.line, engine2.activeLine(atMs: ms))
            expectEqual(r.nextText, engine2.upcomingLineText(afterMs: ms))
            expectEqual(r.index, engine2.activeLineIndex(atMs: ms))
            expectEqual(r.gapIndex, engine2.activeGapIndex(atMs: ms))
        }
        expectEqual(engine2.tickQuery(atMs: 1_500).line?.plainText, "alpha")
        expectEqual(engine2.tickQuery(atMs: 12_000).line?.plainText, "beta")
        expectEqual(engine2.tickQuery(atMs: 0).index, nil)

        let engine3 = LyricsSyncEngine()
        engine3.load(
            lyrics: "[00:01.00] main line",

            lyricsTr: "[00:00.30] early\n[00:01.70] late",
            lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine3.allLines(idPrefix: "t").first?.line.translation, "late")
        let engine4 = LyricsSyncEngine()
        engine4.load(
            lyrics: "[00:01.00] main line",
            lyricsTr: "[00:01.20] first\n[00:01.20] second",
            lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine4.allLines(idPrefix: "t").first?.line.translation, "second")
        let engine5 = LyricsSyncEngine()
        engine5.load(
            lyrics: "[00:01.00] main line",
            lyricsTr: "[00:02.50] too far",
            lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine5.allLines(idPrefix: "t").first?.line.translation, nil)

        let engineTag = LyricsSyncEngine()
        let tagYRC = "[121936,3302](121936,443,0)Crowds (122379,513,0)roaring (122892,173,0)fills (123065,485,0)the (123550,1688,0)atmosphere \n"
            + "[125676,178](125676,51,0)合(125727,127,0)：\n"
            + "[125856,6271](125856,967,0)Reminds (126823,275,0)me (127098,656,0)that (127754,733,0)games (128487,585,0)are (129072,794,0)more (129866,741,0)than (130607,1520,0)rules\n"
        engineTag.load(
            lyrics: "", lyricsTr: "[02:01.93]人群的咆哮充满了气氛\n[02:05.85]提醒我，游戏不仅仅是规则",
            lyricsRoma: "", lyricsYRC: tagYRC)
        let tagLines = engineTag.allLines(idPrefix: "t")

        expectEqual(tagLines.count, 2)
        expectEqual(tagLines[0].line.plainText, "Crowds roaring fills the atmosphere ")
        expectEqual(tagLines[1].line.plainText, "Reminds me that games are more than rules")
        expectEqual(tagLines[1].line.translation, "提醒我，游戏不仅仅是规则")

        expectEqual(tagLines[1].line.side, nil)

        let engineTaggedContent = LyricsSyncEngine()
        engineTaggedContent.load(
            lyrics: "[00:01.00]合：真的歌词内容", lyricsTr: "[00:01.20]真实的翻译",
            lyricsRoma: "", lyricsYRC: "")
        expectEqual(engineTaggedContent.allLines(idPrefix: "t").first?.line.translation, "真实的翻译")

        let engineDrift = LyricsSyncEngine()
        engineDrift.load(
            lyrics: "[00:01.00]drifted line",
            lyricsTr: "[00:01.00]漂移行的译文",
            lyricsRoma: "[00:01.00]piao yi hang de yi wen",
            lyricsYRC: "[3000,500](3000,300,0)drifted (3300,200,0)line")
        expectEqual(engineDrift.allLines(idPrefix: "t").first?.line.translation, "漂移行的译文")

        let engineParenStyle = LyricsSyncEngine()
        engineParenStyle.load(
            lyrics: "[02:55.60]U're so fine (U're so fine)",
            lyricsTr: "[02:55.60]你如此耀眼（你如此耀眼）",
            lyricsRoma: "",
            lyricsYRC: "[174240,1500](174240,300,0)U're (174540,300,0)so (174840,300,0)fine " +
                "(175140,300,0)（U're (175440,300,0)so (175740,300,0)fine）")
        expectEqual(engineParenStyle.allLines(idPrefix: "t").first?.line.translation, "你如此耀眼（你如此耀眼）")

        let engineCase = LyricsSyncEngine()
        engineCase.load(
            lyrics: "[00:01.00]U got the horn",
            lyricsTr: "[00:01.00]号角在手",
            lyricsRoma: "",
            lyricsYRC: "[3000,900](3000,300,0)u (3300,300,0)got (3600,300,0)the horn")
        expectEqual(engineCase.allLines(idPrefix: "t").first?.line.translation, "号角在手")

        let engineDriftNoMatch = LyricsSyncEngine()
        engineDriftNoMatch.load(
            lyrics: "[00:01.00]completely different text",
            lyricsTr: "[00:01.00]漂移行的译文",
            lyricsRoma: "", lyricsYRC: "[3000,500](3000,300,0)drifted (3300,200,0)line")
        expectEqual(engineDriftNoMatch.allLines(idPrefix: "t").first?.line.translation, nil)

        let wordLine = SyncedLyricLine(
            romanization: nil, translation: nil, mainText: nil,
            words: [SyncedLyricWord(text: "ab", startMs: 0, durationMs: 100),
                    SyncedLyricWord(text: "cd", startMs: 100, durationMs: 100)],
            wordGroups: nil, side: nil)
        expectEqual(wordLine.plainText, "abcd")
        let mainLine2 = SyncedLyricLine(
            romanization: nil, translation: nil, mainText: "hello",
            words: nil, wordGroups: nil, side: nil)
        expectEqual(mainLine2.plainText, "hello")

        for text in ["今はまだ悲しい", "受話器を取った君", "明日の朝"] {
            let viaSegments = Romanizer.readingFromSegments(
                Romanizer.japaneseSegments(text), original: text)
            expectEqual(viaSegments, Romanizer.romanize(text, japanese: true))
        }

        let sizes = [CGSize(width: 40, height: 10), CGSize(width: 40, height: 12),
                     CGSize(width: 40, height: 10), CGSize(width: 90, height: 10)]
        let rows = WrapLayoutMath.rows(sizes: sizes, maxWidth: 100, horizontalSpacing: 2)
        expectEqual(
            WrapLayoutMath.totalSize(rows: rows, maxWidth: 100, verticalSpacing: 3),
            WrapLayoutMath.totalSize(sizes: sizes, maxWidth: 100, horizontalSpacing: 2, verticalSpacing: 3))
        expectEqual(
            WrapLayoutMath.placements(rows: rows, sizes: sizes,
                                      bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      horizontalSpacing: 2, verticalSpacing: 3, rowAlignment: .center),
            WrapLayoutMath.placements(sizes: sizes,
                                      bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      horizontalSpacing: 2, verticalSpacing: 3, rowAlignment: .center))

        let engineDup = LyricsSyncEngine()
        engineDup.load(
            lyrics: "",
            lyricsTr: "", lyricsRoma: "",
            lyricsYRC: "[10000,2000](10000,500,0)い(10500,500,0)つ(11000,500,0)か\n"
                + "[30000,2000](30000,500,0)い(30500,500,0)つ(31000,500,0)か")
        let dupLines = engineDup.allLines(idPrefix: "dup")
        expectEqual(dupLines.count, 2)
        expectEqual(dupLines.first?.line.wordGroups?.first?.startMs, 10000)
        expectEqual(dupLines.last?.line.wordGroups?.first?.startMs, 30000)

        expectEqual(MediaControlClient.parseTimestamp("2026-08-20T10:00:00Z") != nil, true)
        expectEqual(MediaControlClient.parseTimestamp("2026-08-20T10:00:00.123Z") != nil, true)
        expectEqual(MediaControlClient.parseTimestamp("not a date"), nil)
        expectEqual(MediaControlClient.parseTimestamp(nil), nil)
        expectEqual(MediaControlClient.parseTimestamp("2026-08-20T10:00:00Z"),
                    MediaControlClient.parseTimestamp("2026-08-20T10:00:00.000Z"))

        expectEqual(KaraokeFill.stops(left: 1.2, right: 1.4), KaraokeFill.allSungStops)
        expectEqual(KaraokeFill.stops(left: -0.4, right: -0.2), KaraokeFill.allUnsungStops)
        let w = SyncedLyricWord(text: "x", startMs: 1000, durationMs: 40)
        expectEqual(KaraokeFill.fillFraction(for: w, atMs: 1040),
                    KaraokeFill.fillFraction(startMs: 1000, durationMs: 40, atMs: 1040))
    }

    do {
        let engine = LyricsSyncEngine()

        engine.load(
            lyrics: """
            [00:01.00]男：
            [00:02.00]All night
            [00:03.00]女：
            [00:04.00]U got to dance all night
            [00:05.00]男：
            [00:06.00]All night yeah
            """,
            lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        let onFirstMale = engine.tickQuery(atMs: 2_500)
        expectEqual(onFirstMale.line?.plainText, "All night")
        expectEqual(onFirstMale.line?.side, .leading)
        expectEqual(onFirstMale.nextText, "U got to dance all night")
        expectEqual(onFirstMale.nextSide, .trailing)
        expectNotEqual(onFirstMale.line?.side, onFirstMale.nextSide)

        let onSecondMale = engine.tickQuery(atMs: 6_500)
        expectEqual(onSecondMale.line?.plainText, "All night yeah")
        expectEqual(onSecondMale.line?.side, .leading)
        expectEqual(onSecondMale.nextSide, nil)

        expectEqual(engine.upcomingLineText(afterMs: 2_500), onFirstMale.nextText)
    }

    do {
        typealias L = CompactLyricLead
        let reveal = L.revealMs

        expectEqual(L.resolve(activeIdx: 3, posMs: 9_000, lineEndMs: 10_000, nextStartMs: 12_000),
                    .line(3))

        expectEqual(L.resolve(activeIdx: 3, posMs: 10_000, lineEndMs: 10_000, nextStartMs: 12_000),
                    .line(4))
        expectEqual(L.resolve(activeIdx: 3, posMs: 9_999, lineEndMs: 10_000, nextStartMs: 12_000),
                    .line(3))

        expectEqual(L.resolve(activeIdx: 3, posMs: 10_000, lineEndMs: 10_000, nextStartMs: 40_000),
                    .placeholder)
        expectEqual(L.resolve(activeIdx: 3, posMs: 40_000 - reveal - 1, lineEndMs: 10_000, nextStartMs: 40_000),
                    .placeholder)
        expectEqual(L.resolve(activeIdx: 3, posMs: 40_000 - reveal, lineEndMs: 10_000, nextStartMs: 40_000),
                    .line(4))

        expectEqual(L.resolve(activeIdx: 3, posMs: 30_000, lineEndMs: nil, nextStartMs: 40_000),
                    .line(3))

        expectEqual(L.resolve(activeIdx: 9, posMs: 99_000, lineEndMs: 10_000, nextStartMs: nil),
                    .line(9))

        expectEqual(L.resolve(activeIdx: -1, posMs: 500, lineEndMs: nil, nextStartMs: 3_000),
                    .line(-1))

        expectEqual(L.displayDurationMs(prevLineEndMs: 8_000, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: 40_000, fallbackEndMs: nil),
                    5_000)

        expectEqual(L.displayDurationMs(prevLineEndMs: 9_800, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: 14_000, fallbackEndMs: nil),
                    3_200)

        expectEqual(L.displayDurationMs(prevLineEndMs: 2_000, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: 14_000, fallbackEndMs: nil),
                    8_000)

        expectEqual(L.displayDurationMs(prevLineEndMs: 11_000, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: 14_000, fallbackEndMs: nil),
                    3_000)

        expectEqual(L.displayDurationMs(prevLineEndMs: nil, startMs: 10_000,
                                        lineEndMs: nil, nextStartMs: 14_000, fallbackEndMs: nil),
                    4_000)

        expectEqual(L.displayDurationMs(prevLineEndMs: 9_000, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: nil, fallbackEndMs: nil),
                    nil)
        expectEqual(L.displayDurationMs(prevLineEndMs: 9_000, startMs: 10_000,
                                        lineEndMs: 13_000, nextStartMs: nil, fallbackEndMs: 30_000),
                    21_000)

        expectEqual(L.leadInMs(prevLineEndMs: 8_000, startMs: 10_000), 2_000)
        expectEqual(L.leadInMs(prevLineEndMs: 9_800, startMs: 10_000), 200)
        expectEqual(L.leadInMs(prevLineEndMs: 2_000, startMs: 10_000), reveal)
        expectEqual(L.leadInMs(prevLineEndMs: 11_000, startMs: 10_000), 0)
        expectEqual(L.leadInMs(prevLineEndMs: nil, startMs: 10_000), 0)

        for (prevEnd, start, end) in [(8_000, 10_000, 13_000), (9_800, 10_000, 13_000),
                                      (2_000, 10_000, 13_000), (11_000, 10_000, 13_000)] {
            let window = L.displayDurationMs(prevLineEndMs: prevEnd, startMs: start,
                                             lineEndMs: end, nextStartMs: 40_000, fallbackEndMs: nil)
            expectEqual(L.leadInMs(prevLineEndMs: prevEnd, startMs: start) + (end - start), window)
        }
    }

    do {

        let yrc = "[10000,1000](10000,500,0)aa (10500,500,0)bb \n"
            + "[13000,1000](13000,500,0)cc (13500,500,0)dd \n"
            + "[30000,1000](30000,500,0)ee (30500,500,0)ff \n"
        let engine = LyricsSyncEngine()
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)

        let singing = engine.tickQuery(atMs: 10_500)
        expectEqual(singing.compactLine?.plainText, "aa bb ")
        expectEqual(singing.compactLeadInMs, 0)

        let lead = engine.tickQuery(atMs: 11_500)
        expectEqual(lead.compactLine?.plainText, "cc dd ")
        expectEqual(lead.compactLeadInMs, 2_000)

        expectEqual(engine.tickQuery(atMs: 12_999).compactLeadInMs, 2_000)

        expectEqual(lead.compactDwellMs, 3_000)

        let idle = engine.tickQuery(atMs: 20_000)
        expectEqual(idle.compactLine == nil && idle.compactPlaceholder, true)
        expectEqual(idle.compactLeadInMs, nil)

        let capped = engine.tickQuery(atMs: 26_000)
        expectEqual(capped.compactLine?.plainText, "ee ff ")
        expectEqual(capped.compactLeadInMs, CompactLyricLead.revealMs)

        let last = engine.tickQuery(atMs: 26_000, trackEndMs: 40_000)
        let lastSinging = engine.tickQuery(atMs: 30_500, trackEndMs: 40_000)

        expectEqual(last.compactDwellMs, 15_000)
        expectEqual(lastSinging.compactDwellMs, last.compactDwellMs)
        expectEqual(lastSinging.compactLeadInMs, last.compactLeadInMs)

        expectEqual(engine.tickQuery(atMs: 26_000).compactDwellMs, nil)

        expectEqual(engine.tickQuery(atMs: 11_500, trackEndMs: 40_000).compactDwellMs, 3_000)

        let lineLevel = LyricsSyncEngine()
        lineLevel.load(lyrics: "[00:10.00]aabb\n[00:13.00]ccdd\n", lyricsTr: "", lyricsRoma: "",
                       lyricsYRC: "")
        let lrcTick = lineLevel.tickQuery(atMs: 11_500)
        expectEqual(lrcTick.compactLine?.plainText, "aabb")
        expectEqual(lrcTick.compactLeadInMs, 0)
    }

    do {
        print("\n== 整行压平 ==")
        let engine = LyricsSyncEngine()
        let yrc = "[1000,2000](1000,1000,0)君 (2000,1000,0)へ \n"
        engine.load(lyrics: "", lyricsTr: "[00:01.00]给你", lyricsRoma: "", lyricsYRC: yrc,
                    romanizationScripts: [.japanese])
        guard let word = engine.activeLine(atMs: 1500) else {
            expectEqual(false, true); return
        }
        expectEqual(word.words?.isEmpty, false)
        let flat = word.lineLevel
        expectEqual(flat.words == nil, true)
        expectEqual(flat.wordGroups == nil, true)
        expectEqual(flat.mainText, word.plainText)
        expectEqual(flat.plainText, word.plainText)
        expectEqual(flat.translation, word.translation)
        expectEqual(flat.romanization != nil || word.romanization == nil, true)
        expectEqual(flat.side, word.side)
        expectEqual(flat.lineLevel, flat)

        let plain = SyncedLyricLine(romanization: nil, translation: "t", mainText: "aabb", words: nil, wordGroups: nil, side: nil)
        expectEqual(plain.lineLevel, plain)
    }

    do {
        print("\n== 快速拖动与边界用例 ==")
        let engine = LyricsSyncEngine()
        let yrc = """
        [1000,4000](1000,1000,0)春 (2000,1000,0)が (3000,2000,0)来た
        [8000,4000](8000,1000,0)夏 (9000,1000,0)が (10000,2000,0)来た
        [15000,5000](15000,2000,0)秋 (17000,3000,0)風
        """
        engine.load(lyrics: "[00:01.00]春が来た\n[00:08.00]夏が来た\n[00:15.00]秋風\n",
                    lyricsTr: "[00:01.00]春天来了\n[00:08.00]夏天来了\n[00:15.00]秋风\n",
                    lyricsRoma: "", lyricsYRC: yrc,
                    trackTitle: "四季", trackArtist: "歌手",
                    romanizationScripts: [.japanese])

        let all = engine.allLines(idPrefix: "yrc-test")
        expectEqual(all.count, 3)
        expectEqual(engine.cachedLinesCount, 3)

        let r1 = engine.tickQuery(atMs: 2500)
        expectEqual(r1.index, 0)
        expectEqual(r1.line?.plainText, "春 が 来た")
        expectEqual(r1.line?.translation, "春天来了")

        let r2 = engine.tickQuery(atMs: 16000)
        expectEqual(r2.index, 2)
        expectEqual(r2.line?.plainText, "秋 風")

        let r3 = engine.tickQuery(atMs: 500)
        expectEqual(r3.index, nil)
        expectEqual(r3.line, nil)
        expectEqual(r3.compactLine, nil)
        expectEqual(engine.upcomingLineText(afterMs: 500), "春 が 来た")

        let r4 = engine.tickQuery(atMs: 50000)
        expectEqual(r4.index, 2)

        let emptyEngine = LyricsSyncEngine()
        let metadataOnlyLrc = "[ti:纯音乐]\n[ar:无人]\n[al:空]\n[by:lyrimuse]\n"
        emptyEngine.load(lyrics: metadataOnlyLrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                         trackTitle: "纯音乐", trackArtist: "无人")
        expectEqual(emptyEngine.hasContent, false)
        expectEqual(emptyEngine.allLines(idPrefix: "inst").isEmpty, true)
        let instTick = emptyEngine.tickQuery(atMs: 10000)
        expectEqual(instTick.index, nil)
        expectEqual(instTick.line, nil)
        expectEqual(instTick.compactLine, nil)

        let oldLine = engine.activeLine(atMs: 2500)
        engine.load(lyrics: "[00:02.00]新歌曲第一行\n", lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                    trackTitle: "新歌", trackArtist: "新歌手")
        let newLine = engine.activeLine(atMs: 2500)
        expectEqual(newLine?.plainText, "新歌曲第一行")
        expectEqual(oldLine?.plainText != newLine?.plainText, true)

        expectEqual(engine.currentLine(at: 2500)?.plainText, engine.activeLine(atMs: 2500)?.plainText)
    }
}
