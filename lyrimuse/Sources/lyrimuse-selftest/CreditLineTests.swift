import LyrimuseCore
import Foundation

@MainActor
func runCreditLineTests() {

    do {
        let engine = LyricsSyncEngine()
        let lrc = "[00:00.00]作词 : 甲\n[00:01.00]作曲：乙\n[00:26.74]la la la\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 500)?.mainText, nil)
        expectEqual(engine.activeLine(atMs: 27000)?.mainText, "la la la")
        expectEqual(engine.upcomingLineText(afterMs: 500), "la la la")
    }

    do {
        let engine = LyricsSyncEngine()
        let yrc = "[0,1000](0,500,0)作词 (500,500,0)：甲 \n[26740,1000](26740,500,0)la (27240,500,0)la \n"
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
        expectEqual(engine.activeLine(atMs: 500)?.words, nil)
        expectEqual(engine.activeLine(atMs: 27000)?.words?.map(\.text), ["la ", "la "])
    }

    do {

        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("主題歌：LiSA"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("片頭曲：藍井エイル"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("収録：ベストアルバム"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("挿入歌：花澤香菜"), true)

        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("作詞：林夕"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("編曲：陳建騏"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("錄音：李振權"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("歌手：周杰伦"), true)

        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("他说：我不走"), false)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("曲婉婷：好久不见"), false)
    }

    do {

        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("-"), true)
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("——"), true)
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("......"), true)
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("~ * ~"), true)

        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("(開心啊)"), false)
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("Oh"), false)
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine(""), false)
    }

    do {

        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("小步舞曲 - 陈绮贞",
                    trackTitle: "小步舞曲", trackArtist: "陳綺貞"), true)

        expectEqual(LyricsSyncEngine.looksLikeHeaderLine(
                    "无所谓 (Explicit) - 方大同 (Khalil Fong)/张靓颖 (Jane Zhang)",
                    trackTitle: "无所谓", trackArtist: "方大同 & 张靓颖"), true)

        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("电子羊 - 某幻君",
                    trackTitle: "电子羊", trackArtist: "某幻君 & 王瀚哲 (中国BOY)"), true)

        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("丁世光 - 日出",
                    trackTitle: "日出 The Dawn", trackArtist: "丁世光"), true)

        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("GF - 方大同",
                    trackTitle: "GF", trackArtist: "方大同"), true)
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("追 - 陶喆 (David Zee Tao)",
                    trackTitle: "追", trackArtist: "陶喆"), true)

        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("陳柏宇-最後的擁抱",
                    trackTitle: "最后的拥抱", trackArtist: "陈柏宇"), true)
    }

    do {

        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("新的经典 蛋堡 x Jabberloop",
                    trackTitle: "经典!", trackArtist: "蛋堡"), false)

        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("First Love",
                    trackTitle: "First Love", trackArtist: "宇多田ヒカル"), false)

        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("我 - 你 - 他都在等",
                    trackTitle: "我", trackArtist: "某人"), false)
    }

    do {

        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("未经著作权人许可不得翻录翻唱或使用"),
                    true)
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("未经著作权人许可 不得翻录翻唱或使用"),
                    true)
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("（未经许可,不得翻唱或使用）"),
                    true)
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("All Rights Reserved"),
                    true)

        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("未经允许的心动"), false)
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("我不得不承认"), false)
    }

    do {

        expectEqual(LyricsSyncEngine.matchesCopyrightMarkLine("著作权人：+© 2019、赋音乐"),
                    true)

        expectEqual(LyricsSyncEngine.matchesCopyrightMarkLine("℗ 2016 北京享耳音乐"),
                    true)
        expectEqual(LyricsSyncEngine.matchesCopyrightMarkLine("(P) 2020 Riot Games"),
                    true)

        expectEqual(LyricsSyncEngine.matchesCopyrightMarkLine("© 赋音乐"), false)
        expectEqual(LyricsSyncEngine.matchesCopyrightMarkLine("那是 2019 年的夏天"), false)

        expectEqual(LyricsSyncEngine.matchesISRCLine("ISRC TWB870211301"), true)
        expectEqual(LyricsSyncEngine.matchesISRCLine("ISRC TW-A47-05-32010"), true)
        expectEqual(LyricsSyncEngine.matchesISRCLine("ISRC: TW-B87-02-11301"), true)

        expectEqual(LyricsSyncEngine.matchesISRCLine("ISRC 是国际标准录音码"), false)
        expectEqual(LyricsSyncEngine.matchesISRCLine("TWB870211301"), false)

        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["其实你很悲伤这很寻常我亲爱的偏执狂",
             "Publisher : Sam Duann", "Mixing : Frankie Hung/Miles Suen"]),
                    [false, true, true])

        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["Chorus: I don't wanna wait", "Verse 1: walking down the street",
             "Bridge: hold me closer now", "Rap: 欢迎来到我的房间"]),
                    [false, false, false, false])

        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["还没来得及习惯", "独自入睡的不安", "艺术指导：程楚楚(廊坊师范学院）", "你外套味道还没散"],
            trackTitle: "甲乙丙丁Strangers", trackArtist: "李佳薇"),
                    [false, false, true, false])
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("艺术指导：程楚楚(廊坊师范学院）"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("项目总监：闫曼嘉/蔡雨燕/庄有豪"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("总策划:赵宗/唐晶晶"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("导演助理：Minto"), true)

        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["进入你梦里 指导你演戏", "当你的时尚顾问 别说你不能", "有超多导演跟编剧", "有谁来导演出好戏",
             "唱情歌唱到像顾问一样"]),
                    [false, false, false, false, false])

        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("著作权人：赋音乐"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("营销推广：戴欣怡 (DDStudio)X深声不息"),
                    true)

        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("自我执著作怪"), false)

        let baifa = [
            "方大同 - 白发", "作词：崔惟楷", "作曲：方大同", "监制：Khalil Fong@JTW",
            "编曲：Khalil Fong", "录音：Fu Music Studio by Jeff Li", "剪辑：Jeff Li",
            "混音：Phil Tan", "母带：Chris Gehringer@Sterling Sound",
            "著作权人：+© 2019、赋音乐", "唱片公司：赋音乐", "推广公司：东亚星光",
            "红尘不复喧哗", "光阴已流成砂", "几许青春年华伴你走天涯", "自我执著作怪",
        ]
        let drops = LyricsSyncEngine.creditLineDropDecisions(
            baifa, trackTitle: "白发", trackArtist: "方大同")
        expectEqual(drops[9], true)
        expectEqual(drops.prefix(12).allSatisfy { $0 }, true)
        expectEqual(drops.suffix(4).allSatisfy { !$0 }, true)
    }

    do {
        typealias E = LyricsSyncEngine

        expectEqual(E.matchesRoleWordCredit("录音师/录音室：王力宏/Homeboy Studios, Taipei, Taiwan"), true)
        expectEqual(E.matchesEnglishCredit("Mixed by Wang Leehom at Homeboy Music Studios"), true)

        expectEqual(E.matchesRoleWordCredit("作词&作曲：某人"), true)
        expectEqual(E.matchesRoleWordCredit("混音、母带：某人"), true)
        expectEqual(E.matchesEnglishCredit("Produced by Someone"), true)
        expectEqual(E.matchesEnglishCredit("Recorded at Abbey Road"), true)

        expectEqual(E.matchesEnglishCredit("a song written by fate"), false)
        expectEqual(E.matchesEnglishCredit("Music makes me lose control"), false)
        expectEqual(E.matchesRoleWordCredit("他说：我不走"), false)
        expectEqual(E.matchesRoleWordCredit("曲婉婷："), false)
    }

    do {
        typealias E = LyricsSyncEngine
        expectEqual(E.matchesRoleWordCredit("和声 Backing Vocal·Dean Ting"), true)
        expectEqual(E.matchesRoleWordCredit("录音室 Studio·Retro Records Studio"), true)
        expectEqual(E.matchesRoleWordCredit("混音与母带工程 Mixing & Mastering Engineer·程振兴 Nathan Cheng"), true)

        expectEqual(E.matchesRoleWordCredit("爱·恨都是你给的"), false)
    }

    do {
        typealias E = LyricsSyncEngine
        expectEqual(E.matchesEnglishCredit("编曲 Arrangement by 丁世光 Dean Ting, 程振兴 Nathan Cheng"), true)
        expectEqual(E.matchesEnglishCredit("制作人 Produced by 丁世光 Dean Ting, 程振兴 Nathan Cheng"), true)
        expectEqual(E.matchesEnglishCredit("键盘 Keyboards by 某某"), true)

        expectEqual(E.matchesEnglishCredit("编曲写好了拿给他听"), false)
        expectEqual(E.matchesEnglishCredit("制作人还没到"), false)
    }

    do {
        typealias E = LyricsSyncEngine
        expectEqual(E.matchesDateStampLine("July 18, 2012 at 5:25 PM"), true)
        expectEqual(E.matchesDateStampLine("Jan 5, 2020"), true)
        expectEqual(E.matchesDateStampLine("  Dec. 25, 1999  "), true)

        expectEqual(E.matchesDateStampLine("I miss you every day"), false)
        expectEqual(E.matchesDateStampLine("May the road rise to meet you"), false)
        expectEqual(E.matchesDateStampLine("我们约好七月十八号见"), false)
    }

    do {
        let engine = LyricsSyncEngine()

        let lrc = "[00:00.00]指挥：某人\n[00:01.00]中提琴：某人\n[00:02.00]母带工程师：某人\n[00:26.74]la la la\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 500)?.mainText, nil)
        expectEqual(engine.activeLine(atMs: 27000)?.mainText, "la la la")
        expectEqual(engine.allLines(idPrefix: "t").count, 1)
    }

    do {
        let engine = LyricsSyncEngine()

        let lrc = """
        [00:10.00]他说：我不走
        [00:20.00]1、2、3：走
        [00:30.00]Verse 1: hello
        [00:40.00]这是一句很长的歌词不是标签所以不该被当成署名行：后面还有内容
        """
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 11000)?.mainText, "他说：我不走")
        expectEqual(engine.activeLine(atMs: 21000)?.mainText, "1、2、3：走")
        expectEqual(engine.activeLine(atMs: 31000)?.mainText, "Verse 1: hello")
        expectEqual(engine.allLines(idPrefix: "t").count, 4)
    }

    do {

        let engine = LyricsSyncEngine()

        var lines = ["他说：走", "她说：不走", "我说：算了"]
        for i in 0..<7 { lines.append("普通歌词第\(i)句") }
        let lrc = lines.enumerated().map { "[00:\(String(format: "%02d", $0.offset + 10)).00]\($0.element)" }.joined(separator: "\n")
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.allLines(idPrefix: "t").count, 10)
    }

    do {

        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]他说：走\n[00:20.00]她说：不走\n[00:30.00]普通歌词\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.allLines(idPrefix: "t").count, 3)
    }

    do {

        let engine = LyricsSyncEngine()
        let lrc = """
        [00:10.00]男：第一句
        [00:20.00]女：第二句
        [00:30.00]合：第三句
        [00:40.00]男：第四句
        [00:50.00]女：第五句
        """
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.allLines(idPrefix: "t").count, 5)

        expectEqual(engine.activeLine(atMs: 11000)?.mainText, "第一句")
        expectEqual(engine.activeLine(atMs: 11000)?.side, .leading)
        expectEqual(engine.activeLine(atMs: 21000)?.side, .trailing)
        expectEqual(engine.activeLine(atMs: 31000)?.side, .center)
    }

    do {

        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]作词：甲\n[00:20.00]作曲：乙\n[00:30.00]编曲：丙\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.allLines(idPrefix: "t").count, 3)
    }

    do {

        let engine = LyricsSyncEngine()
        engine.load(
            lyrics: """
            [00:01.00]词曲：蔡徐坤 KUN/Marco Bernardis
            [00:02.00]作词作曲：某某某
            [00:03.00]词 曲 编：三个连写还带空格
            [00:04.00]他说：我不走
            [00:05.00]真正的歌词在这里
            [00:06.00]又一句歌词
            [00:07.00]再来一句
            [00:08.00]还有一句
            """,
            lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 1500)?.mainText, nil)
        expectEqual(engine.activeLine(atMs: 2500)?.mainText, nil)
        expectEqual(engine.activeLine(atMs: 3500)?.mainText, nil)

        expectEqual(engine.activeLine(atMs: 4500)?.mainText, "他说：我不走")
        expectEqual(engine.activeLine(atMs: 5500)?.mainText, "真正的歌词在这里")
    }

    do {

        let engine = LyricsSyncEngine()
        engine.load(
            lyrics: """
            [00:01.00]制作和编曲：方大同
            [00:02.00]所有乐器和编程：Soulboy
            [00:03.00]他说：我不走
            [00:04.00]真正的歌词
            [00:05.00]又一句歌词
            [00:06.00]再来一句
            """,
            lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 1500)?.mainText, nil)
        expectEqual(engine.activeLine(atMs: 2500)?.mainText, nil)
        expectEqual(engine.activeLine(atMs: 3500)?.mainText, "他说：我不走")
        expectEqual(engine.activeLine(atMs: 4500)?.mainText, "真正的歌词")
    }

    do {
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("数字编辑：Jeff Li"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("母带处理：Randy Merrill@Sterling Sound"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("弦乐录制工程师：某某"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("演唱：Jeremy McKinnon (A Day To Remember)、MAX、henry 刘宪华"), true)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("原唱：张学友"), true)

        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("他说：我不走"), false)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("曲婉婷：好久不见"), false)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("回忆："), false)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("这一句歌词很长很长超过八个字：也不算"), false)
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("Mixing：某某"), false)
    }

    do {
        let real = [
            "制作人 Producer：陶喆 David Tao",
            "曲 Composer：陶喆 David Tao",
            "词 Lyricist：陶喆 David Tao/葛大为",
            "编曲 Arrangement and programming：DT",
            "鼓 Drums：Ash Soan",
            "低音吉他 Bass：Paul Bushnell",
            "和声 Background vocals by：DT",
            "制作协力 Production Assistant：陈震豪 Evan Chen",
            "录音室 Recording Studio：新歌录音室 New Song Studios (Taipei)/The Windmill Studio, Norfolk (England)",
            "录音工程师 Recording Engineer：陈震豪 Evan Chen",
            "混音工程师 Mixing Engineer：Mick Guzauski",
            "混音录音室 Mixing Studio：Barking Doctor",
            "母带后期处理工程 Mastering Engineer：CB",
        ]
        for line in real {
            expectEqual(LyricsSyncEngine.matchesRoleWordCredit(line), true)
        }

        let notCredits = [
            "他：我不走",
            "妈妈 Mom：吃饭了",
            "我爱你 I love you：再见",
            "爱情 Love Story：一场游戏",
            "曲：我们一起唱",
        ]
        for line in notCredits {
            expectEqual(LyricsSyncEngine.matchesRoleWordCredit(line), false)
        }

        let shapeOnly = [
            "西塔琴 Coral sitar：Jamie Wilson",
            "中提琴 Viola：Istvan Loga",
            "竖琴Harp：Michael Maganuco",
            "富鲁格号 Flugehorn: Gary Alesbrook",
            "电钢琴与管风琴 Keys/Organ：丁世光 Dean Ting",
            "词OP：北京大石音乐版权有限公司",
            "画 Painting by：叶喜儿 Ashlee Yip",
        ]
        for line in shapeOnly {
            expectEqual(LyricsSyncEngine.matchesBilingualCreditShape(line), true)
        }

        for line in [
            "我们让彼此难过(SL:那些到底算是谁的错) 都别争了",
            "那些伤害人的话(SL:那些只是气话其实我) 都别说了",
        ] {
            expectEqual(LyricsSyncEngine.matchesBilingualCreditShape(line), false)
        }

        expectEqual(LyricsSyncEngine.matchesBilingualCreditShape("男 Male：我不走"), false)

        do {
            let lone = LyricsSyncEngine()
            lone.load(lyrics: "[00:01.00]妈妈 Mom：吃饭了\n[00:05.00]真的歌词一句\n[00:09.00]真的歌词两句\n",
                      lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
            expectEqual(lone.allLines(idPrefix: "x").count, 3)
        }

        let engine = LyricsSyncEngine()
        var lrc = "[00:00.00]Stupid Pop Song - 陶喆\n"
        for (i, line) in real.enumerated() {
            lrc += "[00:\(String(format: "%02d", i + 1)).00]\(line)\n"
        }
        lrc += "[00:28.61]This is a stupid pop song 我想唱给你听\n"
        lrc += "[00:33.00]谁在乎明天会怎样\n"

        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                    trackTitle: "Stupid Pop Song", trackArtist: "陶喆")
        let kept = engine.allLines(idPrefix: "t").compactMap { $0.line.mainText }
        expectEqual(kept, ["This is a stupid pop song 我想唱给你听", "谁在乎明天会怎样"])
    }

    do {
        let lyrics = """
        [00:00.00]泠鸢yousa - 神的随波逐流
        [00:07.69]词：れるりり
        [00:15.38]曲：れるりり
        [00:23.08]不知最近为什么总是不随心意
        [00:27.00]但我听说这是我最为珍贵的一个小特长
        [00:31.00]化作无穷的力量
        """
        let jaKoOnly: RomanizationScripts = [.japanese, .korean]

        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                        trackTitle: "神的随波逐流", trackArtist: "泠鸢yousa",
                        romanizationScripts: jaKoOnly)
        let line = engine.activeLine(atMs: 27_500)
        expectEqual(line?.plainText, "但我听说这是我最为珍贵的一个小特长")
        expectEqual(line?.romanization, nil)

        let jpLyrics = """
        [00:00.00]作词：れるりり
        [00:05.00]火曜日の朝は
        [00:10.00]受話器を取った君
        """
        let jpEngine = LyricsSyncEngine()
        _ = jpEngine.load(lyrics: jpLyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                          trackTitle: "test", trackArtist: "test",
                          romanizationScripts: jaKoOnly)
        expectEqual(jpEngine.activeLine(atMs: 5_500)?.romanization != nil, true)
    }

    do {
        typealias E = LyricsSyncEngine

        expectEqual(E.matchesNameListCreditShape("钢琴：柳森"), true)
        expectEqual(E.matchesNameListCreditShape("箱琴：赵雷/喜子"), true)
        expectEqual(E.matchesNameListCreditShape("笛子：祝子"), true)
        expectEqual(E.matchesNameListCreditShape("童声：朵朵/天天"), true)
        expectEqual(E.matchesNameListCreditShape("弦乐：亚洲爱乐国际乐团"), true)
        expectEqual(E.matchesNameListCreditShape("弦乐编写：柳森"), true)

        expectEqual(E.matchesNameListCreditShape("他说：我不走"), false)
        expectEqual(E.matchesNameListCreditShape("她说：不走"), false)
        expectEqual(E.matchesNameListCreditShape("我说：算了"), false)
        expectEqual(E.matchesNameListCreditShape("他说：走"), false)
        expectEqual(E.matchesNameListCreditShape("曲婉婷：好久不见"), false)
        expectEqual(E.matchesNameListCreditShape("男：亲爱的"), false)
        expectEqual(E.matchesNameListCreditShape("Verse 1: hello"), false)
        expectEqual(E.matchesNameListCreditShape("1、2、3：走"), false)

        expectEqual(E.matchesNameListCreditShape("项目总监：闫曼嘉/蔡雨燕/庄有豪"), true)

        expectEqual(E.matchesNameListCreditShape("他说：庄有豪"), false)

        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: """
        [00:00.00]成都 - 赵雷
        [00:01.32]词：赵雷
        [00:02.65]曲：赵雷
        [00:03.97]编曲：赵雷/喜子
        [00:05.30]制作人：赵雷/喜子/姜北生
        [00:06.63]BASS：张岭
        [00:07.95]鼓：贝贝
        [00:09.28]钢琴：柳森
        [00:10.60]箱琴：赵雷/喜子
        [00:11.93]笛子：祝子
        [00:13.26]弦乐编写：柳森
        [00:14.58]弦乐：亚洲爱乐国际乐团
        [00:15.91]和声：朱奇迹/赵雷/旭东
        [00:17.23]童声：朵朵/天天
        [00:24.00]让我掉下眼泪的
        [00:27.00]不止昨夜的酒
        [00:30.00]让我依依不舍的
        [00:33.00]不止你的温柔
        """, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
        trackTitle: "成都", trackArtist: "赵雷")
        let kept = engine.allLines(idPrefix: "cd").compactMap { $0.line.plainText }
        expectEqual(kept.count, 4)
        expectEqual(kept.first, "让我掉下眼泪的")
        expectEqual(kept.contains(where: { $0.contains("钢琴") || $0.contains("箱琴")
                        || $0.contains("笛子") || $0.contains("童声") }), false)
    }

    do {
        typealias E = LyricsSyncEngine

        let openers = ["词 Lyrics：某某某", "曲 Composer：某某某", "作词：某某某", "作曲：某某某"]
        let fillers = [
            "让我掉下眼泪的", "不止昨夜的酒", "余路还要走多久", "你攥着我的手",
            "分开总是在雨天", "一杯凉水一根烟", "谁能凭爱意要富士山私有", "夜色如水淹没了街",
        ]

        func verdict(_ line: String) -> Bool {

            let doc = openers + fillers + [line]
            let drop = E.creditLineDropDecisions(doc, trackTitle: "测试曲", trackArtist: "测试歌手")
            return drop[doc.count - 1]
        }

        let mustKeep: [(String, Int)] = [
            ("男：无所谓", 24),
            ("女：无所谓", 6),
            ("合：无所谓", 9),
            ("合：Hey hey ho ho", 8),
            ("合：因为我真的无所谓", 3),
            ("男：多少话也说不出", 3),
            ("女：有时想也想不通", 3),
            ("女：我真的Bae", 3),
            ("男：Khalil", 2),
            ("合：犯错", 2),
            ("钧：迫不及待看见我的未来", 18),
            ("宏：看见我的", 14),
            ("徐：我说男生的无所谓都是自以为", 4),
            ("岩：霸气傲中原 王者扬烽烟", 4),
            ("李：一个人的夜晚 谁和谁陪伴", 3),
            ("华：失去你的我比乞丐落魄", 2),
            ("方：是我闯祸 还是每个月的亲戚害了我", 2),
            ("黄：You are the apple of my eye", 2),
            ("王：不小心", 2),
            ("靖：我们大家的心声", 1),
            ("宏：呦 一位盖世英雄要上台了", 1),
            ("宏：Yeah come on come on", 2),
            ("Rain：给我大声地说我爱你", 12),
            ("Rain：정말 자신 있겠지", 2),
            ("S:只会让我不小心", 2),
            ("S:好想问你", 1),
            ("Rap:欢迎来到我的房间", 1),
            ("SL：啊把日期(給它)撕掉，", 1),
            ("N.Chen：（聽不懂...），", 1),
            ("A: one..two..three…..four", 2),
            ("B: Wu~", 4),
            ("A.B.C.D: Nananana nananana", 5),
            ("我们让彼此难过(SL:那些到底算是谁的错) 都别争了", 1),
            ("（女：Woo I'm sorry Woo So sorry）", 3),

            ("他说：I don't wanna go", 0),
            ("Rain：Baby I love you so much", 0),

            ("王：Hey hey ho ho", 2),
            ("靖：All yours baby", 2),

            ("方：开个玩笑", 2), ("宏：盖世英雄到来", 2), ("王：Oh yeah", 2),
            ("华：喔 喔", 1), ("张：回到拉萨", 1),
        ]
        for (line, seen) in mustKeep {
            expectEqual(verdict(line), false)
        }

        let mustDrop: [(String, String)] = [
            ("词：方大同", "中文单字标签"),
            ("曲：陶喆", "中文单字标签"),
            ("作曲 : 方大同", "半角冒号 + 空格"),
            ("编曲：陶喆", "中文双字标签"),
            ("制作人：赵雷/喜子/姜北生", "一个角色多个人"),
            ("钢琴：柳森", "乐器(第十轮补)"),
            ("箱琴：赵雷/喜子", "乐器(第十轮补)"),
            ("笛子：祝子", "乐器(第十轮补)"),
            ("童声：朵朵/天天", "乐器(第十轮补)"),
            ("弦乐：亚洲爱乐国际乐团", "团体名"),
            ("和声：朱奇迹/赵雷/旭东", "多人"),
            ("鼓：贝贝", "单字乐器"),
            ("BASS：张岭", "拉丁标签 + 全角冒号"),
            ("制作人 Producer：陶喆 David Tao", "双语标签"),
            ("曲 Composer：陶喆 David Tao", "双语标签(汉字头是单字)"),
            ("混音工程师 Mixing Engineer：Mick Guzauski", "双语组合词"),
            ("母带后期处理工程师 : Dave Collins", "长组合词 + 半角冒号"),
            ("制作协力 Production Assistant：陈震豪 Evan Chen", "双语组合词"),
            ("OP：月球唱片Retro Records CO LTD.", "版权归属"),
            ("SP：SMAP(BEIJING) CO.,LTD.", "版权归属"),
            ("Written by：Prince", "英文 by 写法"),
            ("Produced by：Sebastien Najand", "英文 by 写法"),
            ("Mixed by：Riot Games", "英文 by 写法"),
            ("Guitar：秋山浩徳", "拉丁角色名 + 日文人名"),
            ("未经著作权人许可不得翻录翻唱或使用", "版权声明(无冒号)"),
            ("版权声明：未经著作权人书面许可，任何人不得以任何方式使用（包括翻唱、翻录等）", "版权声明(带冒号)"),

            ("P - Line: 2016 北京享耳音乐文化有限公司Sure Recordings Culture Co., Ltd", "℗/© 版权行"),
            ("C - Line: 2016 北京享耳音乐文化有限公司Sure Recordings Culture Co., Ltd", "℗/© 版权行"),
            ("Protools编辑：Derrick Sepnio/Edward Chan/Kelvin Au/King Kong/Tsam Chan/Nick Wong", "标签混拉丁字母"),
            ("副唱：Bekuh BOOM", "表外角色 + 英文名"),
            ("竖琴：Michael Maganuco", "表外乐器 + 英文名"),
            ("长号：Matt Roberts", "表外乐器 + 英文名"),
            ("键盘乐器 DX7 and synths：Jeff Babko", "双语标签带型号"),
            ("键盘乐器 Keyboards (Piano and synth) by：吴庆隆 Goh Kheng Long", "双语标签带括号和 by"),
            ("中音萨克斯/次中音萨克斯/上低音萨克斯：孟庆泽", "一人身兼多职的长标签"),
            ("合作艺人：(G)I-DLE/Bea Miller/Wolftyla", "表外角色 + 多个英文名"),
            ("主唱：SOYEON of (G)I-DLE/MIYEON of (G)I-DLE/Bea Miller/Wolftyla", "表外角色 + 超长名单"),
            ("Additional Vocal Production by：Oscar Free", "英文角色短语 + by"),
        ]
        for (line, family) in mustDrop {
            expectEqual(verdict(line), true)
        }

        let headerDoc = ["成都 - 赵雷"] + fillers
        expectEqual(E.creditLineDropDecisions(headerDoc, trackTitle: "成都", trackArtist: "赵雷").first,
                    true)
        let notHeaderDoc = fillers + ["成都 - 赵雷"]
        expectEqual(E.creditLineDropDecisions(notHeaderDoc, trackTitle: "成都", trackArtist: "赵雷").last,
                    false)

        let allCredits = ["词：某某", "曲：某某", "编曲：某某", "制作人：某某"]
        expectEqual(E.creditLineDropDecisions(allCredits).contains(true), false)
    }

    do {
        typealias S = MusicCatalogSearch

        let u = S.searchURL(title: "轨迹", artist: "周杰伦", storefront: "cn")
        expectEqual(u != nil, true)
        if let u {
            let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func val(_ n: String) -> String? { q.first { $0.name == n }?.value }
            expectEqual(val("term"), "周杰伦 轨迹")
            expectEqual(val("entity"), "song")
            expectEqual(val("country"), "cn")
        }

        func item(_ t: String, _ a: String) -> S.Item {
            S.Item(trackName: t, artistName: a, collectionName: nil,
                   trackViewUrl: nil, artistViewUrl: nil, collectionViewUrl: nil)
        }
        let items = [item("别的歌", "别人"), item("轨迹 (Live)", "周杰伦"), item("随便", "周杰伦")]
        expectEqual(S.pickBest(items, title: "轨迹", artist: "周杰伦")?.trackName, "轨迹 (Live)")
        let onlyArtist = [item("别的歌", "别人"), item("随便", "周杰伦")]
        expectEqual(S.pickBest(onlyArtist, title: "轨迹", artist: "周杰伦")?.trackName, "随便")
        expectEqual(S.pickBest([item("A", "B")], title: "轨迹", artist: "周杰伦")?.trackName, "A")
        expectEqual(S.pickBest([], title: "x", artist: "y") == nil, true)

        let princeItems = [item("Purple Rain", "Prince & The Revolution"), item("Kiss", "Prince")]
        expectEqual(S.pickBest(princeItems, title: "", artist: "Prince")?.artistName, "Prince")
        let noExactMatch = [item("Purple Rain", "Prince & The Revolution")]
        expectEqual(S.pickBest(noExactMatch, title: "", artist: "Prince")?.artistName, "Prince & The Revolution")

        expectEqual(S.musicSchemeURL("https://music.apple.com/cn/album/536108118")?.absoluteString,
                    "music://music.apple.com/cn/album/536108118")
        expectEqual(S.musicSchemeURL("https://example.com/x") == nil, true)
        expectEqual(S.musicSchemeURL(nil) == nil, true)
    }
}
