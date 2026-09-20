import CoreGraphics
import Foundation

public enum NotchReveal {

    public static func startWidthFraction(notchWidth: CGFloat, cardWidth: CGFloat) -> CGFloat {
        guard cardWidth > 0 else { return 1 }
        return min(0.9, max(0.12, notchWidth / cardWidth))
    }

    public static func startHeightFraction(topRowHeight: CGFloat, cardHeight: CGFloat) -> CGFloat {
        guard cardHeight > 0 else { return 1 }
        return min(0.9, max(0.1, topRowHeight / cardHeight))
    }

    public static let widthDuration: Double = 0.20

    public static let heightDelay: Double = 0.06
    public static let heightDuration: Double = 0.24

    public static let contentDelay: Double = 0.10
    public static let contentDuration: Double = 0.16

    public static var totalDuration: Double {
        max(widthDuration, heightDelay + heightDuration, contentDelay + contentDuration)
    }
}
