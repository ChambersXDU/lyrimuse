import LyrimuseCore
import Foundation

@MainActor
func runIdlePageTests() {

    do {

        let key: (String, String) -> String = { a, t in
            (a.trimmingCharacters(in: .whitespaces) + "|" + t.trimmingCharacters(in: .whitespaces))
                .lowercased()
        }

        let three = [(artist: "方大同", title: "月亮代表我的心"),
                     (artist: "方大同", title: "月亮代表我的心"),
                     (artist: "方大同", title: "月亮代表我的心")]
        expectEqual(RecentPlayOrdinal.ordinals(rows: three,
                                               totals: [key("方大同", "月亮代表我的心"): 10],
                                               playCountKey: key),
                    [10, 9, 8])

        let twoForms = [(artist: "周杰倫", title: "一路向北"),
                        (artist: "周杰伦", title: "一路向北")]
        expectEqual(RecentPlayOrdinal.ordinals(
            rows: twoForms,
            totals: [key("周杰倫", "一路向北"): 16, key("周杰伦", "一路向北"): 16],
            playCountKey: key),
                    [16, 15])

        expectEqual(RecentPlayOrdinal.ordinals(rows: [(artist: "无名", title: "无此曲")],
                                               totals: [:], playCountKey: key),
                    [nil])

        expectEqual(RecentPlayOrdinal.ordinals(rows: three,
                                               totals: [key("方大同", "月亮代表我的心"): 2],
                                               playCountKey: key),
                    [2, 1, nil])
    }

    do {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dayKey: (Date) -> String = { fmt.string(from: $0) }

        let today = Date(timeIntervalSince1970: 1_787_000_000)
        func off(_ n: Int) -> String { dayKey(cal.date(byAdding: .day, value: n, to: today)!) }

        let counts = [off(0): 5, off(-1): 3, off(-3): 7]
        expectEqual(IdleListeningStats.series(dailyCounts: counts, endingAt: today, days: 5,
                                              calendar: cal, dayKey: dayKey),
                    [0, 7, 0, 3, 5])

        let wow = IdleListeningStats.weekOverWeekDelta(
            dailyCounts: [off(-13): 100, off(-6): 113], today: today, calendar: cal, dayKey: dayKey)
        expectEqual(wow.map { Int(($0 * 100).rounded()) } ?? -999, 13)
        expectEqual(IdleListeningStats.weekOverWeekDelta(
            dailyCounts: [off(-2): 5], today: today, calendar: cal, dayKey: dayKey) == nil,
                    true)

        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "", albumA: "BADモード",
            mbidB: "", albumB: "Deep River"), false)
        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "", albumA: "橙月", mbidB: "", albumB: "橙月"), true)
        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "", albumA: "", mbidB: "", albumB: "Deep River"), true)
        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "abc-123", albumA: "A", mbidB: "abc-123", albumB: "B"), true)
        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "abc-123", albumA: "A", mbidB: "xyz-999", albumB: "B"), false)

        expectEqual(TitleAliasEvidence.agrees(
            mbidA: "", albumA: "太平盛世", mbidB: "", albumB: "太平盛世 "), true)

        expectEqual(IdleListeningStats.lastSevenDays(
            dailyCounts: [off(0): 5, off(-1): 3, off(-6): 7, off(-7): 999],
            today: today, calendar: cal, dayKey: dayKey),
                    15)
        expectEqual(IdleListeningStats.lastSevenDays(
            dailyCounts: [off(-1): 3], today: today, todayCount: 20,
            calendar: cal, dayKey: dayKey),
                    23)
        expectEqual(IdleListeningStats.lastSevenDays(
            dailyCounts: [off(0): 999, off(-1): 3], today: today, todayCount: 20,
            calendar: cal, dayKey: dayKey),
                    23)

        expectEqual(IdleListeningStats.weekOverWeekDelta(
            dailyCounts: [off(-13): 100, off(-6): 100], today: today,
            calendar: cal, dayKey: dayKey).map { Int(($0 * 100).rounded()) } ?? -999,
                    0)
        expectEqual(IdleListeningStats.weekOverWeekDelta(
            dailyCounts: [off(-13): 100, off(-6): 100], today: today, todayCount: 20,
            calendar: cal, dayKey: dayKey).map { Int(($0 * 100).rounded()) } ?? -999,
                    20)

        expectEqual(IdleListeningStats.weekOverWeekDelta(
            dailyCounts: [off(-13): 100, off(-6): 100, off(0): 999], today: today, todayCount: 20,
            calendar: cal, dayKey: dayKey).map { Int(($0 * 100).rounded()) } ?? -999,
                    20)

        expectEqual(IdleListeningStats.dailyAverage(dailyCounts: ["a": 1, "b": 4])?.average, 3)
        expectEqual(IdleListeningStats.dailyAverage(dailyCounts: ["a": 1, "b": 4])?.days, 2)
        expectEqual(IdleListeningStats.dailyAverage(dailyCounts: [:]) == nil, true)

        let ds = IdleListeningStats.days(endingAt: today, days: 5, calendar: cal)
        expectEqual(ds.count, 5)
        expectEqual(ds.map(dayKey), (-4 ... 0).map(off))

    }

    do {
        func L(_ ms: Int, _ t: String) -> LyricQuotePicker.Line {
            LyricQuotePicker.Line(timeMs: ms, text: t)
        }
        typealias Q = LyricQuotePicker

        expectEqual(Q.phrases([L(20_000, "我们"), L(20_800, "都有难忘的回忆"),
                               L(28_000, "这一句自己就能站住不必再并")]),
                    [["我们", "都有难忘的回忆"], ["这一句自己就能站住不必再并"]])

        expectEqual(Q.phrases([L(0, "我把所有的回忆都留在"), L(9_000, "另一个夏天的午后阳光里")]),
                    [["我把所有的回忆都留在", "另一个夏天的午后阳光里"]])

        expectEqual(Q.phrases([L(0, "我把所有的回忆都留在")]), [])

        expectEqual(Q.phrases([L(0, "的时候我们都还很年轻啊")]), [])

        expectEqual(Q.phrases([L(0, "Rap2："), L(1_000, "面面面面面"),
                               L(2_000, "（和声重复的伴唱）"), L(3_000, "这一句是正常的歌词内容")]),
                    [["这一句是正常的歌词内容"]])

        expectEqual(Q.phrases([L(0, "天气先生 - 方大同"), L(4_000, "这一句是正常的歌词内容")],
                              trackTitle: "天气先生", trackArtist: "方大同"),
                    [["这一句是正常的歌词内容"]])
        expectEqual(Q.phrases([L(0, "如果你正好在成都的街头走一走")], trackTitle: "成都"),
                    [["如果你正好在成都的街头走一走"]])

        expectEqual(Q.phrases([L(90_000, "副歌这一句在第二次出现"),
                               L(10_000, "开头这一句才是最早的"),
                               L(11_000, "紧跟着的短句")]),
                    [["开头这一句才是最早的", "紧跟着的短句"], ["副歌这一句在第二次出现"]])

        expectEqual(Q.phrases([L(0, "重复出现的同一句歌词"), L(20_000, "重复出现的同一句歌词")]),
                    [["重复出现的同一句歌词"]])
    }

    do {
        typealias P = PlatformLinks

        expectEqual(P.isQQSearchFallback("https://y.qq.com/n/ryqq/search?w=%E7%A8%BB%E9%A6%99"), true)
        expectEqual(P.isQQSearchFallback("https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49"), false)
        expectEqual(P.isQQSearchFallback(""), false)

        expectEqual(P.qqAlbumURL(mid: "002B4bAK3AC0Cw")?.absoluteString,
                    "https://y.qq.com/n/ryqq/albumDetail/002B4bAK3AC0Cw")
        expectEqual(P.qqArtistURL(mid: "0025NhlN2yWrP4")?.absoluteString,
                    "https://y.qq.com/n/ryqq/singer/0025NhlN2yWrP4")
        expectEqual(P.qqAlbumURL(mid: "") == nil, true)

        expectEqual(P.isPlausibleQQMid("002B4bAK3AC0Cw"), true)
        expectEqual(P.isPlausibleQQMid("abc/def"), false)
        expectEqual(P.isPlausibleQQMid("abc?x=1"), false)
        expectEqual(P.isPlausibleQQMid(String(repeating: "a", count: 33)), false)
        expectEqual(P.isPlausibleQQMid("a_b-c"), true)

        expectEqual(PlatformLinks(appleMusic: nil, qqSong: nil, qqAlbum: nil,
                                  qqArtist: nil, neteaseSong: nil).isEmpty, true)
        expectEqual(PlatformLinks(appleMusic: nil, qqSong: nil, qqAlbum: nil, qqArtist: nil, neteaseSong: nil,
                                  spotifySong: URL(string: "https://open.spotify.com/track/1")).isEmpty, false)

        expectEqual(P.spotifyTrackURL(id: "1Xyo4u8uXC1ZmMpatF05PJ")?.absoluteString,
                    "https://open.spotify.com/track/1Xyo4u8uXC1ZmMpatF05PJ")
        expectEqual(P.spotifyTrackURL(id: "") == nil, true)
        expectEqual(P.spotifyTrackURL(id: "missing value") == nil, true)
        expectEqual(P.spotifyTrackURL(id: "1Xyo4u8uXC1ZmMpatF05P") == nil, true)
        expectEqual(P.spotifyTrackURL(id: "1Xyo4u8uXC1ZmMpatF05P/") == nil, true)

        let am = URL(string: "music://music.apple.com/cn/album/x/1?i=2")!
        let qq = URL(string: "https://y.qq.com/n/ryqq/songDetail/004Yi5BD3ksoAN")!
        let ne = URL(string: "https://music.163.com/song?id=277787")!
        let sp = URL(string: "https://open.spotify.com/track/1Xyo4u8uXC1ZmMpatF05PJ")!
        let all = PlatformLinks(appleMusic: am, qqSong: qq, qqAlbum: nil, qqArtist: nil, neteaseSong: ne, spotifySong: sp)
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.appleMusic.bundleIdentifier)?.url, am)
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.appleMusic.bundleIdentifier)?.platform, .appleMusic)
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.qqMusic.bundleIdentifier)?.url, qq)
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.netease.bundleIdentifier)?.url, ne)
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.spotify.bundleIdentifier)?.url, sp)
        expectEqual(all.songLink(forPlayerBundleID: "com.google.Chrome", webPlatformID: "spotifyWeb")?.platform, .spotify)
        expectEqual(all.songLink(forPlayerBundleID: "com.google.Chrome", webPlatformID: "youtubeMusic") == nil, true)
        expectEqual(all.songLink(forPlayerBundleID: "com.google.Chrome") == nil, true)
        expectEqual(all.songLink(forPlayerBundleID: PlaybackPlayer.kugou.bundleIdentifier) == nil, true)
        expectEqual(all.songLink(forPlayerBundleID: nil) == nil, true)
        expectEqual(all.songLink(forPlayerBundleID: "") == nil, true)

        let noNetease = PlatformLinks(appleMusic: am, qqSong: qq, qqAlbum: nil, qqArtist: nil, neteaseSong: nil)
        expectEqual(noNetease.songLink(forPlayerBundleID: PlaybackPlayer.netease.bundleIdentifier) == nil, true)
        expectEqual(noNetease.songLink(forPlayerBundleID: PlaybackPlayer.spotify.bundleIdentifier) == nil, true)
    }
}
