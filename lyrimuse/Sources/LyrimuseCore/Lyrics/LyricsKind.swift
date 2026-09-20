import Foundation

public enum LyricsKind: String, CaseIterable, Sendable {

    case wordByWord

    case lineByLine

    case plainText

    case instrumental

    case none

    public static func classify(
        hasWordTiming: Bool,
        hasLyrics: Bool,
        hasPlainTextFallback: Bool,
        isInstrumental: Bool
    ) -> LyricsKind {
        if hasWordTiming { return .wordByWord }
        if hasLyrics { return .lineByLine }
        if hasPlainTextFallback { return .plainText }
        if isInstrumental { return .instrumental }
        return .none
    }
}
