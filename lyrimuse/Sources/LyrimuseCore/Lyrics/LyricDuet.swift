import Foundation

public enum LyricDuet {

    public enum Side: String, Equatable, Sendable {
        case leading
        case trailing

        case center
    }

    private static let soloMarkers = [
        "男声", "女声", "男合", "女合", "男", "女", "Male", "Female", "M", "F",
    ]
    private static let groupMarkers = [
        "合唱", "齐唱", "伴唱", "男女", "合", "众", "齐",
        "白", "旁白", "念", "说", "对白", "口白",
        "Both", "All", "Duet", "Chorus", "Together",
    ]

    private static let anonymousMarkers = (1...8).flatMap { ["v\($0)", "V\($0)"] }

    private static let groupMarkerSet = Set(groupMarkers)
    private static let knownMarkerSet = Set(soloMarkers + groupMarkers + anonymousMarkers)

    private static let canonicalMarker: [String: String] = [
        "男声": "男", "男合": "男", "Male": "男", "M": "男",
        "女声": "女", "女合": "女", "Female": "女", "F": "女",
    ]

    private static func isGroup(_ marker: String) -> Bool { groupMarkerSet.contains(marker) }

    public static func identity(of marker: String) -> String { canonicalMarker[marker] ?? marker }

    private static let labelBreakers: Set<Character> = [
        " ", "\t", "\u{3000}",
        "，", ",", "。", ".", "！", "!", "？", "?", "；", ";",
        "（", "(", "）", ")", "[", "]", "【", "】", "「", "」", "、", "…", "—", "-",
        "\"", "'", "“", "”", "‘", "’",
    ]

    private static let maxLabelCount = 10

    public static func splitLabel(_ text: String) -> (label: String, rest: String, prefixCount: Int)? {
        var idx = text.startIndex

        while idx < text.endIndex, text[idx].isWhitespace { idx = text.index(after: idx) }
        let labelStart = idx
        var count = 0
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "：" || ch == ":" { break }
            if labelBreakers.contains(ch) { return nil }
            count += 1
            if count > maxLabelCount { return nil }
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex, count > 0 else { return nil }
        let label = String(text[labelStart..<idx])
        var after = text.index(after: idx)
        while after < text.endIndex, text[after].isWhitespace { after = text.index(after: after) }
        let prefixCount = text.distance(from: text.startIndex, to: after)
        return (label, String(text[after...]), prefixCount)
    }

    private static let nonNameCharacters: Set<Character> = Set(
        "我你他她它们的了着过吗呢吧啊呀哦嗯不没很就都也还又再和跟与及说问答讲道是有在会要能可想觉得看听之乎者然后最先但而且或如果因为所以这那些")

    private static let instrumentRoots = [
        "琴", "鼓", "号", "笛", "箫", "筝", "胡", "铃", "钹", "提琴", "吉他", "贝斯",
        "弦乐", "打击", "合成", "口琴", "竖琴", "单簧", "双簧", "萨克斯", "定音", "电子",
        "乐器", "乐团", "乐队", "编曲", "录音", "混音", "制作", "母带", "工程", "监制",
        "演出", "数字", "执行", "统筹", "企划", "发行", "出品", "作词", "作曲",
        "Scratch", "Beatbox", "Mellotron", "Sample", "Programming",
    ]

    private static let exactCreditLabels: Set<String> = [
        "词", "詞", "曲", "编", "編", "唱", "录", "錄", "混", "监", "監", "译", "譯",
        "词曲", "詞曲", "原唱", "演唱", "歌手", "出品", "发行", "發行", "策划", "策劃",
        "翻唱", "原曲", "歌名", "歌曲", "专辑", "專輯", "标题", "標題", "歌词", "歌詞",
        "OP", "SP", "Vocal", "Lyrics", "Music", "Composer", "Arranger", "Producer",
    ]

    private static func plausibleSpeakerName(_ label: String) -> Bool {
        if label.isEmpty || label.count > maxLabelCount { return false }
        if exactCreditLabels.contains(label) { return false }
        if exactCreditLabels.contains(label.capitalized) { return false }

        if LyricsSyncEngine.matchesKeywordCreditPattern(label + "：") { return false }
        if label.contains(where: { nonNameCharacters.contains($0) }) { return false }

        if !label.contains(where: { $0.isLetter || $0.unicodeScalars.first?.properties.isIdeographic == true }) {
            return false
        }
        let lowered = label.lowercased()
        for root in instrumentRoots where lowered.contains(root.lowercased()) { return false }
        return true
    }

    private static let minDistinctUnknown = 2
    private static let minUnknownOccurrences = 3
    private static let minUnknownRepeat = 2

    public static func speakers(in lineTexts: [String]) -> Set<String> {
        var known = Set<String>()
        var unknownCounts: [String: Int] = [:]
        for text in lineTexts {
            guard let (label, _, _) = splitLabel(text) else { continue }
            if knownMarkerSet.contains(label) {
                known.insert(label)
            } else if plausibleSpeakerName(label) {
                unknownCounts[label, default: 0] += 1
            }
        }
        var speakers = known
        if unknownCounts.count >= minDistinctUnknown,
           unknownCounts.values.reduce(0, +) >= minUnknownOccurrences,
           unknownCounts.values.contains(where: { $0 >= minUnknownRepeat })
        {
            speakers.formUnion(unknownCounts.keys)
        }

        return speakers
    }

    private static func hasEnoughIdentities(_ speakers: Set<String>) -> Bool {
        var solo = Set<String>()
        for m in speakers where !isGroup(m) { solo.insert(identity(of: m)) }
        return solo.count >= 2
    }

    public static func sides(for markers: [String?]) -> [Side?] {
        guard hasEnoughIdentities(Set(markers.compactMap { $0 })) else {
            return markers.map { _ in nil }
        }
        var order: [String] = []
        var current: Side?
        var out: [Side?] = []
        out.reserveCapacity(markers.count)
        for marker in markers {
            if let marker {
                if isGroup(marker) {
                    current = .center
                } else {

                    let marker = identity(of: marker)
                    if !order.contains(marker) { order.append(marker) }

                    current = (order.firstIndex(of: marker) ?? 0) % 2 == 0 ? .leading : .trailing
                }
            }
            out.append(current)
        }
        return out
    }

    public static func plan(lineTexts texts: [String]) -> (texts: [String], sides: [Side?], dropped: [Bool]) {
        let speakerSet = speakers(in: texts)
        var outTexts: [String] = []
        var markers: [String?] = []
        var dropped: [Bool] = []
        outTexts.reserveCapacity(texts.count)
        markers.reserveCapacity(texts.count)
        dropped.reserveCapacity(texts.count)
        for text in texts {
            guard let (label, rest, _) = splitLabel(text), speakerSet.contains(label) else {
                outTexts.append(text)
                markers.append(nil)
                dropped.append(false)
                continue
            }
            outTexts.append(rest)
            markers.append(label)
            dropped.append(rest.isEmpty)
        }
        return (outTexts, sides(for: markers), dropped)
    }

    static func strippingPrefix(_ words: [LyricWord], count: Int) -> [LyricWord] {
        var remaining = count
        var out = words
        while remaining > 0, let first = out.first {
            let len = first.text.count
            if len <= remaining {
                remaining -= len
                out.removeFirst()
            } else {
                let kept = String(first.text.dropFirst(remaining))
                out[0] = LyricWord(startMs: first.startMs, durationMs: first.durationMs, text: kept)
                remaining = 0
            }
        }

        while let first = out.first, first.text.trimmingCharacters(in: .whitespaces).isEmpty {
            out.removeFirst()
        }
        return out
    }

    public static func planWords(_ lines: [LyricLineWords]) -> (lines: [LyricLineWords], sides: [Side?], dropped: [Bool]) {
        let joined = lines.map { $0.words.map(\.text).joined() }
        let speakerSet = speakers(in: joined)
        var outLines: [LyricLineWords] = []
        var markers: [String?] = []
        var dropped: [Bool] = []
        outLines.reserveCapacity(lines.count)
        markers.reserveCapacity(lines.count)
        dropped.reserveCapacity(lines.count)
        for (line, text) in zip(lines, joined) {
            guard let (label, rest, prefixCount) = splitLabel(text), speakerSet.contains(label) else {
                outLines.append(line)
                markers.append(nil)
                dropped.append(false)
                continue
            }
            let stripped = strippingPrefix(line.words, count: prefixCount)
            outLines.append(LyricLineWords(timeMs: line.timeMs, words: stripped))
            markers.append(label)
            dropped.append(rest.isEmpty || stripped.isEmpty)
        }
        return (outLines, sides(for: markers), dropped)
    }
}
