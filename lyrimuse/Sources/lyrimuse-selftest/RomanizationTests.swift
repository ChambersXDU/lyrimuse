import LyrimuseCore
import Foundation

@MainActor
func runRomanizationTests() {

    expectEqual(Romanizer.romanize(""), nil)
    expectEqual(Romanizer.romanize("hello"), nil)
    expectEqual(Romanizer.romanize("你好") != nil, true)

    expectEqual(Romanizer.looksJapanese("你好"), false)
    expectEqual(Romanizer.looksJapanese("こんにちは"), true)
    expectEqual(Romanizer.looksJapanese("トマト"), true)
    expectEqual(Romanizer.containsHan("你好"), true)
    expectEqual(Romanizer.containsHan("こんにちは"), false)

    do {

        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]你好\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 10000)?.romanization != nil, true)

        let engineOff = LyricsSyncEngine()
        engineOff.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                       romanizationScripts: [.japanese, .korean, .cantonese])
        expectEqual(engineOff.activeLine(atMs: 10000)?.romanization, nil)
    }

    do {

        let engine = LyricsSyncEngine()
        let lrc = "[00:05.00]のの\n[00:10.00]早安\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 10000)?.romanization != nil, true)
    }

    do {
        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]你好\n"

        let roma = "[00:20.00]别的行的罗马音\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: roma, lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 10000)?.romanization, nil)
    }

    do {
        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]副歌歌词\n[00:20.00]桥段歌词\n[00:30.00]副歌歌词\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLineIndex(atMs: 15000), 0)
        expectEqual(engine.activeLineIndex(atMs: 35000), 2)
        expectEqual(engine.activeLineIndex(atMs: 5000), nil)
    }

    do {
        let engine = LyricsSyncEngine()
        let yrc = "[10000,1000](10000,500,0)la (10500,500,0)la \n[20000,1000](20000,500,0)la (20500,500,0)la \n"
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
        let lines = engine.allLines(idPrefix: "test")
        expectEqual(lines.count, 2)
        expectEqual(lines.map { $0.line.words?.map(\.text) }, [["la ", "la "], ["la ", "la "]])
        expectEqual(engine.activeLineIndex(atMs: 20500), 1)
    }

    do {
        typealias H = HanScript
        let t = H.siblingPair(artist: "方大同", title: "我不是農人")
        expectEqual(t?.artist ?? "", "方大同")
        expectEqual(t?.title ?? "", "我不是农人")
        let s = H.siblingPair(artist: "方大同", title: "我不是农人")
        expectEqual(s?.title ?? "", "我不是農人")
        let a = H.siblingPair(artist: "陳奕迅", title: "富士山下")
        expectEqual(a?.artist ?? "", "陈奕迅")
        expectEqual(a?.title ?? "", "富士山下")
        expectEqual(H.siblingPair(artist: "Taylor Swift", title: "Style") == nil, true)
        expectEqual(H.sibling("方大同|我不是農人") ?? "", "方大同|我不是农人")
    }

    expectEqual(
        Romanizer.romanize("火曜日の朝は", japanese: true)?.contains("kayou") ?? false, true)
    expectEqual(
        Romanizer.romanize("火曜日の朝は", japanese: true)?.contains("huǒ") ?? true, false)
    expectEqual(
        Romanizer.romanize("君のことが好きだから", japanese: true), "kimi no koto ga suki da kara")

    expectEqual(
        Romanizer.romanize("取った", japanese: true)?.contains("~tsu") ?? true, false)
    expectEqual(
        Romanizer.romanize("取った", japanese: true), "totta")

    expectEqual(
        Romanizer.romanize("사랑해") != nil, true)

    expectEqual(
        Romanizer.romanize("Baby I love you", japanese: true), nil)

    do {

        let one = Romanizer.koreanSegments("안녕하세요", romanization: "annyeonghaseyo")
        expectEqual(one?.count, 1)
        expectEqual(one?.first?.latin, "annyeonghaseyo")
        expectEqual(one?.first?.utf16Start, 0)
        expectEqual(one?.first?.utf16Length, "안녕하세요".utf16.count)

        let three = Romanizer.koreanSegments("나는 너를 사랑해", romanization: "naneun neoleul salanghae")
        expectEqual(three?.map(\.latin), ["naneun", "neoleul", "salanghae"])

        expectEqual(
            Romanizer.koreanSegments("나는 너를 사랑해", romanization: "naneun salanghae") == nil,
            true)
        expectEqual(Romanizer.koreanSegments("", romanization: "") == nil, true)
    }

    do {
        func w(_ t: String, _ s: Int, _ d: Int) -> SyncedLyricWord {
            SyncedLyricWord(text: t, startMs: s, durationMs: d)
        }

        let words = [w("い", 0, 100), w("つ", 100, 100), w("か", 200, 100),
                     w("誰", 300, 100), w("か", 400, 100)]
        let groups = LyricsSyncEngine.buildWordGroups(
            words: words, line: "いつか誰か", japanese: true)
        expectEqual(groups != nil, true)
        if let groups {

            let flat = groups.flatMap { g in g.words.map { $0.text } }.joined()
            expectEqual(flat, "いつか誰か")
            expectEqual(groups.contains { $0.words.count > 1 }, true)
            expectEqual(groups.contains { ($0.romanization ?? "").isEmpty == false }, true)

            for g in groups {
                expectEqual(g.endMs >= g.startMs, true)
            }
        }

        expectEqual(
            LyricsSyncEngine.buildWordGroups(
                words: [w("我", 0, 100), w("爱", 100, 100)], line: "我爱", japanese: false) == nil,
            true)

        let yueWords = [w("你", 0, 300), w("好", 300, 300)]
        let yueGroups = LyricsSyncEngine.buildWordGroups(
            words: yueWords, line: "你好", japanese: false, hanRomanization: "nei5 hou2")
        expectEqual(yueGroups?.count, 2)
        expectEqual(yueGroups?.map(\.romanization), ["nei5", "hou2"])
        expectEqual(yueGroups?.allSatisfy { $0.words.count == 1 } ?? false, true)

        expectEqual(
            LyricsSyncEngine.buildWordGroups(
                words: [w("你", 0, 300), w("好", 300, 300), w("！", 600, 100)],
                line: "你好！", japanese: false, hanRomanization: "nei5 hou2") == nil,
            true)

        let jaWords2 = [w("こ", 0, 100), w("ん", 100, 100)]
        let jaWithHan = LyricsSyncEngine.buildWordGroups(
            words: jaWords2, line: "こん", japanese: true, hanRomanization: "wrong wrong")
        expectEqual(jaWithHan?.first?.romanization != "wrong", true)

        let koWords = [w("나", 0, 150), w("는", 150, 150), w(" ", 300, 0),
                       w("너", 300, 150), w("를", 450, 150)]
        let koGroups = LyricsSyncEngine.buildWordGroups(
            words: koWords, line: "나는 너를", japanese: false, koreanRomanization: "naneun neoleul")
        expectEqual(koGroups != nil, true)
        if let koGroups {
            let flat = koGroups.flatMap { g in g.words.map(\.text) }.joined()
            expectEqual(flat, "나는 너를")
            expectEqual(koGroups.contains { $0.words.count > 1 }, true)
            expectEqual(koGroups.map { $0.romanization }.compactMap { $0 },
                        ["naneun", "neoleul"])
        }

        expectEqual(
            LyricsSyncEngine.buildWordGroups(
                words: [w("나", 0, 150), w("는", 150, 150)],
                line: "나는", japanese: false, koreanRomanization: "naneun neoleul") == nil,
            true)
    }

    do {
        let cases: [(String, String, String)] = [
            ("今はまだ悲しい", "wa", "は 作助词该读 wa"),
            ("明日の今頃には", "wa", "には 里的 は 同样是助词"),
            ("本を読む", "o", "を 作助词该读 o(不是 wo)"),
            ("海へ行く", "e", "へ 作助词该读 e(不是 he)"),
        ]
        for (text, expect, _) in cases {
            let roma = Romanizer.romanize(text, japanese: true) ?? ""
            expectEqual(roma.split(separator: " ").contains(Substring(expect)), true)
        }

        let anata = Romanizer.romanize("あなたはどこ", japanese: true) ?? ""
        expectEqual(anata.contains("anata"), true)
        expectEqual(anata.split(separator: " ").contains("wa"), true)

        let konnichiwa = Romanizer.romanize("こんにちは", japanese: true) ?? ""
        expectEqual(konnichiwa, "konnichiwa")
    }

    do {

        let lrc = "[00:43.12]明日の今頃には\n[kana:2あした1いま1ごろ]"
        let ann = KanaAnnotation.parse(lrc: lrc)
        expectEqual(ann != nil, true)
        let marks = ann?.marks(forLine: "明日の今頃には") ?? []
        expectEqual(marks.count, 3)
        expectEqual(marks.first?.reading ?? "", "あした")
        expectEqual(marks.first?.utf16Length ?? 0, 2)

        let roma = Romanizer.romanize("明日の今頃には", japanese: true, marks: marks) ?? ""
        expectEqual(roma.contains("ashita"), true)
        expectEqual(roma.contains("asu"), false)
        expectEqual(roma.split(separator: " ").contains("wa"), true)

        let plain = Romanizer.romanize("明日の今頃には", japanese: true) ?? ""
        expectEqual(plain.isEmpty, false)

        let bad = KanaAnnotation.parse(lrc: "[00:43.12]明日の今頃には\n[kana:2あした]")
        expectEqual(bad == nil, true)

        expectEqual(KanaAnnotation.needsAnnotation("々"), true)
        expectEqual(KanaAnnotation.needsAnnotation("明"), true)
        expectEqual(KanaAnnotation.needsAnnotation("の"), false)
    }

    do {
        let lrc = """
        [00:00.00]First Love - 宇多田光 (宇多田ヒカル)
        [00:03.31]词：宇多田ヒカル
        [00:10.18]Strings Arrange：河野圭
        [00:11.84]Keyboards Programming：河野圭
        [00:17.53]Guitar：秋山浩徳
        [00:21.89]最後のキスは
        [00:26.89]タバコのflavorがした
        [00:32.17]ニガくてせつない香り
        [00:43.12]明日の今頃には
        """
        let engine = LyricsSyncEngine()
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                    trackTitle: "First Love (Remastered 2014)", trackArtist: "宇多田ヒカル")
        let shown = engine.allLines(idPrefix: "t").compactMap { $0.line.plainText }
        expectEqual(shown.count, 4)
        expectEqual(shown.first ?? "", "最後のキスは")
        for bad in ["Guitar", "Strings Arrange", "Keyboards", "词：", "First Love - "] {
            expectEqual(shown.contains { $0.contains(bad) }, false)
        }

        expectEqual(LyricsSyncEngine.looksLikeHeaderLine(
            "First Love", trackTitle: "First Love", trackArtist: "宇多田ヒカル"), false)
        let plain = """
        [00:01.00]Verse 1: here we go
        [00:02.00]I said: let's go
        [00:03.00]Baby you know
        """
        let e2 = LyricsSyncEngine()
        e2.load(lyrics: plain, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(e2.allLines(idPrefix: "t").count, 3)
    }

    do {
        expectEqual(ChineseVariant.traditional.converted("这是一首简单的小情歌"),
                    "這是一首簡單的小情歌")
        expectEqual(ChineseVariant.simplified.converted("這是一首簡單的小情歌"),
                    "这是一首简单的小情歌")
        expectEqual(ChineseVariant.off.converted("这是一首简单的小情歌"),
                    "这是一首简单的小情歌")

        let jp = "明日の今頃には"
        expectEqual(ChineseVariant.traditional.converted(jp), jp)
        let jp2 = "新しい歌 うたえるまで"
        expectEqual(ChineseVariant.traditional.converted(jp2), jp2)

        expectEqual(ChineseVariant.traditional.converted("头发"), "頭髮")
        expectEqual(ChineseVariant.traditional.converted("只有你"), "只有你")

        expectEqual(ChineseVariant.traditional.converted("First Love"), "First Love")

    expectEqual(LyricsSyncEngine.matchesPromoCreditLine("网易云音乐特别企划“星辰集”出品"), true)
    expectEqual(LyricsSyncEngine.matchesPromoCreditLine("索尼唱片出版"), true)
    expectEqual(LyricsSyncEngine.matchesPromoCreditLine("网易云音乐特别企划“星辰集”出品。"), true)
    for real in ["下一页结局已经慢慢呈现", "少一点 完美的呈现", "机械的唇语不太够呈现",
                 "让你画面一直呈现", "发光的立体呈现", "发光的 立体呈现"] {
        expectEqual(LyricsSyncEngine.matchesPromoCreditLine(real), false)
    }

    expectEqual(LyricsSyncEngine.matchesPromoCreditLine("出品方：众乐纪"), false)

    expectEqual(LyricsSyncEngine.matchesPromoCreditLine("你最爱听的唱片"), false)

    expectEqual(ChineseVariant.affects("这是一首简单的小情歌"), true)
        expectEqual(ChineseVariant.affects("First Love"), false)
        expectEqual(ChineseVariant.affects(""), false)
        expectEqual(ChineseVariant.affects("君の名は"), false)

        expectEqual(ChineseVariant.affects("사랑 头发 노래"), true)

        expectEqual(ChineseVariant.traditional.converted("사랑 头发 노래"), "사랑 頭髮 노래")

        for sample in ["这是一首简单的小情歌", "First Love", "君の名は", "사랑 头发 노래",
                       "头发", "漢字", ""] {
            if !ChineseVariant.affects(sample) {
                expectEqual(ChineseVariant.traditional.converted(sample), sample)
                expectEqual(ChineseVariant.simplified.converted(sample), sample)
            }
        }

        typealias CV = LocalPlaybackSource
        let jpLine = "これは夢かもしれない 深く霧の立ちこめた場所で"
        let cnTr = "这可能是一场梦，在雾气弥漫的地方"
        expectEqual(CV.supportsChineseVariant(lyrics: jpLine, translation: cnTr,
                                              translationVisible: false), false)
        expectEqual(CV.supportsChineseVariant(lyrics: jpLine, translation: cnTr,
                                              translationVisible: true), true)
        expectEqual(CV.supportsChineseVariant(lyrics: jpLine, translation: "",
                                              translationVisible: true), false)

        for visible in [true, false] {
            expectEqual(CV.supportsChineseVariant(lyrics: "这是一首简单的小情歌",
                                                  translation: "", translationVisible: visible),
                        true)
        }

        expectEqual(CV.supportsChineseVariant(lyrics: "사랑 头发 노래", translation: "",
                                              translationVisible: false), true)
        expectEqual(CV.supportsChineseVariant(lyrics: "", translation: "",
                                              translationVisible: true), false)

        for (lyrics, tr, visible) in [(jpLine, cnTr, false), (jpLine, cnTr, true),
                                      ("这是一首简单的小情歌", "", false), (jpLine, "", true)] {
            let shown = CV.supportsChineseVariant(lyrics: lyrics, translation: tr,
                                                  translationVisible: visible)
            let visiblyChanges =
                ChineseVariant.traditional.converted(lyrics) != lyrics
                || (visible && ChineseVariant.traditional.converted(tr) != tr)
            expectEqual(shown, visiblyChanges)
        }
    }

    do {
        print("\n== 配置文件名识别(iCloud 换机链路) ==")
        typealias N = ConfigSnapshotName
        let real = "Lyrimuse-Config-2026-08-10-164500.json"
        expectEqual(N.realName(ofDirectoryEntry: real), real)

        expectEqual(N.realName(ofDirectoryEntry: ".\(real).icloud"), real)
        expectEqual(N.realName(ofDirectoryEntry: "Lyrimuse-Config-x.txt"), nil)
        expectEqual(N.realName(ofDirectoryEntry: "other.json"), nil)
        expectEqual(N.realName(ofDirectoryEntry: ".hidden.json"), nil)
        expectEqual(N.realName(ofDirectoryEntry: "Lyrimuse-Config-.json"), nil)
    }

    do {

        print("\n== iCloud 备份能不能直接读(换机链路的另一半) ==")
        typealias R = ICloudFileReadiness
        expectEqual(R.isReadyToRead(downloadingStatus: .current, realPathExists: true), true)
        expectEqual(R.isReadyToRead(downloadingStatus: .notDownloaded, realPathExists: true), false)
        expectEqual(R.isReadyToRead(downloadingStatus: .downloaded, realPathExists: true), false)

        expectEqual(R.isReadyToRead(downloadingStatus: nil, realPathExists: false), false)
        expectEqual(R.isReadyToRead(downloadingStatus: nil, realPathExists: true), true)
    }

    do {

        expectEqual(Romanizer.script(of: "こんにちは"), .japanese)
        expectEqual(Romanizer.script(of: "안녕하세요"), .korean)
        expectEqual(Romanizer.script(of: "你对我笑一次"), .chinese)
        expectEqual(Romanizer.script(of: "Hello world"), .other)

        expectEqual(Romanizer.script(of: "受話器を取った君"), .japanese)

        expectEqual(Romanizer.script(of: "그대 漢字"), .korean)

        expectEqual(RomanizationScripts.default.contains(.japanese), true)
        expectEqual(RomanizationScripts.default.contains(.korean), true)
        expectEqual(RomanizationScripts.default.contains(.chinese), true)
        expectEqual(RomanizationScripts.default.contains(.cantonese), true)

        func romanization(
            lyrics: String, roma: String, scripts: RomanizationScripts
        ) -> String? {
            let engine = LyricsSyncEngine()
            engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: roma, lyricsYRC: "",
                        romanizationScripts: scripts)
            return engine.activeLine(atMs: 1000)?.romanization
        }

        let jaLyrics = "[00:01.00]こんにちは"
        expectEqual(romanization(lyrics: jaLyrics, roma: "", scripts: [.japanese]) != nil, true)
        expectEqual(romanization(lyrics: jaLyrics, roma: "", scripts: [.korean, .chinese]), nil)

        let zhLyrics = "[00:01.00]你对我笑一次"
        let zhRoma = "[00:01.00]ni dui wo xiao yi ci"
        expectEqual(romanization(lyrics: zhLyrics, roma: zhRoma, scripts: [.chinese]),
                    "ni dui wo xiao yi ci")
        expectEqual(romanization(lyrics: zhLyrics, roma: zhRoma, scripts: [.japanese, .korean]), nil)

        let zhFallback = romanization(lyrics: zhLyrics, roma: "", scripts: [.chinese])
        expectEqual(zhFallback != nil, true)
        expectEqual(romanization(lyrics: zhLyrics, roma: "", scripts: [.japanese]), nil)

        expectEqual(romanization(lyrics: zhLyrics, roma: zhRoma, scripts: .default),
                    "ni dui wo xiao yi ci")

        expectEqual(romanization(lyrics: zhLyrics, roma: zhRoma, scripts: [.japanese, .korean, .cantonese]),
                    nil)

        let koLyrics = "[00:01.00]안녕하세요"
        expectEqual(romanization(lyrics: koLyrics, roma: "", scripts: [.korean]) != nil, true)
        expectEqual(romanization(lyrics: koLyrics, roma: "", scripts: [.japanese]), nil)

        expectEqual(romanization(lyrics: "[00:01.00]Hello", roma: "", scripts: []), nil)
        expectEqual(romanization(lyrics: "[00:01.00]Hello", roma: "[00:01.00]Hello", scripts: []),
                    "Hello")

        expectEqual(Romanizer.kanaLineRatio("你好\n世界"), 0)
        expectEqual(Romanizer.kanaLineRatio("你好\nサヨナラ\n世界\n再见"), 0.25)

        expectEqual(Romanizer.kanaLineRatio("你好\n\n   \nサヨナラ"), 0.5)
        expectEqual(Romanizer.kanaLineRatio(""), 0)

        let zhWithJa = (Array(repeating: "就从明天开始吧", count: 72) + Array(repeating: "サヨナラ", count: 3))
            .joined(separator: "\n")
        expectEqual(Romanizer.looksJapanese(zhWithJa), true)
        expectEqual(Romanizer.looksJapaneseSong(zhWithJa), false)
        expectEqual(Romanizer.songScript(of: zhWithJa), .chinese)

        let mixed = (Array(repeating: "我的あなた", count: 18) + Array(repeating: "你对我笑一次", count: 26))
            .joined(separator: "\n")
        expectEqual(Romanizer.looksJapaneseSong(mixed), false)

        let jaSong = Array(repeating: "こんにちは世界", count: 30).joined(separator: "\n")
        expectEqual(Romanizer.looksJapaneseSong(jaSong), true)
        expectEqual(Romanizer.songScript(of: jaSong), .japanese)

        expectEqual(Romanizer.script(ofLine: "サヨナラ", song: .chinese), .japanese)
        expectEqual(Romanizer.script(ofLine: "就从明天开始吧", song: .chinese), .chinese)
        expectEqual(Romanizer.script(ofLine: "明日", song: .japanese), .japanese)
        expectEqual(Romanizer.script(ofLine: "안녕", song: .japanese), .korean)
        expectEqual(Romanizer.script(ofLine: "Hello", song: .japanese), .other)

        expectEqual(Romanizer.script(ofLine: "你好", song: .cantonese), .cantonese)
        expectEqual(Romanizer.script(ofLine: "サヨナラ", song: .cantonese), .japanese)

        func romanizationAt(
            _ ms: Int, lyrics: String, scripts: RomanizationScripts, isCantonese: Bool = false
        ) -> String? {
            let engine = LyricsSyncEngine()
            engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                        romanizationScripts: scripts, songIsCantonese: isCantonese)
            return engine.activeLine(atMs: ms)?.romanization
        }

        var songLines: [String] = []
        for i in 0..<24 {
            songLines.append(String(format: "[%02d:%02d.00]就从明天开始吧", i / 60, i % 60))
        }
        songLines.append("[00:30.00]サヨナラ")
        let zhSongWithJa = songLines.joined(separator: "\n")

        expectEqual(romanizationAt(1_000, lyrics: zhSongWithJa, scripts: [.japanese, .korean]), nil)

        let jaLineRoma = romanizationAt(30_000, lyrics: zhSongWithJa, scripts: [.japanese, .korean])
        expectEqual(jaLineRoma != nil, true)
        expectEqual(jaLineRoma?.contains("sayonara") ?? false, true)

        let zhLineRoma = romanizationAt(1_000, lyrics: zhSongWithJa,
                                        scripts: [.japanese, .korean, .chinese])
        expectEqual(zhLineRoma?.contains("mei") ?? true, false)
        expectEqual(zhLineRoma?.contains("m\u{00ED}ng") ?? false, true)

        let yueLyrics = "[00:01.00]你好"
        let yueRoma = "[00:01.00]nei5 hou2"

        expectEqual(romanization(lyrics: yueLyrics, roma: yueRoma, scripts: [.cantonese]), nil)
        func yueRomanization(scripts: RomanizationScripts, isCantonese: Bool) -> String? {
            let engine = LyricsSyncEngine()
            engine.load(lyrics: yueLyrics, lyricsTr: "", lyricsRoma: yueRoma, lyricsYRC: "",
                        romanizationScripts: scripts, songIsCantonese: isCantonese)
            return engine.activeLine(atMs: 1_000)?.romanization
        }
        expectEqual(yueRomanization(scripts: [.cantonese], isCantonese: true), "nei5 hou2")

        expectEqual(yueRomanization(scripts: [.chinese], isCantonese: true), nil)

        expectEqual(yueRomanization(scripts: [.cantonese], isCantonese: false), nil)
        expectEqual(yueRomanization(scripts: [.chinese], isCantonese: false), "nei5 hou2")

        do {
            let yueYRC = "[0,1000](0,500,0)你 (500,500,0)好 \n"
            let yueRomaLRC = "[00:00.00]nei5 hou2\n"
            let engine = LyricsSyncEngine()
            engine.load(lyrics: "", lyricsTr: "", lyricsRoma: yueRomaLRC, lyricsYRC: yueYRC,
                        romanizationScripts: [.cantonese], songIsCantonese: true)
            let line = engine.activeLine(atMs: 200)
            expectEqual(line?.wordGroups?.count, 2)
            expectEqual(line?.wordGroups?.map(\.romanization), ["nei5", "hou2"])

            let engineOff = LyricsSyncEngine()
            engineOff.load(lyrics: "", lyricsTr: "", lyricsRoma: yueRomaLRC, lyricsYRC: yueYRC,
                           romanizationScripts: [.chinese], songIsCantonese: true)
            expectEqual(engineOff.activeLine(atMs: 200)?.wordGroups, nil)
        }

        do {

            let koYRC = "[0,1000](0,150,0)안(150,150,0)녕\n"
            let koRomaLRC = "[00:00.00]annyeong\n"
            let engine = LyricsSyncEngine()
            engine.load(lyrics: "", lyricsTr: "", lyricsRoma: koRomaLRC, lyricsYRC: koYRC,
                        romanizationScripts: [.korean])
            let line = engine.activeLine(atMs: 100)
            expectEqual(line?.wordGroups?.count, 1)
            expectEqual(line?.wordGroups?.first?.words.count, 2)
            expectEqual(line?.wordGroups?.first?.romanization, "annyeong")

            let engineOff = LyricsSyncEngine()
            engineOff.load(lyrics: "", lyricsTr: "", lyricsRoma: koRomaLRC, lyricsYRC: koYRC,
                           romanizationScripts: [.japanese])
            expectEqual(engineOff.activeLine(atMs: 100)?.wordGroups, nil)
        }
    }

    do {
        typealias V = ChineseVariant

        expectEqual(V.simplified.converted("整個畫面是妳 想妳想到睡不著"),
                    "整个画面是你 想你想到睡不着")
        expectEqual(V.simplified.converted("今天的妳過的好不好"), "今天的你过的好不好")
        expectEqual(V.simplified.converted("我一定會呵護著妳也逗妳笑"), "我一定会呵护着你也逗你笑")

        expectEqual(V.simplified.converted("祂與牠"), "他与它")
        expectEqual(V.simplified.converted("細雨濛濛"), "细雨蒙蒙")
        expectEqual(V.simplified.converted("痲痺"), "麻痹")

        expectEqual(V.traditional.converted("你"), "你")
        expectEqual(V.traditional.converted("他"), "他")
        expectEqual(V.traditional.converted("它"), "它")

        expectEqual(V.traditional.converted("头发"), "頭髮")

        expectEqual(V.off.converted("整個畫面是妳"), "整個畫面是妳")

        expectEqual(V.simplified.converted("妳の名前"), "妳の名前")

        expectEqual(V.simplified.converted("神祇"), "神祇")
        expectEqual(V.simplified.converted("乾坤"), "乾坤")
        expectEqual(V.simplified.converted("我嘅"), "我嘅")
        expectEqual(V.simplified.converted("咁樣"), "咁样")

        expectEqual(V.simplified.converted("First Love"), "First Love")
        expectEqual(V.simplified.converted("这是一首简单的小情歌"), "这是一首简单的小情歌")

        var selfMapped = 0, chained = 0
        for (k, v) in HanVariants.toSimplified {
            if k == v { selfMapped += 1 }
            if HanVariants.toSimplified[v] != nil { chained += 1 }
        }

        expectEqual(selfMapped, 0)
        expectEqual(chained, 0)
        expectEqual(HanVariants.toSimplified.count > 100, true)

        var icuGapChecked = 0
        for k in HanVariants.icuGaps {
            guard let want = HanVariants.toSimplified[k] else { continue }
            icuGapChecked += 1
            if V.simplified.converted(String(k)) != String(want) {
                expectEqual(V.simplified.converted(String(k)), String(want))
            }
        }
        expectEqual(icuGapChecked > 50, true)

        let txtURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lyrimuse-collector/dictionary/HanVariants.txt")
        if let txt = try? String(contentsOf: txtURL, encoding: .utf8) {
            var fromFile: [Character: Character] = [:]
            for line in txt.split(separator: "\n") {
                if line.hasPrefix("#") { continue }
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard cols.count >= 2, cols[0].count == 1, cols[1].count == 1 else { continue }
                fromFile[cols[0].first!] = cols[1].first!
            }
            expectEqual(fromFile.count, HanVariants.toSimplified.count)
            expectEqual(fromFile == HanVariants.toSimplified, true)
        } else {
            expectEqual(false, true)
        }
    }

    do {

        let ja = LyricsRomanization.romanizeLRC(
            "[00:17.88]雨と風の吹く\n[00:21.97]轍が続いて")
        expectEqual(ja?.contains("ame") ?? false, true)
        expectEqual(ja?.contains("tetsu") ?? false, true)
        expectEqual(ja?.contains("[00:17.88]") ?? false, true)
        expectEqual(ja?.split(separator: "\n").count, 2)

        let zh = LyricsRomanization.romanizeLRC("[00:01.00]我爱你")
        expectEqual(zh?.contains("[00:01.00]") ?? false, true)

        expectEqual(zh, "[00:01.00]wǒ ài nǐ")

        expectEqual(LyricsRomanization.romanizeLRC("[00:01.00]I'll be there") == nil, true)
        expectEqual(LyricsRomanization.romanizeLRC("") == nil, true)

        let meta = LyricsRomanization.romanizeLRC(
            "[ti:最高品質]\n[ar:9m88]\n[00:07.78]有时候要懂得闭嘴")
        expectEqual(meta?.contains("[ti:") ?? true, false)
        expectEqual(meta?.split(separator: "\n").count, 1)

        let crlf = LyricsRomanization.romanizeLRC("[00:01.00]我爱你\r\n[00:02.00]你爱我")
        expectEqual(crlf?.contains("\r") ?? true, false)
        expectEqual(crlf?.split(separator: "\n").count, 2)
    }

    do {
        typealias JK = JapaneseKanjiRepair
        expectEqual(JK.repairLine("あれに饮まれちまう奴は居ねえ"), "あれに飲まれちまう奴は居ねえ")
        expectEqual(JK.repairLine("はじまりの合図が闻こえたら"), "はじまりの合図が聞こえたら")
        expectEqual(JK.repairLine("远くに见えた 憧れたもの"), "遠くに見えた 憧れたもの")
        expectEqual(JK.repairLine("优しさ 热が出て 一度许せば"), "優しさ 熱が出て 一度許せば")

        let shinjitai = "国の学校で体を動かす会 点灯 双子 旧い 机の上 誉れ 辞める"
        expectEqual(JK.repairLine(shinjitai), shinjitai)

        expectEqual(JK.repairLine("永远"), "永远")
        expectEqual(JK.repairLine("[00:00.00]蔓越莓和煎饼"), "[00:00.00]蔓越莓和煎饼")

        expectEqual(JK.repairLine("你が步く"), "你が步く")

        expectEqual(JK.repairLine("谁かの颜色"), "誰かの顏色")

        let once = JK.repairLine("远くに见えた 憧れたもの")
        expectEqual(JK.repairLine(once), once)

        for sample in ["", "First Love", "사랑 노래", "君の名は", "[00:01.00]", "明日の今頃には"] {
            expectEqual(JK.repairLine(sample), sample)
        }

        let chineseSong = """
        [00:01.00]我在东京的街头
        [00:02.00]只听见おじさん骑着单车卖着馒头
        [00:03.00]这是一首简单的小情歌
        [00:04.00]头发乱了
        """
        expectEqual(Romanizer.looksJapaneseSong(chineseSong), false)
        expectEqual(JK.repair(chineseSong, japaneseSong: Romanizer.looksJapaneseSong(chineseSong)),
                    chineseSong)
        expectEqual(JK.repair("あれに饮まれちまう奴は居ねえ", japaneseSong: false),
                    "あれに饮まれちまう奴は居ねえ")

        let jpSong = "[00:00.00]蔓越莓和煎饼\r\n[00:29.73]あれに饮まれちまう奴は居ねえ\r\n"
            + "[00:34.22]はじまりの合図が闻こえたら\r\n[00:43.68]くだらん话はもうやめて"
        expectEqual(Romanizer.looksJapaneseSong(jpSong), true)
        expectEqual(JK.repair(jpSong, japaneseSong: true),
                    "[00:00.00]蔓越莓和煎饼\r\n[00:29.73]あれに飲まれちまう奴は居ねえ\r\n"
                    + "[00:34.22]はじまりの合図が聞こえたら\r\n[00:43.68]くだらん話はもうやめて")

        expectEqual(JK.repair("[1000,2000](1000,500,0)饮(1500,500,0)まれ", japaneseSong: true),
                    "[1000,2000](1000,500,0)飲(1500,500,0)まれ")

        let clean = """
        [00:11.13]気づけばもう遠くまで来たね
        [00:16.47]日々に追われ ただがむしゃらで
        [00:21.35]ふと立ち止まって 真っ青な空を
        [01:04.41]子供の頃 思い描いてたような
        [02:19.18]向かう先 目指す未来は同じ
        """
        expectEqual(JK.repair(clean, japaneseSong: true), clean)

        let fixed = JK.repair("[00:29.73]あれに饮まれちまう奴は居ねえ", japaneseSong: true)
        expectEqual(ChineseVariant.traditional.converted(fixed), fixed)
        expectEqual(ChineseVariant.simplified.converted(fixed), fixed)
    }
}
