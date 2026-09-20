import Foundation

public struct FrameRateProbe {

    public static let smoothing = 0.1

    public static let discontinuityThreshold: TimeInterval = 1.0

    private var lastFrameAt: Date?
    private(set) public var smoothedInterval: TimeInterval?

    public init() {}

    public var fps: Double? {
        guard let interval = smoothedInterval, interval > 0 else { return nil }
        return 1 / interval
    }

    public mutating func tick(at now: Date) {
        defer { lastFrameAt = now }
        guard let last = lastFrameAt else { return }
        let delta = now.timeIntervalSince(last)

        guard delta > 0 else { return }
        guard delta <= Self.discontinuityThreshold else {
            smoothedInterval = nil
            return
        }
        guard let current = smoothedInterval else {
            smoothedInterval = delta
            return
        }
        smoothedInterval = current + (delta - current) * Self.smoothing
    }
}
