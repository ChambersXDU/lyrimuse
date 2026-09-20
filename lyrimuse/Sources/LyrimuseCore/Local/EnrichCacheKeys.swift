import Foundation

public enum EnrichCacheMerge {

    public static func merge(
        disk: [String: [String: Any]],
        memory: [String: [String: Any]],
        edited: Set<String>,
        deleted: Set<String>
    ) -> [String: [String: Any]] {
        var out = disk
        for k in edited {
            if let v = memory[k] { out[k] = v } else { out.removeValue(forKey: k) }
        }
        for k in deleted { out.removeValue(forKey: k) }
        return out
    }
}

public enum EnrichCacheKeys {

    public static let lyricsFileSuffixes = [".lrc", ".tr.lrc", ".roma.lrc", ".yrc"]

    static let versionWords = [
        "remix", "mix", "live", "acoustic", "instrumental", "inst", "demo", "cover",
        "remaster", "version", "ver.", "edit", "extended", "radio", "karaoke",
        "reprise", "feat", "ft.", "featuring", "session", "mono", "stereo", "dub",
        "unplugged", "acappella", "a cappella",
        "interlude", "intro", "outro", "skit", "prelude", "overture",

        "慢板", "快板",
        "现场", "伴奏", "翻唱", "重制", "修复", "版", "纯音乐", "前奏", "间奏",
    ]

    private static let openBrackets: Set<Character> = ["（", "(", "[", "【"]
    private static let closeBrackets: Set<Character> = ["）", ")", "]", "】"]

    public static func cleanTag(_ s: String) -> String {
        let mapped = s.map { c -> Character? in
            switch c {
            case "\u{00a0}", "\u{2007}", "\u{202f}", "\u{3000}": return " "
            case "\u{200b}", "\u{200c}", "\u{200d}", "\u{feff}": return nil
            default: return c
            }
        }.compactMap { $0 }
        return String(mapped).split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizedTitle(_ title: String) -> String {
        var t = cleanTag(title)
        while true {
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            guard let last = trimmed.last, closeBrackets.contains(last) else { return t }

            var idx = trimmed.index(before: trimmed.endIndex)
            var openIdx: String.Index?
            while idx > trimmed.startIndex {
                idx = trimmed.index(before: idx)
                let c = trimmed[idx]
                if closeBrackets.contains(c) { return t }
                if openBrackets.contains(c) { openIdx = idx; break }
            }
            guard let openIdx else { return t }
            let inner = String(trimmed[trimmed.index(after: openIdx)..<trimmed.index(before: trimmed.endIndex)])
                .lowercased()
            if versionWords.contains(where: { inner.contains($0) }) { return t }
            let head = String(trimmed[trimmed.startIndex..<openIdx])
                .trimmingCharacters(in: .whitespaces)
            if head.isEmpty { return t }
            t = head
        }
    }

    public static func normalizedKey(artist: String, title: String, album: String) -> String {
        cleanTag(artist) + "|" + normalizedTitle(title) + "|" + cleanTag(album)
    }

    public static func sanitizeFilename(_ key: String) -> String {
        var name = key.replacingOccurrences(of: "|", with: " - ")
        for c in ["/", ":", "*", "?", "\"", "<", ">", "\\"] {
            name = name.replacingOccurrences(of: c, with: "_")
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    public static func crc32IEEE(_ s: String) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in Array(s.utf8) {
            c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    public static func disambiguatedName(forKey key: String) -> String {
        let sum = crc32IEEE(key) & 0xFF_FFFF
        return String(format: "%@~%06x", sanitizeFilename(key), sum)
    }

    public static func exportedFileNames(forKey key: String) -> [String] {
        let plain = sanitizeFilename(key)
        let hashed = disambiguatedName(forKey: key)
        return lyricsFileSuffixes.map { plain + $0 } + lyricsFileSuffixes.map { hashed + $0 }
    }

    public static func deletionPlan(selected: Set<String>, existing: Set<String>) -> [String] {
        selected.intersection(existing).sorted()
    }

    private static let creditSeparators: Set<Character> = ["/", "、", "&", ",", "，"]

    public static func looseKey(_ key: String) -> String {
        let simplified = NSMutableString(string: key) as CFMutableString
        CFStringTransform(simplified, nil, "Hant-Hans" as CFString, false)
        let folded = String((simplified as String).map { creditSeparators.contains($0) ? "&" : $0 })
        return folded
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

}
