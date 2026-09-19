import CoreGraphics
import Foundation

/// Per-song floor ensuring monotonic slot width (expanding only) in adaptive lyrics mode
/// to eliminate menu bar icon oscillation (upstream 761df776).
///
/// In adaptive width mode, status item width adapts to lyric line lengths. Because macOS
/// menu bar items reposition neighbouring items upon rebuild, oscillating between widths
/// causes visible jitter. This floor ensures width only expands within the same song
/// and only resets across song boundaries (`trackKey`).
public struct MenuBarSlotFloor: Sendable, Equatable {
    private var trackKey: String?
    private var floor: CGFloat = 0

    public init() {}

    /// Calculates slot width using both the current line and the premeasured song width.
    /// Reserving future lines at the first frame avoids delayed expansion during a long line.
    ///
    /// When `trackKey` changes, resets floor to `target` and flags `didResetOnLastCall`.
    /// Otherwise, maintains monotonic expansion by returning `max(floor, target)`.
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

    /// Indicates whether the floor was reset due to a track transition during the last call.
    public private(set) var didResetOnLastCall = false

    /// Explicitly resets the floor value and track key.
    public mutating func reset() {
        trackKey = nil
        floor = 0
        didResetOnLastCall = true
    }

    /// Current floor value (0 if uninitialized).
    public var currentFloor: CGFloat { floor }
}
