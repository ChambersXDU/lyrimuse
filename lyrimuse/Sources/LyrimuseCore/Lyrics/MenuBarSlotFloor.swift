import CoreGraphics
import Foundation

public struct MenuBarSlotFloor: Sendable, Equatable {
    private var trackKey: String?
    private var floor: CGFloat = 0

    public init() {}

    public mutating func width(target: CGFloat, preparedWidth: CGFloat = 0,
                               maxWidth: CGFloat = .greatestFiniteMagnitude, trackKey: String) -> CGFloat {
        guard !target.isNaN else { return floor }
        let clampedTarget = max(0, min(maxWidth, max(target, preparedWidth)))
        if trackKey != self.trackKey {
            self.trackKey = trackKey
            floor = clampedTarget
            didResetOnLastCall = true
        } else {
            didResetOnLastCall = false
        }
        floor = min(maxWidth, max(floor, clampedTarget))
        return floor
    }

    public private(set) var didResetOnLastCall = false

    public mutating func reset() {
        trackKey = nil
        floor = 0
        didResetOnLastCall = true
    }

}
