import Foundation

public enum LyricsRomanization {

    private static let leadingTagsRegex = try! NSRegularExpression(pattern: #"^((?:\[[^\]]*\])+)"#)

    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]"#)

    public static func romanizeLRC(_ lyrics: String) -> String? {
        guard !lyrics.isEmpty else { return nil }

        let songLooksJapanese = Romanizer.looksJapaneseSong(lyrics)

        let annotation = KanaAnnotation.parse(lrc: lyrics)

        let normalized = lyrics.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var out: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard let tagMatch = leadingTagsRegex.firstMatch(in: line, range: full) else { continue }
            let tags = ns.substring(with: tagMatch.range(at: 1))

            guard timestampRegex.firstMatch(
                in: tags, range: NSRange(location: 0, length: (tags as NSString).length)) != nil
            else { continue }
            let body = ns.substring(from: tagMatch.range.length)
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            guard let reading = Romanizer.lineReading(
                body,
                songLooksJapanese: songLooksJapanese,
                segments: Romanizer.japaneseSegments(
                    body, marks: annotation?.marks(forLine: body) ?? [])),
                !reading.isEmpty, reading != body
            else { continue }
            out.append(tags + reading)
        }

        return out.isEmpty ? nil : out.joined(separator: "\n")
    }
}
