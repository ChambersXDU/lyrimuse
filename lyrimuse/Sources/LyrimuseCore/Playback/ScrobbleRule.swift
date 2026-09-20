import Foundation

public enum ScrobbleRule {

    public static let capSecs: Double = 240

    public static let minTrackSecs: Double = 30

    public static func thresholdFraction(durationMs: Int) -> Double? {
        let duration = Double(durationMs) / 1000
        guard duration >= minTrackSecs else { return nil }
        return min(duration / 2, capSecs) / duration
    }
}
