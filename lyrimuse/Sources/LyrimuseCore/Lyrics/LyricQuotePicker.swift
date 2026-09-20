import Foundation

public enum LyricQuotePicker {
    public struct Line: Sendable {
        public let timeMs: Int
        public let text: String
        public init(timeMs: Int, text: String) {
            self.timeMs = timeMs
            self.text = text
        }
    }

    public static func phrases(
        _ lines: [Line], trackTitle: String = "", trackArtist: String = "",
        charRange: ClosedRange<Int> = 8 ... 32, maxLines: Int = 3
    ) -> [[String]] {

        var ordered = lines
            .map { Line(timeMs: $0.timeMs, text: collapseWhitespace($0.text)) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.timeMs < $1.timeMs }
        guard !ordered.isEmpty else { return [] }

        let duet = LyricDuet.plan(lineTexts: ordered.map(\.text))
        if duet.texts.count == ordered.count, duet.dropped.count == ordered.count {
            var kept: [Line] = []
            for (i, line) in ordered.enumerated() where !duet.dropped[i] {
                let stripped = collapseWhitespace(duet.texts[i])
                if !stripped.isEmpty { kept.append(Line(timeMs: line.timeMs, text: stripped)) }
            }
            ordered = kept
        }
        guard !ordered.isEmpty else { return [] }

        let texts = ordered.map(\.text)
        let drop = LyricsSyncEngine.creditLineDropDecisions(
            texts, trackTitle: trackTitle, trackArtist: trackArtist,
            speakerExemptions: LyricDuet.speakers(in: texts))
        if drop.count == ordered.count {
            ordered = zip(ordered, drop).compactMap { $0.1 ? nil : $0.0 }
        }

        ordered = ordered.filter { !isNoise($0.text, trackTitle: trackTitle, trackArtist: trackArtist) }

        var deduped: [Line] = []
        for line in ordered {
            if let prev = deduped.last?.text, line.text.count <= prev.count,
               prev.contains(line.text) {
                continue
            }
            deduped.append(line)
        }
        ordered = deduped
        guard ordered.count >= 1 else { return [] }

        let threshold = mergeThresholdMs(ordered)
        var segments: [[String]] = []
        var current: [String] = []
        var currentChars = 0
        for (i, line) in ordered.enumerated() {
            current.append(line.text)
            currentChars += line.text.count
            let next: Line? = i + 1 < ordered.count ? ordered[i + 1] : nil
            guard let next else { break }
            let gap = next.timeMs - line.timeMs
            let wantsMore = needsContinuation(line.text, next: next.text)
            let canTake = gap <= threshold
                && current.count < maxLines
                && currentChars + next.text.count <= charRange.upperBound
            if !(wantsMore && canTake) {
                segments.append(current)
                current = []
                currentChars = 0
            }
        }
        if !current.isEmpty { segments.append(current) }

        var seen = Set<String>()
        return segments.filter { seg in
            let joined = seg.joined()
            guard charRange.contains(joined.count),
                  let first = seg.first, let last = seg.last,
                  !danglesAtEnd(last), !opensWithEnclitic(first),
                  hasEnoughWords(seg, joined: joined),
                  seen.insert(joined).inserted
            else { return false }
            return true
        }
    }

    static func mergeThresholdMs(_ lines: [Line]) -> Int {
        var gaps: [Int] = []
        for i in 0 ..< max(0, lines.count - 1) {
            let g = lines[i + 1].timeMs - lines[i].timeMs
            if g > 0, g < 15_000 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return 2500 }
        gaps.sort()
        return max(1800, gaps[gaps.count / 2])
    }

    static func needsContinuation(_ text: String, next: String) -> Bool {
        guard let last = text.last else { return false }

        if terminalPunctuation.contains(last) { return false }
        if text.count <= 5 { return true }
        if danglesAtEnd(text) { return true }

        if let head = next.first, encliticHeads.contains(head) { return true }
        return false
    }

    private static let terminalPunctuation: Set<Character> = [
        "。", "！", "？", "!", "?", "…", "；", ";",
    ]

    private static let danglingTailChars: Set<Character> = [
        "的", "地", "和", "跟", "与", "及", "而", "但", "却", "把", "被", "让", "使",
        "向", "往", "从", "对", "给", "比", "像", "为", "在", "是", "有", "没", "无",
        "要", "想", "会", "能", "可", "就", "才", "也", "还", "更", "又", "很", "太",
        "最", "这", "那", "哪", "如", "若", "因", "所", "将", "由", "于", "被",
    ]

    private static let danglingTailWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for",
        "with", "my", "your", "our", "his", "her", "its", "their", "is", "are",
        "was", "were", "be", "been", "so", "that", "this", "then", "than", "as",
        "does", "did", "would", "could", "should", "must", "gonna", "wanna", "gotta",
    ]

    static func hasEnoughWords(_ seg: [String], joined: String) -> Bool {
        let latin = joined.filter { $0.isASCII && $0.isLetter }.count
        guard latin * 2 > joined.count else { return true }
        let words = seg.joined(separator: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "\'" })
        return words.count >= 3
    }

    static func danglesAtEnd(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return true }
        if danglingTailChars.contains(last) { return true }

        if let raw = t.split(separator: " ").last {
            let word = raw.lowercased().filter { $0.isLetter || $0.isNumber }
            if !word.isEmpty, danglingTailWords.contains(word) { return true }
        }
        return false
    }

    private static let encliticHeads: Set<Character> = [
        "的", "了", "着", "过", "吗", "呢", "吧", "啊", "呀", "嘛", "呐", "地", "得",
    ]

    static func opensWithEnclitic(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespaces).first else { return true }
        return encliticHeads.contains(first)
    }

    static func isNoise(_ text: String, trackTitle: String, trackArtist: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if sectionMarker.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return true }

        var run = 0
        var previous: Character?
        for c in t {
            if c == previous { run += 1; if run >= 3 { return true } } else { run = 0 }
            previous = c
        }

        if (t.hasPrefix("(") && t.hasSuffix(")")) || (t.hasPrefix("（") && t.hasSuffix("）")) {
            return true
        }

        let wordish = t.filter { $0.isLetter || $0.isNumber }.count
        if wordish * 2 < t.count { return true }

        let key = squeeze(t)
        if !key.isEmpty {
            let title = squeeze(trackTitle), artist = squeeze(trackArtist)
            if !title.isEmpty, key == title { return true }
            if !artist.isEmpty, key == artist { return true }
            if !title.isEmpty, !artist.isEmpty, key == title + artist || key == artist + title {
                return true
            }
        }
        return false
    }

    private static let sectionMarker = try! NSRegularExpression(
        pattern: "^(rap|chorus|verse|bridge|intro|outro|hook|pre-?chorus|间奏|間奏|副歌|主歌|前奏|尾奏|独白|獨白)\\s*\\d*\\s*[:：]?$",
        options: [.caseInsensitive])

    private static func squeeze(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
