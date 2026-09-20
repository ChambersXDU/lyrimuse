import Foundation

public enum LyricsTranslationSource: String, CaseIterable, Sendable {

    case none

    case community

    case machine

    public static let machineSentinel = "machine"

    public static func classify(hasTranslation: Bool, trSource: String) -> LyricsTranslationSource {
        guard hasTranslation else { return .none }
        return trSource == machineSentinel ? .machine : .community
    }
}
