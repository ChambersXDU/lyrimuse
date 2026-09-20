import Foundation

public struct SyncedLyricWord: Equatable {
    public let text: String

    public let startMs: Int
    public let durationMs: Int

    public init(text: String, startMs: Int, durationMs: Int) {
        self.text = text
        self.startMs = startMs
        self.durationMs = durationMs
    }
}

public struct SyncedLyricWordGroup: Equatable, Identifiable {
    public let id: Int
    public let words: [SyncedLyricWord]
    public let romanization: String?

    public init(id: Int, words: [SyncedLyricWord], romanization: String?) {
        self.id = id
        self.words = words
        self.romanization = romanization
    }

    public var startMs: Int { words.first?.startMs ?? 0 }
    public var endMs: Int { words.last.map { $0.startMs + $0.durationMs } ?? 0 }
}

public struct SyncedLyricLine: Equatable {
    public let romanization: String?
    public let translation: String?
    public let mainText: String?
    public let words: [SyncedLyricWord]?

    public let wordGroups: [SyncedLyricWordGroup]?

    public var side: LyricDuet.Side?

    public let plainText: String?

    public init(romanization: String?, translation: String?, mainText: String?,
                words: [SyncedLyricWord]?, wordGroups: [SyncedLyricWordGroup]?,
                side: LyricDuet.Side?, plainText: String? = nil) {
        self.romanization = romanization
        self.translation = translation
        self.mainText = mainText
        self.words = words
        self.wordGroups = wordGroups
        self.side = side

        if let plainText, !plainText.isEmpty {
            self.plainText = plainText
        } else if let mainText {
            self.plainText = mainText
        } else if let words, !words.isEmpty {
            self.plainText = words.map(\.text).joined()
        } else {
            self.plainText = nil
        }
    }

    public var lineLevel: SyncedLyricLine {
        guard words != nil || wordGroups != nil else { return self }
        return SyncedLyricLine(
            romanization: romanization, translation: translation,
            mainText: mainText ?? plainText, words: nil, wordGroups: nil,
            side: side, plainText: plainText)
    }
}

extension CharacterSet {

    static let hanLike: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "\u{3040}"..."\u{30FF}")
        s.insert(charactersIn: "\u{3400}"..."\u{4DBF}")
        s.insert(charactersIn: "\u{4E00}"..."\u{9FFF}")
        s.insert(charactersIn: "\u{F900}"..."\u{FAFF}")
        return s
    }()
}

public struct MenuBarLyricLine: Identifiable, Equatable {
    public let id: String
    public let timeMs: Int
    public let line: SyncedLyricLine
}

public struct LyricsGapMarker: Equatable, Identifiable {
    public let index: Int
    public let startMs: Int
    public let endMs: Int
    public var id: Int { index }
}

public final class LyricsSyncEngine {
    private var baseLines: [LyricLine] = []
    private var wordLines: [LyricLineWords] = []

    private var baseSides: [LyricDuet.Side?] = []
    private var wordSides: [LyricDuet.Side?] = []
    private var romaLines: [LyricLine] = []
    private var trLines: [LyricLine] = []
    private var usingWords = false

    private var trTextByPlainText: [String: String] = [:]
    private var romaTextByPlainText: [String: String] = [:]

    private static func contentMatchKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    public var offsetMs: Int = 0

    public private(set) var lrcOffsetMs: Int = 0

    public var effectiveOffsetMs: Int { offsetMs + lrcOffsetMs }

    private static let creditLinePattern = try! NSRegularExpression(
        pattern: #"^(所有|全部|中文|英文|韩文|日文|粤语|中|英|韩|日)?\s*(唱片公司|发行公司|出品公司|专辑|翻译|作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|P\s*-\s*Line|C\s*-\s*Line|℗|©|lyrics|music|composed|produced|arranged|mixed|mastered|written)(\s*(和|与|及|、|/|&|＆)?\s*(唱片公司|发行公司|出品公司|专辑|翻译|作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|lyrics|music|composed|produced|arranged|mixed|mastered|written))*\s*(by\s*)?[:：]"#,
        options: [.caseInsensitive]
    )

    private static let creditRoleWords: [String] = [
        "作词", "作曲", "编曲", "编辑", "编程", "制作", "监制", "混音", "母带", "处理",
        "录音", "录制", "和声", "吉他", "贝斯", "键盘", "弦乐", "乐器", "工程", "企划",
        "统筹", "发行", "出品", "演奏", "指挥", "后期", "音效", "版权", "鸣谢", "摄影",
        "设计", "封面",
        "演唱", "原唱", "翻唱",

        "収録", "主題", "片頭", "片尾", "挿入",
        "收录", "主题", "片头", "插入",
        "歌手", "歌曲", "歌词",

        "钢琴", "箱琴", "笛子", "童声", "口琴", "二胡", "琵琶", "古筝", "长笛", "提琴",
        "唢呐", "手鼓", "打击", "合成", "采样", "编写", "小号", "萨克",
        "竖琴", "长号", "副唱", "和音", "三和",

        "著作", "推广",

        "指导", "总监", "策划", "导演",
    ]

    private static let creditLabelSeparators = CharacterSet(charactersIn: "/／、&＆·・和与及,，")

    private static let englishRoleNounPattern = try! NSRegularExpression(
        pattern: #"\b(producers?|composers?|lyricists?|lyrics|arrang(?:er|ement|ed)|"#
            + #"engineers?|engineering|studios?|drums?|bass|guitars?|keyboards?|strings|"#
            + #"vocals?|chorus|programming|mixing|mixed|mastering|mastered|recording|recorded|"#
            + #"assistant|producti?on|publisher|label|orchestra|conductor|percussion|piano|"#
            + #"synth(?:esizer)?|sax(?:ophone)?|trumpet|violin|cello|harmonica|"#
            + #"photograph(?:y|er)|artwork|design(?:er)?|mv|director)\b"#,
        options: [.caseInsensitive]
    )

    private static func splitBilingualLabel(_ label: String) -> (han: String, latin: String) {
        var han = ""
        var idx = label.startIndex
        while idx < label.endIndex {
            let ch = label[idx]
            let isHan = ch.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
            let isSep = ch.unicodeScalars.allSatisfy { creditLabelSeparators.contains($0) }
            guard isHan || isSep else { break }
            han.append(ch)
            idx = label.index(after: idx)
        }
        let tail = label[idx...].trimmingCharacters(in: .whitespaces)
        guard !han.isEmpty, !tail.isEmpty, tail.count <= 40 else { return (label, "") }

        let brackets = CharacterSet(charactersIn: "()（）[]【】{}〔〕")
        guard !label.unicodeScalars.contains(where: { brackets.contains($0) }),
              tail.first?.isLetter == true
        else { return (label, "") }
        let allowed = CharacterSet.letters.union(.whitespaces)
            .union(CharacterSet(charactersIn: "&/.,'()-＆"))
        guard tail.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              tail.unicodeScalars.allSatisfy({ !$0.properties.isIdeographic })
        else { return (label, "") }
        return (han, tail)
    }

    public static func matchesBilingualCreditShape(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return false }
        let (han, latin) = splitBilingualLabel(String(label))
        guard !latin.isEmpty else { return false }
        let core = han.components(separatedBy: creditLabelSeparators).joined()
        guard !core.isEmpty, (1...10).contains(core.count),
              core.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }

        return !speakerLabels.contains(core)
    }

    public static func matchesRoleWordCredit(_ text: String) -> Bool {

        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" || $0 == "·" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)

        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)

        let (hanLabel, latinLabel) = splitBilingualLabel(String(label))

        var core = hanLabel.components(separatedBy: creditLabelSeparators).joined()

        if !core.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }) || core.isEmpty {
            let hanOnly = String(label).unicodeScalars
                .filter { $0.properties.isIdeographic }
                .map(Character.init)
            let nonHanOK = String(label).unicodeScalars.allSatisfy { u in
                u.properties.isIdeographic || CharacterSet.alphanumerics.contains(u)
                    || " ./&()'’-：:".unicodeScalars.contains(u)
            }
            if nonHanOK, !hanOnly.isEmpty { core = String(hanOnly) }
        }
        guard !rest.isEmpty, (1...10).contains(core.count), !core.isEmpty,
              core.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }

        let forms = [core, HanScript.sibling(core)].compactMap { $0 }
        if creditRoleWords.contains(where: { word in forms.contains { $0.contains(word) } }) {
            return true
        }

        guard !latinLabel.isEmpty else { return false }
        let range = NSRange(latinLabel.startIndex..., in: latinLabel)
        return englishRoleNounPattern.firstMatch(in: latinLabel, range: range) != nil
    }

    private static let englishCreditPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:\#(creditRoleWords.joined(separator: "|")))\p{Han}{0,4}\s*)?(mixed|mastered|produced|written|composed|arranged|arrangement|recorded|engineered|performed|lyrics|music|vocals?|guitars?|bass|drums|keyboards?|strings|programming|artwork|photography|design)\b[^\n]{0,20}?\s+(by|at)\s+\S"#,
        options: [.caseInsensitive]
    )

    public static func matchesEnglishCredit(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return englishCreditPattern.firstMatch(in: text, range: range) != nil
    }

    private static let genericHanCreditLinePattern = try! NSRegularExpression(
        pattern: #"^\p{Han}{1,8}\s*[:：]\s*\S"#
    )

    private static let latinCreditFullWidthPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9 .&/'’()\-]{0,40}：\s*\S"#
    )
    private static let latinCreditHalfWidthPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9 .&/'’()\-]{0,40}:[^\p{Han}\p{Hiragana}\p{Katakana}]{0,24}[\p{Han}\p{Hiragana}\p{Katakana}]"#
    )

    private static let nonNameWordsLatin: Set<String> = [
        "i", "im", "i'm", "you", "you're", "youre", "we", "we're", "he", "she", "they",
        "me", "my", "your", "our", "am", "is", "are", "was", "were", "be", "been",
        "do", "dont", "don't", "doesnt", "doesn't", "did", "can", "cant", "can't",
        "will", "wont", "won't", "not", "never", "gonna", "wanna", "gotta",
        "love", "know", "feel", "need", "want", "say", "said", "tell", "come",
        "go", "going", "gone", "let", "lets", "let's", "get", "got", "make", "made",
        "why", "how", "when", "where", "what", "who", "yeah", "oh", "ooh",
    ]

    static func latinCreditRestLooksLikeSentence(_ rest: String) -> Bool {
        if rest.contains(where: { nonNameChars.contains($0) }) { return true }
        let punct = CharacterSet(charactersIn: "()[]{}'’\"“”,.!?;:/&-_~…")
        let words = rest.lowercased()
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: punct) }
            .filter { !$0.isEmpty }
        if words.contains(where: { nonNameWordsLatin.contains($0) }) { return true }
        if rest.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }),
           rest.filter({ $0 == " " }).count >= 2 { return true }
        if let last = rest.last, "，。！？!?…；;".contains(last) { return true }
        return false
    }

    private static let isrcPattern = try! NSRegularExpression(
        pattern: #"^ISRC[\s:：-]*[A-Za-z]{2}[-\s]?[A-Za-z0-9]{3}[-\s]?\d{2}[-\s]?\d{5}\b"#,
        options: [.caseInsensitive]
    )

    private static let latinRoleColonPattern = try! NSRegularExpression(
        pattern: #"^(?:executive\s+|assistant\s+|co-)?"#
            + #"(producers?|production|publishers?|labels?|composers?|lyricists?|"#
            + #"arrang(?:er|ement|ed)|engineers?|engineering|studios?|"#
            + #"mixing|mixed|mastering|mastered|recording|recorded|"#
            + #"orchestra|conductor|photograph(?:y|er)|artwork|design(?:er)?|director)"#
            + #"\s*:\s*\S"#,
        options: [.caseInsensitive]
    )

    private static func matchesLatinCreditPattern(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        let shapeHit = latinCreditFullWidthPattern.firstMatch(in: text, range: r) != nil
            || latinCreditHalfWidthPattern.firstMatch(in: text, range: r) != nil
            || latinRoleColonPattern.firstMatch(in: text, range: r) != nil
        guard shapeHit else { return false }
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return !latinCreditRestLooksLikeSentence(rest)
    }

    public static func looksLikeHeaderLine(_ text: String, trackTitle: String, trackArtist: String) -> Bool {
        guard !trackTitle.isEmpty, !trackArtist.isEmpty else { return false }
        func norm(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        func stripBrackets(_ s: String) -> String {
            var out = "", depth = 0
            for c in s {
                if c == "(" || c == "[" || c == "（" || c == "［" { depth += 1 }
                else if c == ")" || c == "]" || c == "）" || c == "］" { depth = max(0, depth - 1) }
                else if depth == 0 { out.append(c) }
            }
            return out
        }
        for (lhs, rhs) in headerSplitCandidates(text) {
            let leftTitle = norm(stripBracketsForHeaderMatch(lhs))
            let rightTitle = norm(stripBracketsForHeaderMatch(rhs))
            let leftRaw = norm(lhs), rightRaw = norm(rhs)
            guard !leftRaw.isEmpty, !rightRaw.isEmpty else { continue }
            let titles = Set(headerTitleForms(trackTitle).map(norm)).subtracting([""])
            let artists = headerMatchVariants(of: trackArtist).map(norm).filter { !$0.isEmpty }
            if titles.contains(leftTitle), artists.contains(where: { rightRaw.contains($0) }) { return true }
            if titles.contains(rightTitle), artists.contains(where: { leftRaw.contains($0) }) { return true }
        }
        return false
    }

    private static func headerSplitCandidates(_ text: String) -> [(String, String)] {
        for sep in [" - ", " – ", " — "] {
            let parts = text.components(separatedBy: sep)
            if parts.count == 2 { return [(parts[0], parts[1])] }
        }
        let dashes: Set<Character> = ["-", "–", "—"]
        guard text.filter({ dashes.contains($0) }).count == 1,
              let idx = text.firstIndex(where: { dashes.contains($0) })
        else { return [] }
        return [(String(text[text.startIndex..<idx]), String(text[text.index(after: idx)...]))]
    }

    private static func headerTitleForms(_ s: String) -> [String] {
        var out = [s, stripBracketsForHeaderMatch(s)]
        out.append(contentsOf: scriptRuns(stripBracketsForHeaderMatch(s)))
        var seen = Set<String>()
        var result: [String] = []
        for raw in out {
            let p = raw.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty, seen.insert(p).inserted else { continue }
            result.append(p)
            if let sib = HanScript.sibling(p), seen.insert(sib).inserted { result.append(sib) }
        }
        return result
    }

    private static func headerMatchVariants(of s: String) -> [String] {
        var pieces: [String] = []
        let separators = CharacterSet(charactersIn: "&/、,，;；|-–—")
        for base in [s, stripBracketsForHeaderMatch(s)] where !base.isEmpty {
            pieces.append(base)
            let flattened = base.replacingOccurrences(
                of: "feat.", with: "/", options: .caseInsensitive)
            pieces.append(contentsOf: flattened.components(separatedBy: separators))
            pieces.append(contentsOf: scriptRuns(base))
        }
        var out: [String] = []
        var seen = Set<String>()
        for raw in pieces {
            let p = raw.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty, longEnoughForHeaderMatch(p) else { continue }
            if seen.insert(p).inserted { out.append(p) }
            if let sib = HanScript.sibling(p), seen.insert(sib).inserted { out.append(sib) }
        }
        return out
    }

    private static func longEnoughForHeaderMatch(_ s: String) -> Bool {
        let han = s.unicodeScalars.filter { CharacterSet.hanLike.contains($0) }.count
        if han > 0 { return han >= 2 }
        return s.filter { $0.isLetter || $0.isNumber }.count >= 4
    }

    private static func scriptRuns(_ s: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var currentIsHan: Bool?
        for ch in s {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { runs.append(current) }
                current = ""; currentIsHan = nil
                continue
            }
            let isHan = ch.unicodeScalars.allSatisfy { CharacterSet.hanLike.contains($0) }
            if let was = currentIsHan, was != isHan {
                if !current.isEmpty { runs.append(current) }
                current = ""
            }
            currentIsHan = isHan
            current.append(ch)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func stripBracketsForHeaderMatch(_ s: String) -> String {
        var out = "", depth = 0
        for c in s {
            if c == "(" || c == "[" || c == "（" || c == "［" { depth += 1 }
            else if c == ")" || c == "]" || c == "）" || c == "］" { depth = max(0, depth - 1) }
            else if depth == 0 { out.append(c) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static let copyrightNoticePattern = try! NSRegularExpression(
        pattern: #"(未经[^。]{0,12}(许可|授权|同意))|(不得(翻录|翻唱|复制|转载|使用|下载))|(版权所有)|(保留(所有)?权利)|(all rights reserved)|(unauthor(i[sz]ed)? (copying|reproduction|duplication))"#,
        options: [.caseInsensitive]
    )

    private static let symbolOnlyIgnorable: CharacterSet =
        CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)

    public static func isSymbolOnlyLine(_ text: String) -> Bool {

        var sawNonWhitespace = false
        for scalar in text.unicodeScalars {
            if !symbolOnlyIgnorable.contains(scalar) { return false }
            if !sawNonWhitespace, !CharacterSet.whitespaces.contains(scalar) {
                sawNonWhitespace = true
            }
        }
        return sawNonWhitespace
    }

    private static let promoRoleTailPattern = try! NSRegularExpression(
        pattern: #"(出品|出版|发行|企划|呈现|呈献)$"#
    )
    private static let promoLabelPattern = try! NSRegularExpression(
        pattern: #"网易云音乐|网易音乐|QQ ?音乐|酷狗|酷我|腾讯音乐|环球|索尼|华纳|摩登天空|唱片|娱乐|传媒|文化|厂牌|Records|Entertainment"#,
        options: [.caseInsensitive]
    )

    private static let promoTrailingTrim = CharacterSet.punctuationCharacters
        .union(.symbols)
        .union(.whitespacesAndNewlines)

    public static func matchesPromoCreditLine(_ text: String) -> Bool {

        guard !text.contains(":"), !text.contains("：") else { return false }
        let tail = String(text.unicodeScalars.reversed()
            .drop { promoTrailingTrim.contains($0) }.reversed().map(Character.init))
        guard !tail.isEmpty else { return false }
        let tailRange = NSRange(tail.startIndex..., in: tail)
        guard promoRoleTailPattern.firstMatch(in: tail, range: tailRange) != nil else { return false }
        let full = NSRange(text.startIndex..., in: text)
        return promoLabelPattern.firstMatch(in: text, range: full) != nil
    }

    public static func matchesCopyrightNotice(_ text: String) -> Bool {
        copyrightNoticePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let copyrightMarks: Set<Character> = ["©", "℗", "Ⓒ", "Ⓟ", "ⓒ", "ⓟ"]
    private static let parenCopyrightPattern = try! NSRegularExpression(
        pattern: #"\(\s*[CP]\s*\)"#, options: [.caseInsensitive])
    private static let fourDigitYearPattern = try! NSRegularExpression(
        pattern: #"(?:19|20)\d{2}"#)

    public static func matchesCopyrightMarkLine(_ text: String) -> Bool {
        let full = NSRange(text.startIndex..., in: text)
        guard fourDigitYearPattern.firstMatch(in: text, range: full) != nil else { return false }
        if text.contains(where: { copyrightMarks.contains($0) }) { return true }
        return parenCopyrightPattern.firstMatch(in: text, range: full) != nil
    }

    private static let dateStampPattern = try! NSRegularExpression(
        pattern: #"^(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\.?\s+\d{1,2},\s*\d{4}(\s+at\s+\d{1,2}:\d{2}\s*[ap]m)?$"#,
        options: [.caseInsensitive]
    )

    public static func matchesISRCLine(_ text: String) -> Bool {
        isrcPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func matchesDateStampLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return dateStampPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    static func matchesKeywordCreditPattern(_ text: String) -> Bool {
        creditLinePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let speakerLabels: Set<String> = [
        "男", "女", "合", "男合", "女合", "男女", "众", "齐",
        "白", "旁白", "念", "说", "对白", "口白",
        "男声", "女声", "合唱", "伴唱",
    ]

    private static func matchesStructuralCreditPattern(
        _ text: String, exemptions: Set<String> = []
    ) -> Bool {
        guard genericHanCreditLinePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
            return false
        }
        guard let sep = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<sep].trimmingCharacters(in: .whitespaces)
        return !speakerLabels.contains(label) && !exemptions.contains(String(label))
    }

    private static func shouldApplyStructuralCreditFilter(
        _ texts: [String], exemptions: Set<String> = []
    ) -> Bool {
        guard !texts.isEmpty else { return false }
        let hits = texts.filter { matchesStructuralCreditPattern($0, exemptions: exemptions) }.count
        return hits >= 3 && hits * 2 > texts.count
    }

    private static let nonNameChars = Set("的了是不我你他她它们在也都就很没着过吗呢吧啊呀什么谁别把被让这那要会能又再却但而已经没有想")

    private static let nameListSeparators = CharacterSet(charactersIn: "/／、&＆,，")

    public static func matchesNameListCreditShape(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !rest.isEmpty, !speakerLabels.contains(String(label)) else { return false }
        let labelCore = String(label).components(separatedBy: creditLabelSeparators).joined()
        guard (2...20).contains(labelCore.count),
              labelCore.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }
        let segments = rest.components(separatedBy: nameListSeparators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard segments.count >= 2 || !latinCreditRestLooksLikeSentence(rest) else { return false }
        guard rest.count <= 60, (1...6).contains(segments.count) else { return false }
        return segments.allSatisfy { seg in
            let hasLatin = seg.unicodeScalars.contains { CharacterSet.letters.contains($0) && !$0.properties.isIdeographic }
            let limit = hasLatin ? 30 : 8
            return (2...limit).contains(seg.count)
                && seg.unicodeScalars.allSatisfy { u in
                    u.properties.isIdeographic || CharacterSet.alphanumerics.contains(u)
                        || " ()'’.-".unicodeScalars.contains(u)
                }
        }
    }

    public static func creditLineDropDecisions(
        _ texts: [String], trackTitle: String = "", trackArtist: String = "",
        speakerExemptions: Set<String> = []
    ) -> [Bool] {
        strippingCreditLines(
            texts, trackTitle: trackTitle, trackArtist: trackArtist,
            speakerExemptions: speakerExemptions)
    }

    private static func strippingCreditLines(
        _ texts: [String], trackTitle: String = "", trackArtist: String = "",
        speakerExemptions: Set<String> = []
    ) -> [Bool] {
        let useStructural = shouldApplyStructuralCreditFilter(texts, exemptions: speakerExemptions)

        let bilingualHits = texts.filter(matchesBilingualCreditShape).count
        let useBilingualShape = bilingualHits >= 2

        let nameListHits = texts.filter(matchesNameListCreditShape).count
        let useNameListShape = nameListHits >= 2
        let drop = texts.enumerated().map { i, text -> Bool in

            if let (label, _, _) = LyricDuet.splitLabel(text), speakerExemptions.contains(label) {
                return false
            }
            if useBilingualShape, matchesBilingualCreditShape(text) { return true }
            if useNameListShape, matchesNameListCreditShape(text) { return true }
            if matchesKeywordCreditPattern(text) { return true }
            if matchesLatinCreditPattern(text) { return true }

            if matchesRoleWordCredit(text) { return true }

            if matchesEnglishCredit(text) { return true }

            if matchesCopyrightNotice(text) { return true }

            if matchesCopyrightMarkLine(text) { return true }

            if matchesDateStampLine(text) { return true }

            if matchesISRCLine(text) { return true }

            if matchesPromoCreditLine(text) { return true }

            if isSymbolOnlyLine(text) { return true }

            if i == 0, looksLikeHeaderLine(text, trackTitle: trackTitle, trackArtist: trackArtist) {
                return true
            }
            return useStructural && matchesStructuralCreditPattern(text, exemptions: speakerExemptions)
        }

        if drop.allSatisfy({ $0 }) && !texts.isEmpty {
            return texts.map { _ in false }
        }
        return drop
    }

    public init() {}

    private struct LoadFingerprint: Equatable {
        let lyrics, lyricsTr, lyricsRoma, lyricsYRC: String
        let trackTitle, trackArtist: String
        let romanizationScripts: RomanizationScripts
        let songIsCantonese: Bool
    }
    private var loadedFingerprint: LoadFingerprint?

    @discardableResult
    public func load(
        lyrics: String, lyricsTr: String, lyricsRoma: String, lyricsYRC: String,
        trackTitle: String = "", trackArtist: String = "",
        romanizationScripts: RomanizationScripts = .default, songIsCantonese: Bool = false
    ) -> Bool {
        let fingerprint = LoadFingerprint(
            lyrics: lyrics, lyricsTr: lyricsTr, lyricsRoma: lyricsRoma, lyricsYRC: lyricsYRC,
            trackTitle: trackTitle, trackArtist: trackArtist,
            romanizationScripts: romanizationScripts, songIsCantonese: songIsCantonese)
        if fingerprint == loadedFingerprint { return false }
        loadedFingerprint = fingerprint
        self.romanizationScripts = romanizationScripts
        let normalizedYRC = LyricTimelineNormalizer.normalize(YRCParser.parse(lyricsYRC))
        let yrc = normalizedYRC.lines
        LyricTimelineNormalizer.logSummary(normalizedYRC.report, track: trackTitle)

        lrcOffsetMs = {
            let fromBase = LRCParser.parseOffsetMs(lyrics)
            return fromBase != 0 ? fromBase : LRCParser.parseOffsetMs(lyricsYRC)
        }()
        let parsedBase = LRCParser.parse(lyrics)
        let baseTexts = parsedBase.map(\.text)
        let baseSpeakers = LyricDuet.speakers(in: baseTexts)
        let baseDrop = Self.strippingCreditLines(
            baseTexts, trackTitle: trackTitle, trackArtist: trackArtist,
            speakerExemptions: baseSpeakers)
        let filteredBase = zip(parsedBase, baseDrop).compactMap { $0.1 ? nil : $0.0 }
        var candidateWords: [LyricLineWords] = []
        if !yrc.isEmpty {
            let texts = yrc.map { $0.words.map(\.text).joined() }
            let drop = Self.strippingCreditLines(
                texts, trackTitle: trackTitle, trackArtist: trackArtist,
                speakerExemptions: LyricDuet.speakers(in: texts))
            candidateWords = zip(yrc, drop).compactMap { $0.1 ? nil : $0.0 }
        }

        usingWords = !candidateWords.isEmpty
            && (filteredBase.isEmpty || candidateWords.count * 2 >= filteredBase.count)

        if usingWords {
            let plan = LyricDuet.planWords(candidateWords)
            let kept = zip(zip(plan.lines, plan.sides), plan.dropped).filter { !$0.1 }
            wordLines = kept.map { $0.0.0 }
            wordSides = kept.map { $0.0.1 }
            baseLines = []
            baseSides = []
        } else {
            let plan = LyricDuet.plan(lineTexts: filteredBase.map(\.text))
            wordLines = []
            wordSides = []
            let kept = zip(zip(zip(filteredBase, plan.texts), plan.sides), plan.dropped)
                .filter { !$0.1 }
            baseLines = kept.map { LyricLine(timeMs: $0.0.0.0.timeMs, text: $0.0.0.1) }
            baseSides = kept.map { $0.0.1 }
        }
        romaLines = LRCParser.parse(lyricsRoma)
        trLines = LRCParser.parse(lyricsTr)

        do {
            let trByTime = Dictionary(trLines.map { ($0.timeMs, $0.text) }, uniquingKeysWith: { _, new in new })
            let romaByTime = Dictionary(romaLines.map { ($0.timeMs, $0.text) }, uniquingKeysWith: { _, new in new })
            trTextByPlainText = Dictionary(
                filteredBase.compactMap { line -> (String, String)? in
                    let key = Self.contentMatchKey(line.text)
                    guard !key.isEmpty, let tr = trByTime[line.timeMs], !tr.isEmpty else { return nil }
                    return (key, tr)
                }, uniquingKeysWith: { _, new in new })
            romaTextByPlainText = Dictionary(
                filteredBase.compactMap { line -> (String, String)? in
                    let key = Self.contentMatchKey(line.text)
                    guard !key.isEmpty, let roma = romaByTime[line.timeMs], !roma.isEmpty else { return nil }
                    return (key, roma)
                }, uniquingKeysWith: { _, new in new })
        }

        let contentSample = filteredBase.map(\.text).joined(separator: "\n")
        let contentWordSample = candidateWords
            .map { $0.words.map(\.text).joined() }
            .joined(separator: "\n")
        let scriptSample: String = {
            if !contentSample.isEmpty { return contentSample }
            if !contentWordSample.isEmpty { return contentWordSample }
            return lyrics.isEmpty ? lyricsYRC : lyrics
        }()
        songLooksJapanese = Romanizer.looksJapaneseSong(contentSample)
            || Romanizer.looksJapaneseSong(contentWordSample)
            || (contentSample.isEmpty && contentWordSample.isEmpty
                && (Romanizer.looksJapaneseSong(lyrics) || Romanizer.looksJapaneseSong(lyricsYRC)))

        songScript = Romanizer.songScript(of: scriptSample)

        if songScript == .chinese, songIsCantonese {
            songScript = .cantonese
        }

        kanaAnnotation = KanaAnnotation.parse(lrc: lyrics)

        romanizerFallbackCache.removeAll()
        wordGroupCache.removeAll()
        segmentsCache.removeAll()
        builtLinesCache.removeAll()

        cachedActiveIdx = Int.min
        cachedActiveLine = nil
        cachedNextIdx = Int.min
        cachedNextText = nil
        cachedNextSide = nil
        cachedLeadIdx = Int.min
        cachedLeadLine = nil
        cachedCompactIdx = Int.min
        cachedCompactTrackEndMs = nil
        cachedCompactDwellMs = nil
        cachedCompactLeadInMs = nil
        lastScanIdx = Int.min
        return true
    }

    private var songLooksJapanese = false
    private var songScript: LyricScript = .other
    private var romanizationScripts: RomanizationScripts = .default

    private func romanizationAllowed(for line: String) -> Bool {
        guard let option = Romanizer.script(ofLine: line, song: songScript).option else {
            return true
        }
        return romanizationScripts.contains(option)
    }
    private var kanaAnnotation: KanaAnnotation?

    public var hasContent: Bool { usingWords ? !wordLines.isEmpty : !baseLines.isEmpty }

    private static func isBareSpeakerTag(_ text: String) -> Bool {
        guard let sep = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<sep].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: sep)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty && speakerLabels.contains(String(label))
    }

    private func translationText(timeMs: Int, plainText: String) -> String? {
        guard !Self.isBareSpeakerTag(plainText) else { return nil }
        if let byContent = trTextByPlainText[Self.contentMatchKey(plainText)] {
            return byContent
        }
        return nearestText(trLines, timeMs)
    }

    private func nearestText(_ arr: [LyricLine], _ t: Int, tolerance: Int = 700) -> String? {
        guard !arr.isEmpty else { return nil }

        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].timeMs > t { hi = mid } else { lo = mid + 1 }
        }
        var best: String?
        var bestDiff = tolerance
        if lo > 0 {
            let d = t - arr[lo - 1].timeMs
            if d <= bestDiff { bestDiff = d; best = arr[lo - 1].text }
        }
        if lo < arr.count {
            let d = arr[lo].timeMs - t
            if d <= bestDiff {
                var r = lo
                while r + 1 < arr.count, arr[r + 1].timeMs == arr[lo].timeMs { r += 1 }
                best = arr[r].text
            }
        }
        return best
    }

    private var romanizerFallbackCache: [String: String?] = [:]

    private func romanizationText(timeMs: Int, plainText: String) -> String? {

        guard romanizationAllowed(for: plainText) else { return nil }
        guard !Self.isBareSpeakerTag(plainText) else { return nil }

        if let byContent = romaTextByPlainText[Self.contentMatchKey(plainText)] {
            return byContent
        }
        if let fromSource = nearestText(romaLines, timeMs) { return fromSource }

        guard romaLines.isEmpty else { return nil }
        if let cached = romanizerFallbackCache[plainText] { return cached }

        let result = Romanizer.lineReading(
            plainText,
            songLooksJapanese: songLooksJapanese,
            segments: cachedJapaneseSegments(for: plainText))
        romanizerFallbackCache[plainText] = result
        return result
    }

    private var segmentsCache: [String: [Romanizer.JapaneseSegment]] = [:]

    private func cachedJapaneseSegments(for line: String) -> [Romanizer.JapaneseSegment] {
        if let cached = segmentsCache[line] { return cached }
        let segs = Romanizer.japaneseSegments(
            line, marks: kanaAnnotation?.marks(forLine: line) ?? [])
        segmentsCache[line] = segs
        return segs
    }

    private var wordGroupCache: [String: [SyncedLyricWordGroup]?] = [:]

    private func wordGroups(for words: [SyncedLyricWord], line: String) -> [SyncedLyricWordGroup]? {
        guard !words.isEmpty else { return nil }

        let key = "\(words[0].startMs)|\(line)"
        if let cached = wordGroupCache[key] { return cached }

        let allowed = romanizationAllowed(for: line)

        let segments: [Romanizer.JapaneseSegment]? =
            (allowed && Romanizer.looksJapanese(line)) ? cachedJapaneseSegments(for: line) : nil

        var hanRoma: String?
        var koreanRoma: String?
        if allowed, segments == nil {
            let script = Romanizer.script(ofLine: line, song: songScript)
            if script == .chinese || script == .cantonese {
                hanRoma = romanizationText(timeMs: words[0].startMs, plainText: line)
            } else if script == .korean {
                koreanRoma = romanizationText(timeMs: words[0].startMs, plainText: line)
            }
        }
        let result = Self.buildWordGroups(
            words: words, line: line, japanese: allowed,
            marks: kanaAnnotation?.marks(forLine: line) ?? [],
            segments: segments, hanRomanization: hanRoma, koreanRomanization: koreanRoma)
        wordGroupCache[key] = result
        return result
    }

    public static func buildWordGroups(
        words: [SyncedLyricWord], line: String, japanese: Bool,
        marks: [KanaAnnotation.Mark] = [],
        segments: [Romanizer.JapaneseSegment]? = nil,
        hanRomanization: String? = nil,
        koreanRomanization: String? = nil
    ) -> [SyncedLyricWordGroup]? {
        if japanese, Romanizer.looksJapanese(line) {

            let segs = segments ?? Romanizer.japaneseSegments(line, marks: marks)
            return mergeSegmentsIntoWordGroups(words: words, segs: segs)
        }
        if let hanRomanization, !hanRomanization.isEmpty {
            let tokens = hanRomanization.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count == words.count, !words.isEmpty else { return nil }
            return zip(words, tokens).enumerated().map { i, pair in
                SyncedLyricWordGroup(id: i, words: [pair.0], romanization: String(pair.1))
            }
        }
        if let koreanRomanization, !koreanRomanization.isEmpty,
           let segs = Romanizer.koreanSegments(line, romanization: koreanRomanization)
        {
            return mergeSegmentsIntoWordGroups(words: words, segs: segs)
        }
        return nil
    }

    private static func mergeSegmentsIntoWordGroups(
        words: [SyncedLyricWord], segs: [Romanizer.JapaneseSegment]
    ) -> [SyncedLyricWordGroup]? {
        guard !segs.isEmpty else { return nil }

        var starts: [Int] = []
        var cursor = 0
        for w in words {
            starts.append(cursor)
            cursor += w.text.utf16.count
        }

        var groups: [SyncedLyricWordGroup] = []
        var i = 0
        while i < words.count {
            var j = i
            var end = starts[j] + words[j].text.utf16.count

            var grew = true
            while grew {
                grew = false
                for seg in segs where seg.utf16Start < end && seg.utf16End > end {
                    guard j + 1 < words.count else { break }
                    j += 1
                    end = starts[j] + words[j].text.utf16.count
                    grew = true
                    break
                }
            }
            let start = starts[i]
            let latins = segs.filter { $0.utf16Start < end && $0.utf16End > start }.map(\.latin)
            groups.append(SyncedLyricWordGroup(
                id: groups.count,
                words: Array(words[i...j]),
                romanization: latins.isEmpty ? nil : Romanizer.joinLatin(latins)))
            i = j + 1
        }

        return groups.contains { $0.romanization != nil } ? groups : nil
    }

    private var builtLinesCache: [Int: SyncedLyricLine] = [:]
    public var cachedLinesCount: Int { builtLinesCache.count }
    private var cachedActiveIdx = Int.min
    private var cachedActiveLine: SyncedLyricLine?
    private var cachedNextIdx = Int.min
    private var cachedNextText: String?
    private var cachedNextSide: LyricDuet.Side?
    private var cachedLeadIdx = Int.min
    private var cachedLeadLine: SyncedLyricLine?
    private var cachedCompactIdx = Int.min
    private var cachedCompactTrackEndMs: Int?
    private var cachedCompactDwellMs: Int?
    private var cachedCompactLeadInMs: Int?

    private static func lastIndex(atOrBefore posMs: Int, times: (Int) -> Int, count: Int) -> Int {
        guard count > 0 else { return -1 }
        var low = 0
        var high = count - 1
        var idx = -1
        while low <= high {
            let mid = (low + high) / 2
            if times(mid) <= posMs {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return idx
    }

    private var lastScanIdx = Int.min

    private func activeIndexCorrected(_ posMs: Int) -> Int {
        let count = usingWords ? wordLines.count : baseLines.count
        guard count > 0 else { return -1 }
        let time: (Int) -> Int =
            usingWords ? { self.wordLines[$0].timeMs } : { self.baseLines[$0].timeMs }
        if lastScanIdx >= -1, lastScanIdx < count {
            let lowOK = lastScanIdx == -1 || time(lastScanIdx) <= posMs
            let highOK = lastScanIdx + 1 >= count || time(lastScanIdx + 1) > posMs
            if lowOK && highOK { return lastScanIdx }
            let next = lastScanIdx + 1
            if next < count && time(next) <= posMs {
                let nextHighOK = next + 1 >= count || time(next + 1) > posMs
                if nextHighOK {
                    lastScanIdx = next
                    return next
                }
            }
        }
        let idx = Self.lastIndex(atOrBefore: posMs, times: time, count: count)
        lastScanIdx = idx
        return idx
    }

    public func activeLine(atMs rawPosMs: Int) -> SyncedLyricLine? {
        lineAt(activeIndexCorrected(rawPosMs + effectiveOffsetMs))
    }

    @inlinable
    public func currentLine(at rawPosMs: Int) -> SyncedLyricLine? {
        activeLine(atMs: rawPosMs)
    }

    private func lineAt(_ idx: Int) -> SyncedLyricLine? {
        if idx == cachedActiveIdx { return cachedActiveLine }
        let line = buildLine(idx)
        cachedActiveIdx = idx
        cachedActiveLine = line
        return line
    }

    private func leadLineAt(_ idx: Int) -> SyncedLyricLine? {
        if idx == cachedActiveIdx { return cachedActiveLine }
        if idx == cachedLeadIdx { return cachedLeadLine }
        let line = buildLine(idx)
        cachedLeadIdx = idx
        cachedLeadLine = line
        return line
    }

    private func buildLine(_ idx: Int) -> SyncedLyricLine? {
        guard idx >= 0 else { return nil }
        if let cached = builtLinesCache[idx] { return cached }
        let line: SyncedLyricLine?
        if usingWords {
            guard idx < wordLines.count else { return nil }
            let ln = wordLines[idx]
            let words = KaraokeFill.tailClamped(
                ln.words.map { w in
                    SyncedLyricWord(text: w.text, startMs: w.startMs, durationMs: w.durationMs)
                },
                nextLineStartMs: idx + 1 < wordLines.count ? wordLines[idx + 1].timeMs : nil)
            let joined = words.map(\.text).joined()
            line = SyncedLyricLine(
                romanization: romanizationText(timeMs: ln.timeMs, plainText: joined),
                translation: translationText(timeMs: ln.timeMs, plainText: joined),
                mainText: nil,
                words: words,
                wordGroups: wordGroups(for: words, line: joined),
                side: wordSides.indices.contains(idx) ? wordSides[idx] : nil,
                plainText: joined
            )
        } else {
            guard idx < baseLines.count else { return nil }
            let ln = baseLines[idx]
            line = SyncedLyricLine(
                romanization: romanizationText(timeMs: ln.timeMs, plainText: ln.text),
                translation: translationText(timeMs: ln.timeMs, plainText: ln.text),
                mainText: ln.text,
                words: nil,
                wordGroups: nil,
                side: baseSides.indices.contains(idx) ? baseSides[idx] : nil,
                plainText: ln.text
            )
        }
        if let line {
            builtLinesCache[idx] = line
        }
        return line
    }

    public struct TickResolution {
        public let index: Int?

        public let scrollIndex: Int?
        public let line: SyncedLyricLine?

        public let compactLine: SyncedLyricLine?

        public let compactPlaceholder: Bool

        public let compactDwellMs: Int?

        public let compactLeadInMs: Int?
        public let nextText: String?

        public let nextSide: LyricDuet.Side?
        public let gapIndex: Int?
    }

    public func tickQuery(atMs rawPosMs: Int, trackEndMs: Int? = nil) -> TickResolution {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        let gap: Int?
        if let window = gapWindow(after: idx), posMs >= window.start, posMs < window.end {
            gap = idx
        } else {
            gap = nil
        }

        let compact = CompactLyricLead.resolve(
            activeIdx: idx, posMs: posMs,
            lineEndMs: gapLineEndMs(at: idx),
            nextStartMs: gapLineStartMs(at: idx + 1))
        let compactLine: SyncedLyricLine?
        let compactPlaceholder: Bool
        let compactDwellMs: Int?
        let compactLeadInMs: Int?
        switch compact {
        case .line(let i):
            compactLine = leadLineAt(i)
            compactPlaceholder = false
            if i == cachedCompactIdx && trackEndMs == cachedCompactTrackEndMs {
                compactDwellMs = cachedCompactDwellMs
                compactLeadInMs = cachedCompactLeadInMs
            } else {
                let start = gapLineStartMs(at: i)
                let dwell = start.flatMap { s in
                    CompactLyricLead.displayDurationMs(
                        prevLineEndMs: gapLineEndMs(at: i - 1),
                        startMs: s,
                        lineEndMs: gapLineEndMs(at: i),
                        nextStartMs: gapLineStartMs(at: i + 1),
                        fallbackEndMs: trackEndMs)
                }
                let leadIn = start.map { s in
                    CompactLyricLead.leadInMs(prevLineEndMs: gapLineEndMs(at: i - 1), startMs: s)
                }
                cachedCompactIdx = i
                cachedCompactTrackEndMs = trackEndMs
                cachedCompactDwellMs = dwell
                cachedCompactLeadInMs = leadIn
                compactDwellMs = dwell
                compactLeadInMs = leadIn
            }
        case .placeholder:
            compactLine = nil
            compactPlaceholder = true
            compactDwellMs = nil
            compactLeadInMs = nil
        }
        let next = nextAt(idx + 1)
        return TickResolution(
            index: idx >= 0 ? idx : nil,
            scrollIndex: scrollLeadIndex(activeIdx: idx, posMs: posMs),
            line: lineAt(idx),
            compactLine: compactLine,
            compactPlaceholder: compactPlaceholder,
            compactDwellMs: compactDwellMs,
            compactLeadInMs: compactLeadInMs,
            nextText: next.text,
            nextSide: next.side,
            gapIndex: gap)
    }

    private func scrollLeadIndex(activeIdx idx: Int, posMs: Int) -> Int? {
        if idx < 0 {
            if let w = gapWindow(after: -1), posMs >= w.end, gapLineCount > 0 { return 0 }
            return nil
        }
        guard idx + 1 < gapLineCount else { return idx }
        if let w = gapWindow(after: idx) {
            return posMs >= w.end ? idx + 1 : idx
        }
        if let end = gapLineEndMs(at: idx), posMs >= end { return idx + 1 }
        return idx
    }

    public func upcomingLineText(afterMs rawPosMs: Int) -> String? {
        nextAt(activeIndexCorrected(rawPosMs + effectiveOffsetMs) + 1).text
    }

    private func nextAt(_ nextIdx: Int) -> (text: String?, side: LyricDuet.Side?) {
        if nextIdx == cachedNextIdx { return (cachedNextText, cachedNextSide) }
        let text: String?
        let side: LyricDuet.Side?
        if let line = buildLine(nextIdx) {
            text = line.plainText
            side = line.side
        } else {
            text = nil
            side = nil
        }
        cachedNextIdx = nextIdx
        cachedNextText = text
        cachedNextSide = side
        return (text, side)
    }

    public func allLines(idPrefix: String) -> [MenuBarLyricLine] {
        if usingWords {
            return (0 ..< wordLines.count).compactMap { i in
                guard let line = buildLine(i) else { return nil }
                return MenuBarLyricLine(id: "\(idPrefix)#\(i)", timeMs: wordLines[i].timeMs, line: line)
            }
        }
        return (0 ..< baseLines.count).compactMap { i in
            guard let line = buildLine(i) else { return nil }
            return MenuBarLyricLine(id: "\(idPrefix)#\(i)", timeMs: baseLines[i].timeMs, line: line)
        }
    }

    public func activeLineIndex(atMs rawPosMs: Int) -> Int? {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        return idx >= 0 ? idx : nil
    }

    public enum GapRule {
        public static let minGapMs = 6000
        public static let minIntroMs = 5000
        public static let minPlainIntervalMs = 15000
        public static let tailMarginMs = 1200
        public static let leadMs = 800
        public static let plainAssumedSingingCapMs = 8000
    }

    private var gapLineCount: Int { usingWords ? wordLines.count : baseLines.count }

    private func gapLineStartMs(at index: Int) -> Int? {
        if usingWords {
            return wordLines.indices.contains(index) ? wordLines[index].timeMs : nil
        }
        return baseLines.indices.contains(index) ? baseLines[index].timeMs : nil
    }

    private func gapLineEndMs(at index: Int) -> Int? {
        guard usingWords, wordLines.indices.contains(index),
              let last = wordLines[index].words.last else { return nil }
        return last.startMs + last.durationMs
    }

    public func gapWindow(after index: Int) -> (start: Int, end: Int)? {
        if index == -1 {
            guard let first = gapLineStartMs(at: 0), first >= GapRule.minIntroMs else { return nil }
            return (0, first - GapRule.leadMs)
        }
        guard let start = gapLineStartMs(at: index),
              let next = gapLineStartMs(at: index + 1) else { return nil }
        if let end = gapLineEndMs(at: index) {
            guard next - end >= GapRule.minGapMs else { return nil }
            return (end + GapRule.tailMarginMs, next - GapRule.leadMs)
        }
        guard next - start >= GapRule.minPlainIntervalMs else { return nil }
        let assumedEnd = start + min((next - start) / 3, GapRule.plainAssumedSingingCapMs)
        return (assumedEnd, next - GapRule.leadMs)
    }

    public func gapMarkers() -> [LyricsGapMarker] {
        var out: [LyricsGapMarker] = []
        if let w = gapWindow(after: -1) {
            out.append(LyricsGapMarker(index: -1, startMs: w.start, endMs: w.end))
        }
        for i in 0 ..< max(0, gapLineCount - 1) {
            if let w = gapWindow(after: i) {
                out.append(LyricsGapMarker(index: i, startMs: w.start, endMs: w.end))
            }
        }
        return out
    }

    public func activeGapIndex(atMs rawPosMs: Int) -> Int? {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        guard let window = gapWindow(after: idx) else { return nil }
        return (posMs >= window.start && posMs < window.end) ? idx : nil
    }
}
