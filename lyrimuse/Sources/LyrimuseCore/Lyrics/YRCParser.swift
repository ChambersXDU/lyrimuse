import Foundation

public struct LyricWord: Equatable {
    public let startMs: Int
    public let durationMs: Int
    public let text: String
    public init(startMs: Int, durationMs: Int, text: String) {
        self.startMs = startMs
        self.durationMs = durationMs
        self.text = text
    }
}

public struct LyricLineWords: Equatable {
    public let timeMs: Int
    public let words: [LyricWord]
    public init(timeMs: Int, words: [LyricWord]) {
        self.timeMs = timeMs
        self.words = words
    }
}

public enum YRCParser {
    private static let headRegex = try! NSRegularExpression(pattern: #"^\[(\d+),\d+\]"#)

    private static let wordRegex = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)((?:[^(]|\((?!\d+,\d+,\d+\)))*)"#)

    private static let malformedTupleRegex = try! NSRegularExpression(pattern: #"\(\d+,\d+\)"#)

    public static func parse(_ text: String) -> [LyricLineWords] {
        var out: [LyricLineWords] = []

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLineString = String(rawLine)
            let rawNsLine = rawLineString as NSString
            let headRange = NSRange(location: 0, length: rawNsLine.length)
            guard let head = headRegex.firstMatch(in: rawLineString, range: headRange) else { continue }
            let lineTimeMs = Int(rawNsLine.substring(with: head.range(at: 1))) ?? 0

            let line = malformedTupleRegex.stringByReplacingMatches(
                in: rawLineString, range: headRange, withTemplate: "")
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            var words: [LyricWord] = []
            for m in wordRegex.matches(in: line, range: fullRange) {
                let wordText = nsLine.substring(with: m.range(at: 3))
                if wordText.isEmpty { continue }
                let start = Int(nsLine.substring(with: m.range(at: 1))) ?? 0
                let dur = Int(nsLine.substring(with: m.range(at: 2))) ?? 0
                words.append(LyricWord(startMs: start, durationMs: dur, text: wordText))
            }
            if !words.isEmpty { out.append(LyricLineWords(timeMs: lineTimeMs, words: words)) }
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }
}
