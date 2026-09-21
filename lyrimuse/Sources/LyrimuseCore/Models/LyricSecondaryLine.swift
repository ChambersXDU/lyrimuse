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

}
