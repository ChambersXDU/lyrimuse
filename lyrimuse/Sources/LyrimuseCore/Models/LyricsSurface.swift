import Foundation

public enum LyricsSurface: String, CaseIterable, Hashable, Sendable {
    case overlay
    case menuBar

    public static let appearanceSectionStorageKey = "settings:appearanceSection"

    public var appearanceSectionRawValue: String { rawValue }
}
