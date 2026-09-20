import Foundation

public enum RadioTrackClock {

    public static let maxAdvancePerTick: TimeInterval = 30

    public static let maxStartSeed: TimeInterval = 8

    public struct State: Equatable, Sendable {

        public let trackKey: String

        public let position: Double

        public let tickedAt: Date

        public let playing: Bool

        public init(trackKey: String, position: Double, tickedAt: Date, playing: Bool) {
            self.trackKey = trackKey
            self.position = position
            self.tickedAt = tickedAt
            self.playing = playing
        }
    }

    public static func advance(_ state: State?, trackKey: String, playing: Bool, now: Date,
                               startedAt: Date? = nil) -> State {
        guard let state, state.trackKey == trackKey else {
            return State(trackKey: trackKey, position: seedPosition(startedAt: startedAt, now: now),
                         tickedAt: now, playing: playing)
        }
        guard state.playing else {
            return State(trackKey: trackKey, position: state.position, tickedAt: now, playing: playing)
        }
        let raw = now.timeIntervalSince(state.tickedAt)
        let step = min(max(raw, 0), maxAdvancePerTick)
        return State(trackKey: trackKey, position: state.position + step, tickedAt: now, playing: playing)
    }

    public static let tailGraceSecs: TimeInterval = 5

    public static func passedTrackEnd(position: Double, durationSecs: Double?) -> Bool {
        guard let durationSecs, durationSecs > 0 else { return false }
        return position > durationSecs + tailGraceSecs
    }

    public static func seedPosition(startedAt: Date?, now: Date) -> Double {
        guard let startedAt else { return 0 }
        let gap = now.timeIntervalSince(startedAt)
        guard gap > 0 else { return 0 }
        return min(gap, maxStartSeed)
    }
}
