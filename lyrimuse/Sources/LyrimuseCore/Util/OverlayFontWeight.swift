import Foundation

public enum OverlayFontWeight: String, CaseIterable, Sendable {
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy

    public var appKitWeight: Int {
        switch self {
        case .light: return 4
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        }
    }

    public var ladderIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    public func lighter(by steps: Int) -> OverlayFontWeight {
        let all = Self.allCases
        let target = min(max(ladderIndex - steps, 0), all.count - 1)
        return all[target]
    }

    public static let romanizationSteps = 2

    public static let translationSteps = 3

    public static let nextLinePreviewSteps = 2

}
