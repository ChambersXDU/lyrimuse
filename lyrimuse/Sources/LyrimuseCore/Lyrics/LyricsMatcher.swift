import Foundation

public struct LyricsMatch: Sendable, Equatable {
    public let candidate: LyricsCandidate
    public let score: Int
    public let terms: [LyricsScoreTermValue]
    public let consensusPeers: [String]

    public var source: String { candidate.source }
    public var isRejected: Bool { terms.first?.kind.hasPrefix("reject") ?? false }

    public init(candidate: LyricsCandidate, score: Int, terms: [LyricsScoreTermValue], consensusPeers: [String] = []) {
        self.candidate = candidate
        self.score = score
        self.terms = terms
        self.consensusPeers = consensusPeers
    }
}

public enum LyricsMatcher {
    private static let featWords = ["feat", "ft", "featuring", "with"]
    private static let versionWords = [
        "live", "remix", "mix", "demo", "acoustic", "instrumental", "inst", "remaster", "remastered",
        "version", "edit", "extended", "radio", "karaoke", "reprise", "session", "mono",
        "stereo", "dub", "unplugged", "现场", "伴奏", "翻唱", "重制", "修复", "纯音乐",
    ]

    public static func rank(_ candidates: [LyricsCandidate], for query: LyricsQuery) -> [LyricsMatch] {
        let unique = deduplicate(candidates)
        guard !unique.isEmpty else { return [] }

        let firstPass = unique.map { score($0, for: query, peers: unique) }
        let bestTitle = firstPass.filter { !$0.isRejected }.map { titleScore($0.candidate.title, query.title) }.max() ?? 0
        let adjusted = firstPass.map { match -> LyricsMatch in
            guard match.candidate.hasWordTiming,
                  titleScore(match.candidate.title, query.title) + 30 < bestTitle,
                  match.terms.first?.kind != "rejectPlainTextOnly"
            else { return match }
            var terms = match.terms
            terms.append(.init(kind: "wordTimingOverride", points: -400))
            return LyricsMatch(candidate: match.candidate, score: match.score - 400,
                               terms: terms, consensusPeers: match.consensusPeers)
        }
        return adjusted.sorted {
            if $0.isRejected != $1.isRejected { return !$0.isRejected }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.source < $1.source
        }
    }

    public static func isValidTimedLyrics(_ text: String) -> Bool {
        let lines = LRCParser.parse(text)
        guard !lines.isEmpty else { return false }
        let useful = lines.filter { !isCreditLine($0.text) }
        return !useful.isEmpty && useful.count >= 2 && useful.last!.timeMs > useful.first!.timeMs
    }

    public static func endTime(_ candidate: LyricsCandidate) -> TimeInterval? {
        if let yrc = candidate.wordTiming, let last = YRCParser.parse(yrc).last {
            let end = last.words.map { $0.startMs + max(0, $0.durationMs) }.max() ?? last.timeMs
            return Double(end) / 1000
        }
        guard let last = LRCParser.parse(candidate.lyrics).last else { return nil }
        return Double(last.timeMs) / 1000
    }

    public static func normalizedTitle(_ title: String) -> String {
        var value = normalizeText(title)
        while let range = trailingBracketRange(value) {
            let inside = String(value[value.index(after: range.lowerBound)..<value.index(before: range.upperBound)])
            if versionWords.contains(where: { inside.localizedCaseInsensitiveContains($0) }) { break }
            value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    public static func normalizedArtist(_ artist: String) -> String {
        var value = normalizeText(artist)
        for marker in featWords {
            if let range = value.range(of: " \(marker) ", options: .caseInsensitive) {
                value = String(value[..<range.lowerBound])
                break
            }
        }
        return value.replacingOccurrences(of: " & ", with: " ")
    }

    private static func score(_ candidate: LyricsCandidate, for query: LyricsQuery,
                              peers: [LyricsCandidate]) -> LyricsMatch {
        var terms: [LyricsScoreTermValue] = []
        let timed = isValidTimedLyrics(candidate.lyrics)
        if candidate.plainTextOnly || (!timed && !candidate.instrumental) {
            let kind = candidate.plainTextOnly ? "rejectPlainTextOnly" : "rejectNotTimed"
            return LyricsMatch(candidate: candidate, score: -10_000,
                               terms: [.init(kind: kind, points: -10_000)])
        }
        if candidate.instrumental {
            return LyricsMatch(candidate: candidate, score: -100,
                               terms: [.init(kind: "instrumental", points: -100)])
        }

        let title = titleScore(candidate.title, query.title)
        terms.append(.init(kind: "titleMatch", points: title))

        let artist = artistScore(candidate.artist, query.artist)
        if artist <= 0 {
            return LyricsMatch(candidate: candidate, score: -10_000,
                               terms: [.init(kind: "rejectWrongArtist", points: -10_000)])
        }
        terms.append(.init(kind: "artistMatch", points: artist))

        let album = albumScore(candidate.album, query.album)
        if album > 0 { terms.append(.init(kind: "album", points: album)) }

        let end = endTime(candidate)
        if let end, let duration = query.duration, duration > 0 {
            let delta = abs(end - duration)
            let relative = delta / duration
            if relative > 0.25 {
                terms.append(.init(kind: "durationOff", points: -300))
            } else {
                terms.append(.init(kind: "duration", points: max(0, 300 - Int(relative * 500))))
            }
            if end > duration + 5 { terms.append(.init(kind: "durationOvershoot", points: -500)) }
        } else if end != nil {
            terms.append(.init(kind: "duration", points: 40))
        }
        if let reported = candidate.duration, let duration = query.duration, duration > 0,
           abs(reported - duration) / duration > 0.12 {
            terms.append(.init(kind: "sourceDurationOff", points: -250))
        }
        let lineCount = LRCParser.parse(candidate.lyrics).count
        terms.append(.init(kind: "lines", points: min(200, lineCount)))
        if candidate.hasWordTiming { terms.append(.init(kind: "wordTiming", points: 400)) }
        if candidate.hasTranslation { terms.append(.init(kind: "translation", points: 35)) }
        if candidate.hasRomanization { terms.append(.init(kind: "romanization", points: 35)) }

        let peers = peers.filter { other in
            other.source != candidate.source && lyricsSimilarity(candidate.lyrics, other.lyrics) >= 0.72
        }.map(\.source).sorted()
        if !peers.isEmpty {
            terms.append(.init(kind: "consensus", points: peers.count > 1 ? 250 : 150))
        }

        let versionPenalty = versionMismatch(candidate.title, query.title)
        if versionPenalty < 0 { terms.append(.init(kind: "versionTags", points: versionPenalty)) }
        let score = terms.reduce(0) { $0 + $1.points }
        return LyricsMatch(candidate: candidate, score: score, terms: terms, consensusPeers: peers)
    }

    private static func deduplicate(_ candidates: [LyricsCandidate]) -> [LyricsCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = "\(candidate.source)|\(ManualPickLock.fingerprint(lyrics: candidate.lyrics))|\(normalizeText(candidate.title))"
            guard seen.insert(key).inserted else { return false }
            return true
        }
    }

    private static func titleScore(_ candidate: String, _ query: String) -> Int {
        let a = normalizedTitle(candidate), b = normalizedTitle(query)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 120 }
        if normalizeText(candidate) == normalizeText(query) { return 100 }
        if titleCore(a) == titleCore(b) { return 70 }
        if a.replacingOccurrences(of: " ", with: "") == b.replacingOccurrences(of: " ", with: "") { return 80 }
        if a.contains(b) || b.contains(a) { return 40 }
        return 0
    }

    private static func artistScore(_ candidate: String, _ query: String) -> Int {
        let a = normalizedArtist(candidate), b = normalizedArtist(query)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 180 }
        let candidateParts = artistParts(candidate), queryParts = artistParts(query)
        if !Set(candidateParts).intersection(queryParts).isEmpty { return 100 }
        return 0
    }

    private static func albumScore(_ candidate: String?, _ query: String?) -> Int {
        guard let candidate, let query, !candidate.isEmpty, !query.isEmpty else { return 0 }
        let a = normalizeText(candidate), b = normalizeText(query)
        return a == b ? 100 : ((a.contains(b) || b.contains(a)) ? 40 : 0)
    }

    private static func versionMismatch(_ candidate: String, _ query: String) -> Int {
        let c = normalizedTitle(candidate).split(separator: " ").filter { isVersionToken(String($0)) }
        let q = normalizedTitle(query).split(separator: " ").filter { isVersionToken(String($0)) }
        guard !c.isEmpty else { return 0 }
        guard !q.isEmpty else { return -300 }
        return Set(c).isDisjoint(with: q) ? -300 : 0
    }

    private static func titleCore(_ value: String) -> String {
        let tokens = value.split(separator: " ").map(String.init)
        guard let firstTag = tokens.firstIndex(where: { isVersionToken($0) || featWords.contains($0) }) else {
            return value
        }
        return tokens[..<firstTag].joined(separator: " ")
    }

    private static func isVersionToken(_ value: String) -> Bool {
        let token = normalizeText(value)
        return versionWords.contains { normalizeText($0) == token }
            || token.hasPrefix("remaster")
            || token.hasPrefix("version")
            || token.hasPrefix("re recorded")
    }

    private static func lyricsSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(ManualPickLock.canonicalLyrics(lhs).lowercased().split { $0 == " " || $0 == "\n" })
        let b = Set(ManualPickLock.canonicalLyrics(rhs).lowercased().split { $0 == " " || $0 == "\n" })
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    private static func artistParts(_ value: String) -> [String] {
        var value = value
        if let range = value.range(
            of: "\\s+(feat|ft|featuring|with)\\.?\\s+.*$",
            options: [.regularExpression, .caseInsensitive]) {
            value = String(value[..<range.lowerBound])
        }
        return value.split { "/&、,，".contains($0) }
            .map { normalizeText(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeText(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[’'`\"“”]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    private static func trailingBracketRange(_ value: String) -> Range<String.Index>? {
        guard let close = value.last, "）)]】}".contains(close) else { return nil }
        let open: Character = close == "）" ? "（" : (close == "]" ? "[" : (close == "】" ? "【" : (close == "}" ? "{" : "(")))
        guard let index = value.lastIndex(of: open), index < value.index(before: value.endIndex) else { return nil }
        return index..<value.endIndex
    }

    private static func isCreditLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("作词") || lower.contains("作曲") || lower.contains("编曲")
            || lower.contains("lyrics by") || lower.contains("written by")
    }
}
