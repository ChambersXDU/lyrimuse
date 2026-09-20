import Foundation

public enum PlayCountUnavailableBackoff {

    public static let delays: [TimeInterval] = [60 * 60, 6 * 60 * 60, 24 * 60 * 60]

    public static func delay(strikes: Int) -> TimeInterval {
        guard strikes >= 1 else { return delays[0] }
        return delays[min(strikes, delays.count) - 1]
    }

    public static func isDue(markedAt: Date, strikes: Int, now: Date) -> Bool {
        now.timeIntervalSince(markedAt) >= delay(strikes: strikes)
    }
}
