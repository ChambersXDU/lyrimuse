import Foundation

public struct LyricLine: Equatable {
    public let timeMs: Int
    public let text: String
    public init(timeMs: Int, text: String) {
        self.timeMs = timeMs
        self.text = text
    }
}

public enum LRCParser {
    private static let tagRegex = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
    private static let bracketRegex = try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)
    private static let offsetRegex = try! NSRegularExpression(pattern: #"\[offset:\s*([+-]?\d+)\s*\]"#)

    public static func parseOffsetMs(_ text: String) -> Int {
        let ns = text as NSString
        guard let m = offsetRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let value = Int(ns.substring(with: m.range(at: 1)))
        else { return 0 }

        guard abs(value) <= maxOffsetMs else { return 0 }
        return value
    }

    public static let maxOffsetMs = 10_000

    public static func parse(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = tagRegex.matches(in: line, range: fullRange)
            if matches.isEmpty { continue }
            let stripped = bracketRegex
                .stringByReplacingMatches(in: line, range: fullRange, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            for m in matches {
                let minutes = Int(nsLine.substring(with: m.range(at: 1))) ?? 0
                let seconds = Int(nsLine.substring(with: m.range(at: 2))) ?? 0
                var fracMs = 0
                let fracRange = m.range(at: 3)
                if fracRange.location != NSNotFound {

                    var frac = nsLine.substring(with: fracRange)
                    frac += "00"
                    frac = String(frac.prefix(3))
                    fracMs = Int(frac) ?? 0
                }
                let t = (minutes * 60 + seconds) * 1000 + fracMs
                out.append(LyricLine(timeMs: t, text: stripped))
            }
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }
}
