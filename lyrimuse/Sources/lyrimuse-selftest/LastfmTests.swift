import LyrimuseCore
import Foundation

@MainActor
func runLastfmTests() {

    do {
        typealias R = PlayCountRecency
        func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
        let k = "周杰倫|园游会"

        expectEqual(R.newest([(k, at(1000)), (k, at(3000)), (k, at(2000))])[k], at(3000))

        let before = R.newest([(k, at(1000)), (k, at(2000)), (k, at(3000))])
        let after = R.newest([(k, at(2000)), (k, at(3000)), (k, at(4000))])
        expectEqual(before[k], at(3000))
        expectEqual(after[k]! > before[k]!, true)

        expectEqual(R.newest([(k, at(5000)), (k, nil)])[k], at(5000))
        expectEqual(R.newest([(k, nil)]).isEmpty, true)

        expectEqual(R.newest([(k, at(100)), ("周杰倫|園遊會", at(200))]).count, 2)
    }

    do {
        typealias R = PlayCountRecency
        func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
        let now = at(10_000)
        let throttle: TimeInterval = 300

        expectEqual(R.contradicted(onPage: 11, cachedTotal: 3, lastFetched: nil,
                                   now: now, recheckAfter: throttle), true)

        expectEqual(R.contradicted(onPage: 3, cachedTotal: 3, lastFetched: nil,
                                   now: now, recheckAfter: throttle), false)
        expectEqual(R.contradicted(onPage: 2, cachedTotal: 12, lastFetched: nil,
                                   now: now, recheckAfter: throttle), false)

        expectEqual(R.contradicted(onPage: 11, cachedTotal: 3, lastFetched: at(9_800),
                                   now: now, recheckAfter: throttle), false)
        expectEqual(R.contradicted(onPage: 11, cachedTotal: 3, lastFetched: at(9_700),
                                   now: now, recheckAfter: throttle), true)

        expectEqual(R.contradicted(onPage: 1, cachedTotal: 99, lastFetched: at(0),
                                   now: now, recheckAfter: throttle), false)
    }

    do {
        typealias R = PlayCountRecency
        func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
        let now = at(1_000_000)
        let maxAge: TimeInterval = 24 * 60 * 60

        expectEqual(R.stale(lastFetched: nil, now: now, maxAge: maxAge), true)

        expectEqual(R.stale(lastFetched: at(1_000_000 - 60), now: now, maxAge: maxAge), false)

        expectEqual(R.stale(lastFetched: at(1_000_000 - 24 * 60 * 60), now: now, maxAge: maxAge), true)
        expectEqual(R.stale(lastFetched: at(1_000_000 - 24 * 60 * 60 + 1), now: now, maxAge: maxAge), false)

        expectEqual(R.contradicted(onPage: 1, cachedTotal: 1, lastFetched: nil,
                                   now: now, recheckAfter: 300), false)
        expectEqual(R.stale(lastFetched: at(1_000_000 - 2 * 24 * 60 * 60), now: now, maxAge: maxAge), true)
    }

    do {
        typealias R = PlayCountRecency

        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 27, currentPlayCounted: false), 28)

        expectEqual(R.reconciledNowPlayingCount(current: nil, freshTotal: 5, currentPlayCounted: false), 6)

        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 10, currentPlayCounted: false), nil)

        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 16, currentPlayCounted: false), nil)

        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 17, currentPlayCounted: false), 18)
    }

    do {
        typealias R = PlayCountRecency

        expectEqual(R.reconciledNowPlayingCount(current: 1, freshTotal: 1, currentPlayCounted: true), nil)

        expectEqual(R.reconciledNowPlayingCount(current: 6, freshTotal: 6, currentPlayCounted: true), nil)

        expectEqual(R.reconciledNowPlayingCount(current: 2, freshTotal: 1, currentPlayCounted: true), 1)

        expectEqual(R.reconciledNowPlayingCount(current: 17, freshTotal: 10, currentPlayCounted: true), nil)

        expectEqual(R.reconciledNowPlayingCount(current: 1, freshTotal: 2, currentPlayCounted: true), 2)

        expectEqual(R.reconciledNowPlayingCount(current: nil, freshTotal: 0, currentPlayCounted: true), nil)
    }

    do {
        typealias R = PlayCountRecency
        func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
        let start = at(1_000_000)

        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: start, playStart: start), true)
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: at(1_000_003), playStart: start), true)
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: at(1_000_119), playStart: start), true)

        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: at(1_000_000 - 3 * 24 * 60 * 60),
                                             playStart: start), false)
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: at(1_000_121), playStart: start), false)

        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: nil, playStart: start), false)
        expectEqual(R.currentPlayIsScrobbled(newestScrobbleAt: start, playStart: nil), false)
    }

    do {
        typealias P = LastfmRecentTracksPage

        func trackObj(name: String, artist: String, uts: String? = nil, nowPlaying: Bool = false) -> [String: Any] {
            var t: [String: Any] = ["name": name, "artist": ["#text": artist]]
            if nowPlaying {
                t["@attr"] = ["nowplaying": "true"]
            } else if let uts {
                t["date"] = ["uts": uts]
            }
            return t
        }

        func page(_ tracks: Any, totalPages: String = "1") -> [String: Any] {
            ["recenttracks": ["@attr": ["totalPages": totalPages], "track": tracks]]
        }

        do {
            let json = page([
                trackObj(name: "开不了口", artist: "周杰倫", uts: "1700000000"),
                trackObj(name: "夜曲", artist: "周杰倫", nowPlaying: true),
            ], totalPages: "5")
            let result = P.parse(json)
            expectEqual(result?.totalPages, 5)
            expectEqual(result?.rows.count, 2)
            expectEqual(result?.rows[0], .init(artist: "周杰倫", title: "开不了口", uts: 1_700_000_000))
            expectEqual(result?.rows[1].uts, nil)
        }

        do {
            let json = page(trackObj(name: "十年", artist: "陳奕迅", uts: "1600000000"))
            let result = P.parse(json)
            expectEqual(result?.rows.count, 1)
            expectEqual(result?.rows.first?.title, "十年")
        }

        do {
            let json = page([["name": "畸形", "artist": ["#text": "X"], "date": ["uts": "not-a-number"]]])
            let result = P.parse(json)
            expectEqual(result?.rows.first?.uts, nil)
            expectEqual(result?.rows.first?.artist, "X")
        }

        expectEqual(P.parse(["unexpected": 1]) == nil, true)
        expectEqual(P.parse(["recenttracks": ["track": []]]) == nil, true)

        let empty = P.parse(page([]))
        expectEqual(empty?.rows.count, 0)

        let missingField = P.parse(page([["artist": ["#text": "只有歌手没有歌名"]]]))
        expectEqual(missingField?.rows.count, 0)
    }

    do {
        typealias Q = LastfmQuery
        expectEqual(Q.escape("夜曲+窃爱 (Live)"),
                    "%E5%A4%9C%E6%9B%B2%252B%E7%AA%83%E7%88%B1%20%28Live%29")
        expectEqual(Q.escape("+44"), "%252B44")

        expectEqual(Q.escape("100%"), "100%2525")

        expectEqual(Q.escape("a+b%c"), "a%252Bb%2525c")

        expectEqual(Q.escape("开不了口 (live)"),
                    "%E5%BC%80%E4%B8%8D%E4%BA%86%E5%8F%A3%20%28live%29")
        expectEqual(Q.escape("Beyond"), "Beyond")

        expectEqual(Q.escape("a b").contains("+"), false)
        expectEqual(Q.queryString([("method", "track.getinfo"), ("track", "+44")]),
                    "method=track.getinfo&track=%252B44")
    }

    do {
        typealias V = PlayCountVariants
        let full = V.siblings(artist: "丁世光", title: "一口（The Day You Left Me）").map(\.title)
        expectEqual(full.contains("一口(The Day You Left Me)"), true)
        expectEqual(full.contains("一口 (The Day You Left Me)"), true)
        expectEqual(full.contains("一口"), true)
        expectEqual(full.contains("一口（The Day You Left Me）"), false)
        expectEqual(full.count <= 6, true)

        let half = V.siblings(artist: "丁世光", title: "一口(The Day You Left Me)").map(\.title)
        expectEqual(half.contains("一口（The Day You Left Me）"), true)

        expectEqual(V.siblings(artist: "丁世光", title: "E.T.").isEmpty, true)
        expectEqual(V.siblings(artist: "丁世光", title: "Simon").isEmpty, true)

        let featSibs = V.siblings(artist: "MJ", title: "Scream (feat. Janet Jackson)")
        expectEqual(featSibs.map(\.title), ["Scream"])

        let han = V.siblings(artist: "方大同", title: "我不是農人")
        expectEqual(han.first?.title ?? "", "我不是农人")

        let mixed = V.siblings(artist: "丁世光", title: "小師妹（Love Triangle）")
        expectEqual(mixed.count, 4)
        expectEqual(mixed.map(\.title).contains("小師妹(Love Triangle)"), true)
        expectEqual(mixed.map(\.title).contains("小师妹（Love Triangle）"), true)

        let mo = V.siblings(artist: "丁世光", title: "愛在什麼地方都有（Love Is Everywhere）").map(\.title)
        expectEqual(mo.contains("愛在什麽地方都有(Love Is Everywhere)"), true)
        expectEqual(mo.count <= 6, true)
        expectEqual(V.siblings(artist: "X", title: "為你我受冷風吹").map(\.title).contains("爲你我受冷風吹"),
                    true)
    }

    do {
        typealias F = PlayCountFold

        let a = F.key(artist: "丁世光", title: "愛在什麼地方都有（Love Is Everywhere）")
        expectEqual(a, F.key(artist: "丁世光", title: "愛在什麽地方都有(Love Is Everywhere)"))
        expectEqual(a, F.key(artist: "丁世光", title: "爱在什么地方都有(love is everywhere)"))

        expectEqual(F.key(artist: "丁世光", title: "月食 The Weeping Woman"),
                    F.key(artist: "丁世光", title: "月食"))
        expectEqual(F.key(artist: "X", title: "P.S. 我愛你"),
                    F.key(artist: "X", title: "我爱你"))

        expectNotEqual(F.foldTitle("一口(The Day You Left Me)"), F.foldTitle("一口"))
        expectNotEqual(F.foldTitle("好的一天 (Live)"), F.foldTitle("好的一天"))

        expectEqual(F.key(artist: "陶喆", title: "Susan 说"),
                    F.key(artist: "陶喆", title: "susan说"))
        expectEqual(F.key(artist: "陳奕迅", title: "富士山下"),
                    F.key(artist: "陈奕迅", title: "富士山下"))

        expectNotEqual(F.foldTitle("月食 The 月食 Woman"), F.foldTitle("月食"))

        expectEqual(F.key(artist: "宇多田ヒカル", title: "Automatic (Remastered 2014)"),
                    F.key(artist: "宇多田ヒカル", title: "Automatic"))
        expectEqual(F.foldTitle("Song (2014 Remaster)"), F.foldTitle("Song"))
        expectEqual(F.foldTitle("Song (Remastered Version)"), F.foldTitle("Song"))
        expectEqual(F.foldTitle("月食 (Remastered)"), F.foldTitle("月食"))
        expectNotEqual(F.foldTitle("Song (Remix)"), F.foldTitle("Song"))
        expectNotEqual(F.foldTitle("Song (Live 2014 Remaster)"), F.foldTitle("Song"))

        let autoSibs = PlayCountVariants.siblings(artist: "宇多田ヒカル",
                                                  title: "Automatic (Remastered 2014)")
        expectEqual(autoSibs.contains { $0.title == "Automatic" }, true)

        expectEqual(F.key(artist: "王力宏", title: "盖世英雄 (feat. 欧阳靖 & 李岩)"),
                    F.key(artist: "王力宏", title: "蓋世英雄"))
        expectEqual(F.foldTitle("完美的互动 (feat J-Lim & Rain)"), F.foldTitle("完美的互動"))
        expectEqual(F.foldTitle("Song (featuring X)"), F.foldTitle("Song"))
        expectEqual(F.foldTitle("Song (ft. X)"), F.foldTitle("Song"))
        expectNotEqual(F.foldTitle("Song (Feathers)"), F.foldTitle("Song"))
        expectNotEqual(F.foldTitle("Song (feat.)"), F.foldTitle("Song"))

        expectEqual(F.key(artist: "周杰倫", title: "一路向北 (bonus track)"),
                    F.key(artist: "周杰伦", title: "一路向北"))
        expectEqual(F.foldTitle("Song (Bonus Track)"), F.foldTitle("Song"))
        expectEqual(F.foldTitle("Song (Japanese Bonus Track)"), F.foldTitle("Song"))
        expectEqual(F.foldTitle("Song (Bonus)"), F.foldTitle("Song"))

        expectNotEqual(F.foldTitle("Song (Live Bonus Track)"), F.foldTitle("Song"))
        expectNotEqual(F.foldTitle("Song (Bonus Beats)"), F.foldTitle("Song"))

        expectEqual(F.key(artist: "方大同", title: "无所谓 (Explicit)"),
                    F.key(artist: "方大同", title: "無所謂"))

        expectNotEqual(F.foldTitle("Song (Clean)"), F.foldTitle("Song"))
        expectNotEqual(F.foldTitle("Song (Simple and Clean)"), F.foldTitle("Song"))

        expectEqual(F.key(artist: "周杰倫", title: "不該 (with aMEI)"),
                    F.key(artist: "周杰倫", title: "不該"))
        expectEqual(F.foldTitle("Toronto 2014 (with Mustafa)"), F.foldTitle("Toronto 2014"))

        expectNotEqual(F.foldTitle("Song (Without You)"), F.foldTitle("Song"))
        expectNotEqual(F.foldTitle("Song (with)"), F.foldTitle("Song"))

        expectNotEqual(F.foldTitle("Xscape (original version)"), F.foldTitle("Xscape"))
        expectNotEqual(F.foldTitle("Rock With You (single version)"), F.foldTitle("Rock With You"))
        expectNotEqual(F.foldTitle("愛情轉移(國)"), F.foldTitle("愛情轉移"))

        let bonusSibs = PlayCountVariants.siblings(artist: "周杰倫", title: "一路向北 (bonus track)")
        expectEqual(bonusSibs.contains { $0.title == "一路向北" }, true)

        expectNotEqual(F.key(artist: "方大同", title: "悟空 2003 demo (bonus track)"),
                       F.key(artist: "方大同", title: "悟空"))
        expectNotEqual(F.foldTitle("流沙 Live Version (Remastered)"), F.foldTitle("流沙"))

        expectEqual(F.key(artist: "丁世光", title: "低潮期 Tough Days (feat.葉喜兒)"),
                    F.key(artist: "丁世光", title: "低潮期"))

        expectNotEqual(F.key(artist: "陶喆", title: "流沙 - Live"),
                       F.key(artist: "陶喆", title: "流沙"))

        expectEqual(F.key(artist: "Michael Jackson", title: "Bad - 2012 Remaster"),
                    F.key(artist: "Michael Jackson", title: "Bad"))
        expectEqual(F.foldTitle("Room 608 - Remastered"), F.foldTitle("Room 608"))

        expectNotEqual(F.foldTitle("Anti-Remastered"), F.foldTitle("Anti"))

        expectNotEqual(F.foldTitle("Melody - Live"), F.foldTitle("Melody"))
        expectNotEqual(F.foldTitle("Talking - Demo Version"), F.foldTitle("Talking"))
        expectNotEqual(F.foldTitle("It's All Right With Me - Remastered 2006/Rudy Van Gelder Edition"),
                       F.foldTitle("It's All Right With Me"))

        expectEqual(F.foldTitle("Song - 2012 Remaster (feat. Y)"), F.foldTitle("Song"))

        expectEqual(F.foldTitle("Song - (2012 Remaster)"), F.foldTitle("Song"))

        expectEqual(F.foldTitle("不該 (with aMEI)"), F.foldTitle("不該"))
        expectEqual(F.foldTitle("等你下课 (with 杨瑞代)"), F.foldTitle("等你下课"))
        expectNotEqual(F.foldTitle("Song (with strings)"), F.foldTitle("Song"))
        expectNotEqual(F.foldTitle("Song (with orchestra)"), F.foldTitle("Song"))
        expectNotEqual(F.foldTitle("Song (With or Without You)"), F.foldTitle("Song"))
        expectNotEqual(F.foldTitle("Song (with backing vocals)"), F.foldTitle("Song"))

        expectEqual(F.foldTitle("Song (feat. The Weeknd)"), F.foldTitle("Song"))

        expectNotEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音"))
        expectNotEqual(F.foldTitle("飛機場的10:30 - Demo Version"), F.foldTitle("飛機場的10:30"))
        expectNotEqual(F.foldTitle("Melody - Live"), F.foldTitle("Melody"))

        expectNotEqual(F.key(artist: "方大同", title: "All Night - Live版"),
                       F.key(artist: "方大同", title: "Ten Reasons - Live版"))
        expectNotEqual(F.foldTitle("All Night - Live版"), F.foldTitle("Live版"))
        expectNotEqual(F.foldTitle("Something Stupid [Live 08] featuring 薛凱琪"),
                       F.foldTitle("薛凱琪"))

        expectNotEqual(F.foldTitle("流沙 - Live"), F.foldTitle("流沙 (Live)"))
        expectNotEqual(F.foldTitle("南音 [Live]"), F.foldTitle("南音 - Live"))

        expectEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音 - Live 08"))
        expectEqual(F.foldTitle("南音 - 15 Khalil Live in HK 2011"),
                    F.foldTitle("南音 (15 Khalil Live in HK 2011)"))

        expectNotEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音 - Live"))
        expectEqual(F.foldTitle("沙灘 - 鋼琴版"), F.foldTitle("沙滩 (钢琴版)"))
        expectEqual(F.foldTitle("Rock With You - Single Version"),
                    F.foldTitle("Rock With You (single version)"))
        expectEqual(F.foldTitle("逗陣兄弟 - 獨唱版"), F.foldTitle("逗阵兄弟 (独唱版)"))
        expectNotEqual(F.foldTitle("南音 [Live 08]"), F.foldTitle("南音 [Timeless Live 2009]"))

        expectEqual(F.foldTitle("月食 - The Weeping Woman"), F.foldTitle("月食"))

        expectNotEqual(F.foldTitle("鬼 - Overture"), F.foldTitle("鬼"))

        expectEqual(F.foldTitle("苏州河 - 慕容雪 - Mandarin Version"),
                    F.foldTitle("苏州河 - 慕容雪 (Mandarin Version)"))

        expectEqual(F.foldTitle("你不知道的事 - 宋曉青版本"),
                    F.foldTitle("你不知道的事 (宋晓青版本)"))

        expectEqual(F.foldTitle("一口 [Remastered 2014]"), F.foldTitle("一口"))

        expectNotEqual(F.foldTitle("All Night - Live版"), F.foldTitle("Live版"))

        typealias LA = LocalArtistAliases
        let mb = LA.MusicBrainzCaches(
            aliasCache: ["Crowd Lu": "卢广仲", "Khalil Fong": "方大同"],
            identityZh: ["Soft Lipa": "蛋堡"],
            primaryAliases: ["陶喆": ["David Tao"], "周杰伦": ["Jay Chou", "ジェイ・チョウ", "K"],
                             "宇多田ヒカル": ["Hikaru Utada", "Utada", "宇多田光"],
                             "Count Basie": [], "Fantasia": [], "阿肆": ["A Si"]])
        let artistTable = LA.derive(caches: mb, entries: [])
        F.setLocalArtistAliases(artistTable)
        defer { F.setLocalArtistAliases([:]) }
        expectEqual(F.familyKey(artist: "David Tao", title: "找自己"),
                    F.familyKey(artist: "陶喆", title: "找自己"))
        expectEqual(F.familyKey(artist: "Jay Chou", title: "不該"),
                    F.familyKey(artist: "周杰倫", title: "不该"))
        expectEqual(F.familyKey(artist: "Hikaru Utada", title: "Automatic"),
                    F.familyKey(artist: "宇多田光", title: "Automatic"))
        expectEqual(F.familyKey(artist: "宇多田ヒカル", title: "Automatic"),
                    F.familyKey(artist: "宇多田光", title: "Automatic"))
        expectEqual(F.familyKey(artist: "Soft Lipa", title: "偷偷"),
                    F.familyKey(artist: "蛋堡", title: "偷偷"))
        expectEqual(F.familyKey(artist: "Khalil Fong & Fiona Sit", title: "Oasis"),
                    F.familyKey(artist: "方大同", title: "Oasis"))

        expectEqual(F.familyKey(artist: "K", title: "X"), F.key(artist: "K", title: "X"))

        expectNotEqual(F.familyKey(artist: "Count Basie", title: "X"),
                       F.familyKey(artist: "阿肆", title: "X"))
        expectNotEqual(F.familyKey(artist: "Fantasia", title: "X"),
                       F.familyKey(artist: "阿肆", title: "X"))
        expectEqual(F.familyKey(artist: "A Si", title: "X"), F.familyKey(artist: "阿肆", title: "X"))

        expectEqual(F.familyKey(artist: "Daniel Caesar & Mustafa", title: "Toronto 2014"),
                    F.familyKey(artist: "Daniel Caesar", title: "Toronto 2014"))

        expectEqual(F.familyKey(artist: "Michael Jackson", title: "Bad"),
                    F.key(artist: "Michael Jackson", title: "Bad"))
        expectNotEqual(F.familyKey(artist: "David Tao", title: "找自己"),
                       F.key(artist: "David Tao", title: "找自己"))

        F.setLocalTitleAliases(["方大同": ["lovelovelove": "爱爱爱", "nanyin": "南音", "blackhole": "黑洞里"]])
        defer { F.setLocalTitleAliases([:]) }
        expectEqual(F.familyKey(artist: "方大同", title: "Love Love Love"),
                    F.familyKey(artist: "方大同", title: "爱爱爱"))
        expectEqual(F.familyKey(artist: "Khalil Fong", title: "Love Love Love"),
                    F.familyKey(artist: "方大同", title: "愛愛愛"))

        expectNotEqual(F.familyKey(artist: "王力宏", title: "Love Love Love"),
                       F.familyKey(artist: "方大同", title: "爱爱爱"))
        expectEqual(F.familyKey(artist: "王力宏", title: "Love Love Love"),
                    F.key(artist: "王力宏", title: "Love Love Love"))
        expectEqual(F.familyKey(artist: "某歌手", title: "爱爱爱"),
                    F.key(artist: "某歌手", title: "爱爱爱"))
        expectEqual(F.familyKey(artist: "方大同", title: "nanyin"),
                    F.familyKey(artist: "方大同", title: "南音"))
        expectEqual(F.familyKey(artist: "方大同", title: "南音"),
                    F.key(artist: "方大同", title: "南音"))
        expectEqual(F.familyKey(artist: "Khalil Fong", title: "Black Hole"),
                    F.familyKey(artist: "方大同", title: "黑洞裡"))
        expectEqual(F.familyKey(artist: "方大同", title: "Weather Report"),
                    F.key(artist: "方大同", title: "Weather Report"))
    }

    do {
        typealias F = PlayCountFold
        defer { F.setDiscoveredTitleAliases([:]); F.setLocalTitleAliases([:]) }

        F.setDiscoveredTitleAliases(["测试歌手": ["testsong": "测试歌曲"]])
        expectEqual(F.familyKey(artist: "测试歌手", title: "TestSong"),
                    F.familyKey(artist: "测试歌手", title: "测试歌曲"))
        expectEqual(F.familyKey(artist: "别的歌手", title: "TestSong"),
                    F.key(artist: "别的歌手", title: "TestSong"))

        F.setLocalTitleAliases(["测试歌手": ["testsong": "另一首歌"]])
        expectEqual(F.familyKey(artist: "测试歌手", title: "TestSong"),
                    F.familyKey(artist: "测试歌手", title: "另一首歌"))
    }

    do {

        expectEqual(ScrobbleRule.thresholdFraction(durationMs: 29_000), nil)
        expectEqual(ScrobbleRule.thresholdFraction(durationMs: 0), nil)

        expectEqual(ScrobbleRule.thresholdFraction(durationMs: 200_000), 0.5)

        expectEqual(ScrobbleRule.thresholdFraction(durationMs: 600_000), 0.4)

        expectEqual(ScrobbleRule.thresholdFraction(durationMs: 480_000), 0.5)
    }

    do {
        let sample = """
        {"username":"KhalilChan3","fetchedAt":1800000000,"total":24271,
         "nowPlaying":{"artist":"A","title":"Now","album":"NP","image":"l-np.png"},
         "tracks":[{"artist":"B","title":"One","album":"Alb","image":"xl1.png","uts":1700000100},
                   {"artist":"C","title":"Two","uts":1700000000}]}
        """
        let feed = LastfmRecentFeed.decode(Data(sample.utf8))
        expectEqual(feed?.username, "KhalilChan3")
        expectEqual(feed?.total, 24271)
        expectEqual(feed?.nowPlaying?.title, "Now")
        expectEqual(feed?.nowPlaying?.uts, nil)
        expectEqual(feed?.tracks.count, 2)
        expectEqual(feed?.tracks[1].album, nil)
        expectEqual(feed?.tracks[0].uts, 1700000100)
        expectEqual(LastfmRecentFeed.decode(Data("{\"tracks\":[]}".utf8)), nil)

        let at = Date(timeIntervalSince1970: 1800000000)
        expectEqual(feed?.isFresh(now: at.addingTimeInterval(179)), true)
        expectEqual(feed?.isFresh(now: at.addingTimeInterval(180)), false)
        expectEqual(feed?.isFresh(now: at.addingTimeInterval(-5)), false)

        expectEqual(LastfmRecentFeed.totalPages(total: 24271, pageSize: 20), 1214)
        expectEqual(LastfmRecentFeed.totalPages(total: 40, pageSize: 20), 2)
        expectEqual(LastfmRecentFeed.totalPages(total: 0, pageSize: 20), 1)

        let r1 = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200, 1100, 900, 800], todayStart: 1000,
                                             bucketToday: 99, syncedThrough: 0)
        expectEqual(r1.count, 3)
        expectEqual(r1.exact, true)

        let r2 = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200, 1100, 1050], todayStart: 1000,
                                             bucketToday: 40, syncedThrough: 1150)
        expectEqual(r2.count, 42)
        expectEqual(r2.exact, true)

        let r2b = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200], todayStart: 1000,
                                              bucketToday: nil, syncedThrough: 1100)
        expectEqual(r2b.count, 2)

        let r3 = LastfmRecentFeed.todayCount(rowUTS: [1300, 1200, 1100, 1050], todayStart: 1000,
                                             bucketToday: nil, syncedThrough: 500)
        expectEqual(r3.count, 4)
        expectEqual(r3.exact, false)

        let r4 = LastfmRecentFeed.todayCount(rowUTS: [], todayStart: 1000, bucketToday: nil, syncedThrough: 1200)
        expectEqual(r4.count, 0)
        expectEqual(r4.exact, true)
    }

    do {
        typealias C = LastfmPageComposer
        typealias S = LastfmPageComposer.Source<Int>
        let ident: (Int) -> String = { String($0) }

        expectEqual(C.firstPosition(page: 3, pageSize: 20, totalAtFetch: 100, totalNow: 103), 43)
        expectEqual(C.firstPosition(page: 1, pageSize: 20, totalAtFetch: 100, totalNow: 100), 0)
        expectEqual(C.firstPosition(page: 2, pageSize: 20, totalAtFetch: 100, totalNow: 99), nil)

        let feed = S(firstPosition: 0, rows: Array(0 ..< 50))
        let cachedP3 = S(firstPosition: 43, rows: Array(43 ..< 63))
        expectEqual(C.compose(page: 3, pageSize: 20, total: 103, sources: [feed, cachedP3], identity: ident),
                    Array(40 ..< 60))

        expectEqual(C.compose(page: 2, pageSize: 20, total: 103, sources: [feed], identity: ident),
                    Array(20 ..< 40))
        expectEqual(C.compose(page: 3, pageSize: 20, total: 103, sources: [feed], identity: ident),
                    nil)

        let tail = S(firstPosition: 40, rows: Array(40 ..< 45))
        expectEqual(C.compose(page: 3, pageSize: 20, total: 45, sources: [tail], identity: ident),
                    Array(40 ..< 45))

        expectEqual(C.compose(page: 4, pageSize: 20, total: 45, sources: [tail], identity: ident), nil)
        expectEqual(C.compose(page: 1, pageSize: 20, total: 0, sources: [feed], identity: ident), nil)

        let misaligned = S(firstPosition: 43, rows: Array(42 ..< 62))
        expectEqual(C.compose(page: 3, pageSize: 20, total: 103, sources: [feed, misaligned], identity: ident),
                    nil)

        let newer = S(firstPosition: 40, rows: [1000, 1001])
        let older = S(firstPosition: 40, rows: [2000, 2001] + Array(42 ..< 60))
        expectEqual(C.compose(page: 3, pageSize: 20, total: 103, sources: [newer, older], identity: ident)?.prefix(2).map { $0 },
                    [1000, 1001])

        expectEqual(C.compose(page: 1, pageSize: 20, total: 30, sources: [S(firstPosition: -5, rows: Array(0 ..< 30)), S(firstPosition: 0, rows: Array(0 ..< 20))], identity: ident),
                    Array(0 ..< 20))
    }

    do {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let fmt = DateFormatter()
        fmt.calendar = cal; fmt.timeZone = cal.timeZone; fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let key: (Date) -> String = { fmt.string(from: $0) }
        let today = fmt.date(from: "2026-09-03")!.addingTimeInterval(3600 * 13)

        let buckets: [String: Int] = ["2025-09-03": 5, "2024-09-01": 2, "2024-09-06": 7, "2023-08-20": 3]
        let plan = OnThisDayPlanner.plan(today: today, years: 3, dailyCounts: buckets, synced: true, dayKey: key)
        expectEqual(plan.map { "\($0.yearsAgo):\($0.span.rawValue):\($0.expected ?? -1)" },
                    ["1:1:5", "2:7:9"])
        expectEqual(plan.map { key($0.from) }, ["2025-09-03", "2024-08-31"])
        expectEqual(plan.map { key($0.to) }, ["2025-09-04", "2024-09-07"])

        let blind = OnThisDayPlanner.plan(today: today, years: 3, dailyCounts: [:], synced: false, dayKey: key)
        expectEqual(blind.map { "\($0.yearsAgo):\($0.span.rawValue):\($0.expected == nil)" },
                    ["1:1:true", "2:1:true", "3:1:true"])
        expectEqual(OnThisDayPlanner.plan(today: today, years: 3, dailyCounts: [:], synced: true, dayKey: key).isEmpty,
                    true)

        var days: [String: Int] = [:]
        for d in ["2026-08-10", "2026-08-11", "2026-08-12", "2026-08-13", "2026-08-14"] { days[d] = 10 }
        for d in ["2026-08-30", "2026-08-31", "2026-09-01", "2026-09-02"] { days[d] = 20 }
        days["2026-08-12"] = 209
        days["2023-01-05"] = 7
        days["2023-09-02"] = 40
        days["2023-12-25"] = 99
        days["2025-11-01"] = 3
        let s = ListeningMilestones.summarize(dailyCounts: days, today: today, calendar: cal, dayKey: key)
        expectEqual(s.firstDay, "2023-01-05")
        expectEqual(s.daysSinceFirst, 1338)
        expectEqual(s.recordedDays, 13)
        expectEqual(s.peak, .init(day: "2026-08-12", count: 209))
        expectEqual(s.currentStreak, 4)
        expectEqual(s.longestStreak, 5)
        expectEqual(s.longestStreakEnd, "2026-08-14")
        expectEqual(s.yearToDate, 50 + 80 + 209 - 10)
        expectEqual(s.priorYearSameSpan?.year, 2023)
        expectEqual(s.priorYearSameSpan?.count, 47)

        var days2 = days; days2["2026-09-03"] = 1
        expectEqual(ListeningMilestones.summarize(dailyCounts: days2, today: today, calendar: cal, dayKey: key).currentStreak,
                    5)
        expectEqual(ListeningMilestones.summarize(dailyCounts: [:], today: today, calendar: cal, dayKey: key),
                    .init(firstDay: nil, daysSinceFirst: nil, recordedDays: 0, peak: nil, currentStreak: 0,
                          longestStreak: 0, longestStreakEnd: nil, yearToDate: 0, priorYearSameSpan: nil))

        expectEqual(ListeningMilestones.nextMilestone(total: 24300).target, 25000)
        expectEqual(ListeningMilestones.nextMilestone(total: 24300).remaining, 700)
        expectEqual(ListeningMilestones.nextMilestone(total: 25000).target, 26000)
        expectEqual(ListeningMilestones.nextMilestone(total: 4321).target, 4500)
        expectEqual(ListeningMilestones.nextMilestone(total: 42).target, 100)
    }

    do {
        typealias B = PlayCountUnavailableBackoff
        let h = 3600.0
        expectEqual(B.delay(strikes: 1), 1 * h)
        expectEqual(B.delay(strikes: 2), 6 * h)
        expectEqual(B.delay(strikes: 3), 24 * h)
        expectEqual(B.delay(strikes: 9), 24 * h)
        expectEqual(B.delay(strikes: 0), 1 * h)
        let t0 = Date(timeIntervalSince1970: 1_788_424_564)
        expectEqual(B.isDue(markedAt: t0, strikes: 1, now: t0.addingTimeInterval(59 * 60)), false)
        expectEqual(B.isDue(markedAt: t0, strikes: 1, now: t0.addingTimeInterval(60 * 60)), true)
        expectEqual(B.isDue(markedAt: t0, strikes: 2, now: t0.addingTimeInterval(5 * h)), false)
        expectEqual(B.isDue(markedAt: t0, strikes: 2, now: t0.addingTimeInterval(6 * h)), true)
        expectEqual(B.isDue(markedAt: t0, strikes: 3, now: t0.addingTimeInterval(23 * h)), false)
        expectEqual(B.isDue(markedAt: t0, strikes: 7, now: t0.addingTimeInterval(24 * h)), true)
        expectEqual(B.isDue(markedAt: t0, strikes: 1, now: t0.addingTimeInterval(-10)), false)
    }

    do {
        typealias O = PlayCountOutcome
        func c(_ ok: Bool, _ n: Int?, _ old: Bool) -> O {
            O.classify(requestSucceeded: ok, reportedCount: n, rowIsOldEnough: old)
        }

        expectEqual(c(true, nil, true), .unanswered)

        expectEqual(c(true, 0, true), .definitivelyNone)

        expectEqual(c(true, 0, false), .unanswered)

        expectEqual(c(true, 18, true), .counted(18))
        expectEqual(c(true, 1, false), .counted(1))

        expectEqual(c(false, nil, true), .unanswered)
        expectEqual(c(false, 0, true), .unanswered)
        expectEqual(c(false, 5, true), .unanswered)

        expectEqual(c(true, 0, true), .definitivelyNone)
    }

    do {
        typealias E = PlayCountFoldExplainer
        func r(_ a: (String, String), _ b: (String, String)) -> [PlayCountFoldReason] {
            E.reasons(base: (artist: a.0, title: a.1), variant: (artist: b.0, title: b.1))
        }
        expectEqual(r(("Prince", "Call My Name"), ("Prince", "Call My Name")), [])
        expectEqual(r(("Prince", "Call My Name"), ("Prince", "Call my name")), [.caseOrSpacing])
        expectEqual(r(("Prince", "Call My Name"), ("Prince", "CallMyName")), [.caseOrSpacing])
        expectEqual(r(("丁世光", "一口(The Day You Left Me)"), ("丁世光", "一口（The Day You Left Me）")), [.fullwidth])
        expectEqual(r(("盧廣仲", "我不是农人"), ("盧廣仲", "我不是農人")), [.hanScript])
        expectEqual(r(("宇多田ヒカル", "Automatic"), ("宇多田ヒカル", "Automatic (Remastered 2014)")), [.catalogNoise])
        expectEqual(r(("王力宏", "蓋世英雄"), ("王力宏", "盖世英雄 (feat. 欧阳靖 & 李岩)")), [.catalogNoise])
        expectEqual(r(("方大同", "沙滩 (钢琴版)"), ("方大同", "沙滩 - 钢琴版")), [.versionSuffix])

        expectEqual(r(("方大同", "流沙 (Live)"), ("方大同", "流沙 - Live")), [.other])
        expectEqual(r(("陳綺貞", "月食"), ("陳綺貞", "月食 The Weeping Woman")), [.bilingualTitle])
        expectEqual(r(("Daniel Caesar", "Toronto 2014"), ("Daniel Caesar & Mustafa", "Toronto 2014")), [.artistCredit])
        PlayCountFold.setLocalArtistAliases(["davidtao": "陶喆"])
        expectEqual(r(("陶喆", "普通朋友"), ("David Tao", "普通朋友")), [.artistAlias])
        PlayCountFold.setLocalArtistAliases([:])
        expectEqual(r(("陶喆", "普通朋友"), ("David Tao", "普通朋友")), [.other])
        PlayCountFold.setLocalTitleAliases(["方大同": ["lovelovelove": "爱爱爱"]])
        expectEqual(r(("方大同", "爱爱爱"), ("方大同", "Love Love Love")), [.titleAlias])
        PlayCountFold.setLocalTitleAliases([:])
        expectEqual(r(("周杰倫", "園遊會"), ("周杰伦 & 派伟俊", "园游会")), [.artistCredit, .hanScript])
        expectEqual(r(("Prince", "Call My Name"), ("Prince", "Kiss")), [.other])

        expectEqual(E.albumReason(base: "葉惠美", variant: "叶惠美"), .hanScript)
        expectEqual(E.albumReason(base: "First Love", variant: "First Love (Remastered 2014)"), .catalogNoise)
        expectEqual(E.albumReason(base: "八度空间", variant: "八度空间"), nil)
        expectEqual(E.albumReason(base: nil, variant: "八度空间"), nil)

        expectEqual(E.albumReason(base: "葉惠美", variant: "范特西"), nil)
        expectEqual(E.albumReason(base: "心中的日月", variant: "Shangri-la"), nil)
    }
    do {
        typealias M = PlayCountBreakdownMath
        func at(_ e: Double) -> Date { Date(timeIntervalSince1970: e) }
        func v(_ artist: String, _ title: String, total: Int, isSelf: Bool = false,
               _ times: [Double], failed: Bool = false) -> M.VariantInput {
            .init(artist: artist, title: title, total: total, isSelf: isSelf,
                  reasons: isSelf ? [] : [.hanScript],
                  plays: times.map { (date: at($0), album: nil) }, failed: failed)
        }

        let two = M.build([
            v("周杰倫", "园游会", total: 3, isSelf: true, [3000, 2000, 1000]),
            v("周杰倫", "園遊會", total: 2, [2500, 500]),
        ])
        expectEqual(two.total, 5)
        expectEqual(two.plays.map { $0.date.timeIntervalSince1970 }, [3000, 2500, 2000, 1000, 500])
        expectEqual(two.plays.map(\.variantIndex), [0, 1, 0, 0, 1])
        expectEqual(two.ordinals, [5, 4, 3, 2, 1])
        expectEqual(two.ordinalCutoff, nil)
        expectEqual(two.canLoadOlder, false)
        expectEqual(two.variants.map(\.reasons), [[], [.hanScript]])

        let dup = M.build([
            v("卢广仲", "Boring", total: 3, isSelf: true, [3000, 2000, 2000]),
            v("Crowd Lu", "Boring", total: 3, [3000, 2000, 100]),
        ])
        expectEqual(dup.total, 6)
        expectEqual(dup.plays.count, 6)
        expectEqual(dup.plays.map(\.variantIndex), [0, 1, 0, 0, 1, 1])
        expectEqual(Set(dup.plays.map(\.id)).count, 6)
        expectEqual(dup.ordinals, [6, 5, 4, 3, 2, 1])

        let partial = M.build([
            v("A", "x", total: 300, isSelf: true, [5000, 3000]),
            v("A", "X", total: 2, [4000, 1000]),
        ])
        expectEqual(partial.ordinalCutoff, at(3000))
        expectEqual(partial.total, 302)
        expectEqual(partial.ordinals, [302, 301, 300, nil])
        expectEqual(partial.canLoadOlder, true)

        let both = M.build([
            v("A", "x", total: 300, isSelf: true, [5000, 3000]),
            v("A", "X", total: 300, [4000, 3500]),
        ])
        expectEqual(both.ordinalCutoff, at(3500))

        let failed = M.build([
            v("A", "x", total: 2, isSelf: true, [2000, 1000]),
            v("A", "X", total: 0, [], failed: true),
        ])
        expectEqual(failed.hasFailure, true)
        expectEqual(failed.total, 2)
        expectEqual(failed.ordinals, [nil, nil])
        expectEqual(failed.canLoadOlder, false)
        expectEqual(failed.variants[1].exhausted, false)

        let empty = M.build([v("A", "x", total: 0, isSelf: true, [])])
        expectEqual(empty.total, 0)
        expectEqual(empty.ordinals, [])

        let albums = M.build([
            .init(artist: "周杰倫", title: "晴天", total: 6, isSelf: true, reasons: [], plays: [
                (date: at(6000), album: "葉惠美"), (date: at(5000), album: "叶惠美"),
                (date: at(4000), album: "葉惠美"), (date: at(3000), album: " "),
                (date: at(2000), album: "叶惠美"), (date: at(1000), album: "葉惠美"),
            ]),
            .init(artist: "周杰伦", title: "晴天", total: 1, isSelf: false, reasons: [.hanScript],
                  plays: [(date: at(500), album: "范特西")]),
        ])
        expectEqual(albums.albumGroups(variantIndex: 0).map { ($0.album ?? "∅") + ":\($0.count)" },
                    ["葉惠美:3", "叶惠美:2", "∅:1"])
        expectEqual(albums.albumGroups(variantIndex: 1).map { ($0.album ?? "∅") + ":\($0.count)" }, ["范特西:1"])
        expectEqual(M.build([v("A", "x", total: 2, isSelf: true, [2000, 1000])]).albumGroups(variantIndex: 0).count, 1)
    }

    do {
        typealias A = EnrichTitleAliases
        func e(_ artist: String, _ title: String, netease: String? = nil, qq: String? = nil, dur: Double? = nil) -> A.Entry {
            .init(artist: artist, title: title, neteaseURL: netease, qqMusicURL: qq, durationSecs: dur)
        }
        let ne = "https://music.163.com/song?id=2635125902"

        expectEqual(A.songIDs(neteaseURL: ne, qqMusicURL: nil), ["netease:2635125902"])
        expectEqual(A.songIDs(neteaseURL: "https://music.163.com/#/song?id=42&x=1", qqMusicURL: nil), ["netease:42"])
        expectEqual(A.songIDs(neteaseURL: nil, qqMusicURL: "https://y.qq.com/n/ryqq/songDetail/002lChJY23SXj7"), ["qq:002lChJY23SXj7"])
        expectEqual(A.songIDs(neteaseURL: nil, qqMusicURL: "https://y.qq.com/n/ryqq/search?w=Khalil+Fong+Oasis"), [])
        expectEqual(A.songIDs(neteaseURL: "https://open.spotify.com/search/x", qqMusicURL: nil), [])

        PlayCountFold.setLocalArtistAliases(["khalilfong": "方大同"])
        defer { PlayCountFold.setLocalArtistAliases([:]) }
        let oasis = A.derive([
            e("Khalil Fong", "Oasis", netease: ne, dur: 161.000022),
            e("方大同", "那沙漠里的水", netease: ne, dur: 161),
            e("方大同", "那沙漠里的水", netease: ne, dur: 161),
        ])
        expectEqual(oasis, ["方大同": ["oasis": "那沙漠里的水"]])

        PlayCountFold.setLocalTitleAliases(oasis)
        expectEqual(PlayCountFold.familyKey(artist: "Khalil Fong", title: "Oasis"),
                    PlayCountFold.familyKey(artist: "方大同", title: "那沙漠里的水"))
        expectEqual(PlayCountFoldExplainer.reasons(base: (artist: "Khalil Fong", title: "Oasis"),
                                                   variant: (artist: "方大同", title: "那沙漠里的水")),
                    [.artistAlias, .titleAlias])
        PlayCountFold.setLocalTitleAliases([:])
        expectEqual(PlayCountFold.familyKey(artist: "Khalil Fong", title: "Oasis")
                    == PlayCountFold.familyKey(artist: "方大同", title: "那沙漠里的水"), false)

        expectEqual(A.derive([
            e("方大同", "Oasis", netease: ne), e("方大同", "那沙漠里的水", netease: ne), e("方大同", "梦想家", netease: ne),
        ]), [:])

        expectEqual(A.derive([e("方大同", "Oasis", netease: ne, dur: 161), e("方大同", "那沙漠里的水", netease: ne, dur: 240)]), [:])
        expectEqual(A.derive([e("方大同", "Oasis", netease: ne, dur: 161), e("方大同", "那沙漠里的水", netease: ne, dur: 163)]),
                    ["方大同": ["oasis": "那沙漠里的水"]])
        expectEqual(A.derive([e("方大同", "Oasis", netease: ne), e("方大同", "那沙漠里的水", netease: ne, dur: 161)]),
                    ["方大同": ["oasis": "那沙漠里的水"]])

        expectEqual(A.derive([
            e("方大同", "Oasis", netease: ne), e("方大同", "那沙漠里的水", netease: ne),
            e("方大同", "Oasis", qq: "https://y.qq.com/n/ryqq/songDetail/AAA"), e("方大同", "绿洲", qq: "https://y.qq.com/n/ryqq/songDetail/AAA"),
        ]), [:])

        expectEqual(A.isHanTitled("Ten Reasons (Live版)"), false)
        expectEqual(A.isHanTitled("All for Joy (feat. 关诗敏)"), false)
        expectEqual(A.isHanTitled("一口(The Day You Left Me)"), true)
        expectEqual(A.isHanTitled("刻在我心底的名字 (Your Name Engraved Herein) - 電影<刻在你心底的名字>主題曲"), true)
        expectEqual(A.isHanTitled("Ru Guo Ai"), false)

        let qqA = "https://y.qq.com/n/ryqq/songDetail/003CDIpG2rBZbT"
        expectEqual(A.derive([e("方大同", "Ten Reasons", qq: qqA), e("方大同", "Ten Reasons (Live版)", qq: qqA)]), [:])
        expectEqual(A.derive([e("陶喆", "All for Joy", netease: "https://music.163.com/song?id=26425115"),
                              e("陶喆", "All for Joy (feat. 关诗敏)", netease: "https://music.163.com/song?id=26425115")]), [:])
        expectEqual(A.derive([e("陶喆", "I Like It (Ballad Version)", netease: "https://music.163.com/song?id=150540"),
                              e("陶喆", "What Is Love", netease: "https://music.163.com/song?id=150540"),
                              e("陶喆", "我喜欢(Ballad Version)", netease: "https://music.163.com/song?id=150540")]), [:])

        expectEqual(A.derive([e("方大同", "小小虫", netease: ne), e("方大同", "小小蟲", netease: ne)]), [:])

        expectEqual(A.derive([e("方大同", "Playful", netease: ne), e("方大同", "玩乐", netease: ne), e("方大同", "玩樂", netease: ne)]),
                    ["方大同": ["playful": "玩乐"]])
        expectEqual(A.derive([e("方大同", "Oasis", netease: ne), e("方大同", "Oasis (Live)", netease: ne)]), [:])

        expectEqual(A.derive([e("陶喆", "Oasis", netease: ne), e("方大同", "那沙漠里的水", netease: ne)]), [:])
        expectEqual(A.derive([e("Khalil Fong & 王力宏", "Oasis", netease: ne), e("方大同", "那沙漠里的水", netease: ne)]),
                    ["方大同": ["oasis": "那沙漠里的水"]])
    }

    do {
        typealias A = EnrichTitleAliases

        let lrcHans = """
        [ti:黑洞里]
        [ar:方大同]
        [00:00.50]作词 : 方大同
        [00:01.00]作曲 : 方大同
        [00:12.10]我在黑洞里 找不到出口
        [00:18.30]你说的话 像光一样穿过
        [00:24.00]黑洞里没有时间 只有你的声音
        [00:31.20]我一直往前走 走不到尽头
        [00:38.00]黑洞里没有时间 只有你的声音
        """
        let lrcHant = """
        [00:12.10]<0,300>我<300,300>在<600,300>黑洞裡
        [00:14.00]找不到出口
        [00:18.30]你說的話 像光一樣穿過
        [00:24.00]黑洞裡沒有時間
        [00:26.00]只有你的聲音
        [00:31.20]我一直往前走 走不到盡頭
        [00:38.00]黑洞裡沒有時間 只有你的聲音
        """
        let other = """
        [00:10.00]今天天气很好 我们去公园散步
        [00:15.00]阳光洒在草地上 微风吹过树梢
        [00:20.00]你笑着说这就是幸福 简单而美好
        [00:25.00]我们手牵着手 走过每一个路口
        """
        expectEqual(A.lyricsBody(lrcHans).hasPrefix("我在黑洞里找不到出口"), true)
        expectEqual(A.lyricsSimilarity(A.lyricsBody(lrcHans), A.lyricsBody(lrcHant)) >= A.lyricsSimilarityMin, true)
        expectEqual(A.lyricsSimilarity(A.lyricsBody(lrcHans), A.lyricsBody(other)) < 0.2, true)

        func e(_ artist: String, _ title: String, dur: Double?, resolved: Double? = nil, lyrics: String?) -> A.Entry {
            .init(artist: artist, title: title, neteaseURL: nil, qqMusicURL: nil, durationSecs: dur,
                  resolvedDurationSecs: resolved, lyrics: lyrics)
        }

        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586666, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.586, lyrics: lrcHant),
                              e("方大同", "黑洞裡", dur: 213.586, lyrics: lrcHant)]),
                    ["方大同": ["blackhole": "黑洞裡"]])

        expectEqual(A.derive([e("Khalil Fong", "Black Hole", dur: 213.586666, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.586, lyrics: lrcHant)]), [:])
        expectEqual(A.derive([e("Khalil Fong", "Black Hole", dur: 213.586666, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.586, lyrics: lrcHant)],
                             artistKey: { LocalArtistAliases.canonicalArtistKey($0, table: ["khalilfong": "方大同"]) }),
                    ["方大同": ["blackhole": "黑洞里"]])

        expectEqual(A.derive([e("方大同", "Twenty Three", dur: 224, lyrics: lrcHans),
                              e("方大同", "才二十三", dur: 224.498992919922, lyrics: lrcHant)]),
                    ["方大同": ["twentythree": "才二十三"]])

        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 215, lyrics: lrcHant)]), [:])
        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, lyrics: lrcHans),
                              e("方大同", "公园", dur: 213.586, lyrics: other)]), [:])
        expectEqual(A.derive([e("方大同", "Black Hole", dur: nil, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.586, lyrics: lrcHant)]), [:])
        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, lyrics: nil),
                              e("方大同", "黑洞里", dur: 213.586, lyrics: lrcHant)]), [:])

        expectEqual(A.derive([e("方大同", "Weather Report", dur: 61.08, resolved: 271.5, lyrics: lrcHans),
                              e("方大同", "天气先生", dur: 61.08, lyrics: lrcHant)]), [:])
        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, resolved: 214, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.586, resolved: 213, lyrics: lrcHant)]),
                    ["方大同": ["blackhole": "黑洞里"]])

        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, lyrics: lrcHans),
                              e("方大同", "黑洞里 (Live)", dur: 213.586, lyrics: lrcHant)]), [:])

        expectEqual(A.derive([e("方大同", "Black Hole", dur: 213.586, lyrics: lrcHans),
                              e("方大同", "黑洞里", dur: 213.9, lyrics: lrcHant)]), [:])

        expectEqual(A.derive([e("方大同", "Write A Song For You", dur: 197.273696, lyrics: lrcHans),
                              e("方大同", "为你写的歌", dur: 197.273, lyrics: lrcHant),
                              e("方大同", "为妳写的歌", dur: 197.274002, lyrics: lrcHant),
                              e("方大同", "为妳写的歌", dur: 197.274002, lyrics: lrcHant)]),
                    ["方大同": ["writeasongforyou": "为妳写的歌", "为你写的歌": "为妳写的歌"]])
        expectEqual(A.derive([e("方大同", "阿拉斯加海湾", dur: 200.5, lyrics: lrcHans),
                              e("方大同", "阿拉斯加海湾伴奏", dur: 200.5, lyrics: lrcHans)]), [:])

        let eng1 = """
        [00:10.00]It's close to midnight and something evil's lurking in the dark
        [00:15.00]Under the moonlight you see a sight that almost stops your heart
        [00:20.00]You try to scream but terror takes the sound before you make it
        [00:25.00]You start to freeze as horror looks you right between the eyes
        """
        let eng2 = """
        [00:10.00]Tell me will you keep the faith when the night is long and the road is rough
        [00:15.00]Hold on to the dream and never let it go although the world may say enough
        [00:20.00]Keep the faith and you will find the light that leads you home again
        [00:25.00]Every step you take is one step closer to the day you win
        """
        expectEqual(A.lyricsSimilarity(A.lyricsBody(eng1), A.lyricsBody(eng2)) < 0.1, true)
        expectEqual(A.derive([e("Michael Jackson", "Thriller", dur: 357.75, lyrics: eng1),
                              e("Michael Jackson", "驚悚", dur: 357.75, lyrics: eng2)]), [:])
    }

    do {
        typealias LA = LocalArtistAliases
        typealias A = EnrichTitleAliases
        func e(_ artist: String, _ title: String, netease: String) -> A.Entry {
            .init(artist: artist, title: title, neteaseURL: "https://music.163.com/song?id=" + netease, qqMusicURL: nil, durationSecs: nil)
        }

        let mb = LA.MusicBrainzCaches(
            aliasCache: ["Crowd Lu": "卢广仲"],
            identityZh: ["Soft Lipa": "蛋堡"],
            primaryAliases: ["周杰伦": ["Jay Chou", "Zhou Jie Lun"], "Will Pan": ["潘瑋柏", "Wilber Pan"]])
        let t = LA.derive(caches: mb, entries: [])
        expectEqual(t["crowdlu"], "卢广仲")
        expectEqual(t["softlipa"], "蛋堡")
        expectEqual(t["jaychou"], "周杰伦")
        expectEqual(t["zhoujielun"], "周杰伦")
        expectEqual(t["willpan"], "潘瑋柏")
        expectEqual(t["wilberpan"], "潘瑋柏")
        expectEqual(t["卢广仲"], nil)
        expectEqual(t["michaeljackson"], nil)

        let two = LA.derive(caches: .init(), entries: [
            e("David Tao", "Regular friends", netease: "150623"), e("陶喆", "普通朋友", netease: "150623"),
            e("David Tao", "Let's Fall in Love", netease: "150560"), e("陶喆", "讨厌红楼梦", netease: "150560"),
            e("方大同", "特别的人", netease: "9001"), e("王诗安", "特别的人 (合唱)", netease: "9001"),
        ])
        expectEqual(two["davidtao"], "陶喆")
        expectEqual(two["王诗安"], nil)
        expectEqual(two["方大同"], nil)

        let rep = LA.derive(caches: .init(aliasCache: ["Crowd Lu": "卢广仲"]), entries: [
            e("盧廣仲", "a", netease: "1"), e("盧廣仲", "b", netease: "2"), e("盧廣仲", "c", netease: "3"),
            e("卢广仲", "d", netease: "4"), e("Crowd Lu", "e", netease: "5"),
        ])
        expectEqual(rep["crowdlu"], "盧廣仲")
        expectEqual(rep["卢广仲"], nil)

        let duet = LA.derive(caches: .init(aliasCache: ["Khalil Fong & Fiona Sit": "方大同",
                                                       "Earth, Wind & Fire": "アース、ウインド&ファイアー"]), entries: [])
        expectEqual(duet["khalilfong"], nil)
        expectEqual(duet["earth"], nil)

        let short = LA.derive(caches: .init(primaryAliases: ["周杰伦": ["K", "Jay"]]), entries: [])
        expectEqual(short["k"], nil)
        expectEqual(short["jay"], "周杰伦")

        PlayCountFold.setLocalArtistAliases(two)
        expectEqual(LA.canonicalArtistKey("David Tao & 蔡健雅", table: two), PlayCountFold.canonicalArtistKey("David Tao & 蔡健雅"))
        PlayCountFold.setLocalArtistAliases([:])
    }
}
