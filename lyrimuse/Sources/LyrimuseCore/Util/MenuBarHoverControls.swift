import Foundation

public enum MenuBarTransportControl: String, CaseIterable, Sendable {
    case previous
    case playPause
    case next
}

public enum MenuBarHoverControls {

    public static let pitch: CGFloat = 24

    public static let glyphPointSize: CGFloat = 11.5

    public static var minimumWidth: CGFloat { pitch * CGFloat(MenuBarTransportControl.allCases.count) }

    public static func layout(in bounds: CGRect) -> [MenuBarTransportControl: CGRect]? {
        guard bounds.width >= minimumWidth, bounds.height > 0 else { return nil }
        let total = minimumWidth

        let left = bounds.minX + ((bounds.width - total) / 2).rounded()
        var rects: [MenuBarTransportControl: CGRect] = [:]
        for (index, control) in MenuBarTransportControl.allCases.enumerated() {
            rects[control] = CGRect(x: left + CGFloat(index) * pitch, y: bounds.minY,
                                    width: pitch, height: bounds.height)
        }
        return rects
    }

    public static func control(
        at point: CGPoint, in rects: [MenuBarTransportControl: CGRect]
    ) -> MenuBarTransportControl? {
        MenuBarTransportControl.allCases.first { rects[$0]?.contains(point) == true }
    }

    public static func glyphRect(in hitRect: CGRect, side: CGFloat) -> CGRect {
        CGRect(x: (hitRect.midX - side / 2).rounded(),
               y: (hitRect.midY - side / 2).rounded(),
               width: side, height: side)
    }

    public static func lyricsSlot(
        buttonWidth: CGFloat, contentWidth: CGFloat,
        reservedIconWidth: CGFloat, iconLeading: Bool
    ) -> (x: CGFloat, width: CGFloat)? {

        let contentW = min(contentWidth, buttonWidth)
        guard contentW > 0, buttonWidth > 0 else { return nil }

        let left = max(0, ((buttonWidth - contentW) / 2).rounded())
        let clipW = max(0, contentW - reservedIconWidth)
        guard clipW > 0 else { return nil }
        return (x: iconLeading ? left + reservedIconWidth : left, width: clipW)
    }
}
