import Foundation

public struct KanaAnnotation {

    public struct Mark: Equatable {
        public let utf16Start: Int
        public let utf16Length: Int
        public let reading: String
        public var utf16End: Int { utf16Start + utf16Length }
    }

    private let byLine: [String: [Mark]]

    public func marks(forLine line: String) -> [Mark] { byLine[line] ?? [] }
    public var isEmpty: Bool { byLine.isEmpty }

    public static func needsAnnotation(_ c: Character) -> Bool {
        if c == "々" { return true }
        return c.unicodeScalars.contains { CharacterSet.ideographicHan.contains($0) }
    }

    public static func parse(lrc: String) -> KanaAnnotation? {
        guard let raw = kanaTag(in: lrc) else { return nil }
        let entries = parseEntries(raw)
        guard !entries.isEmpty else { return nil }

        let lines = bodyLines(of: lrc)

        let need = lines.reduce(0) { $0 + $1.filter(needsAnnotation).count }
        guard need == entries.reduce(0, { $0 + $1.count }), need > 0 else { return nil }

        var byLine: [String: [Mark]] = [:]
        var entryIdx = 0
        var pendingInEntry = 0
        for line in lines {
            var marks: [Mark] = []
            var utf16Pos = 0
            var i = line.startIndex
            while i < line.endIndex {
                let ch = line[i]
                let w = utf16Width(ch)
                guard needsAnnotation(ch) else {
                    utf16Pos += w
                    i = line.index(after: i)
                    continue
                }
                if pendingInEntry == 0 {
                    guard entryIdx < entries.count else { return nil }
                    pendingInEntry = entries[entryIdx].count
                }

                let start = utf16Pos
                var length = 0
                var consumed = 0
                while i < line.endIndex, consumed < pendingInEntry {
                    let c = line[i]
                    let cw = utf16Width(c)
                    if needsAnnotation(c) { consumed += 1 }
                    length += cw
                    utf16Pos += cw
                    i = line.index(after: i)

                    if consumed == pendingInEntry { break }
                }
                let reading = entries[entryIdx].reading
                if !reading.isEmpty {
                    marks.append(Mark(utf16Start: start, utf16Length: length, reading: reading))
                }
                if consumed == pendingInEntry {
                    entryIdx += 1
                    pendingInEntry = 0
                } else {

                    pendingInEntry -= consumed
                }
            }
            if !marks.isEmpty { byLine[line] = marks }
        }
        guard !byLine.isEmpty else { return nil }
        return KanaAnnotation(byLine: byLine)
    }

    private static func utf16Width(_ c: Character) -> Int {
        var w = 0
        for scalar in c.unicodeScalars { w += scalar.value > 0xFFFF ? 2 : 1 }
        return w
    }

    private static func kanaTag(in lrc: String) -> String? {
        for line in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("[kana:"), s.hasSuffix("]") else { continue }
            return String(s.dropFirst("[kana:".count).dropLast())
        }
        return nil
    }

    struct Entry: Equatable {
        let count: Int
        let reading: String
    }

    static func parseEntries(_ raw: String) -> [Entry] {
        var out: [Entry] = []
        var idx = raw.startIndex
        while idx < raw.endIndex {
            guard let digit = raw[idx].wholeNumberValue, raw[idx].isNumber else {
                idx = raw.index(after: idx)
                continue
            }
            idx = raw.index(after: idx)
            var reading = ""
            while idx < raw.endIndex {
                let c = raw[idx]
                if c.isNumber { break }
                if c == "(" {

                    while idx < raw.endIndex, raw[idx] != ")" { idx = raw.index(after: idx) }
                    if idx < raw.endIndex { idx = raw.index(after: idx) }
                    continue
                }
                reading.append(c)
                idx = raw.index(after: idx)
            }
            out.append(Entry(count: max(1, digit), reading: reading))
        }
        return out
    }

    static func bodyLines(of lrc: String) -> [String] {
        var out: [String] = []
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard let m = lrcTimeTag.firstMatch(
                in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            _ = m
            let text = lrcTimeTag.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(text) }
        }
        return out
    }

    private static let lrcTimeTag = try! NSRegularExpression(
        pattern: #"\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]"#)
}

extension CharacterSet {

    fileprivate static let ideographicHan: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: Unicode.Scalar(0x4E00)!...Unicode.Scalar(0x9FFF)!)
        s.insert(charactersIn: Unicode.Scalar(0x3400)!...Unicode.Scalar(0x4DBF)!)
        return s
    }()
}
