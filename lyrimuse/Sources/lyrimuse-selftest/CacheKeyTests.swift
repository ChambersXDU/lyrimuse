import LyrimuseCore
import Foundation

@MainActor
func runCacheKeyTests() {

    do {
        let calibratedArtist = "周杰伦"
        let calibratedTitle = "枫"
        let calibratedLyrics = "[00:05.00]词一\n[00:10.00]词二\n"
        let calibratedYRC = ""
        let realOffsetKey = LyricsOffsetStore.trackKey(
            artist: calibratedArtist, title: calibratedTitle,
            lyrics: calibratedLyrics, lyricsYRC: calibratedYRC)
        let snapshot: [String: Int] = [realOffsetKey: 1200]

        let offsetPrefixes: Set<String> = Set(snapshot.keys.compactMap { key in
            guard let sep = key.range(of: "|", options: .backwards) else { return nil }
            return String(key[..<sep.lowerBound])
        })

        let hitPrefix = "\(EnrichCacheKeys.cleanTag(calibratedArtist))|\(EnrichCacheKeys.normalizedTitle(calibratedTitle))"
        expectEqual(offsetPrefixes.contains(hitPrefix), true)
        let hitKey = LyricsOffsetStore.trackKey(
            artist: calibratedArtist, title: calibratedTitle,
            lyrics: calibratedLyrics, lyricsYRC: calibratedYRC)
        expectEqual(snapshot[hitKey], 1200)

        let unrelatedArtist = "五月天"
        let unrelatedTitle = "倔强"
        let missPrefix = "\(EnrichCacheKeys.cleanTag(unrelatedArtist))|\(EnrichCacheKeys.normalizedTitle(unrelatedTitle))"
        expectEqual(offsetPrefixes.contains(missPrefix), false)
        let oldWayKey = LyricsOffsetStore.trackKey(
            artist: unrelatedArtist, title: unrelatedTitle,
            lyrics: "[00:01.00]随便什么歌词\n", lyricsYRC: "")
        expectEqual(snapshot[oldWayKey], nil)
    }

    do {

        expectEqual(EnrichCacheKeys.crc32IEEE(""), UInt32(0))
        expectEqual(EnrichCacheKeys.crc32IEEE("123456789"), UInt32(0xCBF4_3926))
        expectEqual(EnrichCacheKeys.crc32IEEE("a"), UInt32(0xE8B7_BE43))

        expectEqual(
            EnrichCacheKeys.disambiguatedName(forKey: "方大同|张永成 (feat. Ghost Style)|15"),
            "方大同 - 张永成 (feat. Ghost Style) - 15~00fad0"
        )
        expectEqual(
            EnrichCacheKeys.disambiguatedName(forKey: "方大同|张永成 (Feat. Ghost Style)|15"),
            "方大同 - 张永成 (Feat. Ghost Style) - 15~c8df08"
        )
    }

    do {

        expectEqual(EnrichCacheKeys.sanitizeFilename("Artist|Song|Album"), "Artist - Song - Album")
        expectEqual(EnrichCacheKeys.sanitizeFilename("A/B|C:D|E*F?"), "A_B - C_D - E_F_")

        let names = EnrichCacheKeys.exportedFileNames(forKey: "Artist|Song|Album")
        expectEqual(names.count, 8)
        expectEqual(names[0], "Artist - Song - Album.lrc")
        expectEqual(names[3], "Artist - Song - Album.yrc")
        expectEqual(
            names[4], "Artist - Song - Album~\(String(format: "%06x", EnrichCacheKeys.crc32IEEE("Artist|Song|Album") & 0xFF_FFFF)).lrc"
        )

        expectEqual(names[4].hasPrefix("Artist - Song - Album"), true)
    }

    do {

        let existing: Set<String> = ["B|b|al2", "A|a|al1", "C|c|al3"]
        expectEqual(
            EnrichCacheKeys.deletionPlan(selected: ["A|a|al1", "已经没了|x|y"], existing: existing),
            ["A|a|al1"]
        )
        expectEqual(EnrichCacheKeys.deletionPlan(selected: [], existing: existing), [])
        expectEqual(
            EnrichCacheKeys.deletionPlan(selected: existing, existing: existing),
            ["A|a|al1", "B|b|al2", "C|c|al3"]
        )
        expectEqual(
            EnrichCacheKeys.deletionPlan(selected: ["X|x|x"], existing: existing), []
        )
    }

    do {
        let K = EnrichCacheKeys.self
        let cases: [(String, String, String)] = [

            ("全角括号译名", "不散的筵席（I Miss You）", "不散的筵席"),
            ("全角括号译名2", "神探（The Detective）", "神探"),
            ("半角括号译名", "小師妹 (Love Triangle)", "小師妹"),

            ("remix 保留", "Song (Remix)", "Song (Remix)"),
            ("live 保留", "告白气球 (Live)", "告白气球 (Live)"),
            ("remaster 保留", "Bad (2012 Remaster)", "Bad (2012 Remaster)"),
            ("feat 保留", "爱我的人 (feat. MOE.)", "爱我的人 (feat. MOE.)"),
            ("instrumental 保留", "Song (Instrumental)", "Song (Instrumental)"),
            ("interlude 保留", "The Girl In Red (Interlude)", "The Girl In Red (Interlude)"),
            ("中文版本标记保留", "月亮代表我的心 (现场版)", "月亮代表我的心 (现场版)"),

            ("慢板保留", "Secret (慢板)", "Secret (慢板)"),
            ("快板保留", "第二圆舞曲 (快板)", "第二圆舞曲 (快板)"),

            ("括号就是整个歌名", "(Interlude)", "(Interlude)"),
            ("括号就是整个歌名2", "（前奏）", "（前奏）"),
            ("两层括号连剥", "歌名（译名）[Explicit]", "歌名"),
            ("剥到版本标记停手", "歌名（译名）(Live)", "歌名（译名）(Live)"),
            ("中间的括号不动", "Song (A) tail", "Song (A) tail"),
            ("没有括号", "不散的筵席", "不散的筵席"),
            ("空串", "", ""),
            ("不换行空格", "Song\u{00a0}(I Miss You)", "Song"),
            ("零宽字符", "不散\u{200b}的筵席", "不散的筵席"),
            ("全角空格", "不散的筵席\u{3000}（I Miss You）", "不散的筵席"),
        ]
        for (_, input, want) in cases {
            expectEqual(K.normalizedTitle(input), want)
        }

        expectEqual(
            K.normalizedKey(artist: "PRINCE", title: "The Girl In Red (Interlude)", album: "神經志 The Journal"),
            "PRINCE|The Girl In Red (Interlude)|神經志 The Journal"
        )

        let once = K.normalizedKey(artist: "丁世光", title: "不散的筵席（I Miss You）", album: "神經志 The Journal")
        expectEqual(once, "丁世光|不散的筵席|神經志 The Journal")
        expectEqual(K.normalizedTitle("不散的筵席"), "不散的筵席")

        let loosePairs: [(String, String, String)] = [
            ("半角空格", "陶喆|Susan 说|太平盛世", "陶喆|Susan说|太平盛世"),
            ("中英之间空格", "陶喆|Sula 与 Lampa 的寓言|太平盛世", "陶喆|Sula 与 Lampa的寓言|太平盛世"),
            ("歌名繁简", "方大同|千纸鹤|回到未來", "方大同|千紙鶴|回到未來"),
            ("歌手名繁简", "孙燕姿|我懷念的|逆光", "孫燕姿|我懷念的|逆光"),
            ("大小写", "PRINCE|Kiss|Parade", "Prince|Kiss|Parade"),
        ]
        for (_, a, b) in loosePairs {
            expectEqual(K.looseKey(a), K.looseKey(b))
        }

        let looseDistinct: [(String, String, String)] = [
            ("版本括号", "陶喆|Susan 说|太平盛世", "陶喆|Susan 说(Music鉴赏版)|太平盛世"),
            ("不同专辑", "陶喆|Susan 说|太平盛世", "陶喆|Susan 说|黑色柳丁"),
            ("不同歌手", "陶喆|Susan 说|太平盛世", "王力宏|Susan 说|太平盛世"),
        ]
        for (_, a, b) in looseDistinct {
            expectNotEqual(K.looseKey(a), K.looseKey(b))
        }

        expectEqual(
            K.normalizedKey(artist: "孙燕姿", title: "我懷念的", album: "逆光"),
            "孙燕姿|我懷念的|逆光"
        )
    }

    do {
        let R = EnrichCacheReader.self
        expectEqual(R.artistTitleKey(artist: "陶喆", title: "聖誕之吻"), "陶喆|聖誕之吻")

        expectEqual(R.artistTitleKey(artist: "  Prince ", title: " Kiss "), "prince|kiss")

        expectEqual(
            R.artistTitleKey(artist: "丁世光", title: "不散的筵席（I Miss You）"),
            R.artistTitleKey(artist: "丁世光", title: "不散的筵席")
        )

        expectEqual(
            R.artistTitleKey(artist: "周杰伦", title: "告白气球 (Live)") != R.artistTitleKey(artist: "周杰伦", title: "告白气球"),
            true
        )
    }

    do {
        typealias R = EnrichCacheReader
        let sampleLyrics = "[00:01.00]当时如果一起会怎样\n[00:05.00]现在又是在哪里"
        let entry1 = EnrichCacheEntry(
            lyrics: sampleLyrics,
            lyricsTr: "Tr",
            lyricsRoma: "Roma",
            lyricsYRC: "YRC",
            lyricsSource: "netease",
            coverSource: "netease",
            coverURL: "https://cover/dsg",
            instrumental: false,
            ts: 1726000000,
            appleMusicURL: "https://music.apple.com/song/123",
            qqMusicURL: "https://y.qq.com/song/456",
            neteaseURL: "https://music.163.com/song/789",
            durationSecs: 245.0,
            resolvedDurationSecs: 245.5
        )
        let collabEntry = EnrichCacheEntry(
            lyrics: "[00:02.00]Ashe Project",
            lyricsSource: "qq",
            coverSource: "qq",
            instrumental: false,
            ts: 1726000001,
            durationSecs: 180.0
        )
        let emptyEntry = EnrichCacheEntry(
            lyrics: "",
            lyricsSource: nil,
            coverSource: nil,
            instrumental: false,
            ts: 0
        )
        let richEntry = EnrichCacheEntry(
            lyrics: "[00:00.00]故事的小黄花",
            lyricsSource: "kugou",
            coverSource: "kugou",
            instrumental: false,
            ts: 1726000002,
            durationSecs: 269.0
        )

        let mockEntries: [String: EnrichCacheEntry] = [
            "丁世光|如果我们当时一起会怎么样|神经志": entry1,
            "Sebastien Najand/英雄联盟|PROJECT: Ashe|PROJECT: Ashe": collabEntry,
            "周杰伦|晴天|EP": emptyEntry,
            "周杰伦|晴天|叶惠美": richEntry,
        ]
        R.setEntriesForTesting(mockEntries)
        defer { R.setEntriesForTesting(nil) }

        let exact = R.lookup(artist: "丁世光", title: "如果我们当时一起会怎么样", album: "神经志")
        expectEqual(exact?.lyrics, sampleLyrics)
        expectEqual(R.resolvedKey(artist: "丁世光", title: "如果我们当时一起会怎么样", album: "神经志"),
                    "丁世光|如果我们当时一起会怎么样|神经志")

        let mismatched = R.lookup(artist: "丁世光", title: "如果我们当时一起会怎么样", album: "The Journal")
        expectEqual(mismatched?.lyrics, sampleLyrics)
        expectEqual(R.resolvedKey(artist: "丁世光", title: "如果我们当时一起会怎么样", album: "The Journal"),
                    "丁世光|如果我们当时一起会怎么样|神经志")
        expectEqual(R.sourceInfo(artist: "丁世光", title: "如果我们当时一起会怎么样", album: "The Journal")?.lyricsSource,
                    "netease")
        expectEqual(R.trackDurationSecs(artist: "丁世光", title: "如果我们当时一起会怎么样", album: "The Journal"),
                    245.5)
        expectEqual(R.platformLinks(artist: "丁世光", title: "如果我们当时一起会怎么样", album: "The Journal")?.neteaseSong,
                    URL(string: "https://music.163.com/song/789"))

        let emptyAlbum = R.lookup(artist: "丁世光", title: "如果我们当时一起会怎么样", album: "")
        expectEqual(emptyAlbum?.lyrics, sampleLyrics)
        expectEqual(R.resolvedKey(artist: "丁世光", title: "如果我们当时一起会怎么样", album: ""),
                    "丁世光|如果我们当时一起会怎么样|神经志")
        let spaceAlbum = R.lookup(artist: "丁世光", title: "如果我们当时一起会怎么样", album: "   ")
        expectEqual(spaceAlbum?.lyrics, sampleLyrics)

        let collab = R.lookup(artist: "Sebastien Najand", title: "PROJECT: Ashe", album: "Mismatch Album")
        expectEqual(collab?.lyrics, "[00:02.00]Ashe Project")
        expectEqual(R.resolvedKey(artist: "Sebastien Najand", title: "PROJECT: Ashe", album: "Mismatch Album"),
                    "Sebastien Najand/英雄联盟|PROJECT: Ashe|PROJECT: Ashe")

        let queryCollab = R.lookup(artist: "丁世光 feat. 嘉宾", title: "如果我们当时一起会怎么样", album: "The Journal")
        expectEqual(queryCollab?.lyrics, sampleLyrics)
        expectEqual(R.resolvedKey(artist: "丁世光 feat. 嘉宾", title: "如果我们当时一起会怎么样", album: "The Journal"),
                    "丁世光|如果我们当时一起会怎么样|神经志")
        expectEqual(R.sourceInfo(artist: "丁世光 feat. 嘉宾", title: "如果我们当时一起会怎么样", album: "The Journal")?.lyricsSource,
                    "netease")
        expectEqual(R.trackDurationSecs(artist: "丁世光 feat. 嘉宾", title: "如果我们当时一起会怎么样", album: "The Journal"),
                    245.5)
        expectEqual(R.platformLinks(artist: "丁世光 feat. 嘉宾", title: "如果我们当时一起会怎么样", album: "The Journal")?.neteaseSong,
                    URL(string: "https://music.163.com/song/789"))

        let queryDiffSep = R.lookup(artist: "Sebastien Najand & 英雄联盟", title: "PROJECT: Ashe", album: "Mismatch Album")
        expectEqual(queryDiffSep?.lyrics, "[00:02.00]Ashe Project")
        expectEqual(R.resolvedKey(artist: "Sebastien Najand & 英雄联盟", title: "PROJECT: Ashe", album: "Mismatch Album"),
                    "Sebastien Najand/英雄联盟|PROJECT: Ashe|PROJECT: Ashe")

        let prioritized = R.lookup(artist: "周杰伦", title: "晴天", album: "完全不同的专辑")
        expectEqual(prioritized?.lyrics, "[00:00.00]故事的小黄花")
        expectEqual(R.resolvedKey(artist: "周杰伦", title: "晴天", album: "完全不同的专辑"),
                    "周杰伦|晴天|叶惠美")

        let plainOnly = EnrichCacheEntry(ts: 1726000000, plainLyrics: "纯文本歌词")
        let syncedEntry = EnrichCacheEntry(lyrics: "[00:01.00]时间戳歌词", ts: 1726000001)
        let priorityMock: [String: EnrichCacheEntry] = [
            "方大同|红豆|Album A": plainOnly,
            "方大同|红豆|Album B": syncedEntry,
        ]
        R.setEntriesForTesting(priorityMock)
        let lyricsPriority = R.lookup(artist: "方大同", title: "红豆", album: "Unknown Album")
        expectEqual(lyricsPriority?.lyrics, "[00:01.00]时间戳歌词")
        expectEqual(R.resolvedKey(artist: "方大同", title: "红豆", album: "Unknown Album"),
                    "方大同|红豆|Album B")

        let placeholder = EnrichCacheEntry(lyrics: "", ts: 0)
        let resolvedEmpty = EnrichCacheEntry(lyrics: "", ts: 1726000005)
        let statusMock: [String: EnrichCacheEntry] = [
            "陶喆|天天|Album A": placeholder,
            "陶喆|天天|Album B": resolvedEmpty,
        ]
        R.setEntriesForTesting(statusMock)
        let statusPriority = R.lookup(artist: "陶喆", title: "天天", album: "Unknown Album")
        expectEqual(statusPriority?.resolved, true)
        expectEqual(R.resolvedKey(artist: "陶喆", title: "天天", album: "Unknown Album"),
                    "陶喆|天天|Album B")

        R.setEntriesForTesting(mockEntries)

        let notFound = R.lookup(artist: "丁世光", title: "没写过的歌", album: "神經志")
        expectEqual(notFound, nil)
        expectEqual(R.resolvedKey(artist: "丁世光", title: "没写过的歌", album: "神经志"), nil)

        let testIndices = R.entryIndicesByArtistTitle(mockEntries)
        let foundDirect = R.entryForArtistTitle(in: testIndices.entries, artist: "丁世光", title: "如果我们当时一起会怎么样")
        expectEqual(foundDirect?.lyrics, sampleLyrics)
        let foundMerged = R.entryForArtistTitle(in: testIndices.entries, artist: "丁世光 & 朋友", title: "如果我们当时一起会怎么样")
        expectEqual(foundMerged?.lyrics, sampleLyrics)
        let notFoundEntry = R.entryForArtistTitle(in: testIndices.entries, artist: "未知歌手", title: "未知歌名")
        expectEqual(notFoundEntry, nil)

        let keyDirect = R.resolvedKeyForArtistTitle(in: testIndices.keys, artist: "丁世光", title: "如果我们当时一起会怎么样")
        expectEqual(keyDirect, "丁世光|如果我们当时一起会怎么样|神经志")
        let keyMerged = R.resolvedKeyForArtistTitle(in: testIndices.keys, artist: "丁世光 & 朋友", title: "如果我们当时一起会怎么样")
        expectEqual(keyMerged, "丁世光|如果我们当时一起会怎么样|神经志")
        let keyNotFound = R.resolvedKeyForArtistTitle(in: testIndices.keys, artist: "未知歌手", title: "未知歌名")
        expectEqual(keyNotFound, nil)
    }

    do {
        var cal = Calendar(identifier: .gregorian)

        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: month, day: day,
                                          hour: hour, minute: minute))!
        }
        let sixHours: TimeInterval = 6 * 3600
        func needs(fetched: Date?, day: Date?, now: Date) -> Bool {
            DailyRefreshGate.needsRefresh(lastFetchedAt: fetched, cachedDay: day,
                                          now: now, ttl: sixHours, calendar: cal)
        }

        expectEqual(needs(fetched: nil, day: nil, now: at(8, 17, 10)), true)

        expectEqual(needs(fetched: at(8, 17, 10), day: at(8, 17, 10), now: at(8, 17, 14)), false)
        expectEqual(needs(fetched: at(8, 17, 3), day: at(8, 17, 3), now: at(8, 17, 10)), true)

        expectEqual(needs(fetched: at(8, 16, 22), day: at(8, 16, 22), now: at(8, 17, 2)), true)

        expectEqual(needs(fetched: at(8, 16, 23, 59), day: at(8, 16, 23, 59), now: at(8, 17, 0, 0)),
                    true)

        expectEqual(needs(fetched: at(8, 17, 0, 0), day: at(8, 17, 0, 0), now: at(8, 17, 5, 59)),
                    false)

        expectEqual(needs(fetched: at(8, 17, 10), day: nil, now: at(8, 17, 11)), true)
        expectEqual(needs(fetched: nil, day: at(8, 17, 10), now: at(8, 17, 11)), true)
    }

    do {

        expectEqual(ArtistCredit.primary("Daniel Caesar & Mustafa"), "Daniel Caesar")
        expectEqual(ArtistCredit.primary("陶喆、卢广仲"), "陶喆")
        expectEqual(ArtistCredit.primary("UMI, 金泰亨"), "UMI")
        expectEqual(ArtistCredit.primary("Daniel Caesar feat. Mustafa"), "Daniel Caesar")
        expectEqual(ArtistCredit.primary("Doja Cat (feat. SZA)"), "Doja Cat")
        expectEqual(ArtistCredit.primary("Daniel Caesar"), nil)

        expectEqual(ArtistCredit.primary("Soft Lipa"), nil)
        expectEqual(ArtistCredit.primary("Daft Punk"), nil)
        expectEqual(ArtistCredit.primary("Left Boy"), nil)
        expectEqual(ArtistCredit.primary("Craft Spells"), nil)
        expectEqual(ArtistCredit.primary("Soft Machine"), nil)

        expectEqual(ArtistCredit.primary("Soft Lipa feat. 蛋堡"), "Soft Lipa")
        expectEqual(ArtistCredit.primary("A ft. B"), "A")
        expectEqual(ArtistCredit.primary("A ft B"), "A")
        expectEqual(ArtistCredit.primary("A (ft. B)"), "A")
        expectEqual(ArtistCredit.primary(""), nil)

        expectEqual(ArtistCredit.primary("& Friends"), nil)

        expectEqual(ArtistCredit.primary("陶喆/卢广仲"), "陶喆")
        expectEqual(ArtistCredit.primary("K/DA, Madison Beer & (G)I-DLE"), "K/DA")
        expectEqual(ArtistCredit.primary("AC/DC"), nil)
        expectEqual(ArtistCredit.primary("K/DA"), nil)

        expectEqual(ArtistCredit.mergeArtist("Daniel Caesar & Mustafa"), "Daniel Caesar")
        expectEqual(ArtistCredit.mergeArtist("Daniel Caesar"), "Daniel Caesar")

        expectEqual(ArtistCredit.albumConsensusKey(artist: "Daniel Caesar & Mustafa",
                                                   album: "NEVER ENOUGH (Bonus Version)"),
                    ArtistCredit.albumConsensusKey(artist: "Daniel Caesar",
                                                   album: "never enough (bonus version)"))
        expectEqual(ArtistCredit.albumConsensusKey(artist: "Daniel Caesar", album: nil), nil)

        let albumArt = URL(string: "https://cover.example/album.jpg")!
        let singleArt = URL(string: "https://cover.example/single.jpg")!
        let album = "NEVER ENOUGH (Bonus Version)"
        let rows: [(artist: String, album: String?, image: URL?)] = [
            ("Daniel Caesar & Mustafa", album, singleArt),
            ("Daniel Caesar", album, albumArt),
            ("Daniel Caesar", album, albumArt),
            ("Daniel Caesar", album, albumArt),
        ]
        let consensus = ArtistCredit.albumConsensusCovers(rows: rows)
        expectEqual(consensus[ArtistCredit.albumConsensusKey(artist: "Daniel Caesar", album: album)!],
                    albumArt)

        let noConsensus = ArtistCredit.albumConsensusCovers(rows: [
            ("V.A.", "Compilation", URL(string: "https://cover.example/a.jpg")!),
            ("V.A.", "Compilation", URL(string: "https://cover.example/b.jpg")!),
        ])
        expectEqual(noConsensus.isEmpty, true)

        let single = ArtistCredit.albumConsensusCovers(rows: [("Solo", "One Track", albumArt)])
        expectEqual(single.isEmpty, true)

        let withNil = ArtistCredit.albumConsensusCovers(rows: [
            ("Daniel Caesar", album, nil),
            ("Daniel Caesar", album, albumArt),
            ("Daniel Caesar", album, albumArt),
        ])
        expectEqual(withNil.count, 1)
    }

    do {
        let artist = "Denzel Curry/GIZZLE/Bren Joy"
        let title = "Dynasties and Dystopia (from the series Arcane League of Legends)"
        let album = "Arcane League of Legends (Soundtrack from the Animated Series)"
        expectEqual(EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album),
                    "Denzel Curry/GIZZLE/Bren Joy|Dynasties and Dystopia|"
                        + "Arcane League of Legends (Soundtrack from the Animated Series)")

        expectEqual(EnrichCacheKeys.looseKey("\(artist)|\(title)|\(album)")
                        == EnrichCacheKeys.looseKey(
                            EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)),
                    false)

        expectEqual(EnrichCacheKeys.normalizedTitle("Purple Rain (Live)"), "Purple Rain (Live)")
    }

    do {
        expectEqual(
            EnrichCacheKeys.looseKey("VALORANT/Grabbitz/bbno$|Ticking Away|Ticking Away"),
            EnrichCacheKeys.looseKey("VALORANT & Grabbitz & bbno$|Ticking Away|Ticking Away"))
        expectEqual(
            EnrichCacheKeys.looseKey("陶喆、卢广仲|某首歌|某专辑"),
            EnrichCacheKeys.looseKey("陶喆/卢广仲|某首歌|某专辑"))

        expectEqual(
            EnrichCacheKeys.looseKey("丁世光|無名花香|背面是我"),
            EnrichCacheKeys.looseKey("丁世光|无名花香|背面是我"))

        expectEqual(
            EnrichCacheKeys.looseKey("K/DA|POP/STARS|POP/STARS")
                == EnrichCacheKeys.looseKey("K/DA|MORE|MORE"),
            false)
    }
}
