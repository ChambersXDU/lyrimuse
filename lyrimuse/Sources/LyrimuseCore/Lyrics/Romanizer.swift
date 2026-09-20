import Foundation

public enum ChineseVariant: String, CaseIterable, Sendable {
    case off, simplified, traditional

    public static func affects(_ text: String) -> Bool {
        !text.isEmpty && Romanizer.containsHan(text) && !Romanizer.looksJapanese(text)
    }

    public func converted(_ text: String) -> String {
        guard self != .off, Self.affects(text) else { return text }
        let transform: StringTransform =
            self == .traditional
            ? StringTransform("Simplified-Traditional")
            : StringTransform("Traditional-Simplified")
        let icu = text.applyingTransform(transform, reverse: false) ?? text
        return self == .simplified ? HanVariants.normalizeToSimplified(icu) : icu
    }
}

public enum Romanizer {

    public static func romanize(
        _ text: String, japanese: Bool = false,
        marks: [KanaAnnotation.Mark] = []
    ) -> String? {
        guard !text.isEmpty else { return nil }

        if japanese, looksJapanese(text) || containsHan(text),
            let reading = japaneseReading(text, marks: marks), reading != text
        {
            return reading
        }

        guard let transformed = text.applyingTransform(.toLatin, reverse: false),
            transformed != text
        else { return nil }
        return transformed
    }

    private static let japaneseLocale = CFLocaleCreate(
        nil, CFLocaleIdentifier("ja_JP" as CFString))

    static func particleLatin(for piece: String) -> String? {
        switch piece {
        case "は": return "wa"
        case "へ": return "e"
        case "を": return "o"
        case "こんにちは": return "konnichiwa"
        case "こんばんは": return "konbanwa"
        default: return nil
        }
    }

    public struct JapaneseSegment: Equatable {
        public let utf16Start: Int
        public let utf16Length: Int
        public let latin: String
        public var utf16End: Int { utf16Start + utf16Length }
    }

    static func annotatedReading(
        in text: String, utf16Start: Int, utf16Length: Int, marks: [KanaAnnotation.Mark],
        unitsHint: [UTF16.CodeUnit]? = nil
    ) -> String? {
        let end = utf16Start + utf16Length
        let hits = marks.filter { $0.utf16Start < end && $0.utf16End > utf16Start }
            .sorted { $0.utf16Start < $1.utf16Start }
        guard !hits.isEmpty else { return nil }
        let units = unitsHint ?? Array(text.utf16)
        guard end <= units.count else { return nil }
        var kana = ""
        var cursor = utf16Start
        for m in hits {

            guard m.utf16Start >= utf16Start, m.utf16End <= end else { return nil }
            if m.utf16Start > cursor {
                kana += String(utf16CodeUnits: Array(units[cursor..<m.utf16Start]),
                               count: m.utf16Start - cursor)
            }
            kana += m.reading
            cursor = m.utf16End
        }
        if cursor < end {
            kana += String(utf16CodeUnits: Array(units[cursor..<end]), count: end - cursor)
        }
        guard !kana.isEmpty,
            let latin = kana.applyingTransform(.toLatin, reverse: false),
            latin != kana
        else { return nil }
        return latin.trimmingCharacters(in: .whitespaces)
    }

    public static func joinLatin(_ pieces: [String]) -> String {
        mergeSokuon(pieces).joined(separator: " ")
    }

    public static func lineReading(
        _ line: String,
        songLooksJapanese: Bool,
        segments: @autoclosure () -> [JapaneseSegment]
    ) -> String? {
        if looksJapanese(line) || (songLooksJapanese && containsHan(line)),
            let reading = readingFromSegments(segments(), original: line)
        {
            return reading
        }
        return romanize(line, japanese: false)
    }

    public static func readingFromSegments(
        _ segs: [JapaneseSegment], original text: String
    ) -> String? {
        guard !segs.isEmpty else { return nil }
        let joined = joinLatin(segs.map(\.latin))

        guard joined != text else { return nil }
        return joined
    }

    public static func koreanSegments(_ text: String, romanization: String) -> [JapaneseSegment]? {
        let romTokens = romanization.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !romTokens.isEmpty else { return nil }
        var segs: [JapaneseSegment] = []
        var utf16Offset = 0
        var tokenIdx = 0
        var wordStart: Int?
        for ch in text {
            let chLen = String(ch).utf16.count
            if ch.isWhitespace {
                if let start = wordStart {
                    guard tokenIdx < romTokens.count else { return nil }
                    segs.append(JapaneseSegment(
                        utf16Start: start, utf16Length: utf16Offset - start, latin: romTokens[tokenIdx]))
                    tokenIdx += 1
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = utf16Offset
            }
            utf16Offset += chLen
        }
        if let start = wordStart {
            guard tokenIdx < romTokens.count else { return nil }
            segs.append(JapaneseSegment(
                utf16Start: start, utf16Length: utf16Offset - start, latin: romTokens[tokenIdx]))
            tokenIdx += 1
        }
        guard tokenIdx == romTokens.count else { return nil }
        return segs
    }

    public static func japaneseSegments(
        _ text: String, marks: [KanaAnnotation.Mark] = []
    ) -> [JapaneseSegment] {
        let cf = text as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        let tokenizer = CFStringTokenizerCreate(
            nil, cf, range, kCFStringTokenizerUnitWordBoundary, japaneseLocale)

        let units: [UTF16.CodeUnit]? = marks.isEmpty ? nil : Array(text.utf16)
        var out: [JapaneseSegment] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let piece = CFStringCreateWithSubstring(nil, cf, r) as String? ?? ""
            var latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String ?? ""

            if let annotated = annotatedReading(
                in: text, utf16Start: r.location, utf16Length: r.length, marks: marks,
                unitsHint: units)
            {
                latin = annotated
            }
            if let fixed = particleLatin(for: piece) { latin = fixed }
            if latin.isEmpty {

                guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                latin = piece
            }

            out.append(JapaneseSegment(
                utf16Start: r.location, utf16Length: r.length, latin: latin))
        }
        return out
    }

    private static func japaneseReading(
        _ text: String, marks: [KanaAnnotation.Mark] = []
    ) -> String? {
        let cf = text as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        let tokenizer = CFStringTokenizerCreate(
            nil, cf, range, kCFStringTokenizerUnitWordBoundary, japaneseLocale)
        var tokens: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let piece = CFStringCreateWithSubstring(nil, cf, tokenRange) as String? ?? ""
            if let fixed = particleLatin(for: piece) {
                tokens.append(fixed)
            } else if let annotated = annotatedReading(
                in: text, utf16Start: tokenRange.location, utf16Length: tokenRange.length,
                marks: marks)
            {
                tokens.append(annotated)
            } else if let reading = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                !reading.isEmpty
            {
                tokens.append(reading)
            } else if !piece.trimmingCharacters(in: .whitespaces).isEmpty {

                tokens.append(piece)
            }
        }
        guard !tokens.isEmpty else { return nil }
        return mergeSokuon(tokens).joined(separator: " ")
    }

    private static func mergeSokuon(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasSuffix("~tsu"), index + 1 < tokens.count,
                let consonant = tokens[index + 1].first, consonant.isASCII, consonant.isLetter
            {
                out.append(token.dropLast(4) + String(consonant) + tokens[index + 1])
                index += 2
            } else if token.hasSuffix("~tsu") {

                let head = String(token.dropLast(4))
                if !head.isEmpty { out.append(head) }
                index += 1
            } else {
                out.append(token)
                index += 1
            }
        }
        return out
    }

    private static let kanaPattern = try! NSRegularExpression(
        pattern: #"\p{Hiragana}|\p{Katakana}"#)

    public static func looksJapanese(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return kanaPattern.firstMatch(in: text, range: range) != nil
    }

    private static let hanPattern = try! NSRegularExpression(pattern: #"\p{Han}"#)

    public static func containsHan(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return hanPattern.firstMatch(in: text, range: range) != nil
    }
}

public enum LyricScript: String, Sendable, CaseIterable {
    case japanese, korean, chinese

    case cantonese

    case other

    var option: RomanizationScripts? {
        switch self {
        case .japanese: return .japanese
        case .korean: return .korean
        case .chinese: return .chinese
        case .cantonese: return .cantonese
        case .other: return nil
        }
    }
}

public struct RomanizationScripts: OptionSet, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let japanese = RomanizationScripts(rawValue: 1 << 0)
    public static let korean = RomanizationScripts(rawValue: 1 << 1)

    public static let chinese = RomanizationScripts(rawValue: 1 << 2)

    public static let cantonese = RomanizationScripts(rawValue: 1 << 3)

    public static let `default`: RomanizationScripts = [.japanese, .korean, .chinese, .cantonese]
}

extension Romanizer {

    private static let hangulPattern = try! NSRegularExpression(
        pattern: #"\p{Hangul}"#)

    public static func containsHangul(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return hangulPattern.firstMatch(in: text, range: range) != nil
    }

    public static func script(of text: String) -> LyricScript {
        if looksJapanese(text) { return .japanese }
        if containsHangul(text) { return .korean }
        if containsHan(text) { return .chinese }
        return .other
    }

    public static let japaneseSongKanaLineRatio = 0.5

    public static func kanaLineRatio(_ text: String) -> Double {
        var total = 0
        var kana = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            total += 1
            if looksJapanese(line) { kana += 1 }
        }
        guard total > 0 else { return 0 }
        return Double(kana) / Double(total)
    }

    public static func looksJapaneseSong(_ text: String) -> Bool {
        kanaLineRatio(text) >= japaneseSongKanaLineRatio
    }

    public static func songScript(of text: String) -> LyricScript {
        if looksJapaneseSong(text) { return .japanese }
        if containsHangul(text) { return .korean }
        if containsHan(text) { return .chinese }
        return .other
    }

    public static func script(ofLine line: String, song: LyricScript) -> LyricScript {
        if looksJapanese(line) { return .japanese }
        if containsHangul(line) { return .korean }
        if containsHan(line) {
            if song == .japanese { return .japanese }
            if song == .cantonese { return .cantonese }
            return .chinese
        }
        return .other
    }
}
