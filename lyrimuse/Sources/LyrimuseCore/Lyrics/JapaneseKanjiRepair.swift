import Foundation

public enum JapaneseKanjiRepair {

    private static let japaneseEncoding: String.Encoding = .shiftJIS

    private static let toTraditional = StringTransform("Simplified-Traditional")

    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var memo: [Character: Character?] = [:]

    static func isJapaneseKanji(_ ch: Character) -> Bool {
        String(ch).data(using: japaneseEncoding) != nil
    }

    static func repaired(_ ch: Character) -> Character? {

        guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first,
              scalar.properties.isIdeographic else { return nil }
        memoLock.lock()
        defer { memoLock.unlock() }
        if let cached = memo[ch] { return cached }
        var result: Character? = nil
        if !isJapaneseKanji(ch),
           let trad = String(ch).applyingTransform(toTraditional, reverse: false),
           trad.count == 1, let candidate = trad.first,
           candidate != ch, isJapaneseKanji(candidate) {
            result = candidate
        }
        memo[ch] = result
        return result
    }

    public static func repairLine(_ line: String) -> String {
        guard Romanizer.looksJapanese(line), Romanizer.containsHan(line),
              line.contains(where: { repaired($0) != nil }) else { return line }
        return String(line.map { repaired($0) ?? $0 })
    }

    public static func repair(_ text: String, japaneseSong: Bool) -> String {
        guard japaneseSong, !text.isEmpty, Romanizer.containsHan(text),
              text.contains(where: { repaired($0) != nil }) else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var lineStart = text.startIndex
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch.isNewline {
                out += repairLine(String(text[lineStart..<idx]))
                out.append(ch)
                lineStart = text.index(after: idx)
            }
            idx = text.index(after: idx)
        }
        out += repairLine(String(text[lineStart..<text.endIndex]))
        return out
    }
}
