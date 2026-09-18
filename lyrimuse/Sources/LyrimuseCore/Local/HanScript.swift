import Foundation

/// Traditional and Simplified Chinese script transformations (Hant <-> Hans twins).
///
/// Used by Last.fm play count queries to aggregate scrobbles across differing script variants
/// of the same song entity.
///
/// Transform strategy: attempts Traditional -> Simplified first via ICU CFStringTransform;
/// if unchanged, attempts Simplified -> Traditional. Because Simplified -> Traditional can be
/// a 1-to-many mapping, results are used strictly for query aggregation rather than authoritative
/// display.
public enum HanScript {
    /// Returns (artist, title) transformed in a single consistent direction, or nil if unchanged.
    public static func siblingPair(artist: String, title: String)
        -> (artist: String, title: String)?
    {
        let sa = transform(artist, "Hant-Hans"), st = transform(title, "Hant-Hans")
        if sa != artist || st != title { return (sa, st) }
        let ta = transform(artist, "Hans-Hant"), tt = transform(title, "Hans-Hant")
        if ta != artist || tt != title { return (ta, tt) }
        return nil
    }

    /// Single-string variant for composite keys.
    public static func sibling(_ s: String) -> String? {
        let t2s = transform(s, "Hant-Hans")
        if t2s != s { return t2s }
        let s2t = transform(s, "Hans-Hant")
        if s2t != s { return s2t }
        return nil
    }

    private static func transform(_ s: String, _ id: String) -> String {
        let m = NSMutableString(string: s) as CFMutableString
        CFStringTransform(m, nil, id as CFString, false)
        return m as String
    }
}

/// Play count variant candidates for resolving title formatting fragmentation in Last.fm.
///
/// Generates common bracket and spacing variants (half-width, full-width, spaced, plain title)
/// and Traditional/Simplified script twins for songs containing Han characters.
public enum PlayCountVariants {
    /// Han character variant pairs within Traditional Chinese orthography where standard
    /// bidirectional ICU transforms fold both forms into a single simplified character,
    /// but cannot produce both traditional forms from simplified input.
    static let hanVariantPairs: [Character: Character] = [
        "麼": "麽", "麽": "麼", "裡": "裏", "裏": "裡", "為": "爲", "爲": "為",
        "晚": "晩", "晩": "晚", "線": "綫", "綫": "線", "眾": "衆", "衆": "眾",
    ]

    /// Applies character variant substitutions; returns nil if no mapped characters exist.
    static func variantSwapped(_ s: String) -> String? {
        guard s.contains(where: { hanVariantPairs[$0] != nil }) else { return nil }
        return String(s.map { hanVariantPairs[$0] ?? $0 })
    }

    /// Returns deduplicated sibling candidate pairs ranked by priority (max 6).
    public static func siblings(artist: String, title: String) -> [(artist: String, title: String)] {
        var out: [(artist: String, title: String)] = []
        var seen: Set<String> = [fold(artist, title)]
        func add(_ a: String, _ t: String) {
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, out.count < 6, seen.insert(fold(a, trimmed)).inserted else { return }
            out.append((a, trimmed))
        }
        // Catalog noise subtitles (e.g. remaster/feat): generate stripped base title candidate.
        if let (base, sub) = subtitleSplit(title), isCatalogNoiseSubtitle(sub) {
            add(artist, base)
        }
        if let (base, sub) = subtitleSplit(title), containsHan(title) {
            let bases = [base] + (variantSwapped(base).map { [$0] } ?? [])
            for b in bases { add(artist, "\(b)(\(sub))") }
            for b in bases { add(artist, "\(b)（\(sub)）") }
            add(artist, "\(base) (\(sub))")
            for b in bases { add(artist, b) }
        } else if let swapped = variantSwapped(title) {
            add(artist, swapped)
        }
        if let sib = HanScript.siblingPair(artist: artist, title: title) {
            add(sib.artist, sib.title)
        }
        return out
    }

    /// Evaluates whether a title subtitle represents catalog/editorial metadata rather than a distinct recording.
    ///
    /// Categories:
    ///  - Featured artist credits: `(feat. X)`, `(ft. X)`, `(featuring X)`, `(with X)`.
    ///  - Edition/reissue tags: `(Remastered 2014)`, `(2014 Remaster)`, `(Bonus Track)`, `(Explicit)`.
    ///
    /// Distinct audio recordings (e.g. Live, Remix, Acoustic, Clean edits) are intentionally excluded
    /// to preserve distinct track accounting.
    static func isCatalogNoiseSubtitle(_ sub: String) -> Bool {
        let normalized = sub.precomposedStringWithCompatibilityMapping
            .lowercased().trimmingCharacters(in: .whitespaces)
        // 地区/渠道限定词:附加曲标记常带发行地或渠道前缀。刻意是白名单而不是 `\\w+`。
        let region = "japan(ese)?|jp|us|uk|eu|international|digital|itunes|deluxe(\\s+edition)?|cd|hidden"
        for pattern in [
            "^(\\d{4}\\s+)?remaster(ed)?(\\s+\\d{4})?(\\s+version)?$",
            "^((\(region))\\s+)?bonus(\\s+track)?(\\s+version)?$",
            "^explicit(\\s+version)?$",
        ] where normalized.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        // 客串署名家族:前缀 + (点或空格) + 非空署名。"feathers" 这类只是巧合同头的词
        // 靠「必须跟点/空格」挡住(实测 Without You / Withdrawal / Within Temptation
        // 全部被它挡住,这道守卫别动);空署名("(feat.)")不算,不折。
        for prefix in ["featuring", "feat", "ft", "with"] where normalized.hasPrefix(prefix) {
            let rest = normalized.dropFirst(prefix.count)
            guard let boundary = rest.first, boundary == "." || boundary == " " else { continue }
            let credit = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !credit.isEmpty else { continue }
            // `with` 专属的第二道:feat./ft./featuring 是纯署名标记,语法上后面只能跟
            // 表演者;`with` 是介词,后面还可以跟乐队编制、音频内容,本身又能当歌名首词。
            // 这是 with 与 feat 的本质不对称,守卫不能照搬。
            if prefix == "with",
               let head = credit.split(whereSeparator: { $0.isWhitespace }).first,
               nonCreditHeadWords.contains(
                   String(head).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)) {
                continue
            }
            return true
        }
        return false
    }

    /// `(with …)` 后面跟的**不是人**的头词。两类:
    ///  ①乐队编制/音频内容(strings / orchestra / intro / backing …)—— 那标的是
    ///    **另一份录音**(重录的管弦版之类),不是署名;
    ///  ②冠词与连接词(the / a / or / out …)—— 说明副题是个**词组**而不是署名,
    ///    典型 `(With or Without You)` / `(With A Little Help From My Friends)`,
    ///    剥掉会把两首**不同的歌**并成一首。
    /// ⚠️ 这份用户索引里 19 条 `(with …)` 的头词全是真人名,这张表**当下 0 命中**——
    /// 也就是加它零行为变化。加的理由是折叠键会**永久**写进索引文件,而这个库里就有
    /// Horace Silver / Paul Desmond / Johnny Griffin / Nancy Wilson 这批爵士,
    /// 「with strings」正是该品类的标准写法,哪天进库就是错合。
    /// 代价:`with The Weeknd` 会被 `the` 漏掉 —— 符合本文件一贯的「宁可漏合,不错合」。
    static let nonCreditHeadWords: Set<String> = [
        "the", "a", "an", "no", "or", "out", "my", "your", "all",
        "strings", "string", "orchestra", "orchestral", "choir", "chorus", "band",
        "intro", "outro", "interlude", "dialogue", "commentary", "narration",
        "vocal", "vocals", "backing", "drums", "beat", "beats", "rain", "lyrics",
        "弦乐", "弦樂", "交响", "交響", "乐团", "樂團", "伴奏", "和声", "和聲", "前奏",
    ]

    /// 版本/发行标记词:这一段不是"译名"而是"另一份录音的标记"。刻意**不**收 feat/with ——
    /// 那是署名(目录学噪音),该收敛;这里收的是"不同录音"。
    /// 输入都已过 PlayCountFold.normalized(NFKC + ICU 繁简 + 小写),所以只列**简体**形。
    static let versionMarkerWords: Set<String> = [
        "live", "demo", "remix", "mix", "acoustic", "instrumental", "inst", "karaoke",
        "unplugged", "reprise", "edit", "version", "remaster", "remastered", "acappella",
        "alternate", "reimagined", "session", "sessions", "medley", "dub",
    ]

    /// 中文的版本词。中文没有空格、分不了词,所以另走一条判据:整串以「版」收尾
    /// (钢琴版/独唱版/live版/国语版/完整版),或整串就是这几个词。
    static let cjkVersionWords: Set<String> = ["现场", "演唱会", "纯音乐", "伴奏", "原唱"]

    /// 这个尾缀是不是**版本标记**。给分隔符归一用(见 PlayCountFold.canonicalizeVersionSuffix)。
    static func isVersionSuffix(_ sub: String) -> Bool {
        let t = sub.trimmingCharacters(in: .whitespaces)
        let squeezed = String(t.filter { !$0.isWhitespace })
        // 「…版」/「…版本」都是中文的 version。`版本` 单独判是因为它以「本」收尾、
        // hasSuffix("版") 接不住(实测漏判 `你不知道的事 - 宋曉青版本`)。
        if squeezed.hasSuffix("版") || squeezed.hasSuffix("版本") { return true }
        if cjkVersionWords.contains(squeezed) { return true }
        return t.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .contains { versionMarkerWords.contains($0) }
    }

    /// Ambiguous concert markers that indicate a live performance without identifying a specific concert.
    /// Excluded from suffix delimiter canonicalization because different live releases of the same song
    /// represent distinct recordings.
    static let ambiguousConcertMarkers: Set<String> = [
        "live", "现场", "现场版", "live版", "演唱会", "演唱会版", "演唱会现场",
    ]

    /// Splits bracketed suffix: `Song [Live 08]` -> ("Song", "Live 08").
    /// Used for delimiter canonicalization.
    static func bracketSuffixSplit(_ title: String) -> (base: String, sub: String)? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let last = t.last, last == "]" || last == "】" else { return nil }
        let body = t.dropLast()
        guard let open = body.lastIndex(where: { $0 == "[" || $0 == "【" }) else { return nil }
        let base = String(body[..<open]).trimmingCharacters(in: .whitespaces)
        let sub = String(body[body.index(after: open)...]).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !sub.isEmpty else { return nil }
        return (base, sub)
    }

    /// Splits dash-delimited suffix: `Bad - 2012 Remaster` -> ("Bad", "2012 Remaster").
    /// Requires whitespace surrounding the dash to avoid splitting hyphenated words.
    static func dashSuffixSplit(_ title: String) -> (base: String, sub: String)? {
        let t = title.trimmingCharacters(in: .whitespaces)
        var lastRange: Range<String.Index>?
        var from = t.startIndex
        while let hit = t.range(of: "\\s+[-\u{2013}\u{2014}]\\s+",
                                options: .regularExpression, range: from..<t.endIndex) {
            lastRange = hit
            from = hit.upperBound
        }
        guard let r = lastRange else { return nil }
        let base = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        let sub = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !sub.isEmpty else { return nil }
        return (base, sub)
    }

    /// 歌名结尾的括号副题:`一口（The Day You Left Me）` → ("一口", "The Day You Left Me")。
    /// 开/闭括号不要求同风格配对 —— 目的只是切出副题,不是校验语法。
    static func subtitleSplit(_ title: String) -> (base: String, sub: String)? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let last = t.last, last == "）" || last == ")" else { return nil }
        let body = t.dropLast()
        guard let openIdx = body.lastIndex(where: { $0 == "（" || $0 == "(" }) else { return nil }
        let base = String(body[..<openIdx]).trimmingCharacters(in: .whitespaces)
        let sub = String(body[body.index(after: openIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !sub.isEmpty else { return nil }
        return (base, sub)
    }

    static func containsHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    private static func fold(_ a: String, _ t: String) -> String {
        a.trimmingCharacters(in: .whitespaces).lowercased()
            + "|" + t.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// Folding key for Last.fm play count variant index.
///
/// Normalizes titles and artist names to aggregate scrobble counts across variant spellings:
///  - Full-width / half-width forms and spaces (NFKC).
///  - Traditional / Simplified Han script (ICU Hant-Hans).
///  - Whitespace removal and case folding.
///  - Bilingual "CJK + Latin" concatenated titles (collapses to CJK segment).
///  - Catalog noise subtitles (remaster, feat).
/// General parenthesized subtitles with distinct recording markers (Live, Remix) are preserved.
public enum PlayCountFold {
    /// Folding rule version. Incremented when `key()` or `foldTitle()` semantics change to trigger
    /// index rebuild on load (`LastfmStatsService.loadTitleForms`).
    public static let foldVersion = 7

    /// In-memory cache for folding keys to optimize repeated NFKC and ICU transforms.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var keyCache: [String: String] = [:]

    public static func key(artist: String, title: String) -> String {
        let raw = artist + "\u{1F}" + title
        cacheLock.lock()
        let hit = keyCache[raw]
        cacheLock.unlock()
        if let hit { return hit }
        let value = stripSpaces(normalized(artist)) + "|" + foldTitle(title)
        cacheLock.lock()
        keyCache[raw] = value
        cacheLock.unlock()
        return value
    }

    /// Generates key for writing variant groupings in `primaryCreditFamilies`.
    /// Canonicalizes artist to primary credit and canonical name, and resolves title aliases to Chinese canonical names.
    public static func familyKey(artist: String, title: String) -> String {
        let canonArtist = canonicalArtist(artist)
        let artistKey = canonicalArtistKey(canonArtist)
        let foldedTitle = foldTitle(title)
        // Locally inferred title aliases take precedence over discovered aliases.
        let canonTitle = lookupLocalTitleAlias(artistKey: artistKey, foldedTitle: foldedTitle)
            ?? lookupDiscoveredTitleAlias(artistKey: artistKey, foldedTitle: foldedTitle)
            ?? title
        return key(artist: canonArtist, title: canonTitle)
    }

    /// `familyKey` 拼外层键那一步单独拎出来 —— App 侧的自动发现扫描
    /// (LastfmStatsService.discoverTitleAliasesIfNeeded)要按「同一个歌手」分组比较
    /// 候选写法,得用**跟 familyKey 完全同一把尺子**算歌手键,不能自己另写一遍归一逻辑
    /// (两处稍有出入就会出现"发现表写的键,familyKey 查的时候对不上"的静默失效)。
    /// 参数接受原始歌手写法即可(内部会先 canonicalArtist),不要求调用方先归一。
    public static func canonicalArtistKey(_ artist: String) -> String {
        stripSpaces(normalized(canonicalArtist(artist)))
    }

    /// 一个歌名折叠键里完全不含汉字/假名 —— 判定"这是候选的罗马字/译名写法,值得去
    /// 找它的中文对应"的信号。复用 LyricsSyncEngine 里给歌词抬头分段判定用的
    /// `CharacterSet.hanLike`(汉字 + 假名),不新造一套字符集判断。
    public static func hasNoHanLikeChars(_ s: String) -> Bool {
        !s.unicodeScalars.contains { CharacterSet.hanLike.contains($0) }
    }

    /// Canonicalizes artist credit: collapses featured artist credits to primary artist,
    /// then resolves romanized/alias artist names to their canonical Chinese representation
    /// via locally inferred aliases (`LocalArtistAliases`).
    public static func canonicalArtist(_ artist: String) -> String {
        let primary = ArtistCredit.mergeArtist(artist)
        return lookupLocalArtistAlias(stripSpaces(normalized(primary))) ?? primary
    }

    private static let artistLock = NSLock()
    nonisolated(unsafe) private static var localArtistAliases: [String: String] = [:]

    /// Registers locally inferred artist alias table: `stripSpaces(normalized(mergeArtist(variant))) -> canonicalName`.
    public static func setLocalArtistAliases(_ table: [String: String]) {
        artistLock.lock()
        localArtistAliases = table
        artistLock.unlock()
    }

    private static func lookupLocalArtistAlias(_ key: String) -> String? {
        artistLock.lock()
        let value = localArtistAliases[key]
        artistLock.unlock()
        return value
    }

    // Title alias mapping resolution order: locally inferred table (high confidence via shared
    // track IDs or matching duration/lyrics) -> discovered aliases table (Last.fm duration match).

    // In-memory cache of discovered title aliases populated asynchronously by LastfmStatsService.
    // Keyed by canonical artist key -> folded title -> target Chinese title.
    private static let discoveredLock = NSLock()
    nonisolated(unsafe) private static var discoveredTitleAliasesByArtist: [String: [String: String]] = [:]

    public static func setDiscoveredTitleAliases(_ table: [String: [String: String]]) {
        discoveredLock.lock()
        discoveredTitleAliasesByArtist = table
        discoveredLock.unlock()
    }

    private static func lookupDiscoveredTitleAlias(artistKey: String, foldedTitle: String) -> String? {
        discoveredLock.lock()
        let value = discoveredTitleAliasesByArtist[artistKey]?[foldedTitle]
        discoveredLock.unlock()
        return value
    }

    // In-memory cache of title aliases inferred locally from the enrich cache.
    // Inferred when different title forms share the same service song ID.
    private static let localLock = NSLock()
    nonisolated(unsafe) private static var localTitleAliasesByArtist: [String: [String: String]] = [:]

    public static func setLocalTitleAliases(_ table: [String: [String: String]]) {
        localLock.lock()
        localTitleAliasesByArtist = table
        localLock.unlock()
    }

    private static func lookupLocalTitleAlias(artistKey: String, foldedTitle: String) -> String? {
        localLock.lock()
        let value = localTitleAliasesByArtist[artistKey]?[foldedTitle]
        localLock.unlock()
        return value
    }

    /// Normalizes a song title by stripping catalog metadata, canonicalizing version delimiters,
    /// and collapsing bilingual segments while preserving genuine version distinctions.
    public static func foldTitle(_ title: String) -> String {
        let n = normalized(title)
        let stripped = stripCatalogNoise(n)
        let canon = stripCatalogNoise(canonicalizeVersionSuffix(stripped))
        return stripSpaces(collapseBilingualGuardingVersionMarkers(canon))
    }

    /// Canonicalizes delimiter format for recognized version suffixes (e.g. `- Version` or `[Version]` to `(Version)`).
    /// Preserves raw strings for ambiguous live concert markers lacking venue/date context.
    static func canonicalizeVersionSuffix(_ s: String) -> String {
        let splits = [PlayCountVariants.subtitleSplit,
                      PlayCountVariants.bracketSuffixSplit,
                      PlayCountVariants.dashSuffixSplit]
        for split in splits {
            guard let (base, sub) = split(s), PlayCountVariants.isVersionSuffix(sub) else { continue }
            let squeezed = String(sub.filter { !$0.isWhitespace }).lowercased()
            if PlayCountVariants.ambiguousConcertMarkers.contains(squeezed) { return s }
            return base + "(" + sub + ")"
        }
        return s
    }

    /// Guards bilingual title collapse against strings containing recognized version markers.
    static func collapseBilingualGuardingVersionMarkers(_ s: String) -> String {
        let words = s.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
        if words.contains(where: isVersionToken) { return s }
        return collapseBilingual(s)
    }

    /// Evaluates whether a token represents a version marker (e.g. matching `versionMarkerWords` or ending in "版" / "版本").
    static func isVersionToken(_ w: String) -> Bool {
        if PlayCountVariants.versionMarkerWords.contains(w) { return true }
        return w.hasSuffix("版") || w.hasSuffix("版本")
    }

    /// Strips catalog noise subtitles (e.g. remaster tags, featured artist credits).
    static func stripCatalogNoise(_ s: String) -> String {
        var t = s
        while true {
            if let (base, sub) = PlayCountVariants.subtitleSplit(t),
               PlayCountVariants.isCatalogNoiseSubtitle(sub) {
                t = trimTrailingJoiners(base); continue
            }
            if let (base, sub) = PlayCountVariants.dashSuffixSplit(t),
               PlayCountVariants.isCatalogNoiseSubtitle(sub) {
                t = trimTrailingJoiners(base); continue
            }
            break
        }
        return t
    }

    private static func trimTrailingJoiners(_ s: String) -> String {
        var t = s
        while let last = t.last,
              last.isWhitespace || "-\u{2013}\u{2014}:,\u{3001}".contains(last) {
            t.removeLast()
        }
        return t
    }

    /// Applies NFKC normalization, Traditional-to-Simplified Han transformation, and lowercase folding.
    static func normalized(_ s: String) -> String {
        let nfkc = s.precomposedStringWithCompatibilityMapping
        let m = NSMutableString(string: nfkc) as CFMutableString
        CFStringTransform(m, nil, "Hant-Hans" as CFString, false)
        return (m as String).lowercased()
    }

    /// R1:恰好「CJK 段 + 拉丁段」(顺序不限、以空格分界、不含括号)的双语拼接名
    /// → 取 CJK 段。含括号或段落交错的不动 —— 宁可漏合,不错合。
    static func collapseBilingual(_ s: String) -> String {
        guard !s.contains("("), !s.contains(")") else { return s }
        let t = s.trimmingCharacters(in: .whitespaces)
        let tokens = t.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return t }
        let flags = tokens.map { PlayCountVariants.containsHan($0) }
        guard flags.contains(true), flags.contains(false) else { return t }
        // CJK 全在前缀:后面全是拉丁
        if flags[0], let cut = flags.firstIndex(of: false), !flags[cut...].contains(true) {
            let han = tokens[..<cut].joined()
            if han.count >= 2 { return han }
        }
        // CJK 全在后缀:前面全是拉丁
        if !flags[0], let cut = flags.firstIndex(of: true), !flags[cut...].contains(false) {
            let han = tokens[cut...].joined()
            if han.count >= 2 { return han }
        }
        return t
    }

    /// 模块内可见,理由同 normalized。
    static func stripSpaces(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }
}
