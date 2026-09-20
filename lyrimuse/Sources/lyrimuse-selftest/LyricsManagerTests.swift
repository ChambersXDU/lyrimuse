import LyrimuseCore
import Foundation

@MainActor
func runLyricsManagerTests() {

    do {
        let W = LyricsColumnWidths.self
        let d = W.defaults

        let total: CGFloat = 630, chrome: CGFloat = 48

        expectEqual(
            W.dragged(from: d, divider: 0, dx: 20, totalWidth: total, chrome: chrome).artist,
            d.artist - 20
        )
        expectEqual(
            W.dragged(from: d, divider: 0, dx: -20, totalWidth: total, chrome: chrome).artist,
            d.artist + 20
        )

        do {
            let r = W.dragged(from: d, divider: 0, dx: 30, totalWidth: total, chrome: chrome)
            expectEqual(r.album, d.album)
            expectEqual(r.source, d.source)
        }

        expectEqual(
            W.dragged(from: d, divider: 0, dx: 9999, totalWidth: total, chrome: chrome).artist,
            W.minColumn
        )

        expectEqual(
            W.dragged(from: d, divider: 0, dx: -9999, totalWidth: total, chrome: chrome).artist,
            total - chrome - W.minTitle - d.album - d.source
        )

        expectEqual(
            W.dragged(from: d, divider: 0, dx: -9999, totalWidth: 200, chrome: chrome).artist >= W.minColumn,
            true
        )

        expectEqual(
            W.dragged(from: d, divider: 0, dx: -20, totalWidth: 0, chrome: chrome).artist,
            d.artist + 20
        )
    }

    do {
        let W = LyricsColumnWidths.self
        let d = W.defaults
        let total: CGFloat = 630, chrome: CGFloat = 48

        do {
            let r = W.dragged(from: d, divider: 1, dx: 25, totalWidth: total, chrome: chrome)
            expectEqual(r.artist, d.artist + 25)
            expectEqual(r.album, d.album - 25)
            expectEqual(r.artist + r.album, d.artist + d.album)
            expectEqual(r.source, d.source)
        }

        do {
            let r = W.dragged(from: d, divider: 1, dx: 9999, totalWidth: total, chrome: chrome)
            expectEqual(r.album, W.minColumn)
            expectEqual(r.artist + r.album, d.artist + d.album)
        }

        do {
            let r = W.dragged(from: d, divider: 2, dx: 9999, totalWidth: total, chrome: chrome)
            expectEqual(r.source, W.minSourceColumn)
            expectEqual(r.album + r.source, d.album + d.source)
        }
    }

    do {
        let W = LyricsColumnWidths.self
        let chrome: CGFloat = 48

        expectEqual(W.fitted(W.defaults, totalWidth: 900, chrome: chrome), W.defaults)

        expectEqual(W.fitted(W.defaults, totalWidth: 0, chrome: chrome), W.defaults)

        do {
            let wide = LyricsColumnWidths(artist: 240, album: 240, source: 200)
            let r = W.fitted(wide, totalWidth: 600, chrome: chrome)
            expectEqual(r.total <= 600 - chrome - W.minTitle + 0.001, true)
            expectEqual(r.artist >= W.minColumn && r.album >= W.minColumn && r.source >= W.minSourceColumn,
                        true)
        }

        do {
            let r = W.fitted(W.defaults, totalWidth: 240, chrome: chrome)
            expectEqual(r, LyricsColumnWidths(artist: W.minColumn, album: W.minColumn, source: W.minSourceColumn))
        }
    }

    do {
        let W = LyricsColumnWidths.self
        let stored = LyricsColumnWidths(artist: 56, album: 137.66796875, source: 70)
        let floors = LyricsColumnWidths(artist: W.minColumn, album: W.minColumn, source: W.minSourceColumn)

        expectEqual(W.fitted(stored, totalWidth: 713, chrome: 8 * 3), stored)

        expectEqual(W.fitted(stored, totalWidth: 218, chrome: 36), floors)
    }

    do {
        let W = LyricsColumnWidths.self

        expectEqual(W.sanitized(W.defaults), W.defaults)
        expectEqual(W.sanitized(LyricsColumnWidths(artist: 0, album: 110, source: 84)), W.defaults)
        expectEqual(W.sanitized(LyricsColumnWidths(artist: -50, album: 110, source: 84)), W.defaults)
        expectEqual(W.sanitized(LyricsColumnWidths(artist: 5000, album: 110, source: 84)), W.defaults)
        expectEqual(W.sanitized(LyricsColumnWidths(artist: .nan, album: 110, source: 84)), W.defaults)
        expectEqual(W.sanitized(LyricsColumnWidths(artist: .infinity, album: 110, source: 84)), W.defaults)

        expectEqual(W.sanitized(LyricsColumnWidths(artist: 96, album: 110, source: 60)), W.defaults)
    }

    do {
        let base: [String: [String: Any]] = ["A|a|x": ["lyrics": "L"]]

        let disk: [String: [String: Any]] = [
            "A|a|x": ["lyrics": "L", "lyrics_tr": "译文"],
            "B|b|y": ["lyrics": "N"],
        ]
        var memory = base
        memory["C|c|z"] = ["lyrics": "C"]
        let merged = EnrichCacheMerge.merge(
            disk: disk, memory: memory, edited: ["C|c|z"], deleted: [])
        expectEqual(merged["A|a|x"]?["lyrics_tr"] as? String, "译文")
        expectEqual(merged["B|b|y"] != nil, true)
        expectEqual(merged["C|c|z"]?["lyrics"] as? String, "C")

        let edited = EnrichCacheMerge.merge(
            disk: ["A|a|x": ["lyrics": "盘上旧的"]],
            memory: ["A|a|x": ["lyrics": "用户改的"]],
            edited: ["A|a|x"], deleted: [])
        expectEqual(edited["A|a|x"]?["lyrics"] as? String, "用户改的")

        let deleted = EnrichCacheMerge.merge(
            disk: ["A|a|x": ["lyrics": "L"]], memory: [:],
            edited: [], deleted: ["A|a|x"])
        expectEqual(deleted["A|a|x"] == nil, true)

        let editThenDelete = EnrichCacheMerge.merge(
            disk: ["A|a|x": ["lyrics": "L"]], memory: [:],
            edited: ["A|a|x"], deleted: ["A|a|x"])
        expectEqual(editThenDelete["A|a|x"] == nil, true)
    }

    do {
        typealias A = LyricsBackupArchive

        expectEqual(A.sidecarName(forConfigName: "Lyrimuse-Config-2026-08-21-181500.json"),
                    "Lyrimuse-Lyrics-2026-08-21-181500.json.z")

        expectEqual(A.sidecarName(forConfigName: "我的备份.json").hasSuffix(".json.z"), true)

        expectEqual(A.sanitizedFileName("周杰伦 - 枫 - 十一月的萧邦.lrc") != nil, true)
        expectEqual(A.sanitizedFileName("x.tr.lrc") != nil, true)
        expectEqual(A.sanitizedFileName("x.roma.lrc") != nil, true)
        expectEqual(A.sanitizedFileName("x.yrc") != nil, true)

        expectEqual(A.sanitizedFileName("../../.ssh/authorized_keys.lrc"), nil)
        expectEqual(A.sanitizedFileName("sub/dir/x.lrc"), nil)

        expectEqual(A.sanitizedFileName("陶喆 - 天天 - I'm O.K..yrc") != nil, true)
        expectEqual(A.sanitizedFileName("Wale - Watching Us - everything is a lot..lrc") != nil, true)
        expectEqual(A.sanitizedFileName("a..b.lrc") != nil, true)

        expectEqual(A.sanitizedFileName("..lrc"), nil)
        expectEqual(A.sanitizedFileName("\\tmp\\x.lrc"), nil)
        expectEqual(A.sanitizedFileName(".hidden.lrc"), nil)

        expectEqual(A.sanitizedFileName("payload.sh"), nil)
        expectEqual(A.sanitizedFileName("x.lrc.sh"), nil)
        expectEqual(A.sanitizedFileName(""), nil)

        expectEqual(A.sanitizedFileName(String(repeating: "a", count: 260) + ".lrc"), nil)

        let plan = A.plan(incoming: ["a.lrc", "b.yrc", "../evil.lrc", "c.lrc"],
                          existing: ["a.lrc", "z.lrc"])
        expectEqual(plan.added, ["b.yrc", "c.lrc"])
        expectEqual(plan.overwritten, ["a.lrc"])
        expectEqual(plan.rejected, ["../evil.lrc"])

        expectEqual(plan.added.contains("z.lrc") || plan.overwritten.contains("z.lrc"), false)

        let again = A.plan(incoming: ["c.lrc", "../evil.lrc", "b.yrc", "a.lrc"],
                           existing: ["a.lrc", "z.lrc"])
        expectEqual(again, plan)

        let payload = A.Payload(at: "2026-08-21T10:00:00Z", device: "Mac",
                                files: ["周杰伦 - 枫.lrc": "[00:01.00]枫"],
                                pins: ["周杰伦|枫|十一月的萧邦": 1787296579])
        guard let archived = A.encode(payload) else {
            expectEqual(true, false)
            exit(1)
        }

        expectEqual(archived.first != UInt8(ascii: "{"), true)
        let plain = String(data: (try! (archived as NSData).decompressed(using: .zlib)) as Data,
                           encoding: .utf8) ?? ""
        for field in ["\"v\"", "\"at\"", "\"device\"", "\"files\"", "\"pins\""] {
            expectEqual(plain.contains(field), true)
        }

        expectEqual(A.decode(archived), payload)

        let raw = try! JSONEncoder().encode(payload)
        expectEqual(A.decode(raw), payload)

        expectEqual(A.decode(Data("not an archive".utf8)) == nil, true)

        expectEqual(A.lyricFieldKeys,
                    ["lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc", "lyrics_source", "manual_lyrics"])

        let cacheJSON = """
        {
          "周杰伦|枫|十一月的萧邦": {
            "lyrics": "[00:01.00]正文", "lyrics_tr": "译文", "lyrics_roma": "罗马音",
            "lyrics_yrc": "逐字", "lyrics_source": "netease", "manual_lyrics": true,
            "lyrics_decision": {"winner": "netease", "path": "rescore"},
            "lyrics_scoring_version": 9, "canonical_artist": "周杰伦", "plain_lyrics": "纯文本"
          },
          "只有歌词的条目|x|y": {"lyrics": "[00:01.00]只有正文", "lyrics_source": "qq"}
        }
        """
        guard let strippedData = A.strippedMeta(fromCacheJSON: Data(cacheJSON.utf8)),
              let strippedRoot = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any]
        else {
            expectEqual(true, false)
            exit(1)
        }
        let strippedEntry = strippedRoot["周杰伦|枫|十一月的萧邦"] as? [String: Any] ?? [:]
        for field in A.lyricFieldKeys {
            expectEqual(strippedEntry[field] == nil, true)
        }
        expectEqual(strippedEntry["lyrics_scoring_version"] as? Int, 9)
        expectEqual(strippedEntry["canonical_artist"] as? String, "周杰伦")
        expectEqual(strippedEntry["plain_lyrics"] as? String, "纯文本")
        expectEqual((strippedEntry["lyrics_decision"] as? [String: Any])?["winner"] as? String, "netease")

        expectEqual(strippedRoot["只有歌词的条目|x|y"] == nil, true)

        expectEqual(A.strippedMeta(fromCacheJSON: Data("不是 JSON".utf8)) == nil, true)
        expectEqual(A.strippedMeta(fromCacheJSON: Data("{}".utf8)) == nil, true)

        let metaPayload = A.Payload(at: "2026-09-02T03:00:00Z", device: "Mac",
                                    files: ["a.lrc": "[00:01.00]a"],
                                    pins: [:], meta: strippedData)
        guard let metaArchived = A.encode(metaPayload) else {
            expectEqual(true, false)
            exit(1)
        }
        let metaPlain = String(data: (try! (metaArchived as NSData).decompressed(using: .zlib)) as Data,
                               encoding: .utf8) ?? ""
        expectEqual(metaPlain.contains("\"meta\""), true)
        expectEqual(A.decode(metaArchived), metaPayload)
        expectEqual(A.decode(metaArchived)?.meta, strippedData)

        expectEqual(A.payloadVersion, 2)
        let v1JSON = """
        {"v":1,"at":"2026-08-21T10:00:00Z","device":"Old","files":{"a.lrc":"x"},"pins":{}}
        """
        let v1Decoded = A.decode(Data(v1JSON.utf8))
        expectEqual(v1Decoded?.files["a.lrc"], "x")
        expectEqual(v1Decoded?.meta == nil, true)
    }

    do {
        typealias D = LyricsRematchDecision

        expectEqual(D.decide(decidable: true, winnerSource: "kugou", currentHasWordTiming: false,
                             winnerHasWordTiming: false, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .adopt)

        expectEqual(D.decide(decidable: false, winnerSource: "kugou", currentHasWordTiming: false,
                             winnerHasWordTiming: true, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .keptNotDecidable)

        expectEqual(D.decide(decidable: true, winnerSource: "", currentHasWordTiming: false,
                             winnerHasWordTiming: false, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .keptNoCandidate)

        expectEqual(D.decide(decidable: true, winnerSource: "lrclib", currentHasWordTiming: true,
                             winnerHasWordTiming: false, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .keptWouldLoseWordTiming)

        expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: false,
                             winnerHasWordTiming: true, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .adopt)

        expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: true,
                             winnerHasWordTiming: true, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .adopt)

        expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: true,
                             winnerHasWordTiming: true, sameSource: true, sameLyrics: true,
                             sameWordTiming: true),
                    .unchanged)

        expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: false,
                             winnerHasWordTiming: false, sameSource: true, sameLyrics: false,
                             sameWordTiming: true),
                    .adopt)

        expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: false,
                             winnerHasWordTiming: true, sameSource: true, sameLyrics: true,
                             sameWordTiming: false),
                    .adopt)
    }

    do {

        let lyricsA = "[ti:测试]\n[00:01.00]第一句\n[00:05.00]第二句\n"
        let lyricsB = "[ar:某人]\r\n[offset:120]\r\n[00:02.34]第一句  \r\n\r\n[00:09.99][01:20.00]第二句\t\r\n"
        let lyricsC = "[00:01.00]第一句\n[00:05.00]完全不同的第二句\n"
        let sha = ManualPickLock.fingerprint(lyrics: lyricsA)

        expectEqual(sha, "13ec24ce7207")

        expectEqual(ManualPickLock.fingerprint(lyrics: lyricsB), sha)
        expectEqual(ManualPickLock.fingerprint(lyrics: lyricsC) == sha, false)
        expectEqual(ManualPickLock.canonicalLyrics(lyricsA), "第一句\n第二句")
        expectEqual(ManualPickLock.fingerprint(lyrics: "[ti:只有元数据]\n\n"), "")
        expectEqual(ManualPickLock.fingerprint(lyrics: ""), "")
        expectEqual(sha.count, 12)

        expectEqual(ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsA,
                                              isLocked: false, locking: true), true)

        expectEqual(ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsB,
                                              isLocked: false, locking: true), true)

        expectEqual(ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsA,
                                              isLocked: true, locking: true), false)
        expectEqual(ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsA,
                                              isLocked: true, locking: false), true)

        expectEqual(ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsC,
                                              isLocked: false, locking: true), false)

        expectEqual(ManualPickLock.shouldFlip(sha: nil, lyrics: lyricsA,
                                              isLocked: true, locking: false), false)
        expectEqual(ManualPickLock.shouldFlip(sha: "", lyrics: lyricsA,
                                              isLocked: true, locking: false), false)

        expectEqual(ManualPickLock.state(sha: nil, lyrics: lyricsA), .neverPicked)
        expectEqual(ManualPickLock.state(sha: "", lyrics: lyricsA), .neverPicked)
        expectEqual(ManualPickLock.state(sha: sha, lyrics: lyricsB), .original)
        expectEqual(ManualPickLock.state(sha: sha, lyrics: lyricsC), .replaced)

        for locked in [true, false] {
            for locking in [true, false] {
                expectEqual(
                    ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsA,
                                              isLocked: locked, locking: locking),
                    ManualPickLock.state(sha: sha, lyrics: lyricsA) == .original
                        && locked != locking)
            }
        }
    }

    do {
        func k(
            _ title: String,
            artist: String = "aa",
            album: String = "al",
            source: String = "",
            updated: Double? = nil,
            resolved: Double? = nil,
            responded: Int = 0
        ) -> LyricsSortKey {
            LyricsSortKey(
                normPrimaryArtist: artist,
                normAlbum: album,
                title: title,
                searchTitleLower: title.lowercased(),
                sourceDisplayName: source.isEmpty ? "无来源" : source,
                hasSource: !source.isEmpty,
                lyricsUpdatedAt: updated.map { Date(timeIntervalSince1970: $0) },
                resolvedAt: resolved.map { Date(timeIntervalSince1970: $0) },
                sourcesRespondedCount: responded
            )
        }
        func order(_ keys: [LyricsSortKey], _ o: LyricsSortOrder) -> [String] {
            keys.sorted { o.less($0, $1) }.map(\.title)
        }

        let byName = [
            k("c", artist: "b", album: "a2"),
            k("a", artist: "a", album: "a1"),
            k("b", artist: "a", album: "a1"),
        ]
        expectEqual(order(byName, .defaultOrder), ["a", "b", "c"])
        expectEqual(order(byName, .title(ascending: true)), ["a", "b", "c"])
        expectEqual(order(byName, .title(ascending: false)), ["c", "b", "a"])
        expectEqual(order(byName, .artist(ascending: false)), ["c", "a", "b"])
        expectEqual(order(byName, .album(ascending: false)), ["c", "a", "b"])

        let mixed = [
            k("old", artist: "b", updated: 1000),
            k("new", artist: "a", updated: 3000),
            k("mid", artist: "c", updated: 2000),
        ]
        expectEqual(order(mixed, .updated(ascending: false)), ["new", "mid", "old"])
        expectEqual(order(mixed, .updated(ascending: true)), ["old", "mid", "new"])

        let withGap = [
            k("noFile", artist: "a", updated: nil, resolved: 9999),
            k("hasFile", artist: "z", updated: 1000),
        ]
        expectEqual(order(withGap, .updated(ascending: false)), ["hasFile", "noFile"])
        expectEqual(
            order(withGap, .updated(ascending: true)), ["hasFile", "noFile"]
        )

        let allMissing = [
            k("A", artist: "a", resolved: 100),
            k("B", artist: "b", resolved: 300),
            k("C", artist: "c", resolved: 200),
        ]
        expectEqual(
            order(allMissing, .updated(ascending: false)), ["B", "C", "A"]
        )
        expectEqual(order(allMissing, .updated(ascending: true)), ["A", "C", "B"])
        expectNotEqual(
            order(allMissing, .updated(ascending: false)), order(allMissing, .defaultOrder)
        )

        let noTS = [k("hasTS", artist: "z", resolved: 500), k("noTS", artist: "a")]
        expectEqual(order(noTS, .updated(ascending: false)), ["hasTS", "noTS"])
        expectEqual(order(noTS, .updated(ascending: true)), ["hasTS", "noTS"])

        let byEvidence = [
            k("thick", artist: "a", responded: 6),
            k("thin", artist: "z", responded: 2),
            k("mid", artist: "m", responded: 4),
        ]
        expectEqual(
            order(byEvidence, .evidence(ascending: true)), ["thin", "mid", "thick"]
        )

        let withUnknown = [
            k("unknown", artist: "a", resolved: 9999, responded: 0),
            k("known", artist: "z", responded: 2),
        ]
        expectEqual(
            order(withUnknown, .evidence(ascending: true)), ["known", "unknown"]
        )

        let allUnknown = [
            k("A", artist: "a", resolved: 100),
            k("B", artist: "b", resolved: 300),
            k("C", artist: "c", resolved: 200),
        ]
        expectEqual(
            order(allUnknown, .evidence(ascending: true)), ["A", "C", "B"]
        )
        expectNotEqual(
            order(allUnknown, .evidence(ascending: true)), order(byEvidence, .defaultOrder)
        )

        let bySource = [
            k("q", artist: "b", source: "QQ音乐"),
            k("n", artist: "a", source: "网易云音乐"),
            k("none", artist: "a", resolved: 700),
        ]
        expectEqual(order(bySource, .source(ascending: true)), ["q", "n", "none"])
        expectEqual(
            order(bySource, .source(ascending: false)), ["n", "q", "none"]
        )

        let sameSource = [
            k("y", artist: "b", source: "QQ音乐", resolved: 100),
            k("x", artist: "a", source: "QQ音乐", resolved: 900),
        ]
        expectEqual(
            order(sameSource, .source(ascending: true)), ["x", "y"]
        )
        expectEqual(
            order(sameSource, .source(ascending: false)), ["x", "y"]
        )

        let allNoSource = [
            k("A", artist: "a", resolved: 100),
            k("B", artist: "b", resolved: 300),
            k("C", artist: "c", resolved: 200),
        ]
        expectEqual(
            order(allNoSource, .source(ascending: false)), ["B", "C", "A"]
        )
        expectNotEqual(
            order(allNoSource, .source(ascending: true)), order(allNoSource, .defaultOrder)
        )
    }

    do {
        func classify(_ word: Bool, _ line: Bool, _ plain: Bool, _ inst: Bool) -> LyricsKind {
            LyricsKind.classify(
                hasWordTiming: word, hasLyrics: line,
                hasPlainTextFallback: plain, isInstrumental: inst)
        }

        let table: [(Bool, Bool, Bool, Bool, LyricsKind)] = [
            (true,  true,  true,  true,  .wordByWord),
            (true,  true,  true,  false, .wordByWord),
            (true,  true,  false, true,  .wordByWord),
            (true,  true,  false, false, .wordByWord),
            (true,  false, true,  true,  .wordByWord),
            (true,  false, true,  false, .wordByWord),
            (true,  false, false, true,  .wordByWord),
            (true,  false, false, false, .wordByWord),
            (false, true,  true,  true,  .lineByLine),
            (false, true,  true,  false, .lineByLine),
            (false, true,  false, true,  .lineByLine),
            (false, true,  false, false, .lineByLine),
            (false, false, true,  true,  .plainText),
            (false, false, true,  false, .plainText),
            (false, false, false, true,  .instrumental),
            (false, false, false, false, .none),
        ]
        expectEqual(table.count, 16)
        for (word, line, plain, inst, expected) in table {
            expectEqual(
                classify(word, line, plain, inst), expected)
        }

        expectEqual(LyricsKind.allCases.count, 5)

        expectNotEqual(
            classify(false, false, false, true), LyricsKind.none)
    }

    do {
        func source(_ has: Bool, _ raw: String) -> LyricsTranslationSource {
            LyricsTranslationSource.classify(hasTranslation: has, trSource: raw)
        }

        expectEqual(source(false, ""), .none)
        expectEqual(source(false, "machine"), .none)
        expectEqual(source(true, ""), .community)
        expectEqual(source(true, "machine"), .machine)

        expectEqual(source(true, "mt"), .community)
    }

    do {
        typealias D = LyricsCandidateDuplicates
        let ordered: [(source: String, fingerprint: String)] = [
            ("kugou", "aaa"), ("qq", "bbb"), ("netease", "aaa"), ("lrclib", ""), ("migu", "aaa"), ("amll", ""),
        ]
        let m = D.firstMatches(ordered)
        expectEqual(m["kugou"], nil)
        expectEqual(m["netease"], "kugou")
        expectEqual(m["migu"], "kugou")
        expectEqual(m["qq"], nil)
        expectEqual(m["lrclib"], nil)
        expectEqual(D.firstMatches([("lrclib", ""), ("amll", "")]).isEmpty, true)
        expectEqual(D.firstMatches([]).isEmpty, true)
        expectEqual(D.isCurrent(candidateSource: "qq", candidateFingerprint: "x", currentSource: "qq", currentFingerprint: "x"), true)
        expectEqual(D.isCurrent(candidateSource: "qq", candidateFingerprint: "x", currentSource: "qq", currentFingerprint: "y"), false)
        expectEqual(D.isCurrent(candidateSource: "kugou", candidateFingerprint: "x", currentSource: "qq", currentFingerprint: "x"), false)
        expectEqual(D.isCurrent(candidateSource: "qq", candidateFingerprint: "x", currentSource: "qq", currentFingerprint: nil), true)
        expectEqual(D.isCurrent(candidateSource: "qq", candidateFingerprint: "", currentSource: "qq", currentFingerprint: "x"), true)
        expectEqual(D.isCurrent(candidateSource: "qq", candidateFingerprint: "x", currentSource: nil, currentFingerprint: "x"), false)

        let a = ManualPickLock.fingerprint(lyrics: "[00:01.00]你好\n[00:05.00]世界")
        let b = ManualPickLock.fingerprint(lyrics: "[00:02.50]你好\r\n[00:06.10]世界\n")
        expectEqual(a == b && !a.isEmpty, true)
    }

    do {
        let SRC = ["netease", "qq", "lrclib", "musixmatch", "amll", "kuwo", "migu"]
        let TITLE = "Beautiful World (Da Capo Version) [Instrumental]"

        let rounds = [LyricQueryRound(artist: "Utada", title: TITLE, reason: "", sources: [])]
            + ["Hikaru Utada", "宇多田ヒカル", "Cubic U", "Hikki",
               "Utada Hikaru", "ヒッキー", "宇多田光", "うただひかる"].map {
                LyricQueryRound(artist: $0, title: TITLE, reason: "alias-missing", sources: SRC)
            }
        let d = LyricQueryDigestBuilder.build(rounds)
        expectEqual(d.total, 9)
        expectEqual(d.sharedTitle, TITLE)
        expectEqual(d.groups.count, 2)
        expectEqual(d.groups[0].reason, "")
        expectEqual(d.groups[0].queries, [LyricQueryPair(artist: "Utada", title: "")])
        expectEqual(d.groups[1].queries.count, 8)
        expectEqual(d.groups[1].queries.first?.artist, "Hikaru Utada")
        expectEqual(d.groups[1].sources, SRC)

        let mixed = [
            LyricQueryRound(artist: "方大同", title: "Love Love Love", reason: "", sources: []),
            LyricQueryRound(artist: "方大同", title: "爱爱爱", reason: "title-from-artist-search", sources: []),
        ]
        let dm = LyricQueryDigestBuilder.build(mixed)
        expectEqual(dm.sharedTitle, nil)

        expectEqual(dm.groups[0].queries,
                    [LyricQueryPair(artist: "方大同", title: "Love Love Love")])
        expectEqual(dm.groups[1].queries,
                    [LyricQueryPair(artist: "方大同", title: "爱爱爱")])

        let ordered = [
            LyricQueryRound(artist: "A", title: "T", reason: "title-split", sources: []),
            LyricQueryRound(artist: "B", title: "T", reason: "", sources: []),
            LyricQueryRound(artist: "C", title: "T", reason: "title-split", sources: []),
        ]
        let dord = LyricQueryDigestBuilder.build(ordered)
        expectEqual(dord.groups.map(\.reason), ["title-split", ""])
        expectEqual(dord.groups[0].queries.map(\.artist), ["A", "C"])

        let diffSrc = [
            LyricQueryRound(artist: "A", title: "T", reason: "alias-missing", sources: ["qq"]),
            LyricQueryRound(artist: "B", title: "T", reason: "alias-missing", sources: ["kugou"]),
        ]
        expectEqual(LyricQueryDigestBuilder.build(diffSrc).groups.count, 2)

        let dup = [
            LyricQueryRound(artist: "A", title: "T", reason: "primary-artist-variant", sources: []),
            LyricQueryRound(artist: "B", title: "T", reason: "primary-artist-variant", sources: []),
            LyricQueryRound(artist: "A", title: "T", reason: "primary-artist-variant", sources: []),
        ]
        let ddup = LyricQueryDigestBuilder.build(dup)
        expectEqual(ddup.queriesFlatCount, 2)
        expectEqual(ddup.total, 3)

        expectEqual(LyricQueryDigestBuilder.build([]).groups.count, 0)

        let noTitle = [LyricQueryRound(artist: "A", title: "", reason: "", sources: [])]
        expectEqual(LyricQueryDigestBuilder.build(noTitle).sharedTitle, nil)
        expectEqual(LyricQueryDigestBuilder.build(noTitle).groups[0].queries,
                    [LyricQueryPair(artist: "A", title: "")])
    }

    do {
        typealias V = LyricsVerdictBuilder
        func term(_ k: String, _ p: Int) -> LyricsScoreTermValue {
            LyricsScoreTermValue(kind: k, points: p)
        }
        func cand(_ src: String, _ score: Int, _ t: [(String, Int)],
                  instrumental: Bool? = nil, peers: [String] = []) -> LyricsScoredCandidate {
            LyricsScoredCandidate(source: src, score: score, terms: t.map { term($0.0, $0.1) },
                                  instrumental: instrumental, consensusPeers: peers)
        }

        let peersA = ["netease", "qq", "kugou", "lrclib", "musixmatch"]
        let sampleA = [
            cand("qq", 945, [("duration", 164), ("wordTiming", 400), ("lines", 51),
                             ("consensus", 250), ("translation", 50), ("romanization", 30)],
                 peers: peersA),
            cand("kugou", 944, [("duration", 164), ("wordTiming", 400), ("lines", 50),
                                ("consensus", 250), ("translation", 50), ("romanization", 30)]),
            cand("netease", 942, [("duration", 163), ("wordTiming", 400), ("lines", 49),
                                  ("consensus", 250), ("translation", 50), ("romanization", 30)]),
            cand("musixmatch", 892, [("duration", 164), ("wordTiming", 400), ("lines", 28),
                                     ("consensus", 250), ("translation", 50)]),
            cand("lrclib", 460, [("duration", 180), ("lines", 30), ("consensus", 250)]),
        ]
        let vA = V.build(candidates: sampleA, winner: "qq")
        expectEqual(vA, .sameLyrics(contenders: 5, gap: 1,
                                    gapPercent: 100.0 / 945.0, nearTie: true,
                                    separator: .single(term("lines", 1))))

        let dA = V.deltas(champion: sampleA[0], others: Array(sampleA.dropFirst()))
        expectEqual(dA.count, 4)
        expectEqual(dA[0].scoreGap, -1)
        expectEqual(dA[0].terms, [term("lines", -1)])
        expectEqual(dA[1].terms, [term("lines", -2), term("duration", -1)])
        expectEqual(dA[2].terms, [term("romanization", -30), term("lines", -23)])
        expectEqual(dA[3].scoreGap, -485)
        expectEqual(dA.allSatisfy { $0.clampedRawSum == nil }, true)

        expectEqual(V.sharedTerms(among: sampleA), [term("consensus", 250)])

        let sampleC = [
            cand("kugou", 850, [("duration", 276), ("wordTiming", 400), ("lines", 39),
                                ("album", 75), ("titleMatch", 60)]),
            cand("netease", 629, [("duration", 278), ("wordTiming", 400), ("lines", 41),
                                  ("versionTags", -600), ("album", 150), ("titleMatch", 60),
                                  ("consensus", 250), ("translation", 50)]),
            cand("qq", 429, [("duration", 275), ("wordTiming", 400), ("lines", 44),
                             ("versionTags", -600), ("titleMatch", 60), ("consensus", 250)]),
            cand("musixmatch", 1, [("durationOvershoot", -700), ("lines", 77),
                                   ("album", 150), ("titleMatch", 120)]),
            cand("lrclib", -1, [("rejectPlainTextOnly", 0)]),
        ]
        expectEqual(V.build(candidates: sampleC, winner: "kugou"),
                    .decisiveNegative(term: term("versionTags", -600), loser: "netease", gap: 221))

        expectEqual(V.ranked(sampleC).map(\.source), ["kugou", "netease", "qq", "musixmatch"])
        expectEqual(sampleC[4].isRejected, true)
        expectEqual(V.sharedTerms(among: sampleC), [])

        expectEqual(sampleC[3].rawTermSum, -353)
        expectEqual(sampleC[3].clampedRawSum, -353)
        expectEqual(sampleC[0].clampedRawSum, nil)
        let dC = V.deltas(champion: sampleC[0], others: Array(sampleC[1 ... 3]))
        expectEqual(dC[2].clampedRawSum, -353)
        expectEqual(dC[2].terms.first, term("durationOvershoot", -700))

        let tie = [cand("qq", 500, [("duration", 250), ("consensus", 250)]),
                   cand("kugou", 500, [("duration", 250), ("consensus", 250)])]
        expectEqual(V.build(candidates: tie, winner: "kugou"),
                    .sameLyrics(contenders: 2, gap: 0, gapPercent: 0.0, nearTie: true,
                                separator: .identical))
        expectEqual(V.champion(among: tie, winner: "kugou")?.source, "kugou")
        expectEqual(V.champion(among: tie, winner: "netease")?.source, "kugou")

        let tooCloseMulti = [
            cand("qq", 700, [("duration", 300), ("lines", 150), ("consensus", 250)]),
            cand("kugou", 696, [("duration", 297), ("lines", 149), ("consensus", 250)]),
            cand("netease", 100, [("duration", 100)]),
        ]
        expectEqual(V.build(candidates: tooCloseMulti, winner: "qq"),
                    .tooClose(contenders: 3, corroborated: 2, gap: 4,
                              gapPercent: 400.0 / 700.0, separator: .multiple))

        if case let .tooClose(n, ok, _, _, _)? = V.build(candidates: tooCloseMulti, winner: "qq") {
            expectEqual([n, ok], [3, 2])
        }

        expectEqual(V.ranked(tie).map(\.source), ["kugou", "qq"])
        expectEqual(V.ranked(tie, winner: "qq").map(\.source), ["qq", "kugou"])
        expectEqual(V.ranked(sampleA, winner: "qq").map(\.source).first, "qq")
        expectEqual(V.ranked(tie, winner: "netease").map(\.source), ["kugou", "qq"])

        expectEqual(V.isNearTie(gap: 1, championScore: 50), true)
        expectEqual(V.isNearTie(gap: 5, championScore: 1200), true)
        expectEqual(V.isNearTie(gap: 5, championScore: 200), false)
        expectEqual(V.isNearTie(gap: 2, championScore: 0), false)

        let noVerdict = [cand("qq", 900, [("duration", 300), ("wordTiming", 400), ("lines", 200)]),
                         cand("kugou", 500, [("duration", 300), ("lines", 200)])]
        expectEqual(V.build(candidates: noVerdict, winner: "qq"), nil)
        expectEqual(V.build(candidates: [sampleA[0]], winner: "qq"), nil)
        expectEqual(V.build(candidates: [], winner: nil), nil)

        let withMarker = tie + [cand("lrclib", -1, [], instrumental: true)]
        expectEqual(V.ranked(withMarker).count, 2)
        expectEqual(V.sharedTerms(among: withMarker), [term("duration", 250), term("consensus", 250)])

        let bothPenalized = [
            cand("qq", 400, [("duration", 300), ("versionTags", -600), ("lines", 700)]),
            cand("kugou", 100, [("duration", 300), ("versionTags", -600), ("lines", 400)]),
        ]
        expectEqual(V.build(candidates: bothPenalized, winner: "qq"), nil)
    }

    do {
        typealias P = EnrichSourcePresence
        expectEqual(P.knownOnSources(neteaseURL: "https://music.163.com/song?id=3421955553", qqMusicURL: nil), true)
        expectEqual(P.knownOnSources(neteaseURL: nil, qqMusicURL: "https://y.qq.com/n/ryqq/songDetail/0015Wy5y3rO14w"), true)
        expectEqual(P.knownOnSources(neteaseURL: "", qqMusicURL: "https://y.qq.com/n/ryqq/search?w=%E8%8C%83%E9%80%B8%E8%87%A3+%E9%9D%A9%E5%91%BD"), false)
        expectEqual(P.knownOnSources(neteaseURL: nil, qqMusicURL: nil), false)

        expectEqual(P.lastRoundHadNoResponder(hasDecisionRecord: true, respondedCount: 0), true)
        expectEqual(P.lastRoundHadNoResponder(hasDecisionRecord: false, respondedCount: 0), false)
        expectEqual(P.lastRoundHadNoResponder(hasDecisionRecord: true, respondedCount: 1), false)
        expectEqual(P.lastRoundHadNoResponder(hasDecisionRecord: true, respondedCount: 9), false)
    }

    do {
        typealias S = LyricsFillSweep
        expectEqual(S.requestBody(keys: []), "all\n")
        expectEqual(S.requestBody(keys: ["周杰伦|晴天|叶惠美", "A|B|C"]), "周杰伦|晴天|叶惠美\nA|B|C\n")
        let json = """
        {"running":true,"manual":true,"total":82,"done":3,"filled":1,"current":"范逸臣|革命|無樂不作","startedAt":1788700000,"updatedAt":1788700100}
        """
        let info = try? JSONDecoder().decode(S.Info.self, from: Data(json.utf8))
        expectEqual(info?.running, true)
        expectEqual(info?.total, 82)
        expectEqual(info?.current, "范逸臣|革命|無樂不作")
        expectEqual(info?.finishedAt, nil)
        let done = try? JSONDecoder().decode(S.Info.self, from: Data("""
        {"running":false,"manual":false,"total":40,"done":40,"filled":6,"startedAt":1,"updatedAt":2,"finishedAt":3,"cancelled":true}
        """.utf8))
        expectEqual(done?.cancelled, true)
        expectEqual(done?.finishedAt, 3)
    }

    do {
        typealias R = LyricsDecisionRow
        expectEqual(R.isInstrumentalMarker(instrumental: true, score: -1), true)
        expectEqual(R.isInstrumentalMarker(instrumental: nil, score: -1), false)
        expectEqual(R.isInstrumentalMarker(instrumental: false, score: -1), false)
        expectEqual(R.isInstrumentalMarker(instrumental: true, score: 0), false)
        expectEqual(R.isInstrumentalMarker(instrumental: true, score: 1208), false)
        expectEqual(R.isInstrumentalMarker(instrumental: nil, score: 1208), false)
    }

    do {
        let sheet = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/lyrimuse/LyricsManager/LyricsDecisionSheet.swift")
        if let text = try? String(contentsOfFile: sheet.path, encoding: .utf8) {

            let marker = text.components(separatedBy: "isInstrumentalMarker").count - 1
            expectEqual(marker >= 2, true)
            let rejected = text.components(separatedBy: "isRejected").count - 1
            expectEqual(rejected >= 2, true)
            expectEqual(text.contains("sidelinedRow"), true)

            if let start = text.range(of: "private func sidelinedRow"),
               let end = text.range(of: "private func scoreBar") {
                let row = String(text[start.lowerBound..<end.lowerBound])
                expectEqual(row.contains("Text(\"\\(c.score)\")"), false)
            } else {
                expectEqual(true, false)
            }
        } else {
            expectEqual(true, false)
        }
    }
}
