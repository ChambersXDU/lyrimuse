import Foundation

public enum HanScript {

    public static func siblingPair(artist: String, title: String)
        -> (artist: String, title: String)?
    {
        let sa = transform(artist, "Hant-Hans"), st = transform(title, "Hant-Hans")
        if sa != artist || st != title { return (sa, st) }
        let ta = transform(artist, "Hans-Hant"), tt = transform(title, "Hans-Hant")
        if ta != artist || tt != title { return (ta, tt) }
        return nil
    }

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

public enum PlayCountVariants {

    static let hanVariantPairs: [Character: Character] = [
        "麼": "麽", "麽": "麼", "裡": "裏", "裏": "裡", "為": "爲", "爲": "為",
        "晚": "晩", "晩": "晚", "線": "綫", "綫": "線", "眾": "衆", "衆": "眾",
    ]

    static func variantSwapped(_ s: String) -> String? {
        guard s.contains(where: { hanVariantPairs[$0] != nil }) else { return nil }
        return String(s.map { hanVariantPairs[$0] ?? $0 })
    }

    public static func siblings(artist: String, title: String) -> [(artist: String, title: String)] {
        var out: [(artist: String, title: String)] = []
        var seen: Set<String> = [fold(artist, title)]
        func add(_ a: String, _ t: String) {
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, out.count < 6, seen.insert(fold(a, trimmed)).inserted else { return }
            out.append((a, trimmed))
        }

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

    static func isCatalogNoiseSubtitle(_ sub: String) -> Bool {
        let normalized = sub.precomposedStringWithCompatibilityMapping
            .lowercased().trimmingCharacters(in: .whitespaces)

        let region = "japan(ese)?|jp|us|uk|eu|international|digital|itunes|deluxe(\\s+edition)?|cd|hidden"
        for pattern in [
            "^(\\d{4}\\s+)?remaster(ed)?(\\s+\\d{4})?(\\s+version)?$",
            "^((\(region))\\s+)?bonus(\\s+track)?(\\s+version)?$",
            "^explicit(\\s+version)?$",
        ] where normalized.range(of: pattern, options: .regularExpression) != nil {
            return true
        }

        for prefix in ["featuring", "feat", "ft", "with"] where normalized.hasPrefix(prefix) {
            let rest = normalized.dropFirst(prefix.count)
            guard let boundary = rest.first, boundary == "." || boundary == " " else { continue }
            let credit = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !credit.isEmpty else { continue }

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

    static let nonCreditHeadWords: Set<String> = [
        "the", "a", "an", "no", "or", "out", "my", "your", "all",
        "strings", "string", "orchestra", "orchestral", "choir", "chorus", "band",
        "intro", "outro", "interlude", "dialogue", "commentary", "narration",
        "vocal", "vocals", "backing", "drums", "beat", "beats", "rain", "lyrics",
        "弦乐", "弦樂", "交响", "交響", "乐团", "樂團", "伴奏", "和声", "和聲", "前奏",
    ]

    static let versionMarkerWords: Set<String> = [
        "live", "demo", "remix", "mix", "acoustic", "instrumental", "inst", "karaoke",
        "unplugged", "reprise", "edit", "version", "remaster", "remastered", "acappella",
        "alternate", "reimagined", "session", "sessions", "medley", "dub",
    ]

    static let cjkVersionWords: Set<String> = ["现场", "演唱会", "纯音乐", "伴奏", "原唱"]

    static func isVersionSuffix(_ sub: String) -> Bool {
        let t = sub.trimmingCharacters(in: .whitespaces)
        let squeezed = String(t.filter { !$0.isWhitespace })

        if squeezed.hasSuffix("版") || squeezed.hasSuffix("版本") { return true }
        if cjkVersionWords.contains(squeezed) { return true }
        return t.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .contains { versionMarkerWords.contains($0) }
    }

    static let ambiguousConcertMarkers: Set<String> = [
        "live", "现场", "现场版", "live版", "演唱会", "演唱会版", "演唱会现场",
    ]

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

public enum PlayCountFold {

    public static let foldVersion = 7

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

    public static func familyKey(artist: String, title: String) -> String {
        let canonArtist = canonicalArtist(artist)
        let artistKey = canonicalArtistKey(canonArtist)
        let foldedTitle = foldTitle(title)

        let canonTitle = lookupLocalTitleAlias(artistKey: artistKey, foldedTitle: foldedTitle)
            ?? lookupDiscoveredTitleAlias(artistKey: artistKey, foldedTitle: foldedTitle)
            ?? title
        return key(artist: canonArtist, title: canonTitle)
    }

    public static func canonicalArtistKey(_ artist: String) -> String {
        stripSpaces(normalized(canonicalArtist(artist)))
    }

    public static func hasNoHanLikeChars(_ s: String) -> Bool {
        !s.unicodeScalars.contains { CharacterSet.hanLike.contains($0) }
    }

    public static func canonicalArtist(_ artist: String) -> String {
        let primary = ArtistCredit.mergeArtist(artist)
        return lookupLocalArtistAlias(stripSpaces(normalized(primary))) ?? primary
    }

    private static let artistLock = NSLock()
    nonisolated(unsafe) private static var localArtistAliases: [String: String] = [:]

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

    public static func foldTitle(_ title: String) -> String {
        let n = normalized(title)
        let stripped = stripCatalogNoise(n)
        let canon = stripCatalogNoise(canonicalizeVersionSuffix(stripped))
        return stripSpaces(collapseBilingualGuardingVersionMarkers(canon))
    }

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

    static func collapseBilingualGuardingVersionMarkers(_ s: String) -> String {
        let words = s.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
        if words.contains(where: isVersionToken) { return s }
        return collapseBilingual(s)
    }

    static func isVersionToken(_ w: String) -> Bool {
        if PlayCountVariants.versionMarkerWords.contains(w) { return true }
        return w.hasSuffix("版") || w.hasSuffix("版本")
    }

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

    static func normalized(_ s: String) -> String {
        let nfkc = s.precomposedStringWithCompatibilityMapping
        let m = NSMutableString(string: nfkc) as CFMutableString
        CFStringTransform(m, nil, "Hant-Hans" as CFString, false)
        return (m as String).lowercased()
    }

    static func collapseBilingual(_ s: String) -> String {
        guard !s.contains("("), !s.contains(")") else { return s }
        let t = s.trimmingCharacters(in: .whitespaces)
        let tokens = t.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return t }
        let flags = tokens.map { PlayCountVariants.containsHan($0) }
        guard flags.contains(true), flags.contains(false) else { return t }

        if flags[0], let cut = flags.firstIndex(of: false), !flags[cut...].contains(true) {
            let han = tokens[..<cut].joined()
            if han.count >= 2 { return han }
        }

        if !flags[0], let cut = flags.firstIndex(of: true), !flags[cut...].contains(false) {
            let han = tokens[cut...].joined()
            if han.count >= 2 { return han }
        }
        return t
    }

    static func stripSpaces(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }
}
