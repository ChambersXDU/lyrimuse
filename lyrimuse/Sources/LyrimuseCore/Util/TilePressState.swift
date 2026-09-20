import Foundation

public struct TilePressState: Sendable {
    public enum Event: Sendable {

        case down

        case holdElapsed

        case dragOutside

        case dragInside

        case up

        case secondaryClick
    }

    public enum Action: Equatable, Sendable {
        case none

        case primary

        case secondary
    }

    public private(set) var isPressing = false

    private var consumed = false

    private var inside = false

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .down:
            consumed = false
            inside = true
            isPressing = true
            return .none
        case .holdElapsed:

            guard !consumed, inside else { return .none }
            consumed = true
            isPressing = false
            return .secondary
        case .dragOutside:
            inside = false
            isPressing = false
            return .none
        case .dragInside:
            guard !consumed else { return .none }
            inside = true
            isPressing = true
            return .none
        case .up:
            let fire = !consumed && inside
            consumed = true
            isPressing = false
            return fire ? .primary : .none
        case .secondaryClick:
            consumed = true
            isPressing = false
            return .secondary
        }
    }
}
