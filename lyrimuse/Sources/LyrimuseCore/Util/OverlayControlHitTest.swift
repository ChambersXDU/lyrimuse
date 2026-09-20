import Foundation

public enum OverlayControlID: String, Hashable, CaseIterable, Sendable {
    case previous
    case playPause
    case next
    case favorite
    case lock
    case expandToLyricsWindow
    case settingsMenu
    case closeOverlay
    case unlockPill
}

public enum OverlayControlHitTest {

    public static func windowLocalRect(
        swiftUI rect: CGRect, windowHeight: CGFloat, contentTopInset: CGFloat = 0
    ) -> CGRect {
        CGRect(x: rect.minX, y: windowHeight - contentTopInset - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func contentTopInset(
        anchorsBottom: Bool, windowHeight: CGFloat, contentHeight: CGFloat
    ) -> CGFloat {
        anchorsBottom ? windowHeight - contentHeight : 0
    }

    public static func control(
        at point: CGPoint, in rects: [OverlayControlID: CGRect]
    ) -> OverlayControlID? {
        rects
            .filter { $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?
            .key
    }

    public static func hoveredControl(
        at point: CGPoint, in rects: [OverlayControlID: CGRect],
        insideWindow: Bool, positionLocked: Bool
    ) -> OverlayControlID? {
        guard insideWindow, let id = control(at: point, in: rects) else { return nil }
        if positionLocked && id != .unlockPill { return nil }
        return id
    }

    public static func chromeHoverZone(
        lyrics: CGRect?, controlsPill: CGRect?, controlRects: [OverlayControlID: CGRect]
    ) -> CGRect? {
        var zone: CGRect?

        for rect in [lyrics, controlsPill].compactMap({ $0 }) + Array(controlRects.values) {
            guard !rect.isEmpty else { continue }
            zone = zone.map { $0.union(rect) } ?? rect
        }
        return zone
    }
}
