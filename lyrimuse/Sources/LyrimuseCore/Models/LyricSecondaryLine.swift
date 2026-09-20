import Foundation

public enum LyricSecondaryLine: String, CaseIterable, Sendable {
    case off
    case nextLine
    case translation
    case romanization

    public var showsSecondaryRow: Bool { self != .off }

    public func secondaryText(currentLine: SyncedLyricLine?, nextLineText: String?) -> String? {
        let raw: String?
        switch self {
        case .off: raw = nil
        case .nextLine: raw = nextLineText
        case .translation: raw = currentLine?.translation
        case .romanization: raw = currentLine?.romanization
        }
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    public var hidesExpandedNextLinePreview: Bool { self == .nextLine }

    public static func expandedNextLinePreviewVisible(userToggle: Bool, secondary: LyricSecondaryLine) -> Bool {
        userToggle && !secondary.hidesExpandedNextLinePreview
    }
}

public enum NotchLyricRowMetrics {

    public static let rowHeight: CGFloat = 44

    public static let defaultMainFontSize: CGFloat = 13
    public static let mainFontSizeRange: ClosedRange<CGFloat> = 11...17

    public static let secondaryFontSize: CGFloat = 11

    public static func lineHeight(fontSize: CGFloat) -> CGFloat { fontSize.rounded() + 2 }

    public static func mainLineHeight(fontSize: CGFloat) -> CGFloat {
        lineHeight(fontSize: clampedMainFontSize(fontSize))
    }

    public static var mainLineHeight: CGFloat { mainLineHeight(fontSize: defaultMainFontSize) }

    public static var secondaryLineHeight: CGFloat { lineHeight(fontSize: secondaryFontSize) }

    public static let lineSpacing: CGFloat = 3

    public static func twoLineStackHeight(fontSize: CGFloat) -> CGFloat {
        mainLineHeight(fontSize: fontSize) + lineSpacing + secondaryLineHeight
    }
    public static var twoLineStackHeight: CGFloat { twoLineStackHeight(fontSize: defaultMainFontSize) }

    public static func clampedMainFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size, mainFontSizeRange.lowerBound), mainFontSizeRange.upperBound)
    }
}
