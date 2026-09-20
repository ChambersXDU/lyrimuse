import CoreGraphics
import Foundation

public enum MarqueeMath {

    public static func overflow(contentWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        contentWidth - containerWidth
    }

    public static let deadZone: CGFloat = 4

    public static func isOverflowing(contentWidth: CGFloat, containerWidth: CGFloat) -> Bool {
        containerWidth > 0
            && overflow(contentWidth: contentWidth, containerWidth: containerWidth) > deadZone
    }

    public static func trailingFadeWidth(configured: CGFloat,
                                         contentWidth: CGFloat,
                                         containerWidth: CGFloat,
                                         offset: CGFloat) -> CGFloat {
        guard configured > 0,
              offset == 0,
              isOverflowing(contentWidth: contentWidth, containerWidth: containerWidth) else { return 0 }

        return min(configured, containerWidth / 2)
    }
}
