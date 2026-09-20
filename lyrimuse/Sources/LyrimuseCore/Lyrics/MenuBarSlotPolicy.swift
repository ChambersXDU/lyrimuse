import CoreGraphics
import Foundation

public enum MenuBarSlotPolicy {

    public static let minimumShrinkPoints: CGFloat = 6

    public static let minimumWidenPoints: CGFloat = 6

    public static func skipsResize(
        currentLength: CGFloat, targetLength: CGFloat,
        dwellSeconds: Double?, quietSecs: Double
    ) -> Bool {
        let delta = targetLength - currentLength
        guard delta != 0 else { return false }
        let deadZone = delta > 0 ? minimumWidenPoints : minimumShrinkPoints
        if abs(delta) < deadZone { return true }
        guard let dwellSeconds else { return false }
        return dwellSeconds < quietSecs
    }

    public static func slotWidth(
        naturalWidth: CGFloat, upcomingWidth: CGFloat,
        isPlaceholder: Bool, maxWidth: CGFloat
    ) -> CGFloat {
        guard isPlaceholder else { return naturalWidth }
        return min(maxWidth, max(naturalWidth, upcomingWidth))
    }

    public static func displayText(
        lyricText: String, title: String, isPlaying: Bool, isAdBreak: Bool,
        showsTitleWhenNoLyrics: Bool, placeholderGlyph: String
    ) -> (text: String, isFallback: Bool)? {
        guard isPlaying else { return nil }
        if !lyricText.isEmpty { return (lyricText, false) }
        guard showsTitleWhenNoLyrics, !isAdBreak else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (placeholderGlyph + " " + trimmed, true)
    }
}
