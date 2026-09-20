import CoreGraphics
import Foundation

public enum ScrollForwardDecision {

    public static let ttl: TimeInterval = 0.25

    public static let slopPoints: CGFloat = 4

    public static func canReuse(cachedWindow: Int, cachedPoint: CGPoint, cachedAt: Date,
                                window: Int, point: CGPoint, now: Date,
                                ttl: TimeInterval = ttl,
                                slop: CGFloat = slopPoints) -> Bool {
        guard cachedWindow == window else { return false }
        let age = now.timeIntervalSince(cachedAt)
        guard age >= 0, age < ttl else { return false }
        return abs(point.x - cachedPoint.x) <= slop && abs(point.y - cachedPoint.y) <= slop
    }
}
