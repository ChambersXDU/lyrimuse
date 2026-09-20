import Foundation

public enum EnrichTitleAliases {
    public struct Entry {
        public var artist: String
        public var title: String
        public var neteaseURL: String?
        public var qqMusicURL: String?

        public var durationSecs: Double?

        public var resolvedDurationSecs: Double?

        public var lyrics: String?

        public init(artist: String, title: String, neteaseURL: String?, qqMusicURL: String?, durationSecs: Double?,
                    resolvedDurationSecs: Double? = nil, lyrics: String? = nil) {
            self.artist = artist
            self.title = title
            self.neteaseURL = neteaseURL
            self.qqMusicURL = qqMusicURL
            self.durationSecs = durationSecs
            self.resolvedDurationSecs = resolvedDurationSecs
            self.lyrics = lyrics
        }
    }

    public static let durationTolerance: Double = 3

    public static let e2DurationTolerance: Double = 0.6

    public static let lyricsTrustTolerance: Double = 3

    public static let lyricsSimilarityMin: Double = 0.6

    public static let lyricsMinTokens = 24

    public static func songIDs(neteaseURL: String?, qqMusicURL: String?) -> [String] {
        var out: [String] = []
        if let s = neteaseURL, let id = neteaseSongID(s) { out.append("netease:" + id) }
        if let s = qqMusicURL, let mid = qqSongMid(s) { out.append("qq:" + mid) }
        return out
    }

    static func neteaseSongID(_ url: String) -> String? {
        guard url.contains("music.163.com"), let range = url.range(of: "id=") else { return nil }
        let digits = url[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    static func qqSongMid(_ url: String) -> String? {
        guard url.contains("y.qq.com"), let range = url.range(of: "/songDetail/") else { return nil }
        let mid = url[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
        return mid.isEmpty ? nil : String(mid)
    }

    public static func coreTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespaces)
        for _ in 0..<4 {
            if let (base, _) = PlayCountVariants.subtitleSplit(t) { t = base; continue }
            if let (base, _) = PlayCountVariants.bracketSuffixSplit(t) { t = base; continue }
            if let (base, _) = PlayCountVariants.dashSuffixSplit(t) { t = base; continue }
            break
        }
        return t
    }

    public static func isHanTitled(_ title: String) -> Bool {
        !PlayCountFold.hasNoHanLikeChars(coreTitle(title))
    }

    public static func lyricsBody(_ lrc: String) -> String {
        var out = ""
        for rawLine in lrc.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            var line = String(rawLine)
            line = line.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            let norm = PlayCountFold.normalized(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !norm.isEmpty, !isCreditLine(norm) else { continue }

            var line2 = ""
            var pendingBreak = false
            for scalar in norm.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) {
                    if pendingBreak, let last = line2.unicodeScalars.last,
                       !CharacterSet.hanLike.contains(last), !CharacterSet.hanLike.contains(scalar) {
                        line2.append(" ")
                    }
                    line2.unicodeScalars.append(scalar)
                    pendingBreak = false
                } else {
                    pendingBreak = !line2.isEmpty
                }
            }
            out += line2 + " "
        }
        return out
    }

    static func isCreditLine(_ s: String) -> Bool {
        let prefixes = ["作词", "作曲", "编曲", "词:", "曲:", "词：", "曲：", "制作", "监制", "录音", "混音", "母带",
                        "lyrics", "lyricist", "composer", "producer", "arranger", "arrangement", "written by",
                        "produced by", "mixed by", "mastered by"]
        return prefixes.contains { s.hasPrefix($0) }
    }

    public static func lyricsSimilarity(_ a: String, _ b: String) -> Double {
        let ga = shingles(lyricsTokens(a)), gb = shingles(lyricsTokens(b))
        let union = ga.union(gb)
        guard !union.isEmpty else { return 0 }
        return Double(ga.intersection(gb).count) / Double(union.count)
    }

    static func lyricsTokens(_ body: String) -> [String] {
        var out: [String] = []
        var latin = ""
        for ch in body {
            if ch == " " {
                if !latin.isEmpty { out.append(latin); latin = "" }
                continue
            }
            let isHan = ch.unicodeScalars.contains { CharacterSet.hanLike.contains($0) }
            if isHan {
                if !latin.isEmpty { out.append(latin); latin = "" }
                out.append(String(ch))
            } else {
                latin.append(ch)
            }
        }
        if !latin.isEmpty { out.append(latin) }
        return out
    }

    static func shingles(_ tokens: [String], size: Int = 3) -> Set<String> {
        guard tokens.count >= size else { return tokens.isEmpty ? [] : [tokens.joined(separator: "\u{1F}")] }
        var out = Set<String>()
        for i in 0...(tokens.count - size) { out.insert(tokens[i..<(i + size)].joined(separator: "\u{1F}")) }
        return out
    }

    static func lyricsTrusted(_ e: Entry) -> Bool {
        guard let d = e.durationSecs, d > 0, let r = e.resolvedDurationSecs, r > 0 else { return true }
        return abs(d - r) <= lyricsTrustTolerance
    }

    static func durationsClose(_ a: [Double], _ b: [Double], tolerance: Double) -> Bool {
        for x in a {
            for y in b {
                let tol = (isIntegral(x) || isIntegral(y)) ? tolerance : e2PreciseTolerance
                if abs(x - y) <= tol { return true }
            }
        }
        return false
    }

    static func isIntegral(_ v: Double) -> Bool { abs(v - v.rounded()) < 1e-6 }

    public static let e2PreciseTolerance: Double = 0.05

    static func oneCharVariant(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard x.count == y.count, x.count >= 2 else { return false }
        var diff = 0
        for i in 0..<x.count where x[i] != y[i] { diff += 1; if diff > 1 { return false } }
        return diff == 1
    }

    public static func derive(_ entries: [Entry],
                              artistKey: (String) -> String = { PlayCountFold.canonicalArtistKey($0) }) -> [String: [String: String]] {

        struct Item {
            var title: String
            var count = 0
            var durations: [Double] = []
            var lyricsBodies: [String] = []
        }
        struct Bucket { var han: [String: Item] = [:]; var nonHan: [String: Item] = [:] }
        var buckets: [String: Bucket] = [:]

        struct IDGroup { var han: [String: String] = [:]; var nonHan: [String: String] = [:]
                         var hanDur: [Double] = []; var nonHanDur: [Double] = [] }
        var idGroups: [String: [String: IDGroup]] = [:]

        func eligibleForE2(_ folded: String, _ item: Item) -> Bool {
            !item.durations.isEmpty && !item.lyricsBodies.isEmpty
                && PlayCountFold.foldTitle(coreTitle(item.title)) == folded
        }

        for e in entries {
            let title = e.title.trimmingCharacters(in: .whitespaces)
            guard !e.artist.isEmpty, !title.isEmpty else { continue }
            let artistKey = artistKey(e.artist)
            let folded = PlayCountFold.foldTitle(title)
            let isHan = isHanTitled(title)

            var bucket = buckets[artistKey] ?? Bucket()
            var side = isHan ? bucket.han : bucket.nonHan
            var item = side[folded] ?? Item(title: title)
            item.count += 1
            if title < item.title { item.title = title }
            if let d = e.durationSecs, d > 0 { item.durations.append(d) }
            if let l = e.lyrics, lyricsTrusted(e) {
                let body = lyricsBody(l)
                if lyricsTokens(body).count >= lyricsMinTokens { item.lyricsBodies.append(body) }
            }
            side[folded] = item
            if isHan { bucket.han = side } else { bucket.nonHan = side }
            buckets[artistKey] = bucket

            for id in songIDs(neteaseURL: e.neteaseURL, qqMusicURL: e.qqMusicURL) {
                var byID = idGroups[artistKey] ?? [:]
                var g = byID[id] ?? IDGroup()
                if isHan {
                    if let existing = g.han[folded] { if title < existing { g.han[folded] = title } } else { g.han[folded] = title }
                    if let d = e.durationSecs, d > 0 { g.hanDur.append(d) }
                } else {
                    if let existing = g.nonHan[folded] { if title < existing { g.nonHan[folded] = title } } else { g.nonHan[folded] = title }
                    if let d = e.durationSecs, d > 0 { g.nonHanDur.append(d) }
                }
                byID[id] = g
                idGroups[artistKey] = byID
            }
        }

        var proposals: [String: [String: [String: String]]] = [:]
        func propose(_ artistKey: String, _ engFolded: String, _ hanFolded: String, _ hanRaw: String) {
            guard engFolded != hanFolded else { return }
            var forEng = proposals[artistKey]?[engFolded] ?? [:]
            if let existing = forEng[hanFolded] { if hanRaw < existing { forEng[hanFolded] = hanRaw } }
            else { forEng[hanFolded] = hanRaw }
            proposals[artistKey, default: [:]][engFolded] = forEng
        }

        for artistKey in idGroups.keys.sorted() {
            for id in idGroups[artistKey]!.keys.sorted() {
                let g = idGroups[artistKey]![id]!
                guard g.nonHan.count == 1, g.han.count == 1,
                      let (hanFolded, hanRaw) = g.han.first, let (engFolded, _) = g.nonHan.first
                else { continue }
                if let a = g.hanDur.min(), let b = g.nonHanDur.min(), abs(a - b) > durationTolerance { continue }
                propose(artistKey, engFolded, hanFolded, hanRaw)
            }
        }

        for artistKey in buckets.keys.sorted() {
            let bucket = buckets[artistKey]!
            var members: [(folded: String, item: Item, han: Bool)] = []
            for (folded, item) in bucket.han where eligibleForE2(folded, item) { members.append((folded, item, true)) }
            for (folded, item) in bucket.nonHan where eligibleForE2(folded, item) { members.append((folded, item, false)) }
            guard members.count >= 2 else { continue }
            members.sort { $0.folded < $1.folded }
            var uf = LocalArtistAliases.UnionFind()
            for i in 0..<members.count {
                uf.add(members[i].folded)
                for j in (i + 1)..<members.count {
                    let x = members[i], y = members[j]

                    guard x.han != y.han || oneCharVariant(x.folded, y.folded) else { continue }
                    guard durationsClose(x.item.durations, y.item.durations, tolerance: e2DurationTolerance) else { continue }
                    var best = 0.0
                    for p in x.item.lyricsBodies { for q in y.item.lyricsBodies { best = max(best, lyricsSimilarity(p, q)) } }
                    if best >= lyricsSimilarityMin { uf.union(x.folded, y.folded) }
                }
            }
            var classes: [String: [(folded: String, item: Item, han: Bool)]] = [:]
            for m in members { classes[uf.find(m.folded), default: []].append(m) }
            for (_, group) in classes where group.count >= 2 {
                let rep = group.min { a, b in
                    if a.han != b.han { return a.han }
                    if a.item.count != b.item.count { return a.item.count > b.item.count }
                    return a.folded < b.folded
                }!
                for m in group where m.folded != rep.folded {
                    propose(artistKey, m.folded, rep.folded, rep.item.title)
                }
            }
        }

        var out: [String: [String: String]] = [:]
        for artistKey in proposals.keys.sorted() {
            for (engFolded, targets) in proposals[artistKey]! where targets.count == 1 {
                out[artistKey, default: [:]][engFolded] = targets.values.first!
            }
        }
        return out
    }
}
