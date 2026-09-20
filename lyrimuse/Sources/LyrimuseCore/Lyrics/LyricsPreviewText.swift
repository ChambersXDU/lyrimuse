import Foundation

public enum LyricsPreviewText {

    struct ClassifiedLine {
        enum Kind { case blank, hidden, visible }
        let raw: String
        let kind: Kind
    }

    static func classify(_ lyrics: String, title: String, artist: String) -> [ClassifiedLine] {

        struct Line { let raw: String; let body: String; let isBlank: Bool }
        var lines: [Line] = []

        for rawScalars in lyrics.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(String.UnicodeScalarView(rawScalars))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {

                lines.append(Line(raw: "", body: "", isBlank: true))
                continue
            }
            var body = trimmed
            while body.hasPrefix("["), let end = body.firstIndex(of: "]") {
                body = String(body[body.index(after: end)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            lines.append(Line(raw: trimmed, body: body, isBlank: false))
        }

        let bodies = lines.filter { !$0.isBlank && !$0.body.isEmpty }.map(\.body)
        var drop: [Bool] = Array(repeating: false, count: bodies.count)
        if !bodies.isEmpty {
            drop = LyricsSyncEngine.creditLineDropDecisions(
                bodies, trackTitle: title, trackArtist: artist,
                speakerExemptions: LyricDuet.speakers(in: bodies))
        }

        var out: [ClassifiedLine] = []
        var i = 0
        for line in lines {
            if line.isBlank {
                out.append(ClassifiedLine(raw: "", kind: .blank))
                continue
            }
            if line.body.isEmpty {
                out.append(ClassifiedLine(raw: line.raw, kind: .hidden))
                continue
            }
            defer { i += 1 }
            out.append(ClassifiedLine(raw: line.raw, kind: drop[i] ? .hidden : .visible))
        }
        return out
    }

    public static func forPreview(_ lyrics: String, title: String = "", artist: String = "") -> String {
        var out: [String] = []
        for line in classify(lyrics, title: title, artist: artist) {
            switch line.kind {
            case .blank: out.append("")
            case .hidden: continue
            case .visible: out.append(line.raw)
            }
        }

        while out.first?.isEmpty == true { out.removeFirst() }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}

public struct LyricsBodyEdit: Equatable, Sendable {

    public let original: String

    public let body: String

    public let hiddenPrefix: [String]

    public let hiddenSuffix: [String]

    public init(lyrics: String, title: String = "", artist: String = "") {
        original = lyrics
        var prefix: [String] = []
        var suffix: [String] = []
        var visible: [String] = []
        var seenVisible = false
        for line in LyricsPreviewText.classify(lyrics, title: title, artist: artist) {
            switch line.kind {
            case .blank:
                visible.append("")
            case .hidden:
                if seenVisible { suffix.append(line.raw) } else { prefix.append(line.raw) }
            case .visible:
                seenVisible = true
                visible.append(line.raw)
            }
        }
        while visible.first?.isEmpty == true { visible.removeFirst() }
        while visible.last?.isEmpty == true { visible.removeLast() }
        body = visible.joined(separator: "\n")
        hiddenPrefix = prefix
        hiddenSuffix = suffix
    }

    public func reassembled(body newBody: String) -> String {
        if newBody == body { return original }
        var out = hiddenPrefix
        if !newBody.isEmpty {
            out.append(contentsOf: newBody.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
        out.append(contentsOf: hiddenSuffix)
        var text = out.joined(separator: "\n")
        if original.hasSuffix("\n"), !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        return text
    }
}
