import CoreGraphics
import Foundation

public enum ProgressFillGeometry {

    public static let minimumVisibleWidth: CGFloat = 4

    public static func visibleWidth(containerWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        let raw = containerWidth * min(1, max(0, fraction))
        return min(containerWidth, max(minimumVisibleWidth, raw))
    }

    public static func leadingOffset(containerWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        return containerWidth - visibleWidth(containerWidth: containerWidth, fraction: fraction)
    }
}
