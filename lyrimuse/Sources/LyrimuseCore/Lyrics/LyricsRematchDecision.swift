import Foundation

public enum LyricsRematchDecision {
    public enum Outcome: Equatable {

        case adopt

        case keptNotDecidable

        case keptNoCandidate

        case keptWouldLoseWordTiming

        case unchanged
    }

    public static func decide(decidable: Bool,
                             winnerSource: String,
                             currentHasWordTiming: Bool,
                             winnerHasWordTiming: Bool,
                             sameSource: Bool,
                             sameLyrics: Bool,
                             sameWordTiming: Bool) -> Outcome {

        guard decidable else { return .keptNotDecidable }
        guard !winnerSource.isEmpty else { return .keptNoCandidate }
        if currentHasWordTiming && !winnerHasWordTiming { return .keptWouldLoseWordTiming }
        if sameSource && sameLyrics && sameWordTiming { return .unchanged }
        return .adopt
    }
}
