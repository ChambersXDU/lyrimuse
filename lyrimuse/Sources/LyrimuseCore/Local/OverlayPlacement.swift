import CoreGraphics

public enum OverlayPlacementMode: String, Codable, Hashable, CaseIterable, Sendable {

    case free

    case topCenter

    case bottomCenter

    public var isPreset: Bool { self != .free }

    public var anchorsBottom: Bool { self == .bottomCenter }
}

public enum OverlayPlacement {

    public static let minVisibleWidth: CGFloat = 60
    public static let minVisibleHeight: CGFloat = 30

    public static func isSufficientlyVisible(frame: CGRect, screens: [CGRect]) -> Bool {
        for screen in screens {
            let inter = screen.intersection(frame)
            if inter.isNull { continue }

            let needW = min(minVisibleWidth, frame.width)
            let needH = min(minVisibleHeight, frame.height)
            if inter.width >= needW && inter.height >= needH { return true }
        }
        return false
    }

    public static func clamped(frame: CGRect, into screen: CGRect) -> CGPoint {
        var origin = frame.origin

        origin.x = min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - frame.width))
        origin.y = min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - frame.height))
        return origin
    }

    public static func hostVisibleFrame(of frame: CGRect, screens: [CGRect]) -> CGRect? {
        var best: (frame: CGRect, area: CGFloat)?
        for screen in screens {
            let inter = screen.intersection(frame)
            if inter.isNull || inter.isEmpty { continue }
            let area = inter.width * inter.height
            if let b = best, b.area >= area { continue }
            best = (screen, area)
        }
        return best?.frame
    }

    public struct RestoredPlacement: Equatable {
        public let origin: CGPoint
        public let wasRescued: Bool
        public init(origin: CGPoint, wasRescued: Bool) {
            self.origin = origin
            self.wasRescued = wasRescued
        }
    }

    public static func restored(frame: CGRect, screens: [CGRect]) -> RestoredPlacement {
        if isSufficientlyVisible(frame: frame, screens: screens) {
            return RestoredPlacement(origin: frame.origin, wasRescued: false)
        }

        guard let primary = screens.first else {
            return RestoredPlacement(origin: frame.origin, wasRescued: false)
        }
        return RestoredPlacement(origin: clamped(frame: frame, into: primary), wasRescued: true)
    }

    public static func repositionIfOffscreen(frame: CGRect, screens: [CGRect]) -> CGPoint? {
        guard let primary = screens.first else { return nil }
        if isSufficientlyVisible(frame: frame, screens: screens) { return nil }
        let target = clamped(frame: frame, into: primary)

        if abs(target.x - frame.origin.x) < 0.5 && abs(target.y - frame.origin.y) < 0.5 {
            return nil
        }
        return target
    }

    public static let presetTopMargin: CGFloat = 12

    public static let presetBottomMargin: CGFloat = 12

    public static func presetFrame(mode: OverlayPlacementMode, size: CGSize, visibleFrame: CGRect) -> CGRect? {
        let x = visibleFrame.midX - size.width / 2
        switch mode {
        case .free:
            return nil
        case .topCenter:
            return CGRect(x: x, y: visibleFrame.maxY - presetTopMargin - size.height,
                          width: size.width, height: size.height)
        case .bottomCenter:
            return CGRect(x: x, y: visibleFrame.minY + presetBottomMargin,
                          width: size.width, height: size.height)
        }
    }

    public static func grownFrame(
        current: CGRect, contentHeight: CGFloat, minHeight: CGFloat,
        anchorsBottom: Bool, visibleFrame: CGRect?
    ) -> CGRect {
        let rawHeight = max(minHeight, ceil(contentHeight))
        if anchorsBottom {
            let bottom = current.minY
            let maxHeight = visibleFrame.map { max(minHeight, $0.maxY - bottom) }
            let newHeight = min(rawHeight, maxHeight ?? rawHeight)
            return CGRect(x: current.minX, y: bottom, width: current.width, height: newHeight)
        }
        let top = current.minY + current.height
        let maxHeight = visibleFrame.map { max(minHeight, top - $0.minY) }
        let newHeight = min(rawHeight, maxHeight ?? rawHeight)
        return CGRect(x: current.minX, y: top - newHeight, width: current.width, height: newHeight)
    }
}
