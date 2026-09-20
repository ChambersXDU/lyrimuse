import Foundation

public enum LyricsLineDisplay: Equatable, Sendable {

    case words

    case plain
    case adBreak

    case radioTalk
    case instrumental
    case noLyrics
    case networkDown
    case searching

    case idle

    public static func resolve(
        hasWordTiming: Bool,
        hasCurrentLine: Bool,
        isAdBreak: Bool,
        isRadioTalk: Bool,
        isInstrumental: Bool,
        hasNoLyrics: Bool,
        networkDown: Bool,
        hasLyricsContent: Bool,
        isPlaying: Bool
    ) -> LyricsLineDisplay {

        if hasWordTiming { return .words }
        if isAdBreak { return .adBreak }

        if isRadioTalk { return .radioTalk }
        if isInstrumental { return .instrumental }
        if hasNoLyrics { return .noLyrics }
        if networkDown, !hasLyricsContent { return .networkDown }
        if isPlaying, !hasLyricsContent { return .searching }
        return hasCurrentLine ? .plain : .idle
    }
}
