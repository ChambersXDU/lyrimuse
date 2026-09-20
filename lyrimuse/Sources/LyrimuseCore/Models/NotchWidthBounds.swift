import CoreGraphics
import Foundation

public enum NotchWidthBounds {

    public static func expandedWidth(steady: CGFloat, expandedSetting: CGFloat) -> CGFloat {
        max(steady, expandedSetting)
    }

    public static func normalized(steady: Double, expanded: Double) -> (steady: Double, expanded: Double) {
        (steady, max(steady, expanded))
    }
}

public enum NotchWidthRangeDrag {
    public enum Thumb: Equatable, Sendable {
        case steady
        case expanded
    }

    public static func thumb(pressX: CGFloat, steadyX: CGFloat, expandedX: CGFloat, dx: CGFloat) -> Thumb? {
        let toSteady = abs(pressX - steadyX)
        let toExpanded = abs(pressX - expandedX)
        if toSteady < toExpanded { return .steady }
        if toExpanded < toSteady { return .expanded }

        if dx > 0 { return .expanded }
        if dx < 0 { return .steady }
        return nil
    }

    public static func dragging(_ thumb: Thumb, to value: Double,
                                steady: Double, expanded: Double) -> (steady: Double, expanded: Double) {
        switch thumb {
        case .steady: return (min(value, expanded), expanded)
        case .expanded: return (steady, max(value, steady))
        }
    }
}
