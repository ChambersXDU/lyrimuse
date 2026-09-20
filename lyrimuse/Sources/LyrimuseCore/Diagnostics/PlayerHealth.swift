import Foundation

public enum PlayerHealth {
    public enum Warning: Equatable, CaseIterable, Sendable {

        case automationDenied

        case collectorNotRunning
    }

    public struct Inputs: Equatable, Sendable {
        public var appleMusicSelected: Bool
        public var automationDenied: Bool
        public var collectorServiceEnabled: Bool
        public var collectorRunning: Bool

        public init(appleMusicSelected: Bool, automationDenied: Bool,
                    collectorServiceEnabled: Bool, collectorRunning: Bool) {
            self.appleMusicSelected = appleMusicSelected
            self.automationDenied = automationDenied
            self.collectorServiceEnabled = collectorServiceEnabled
            self.collectorRunning = collectorRunning
        }
    }

    public static func warnings(_ inputs: Inputs) -> [Warning] {
        var out: [Warning] = []
        if inputs.collectorServiceEnabled && !inputs.collectorRunning { out.append(.collectorNotRunning) }
        if inputs.appleMusicSelected && inputs.automationDenied { out.append(.automationDenied) }
        return out
    }
}
