import Foundation

public struct ProgressAnchor {
    public let durationMs: Int
    public let progressMs: Int
    public let rate: Double
    public let progressTs: Int?
    public let baseAgeMs: Int?
    public let fetchedAt: Date
    public let correctionMs: Int
    public let fresh: Bool

    public init(durationMs: Int, progressMs: Int, rate: Double, progressTs: Int?, baseAgeMs: Int?, fetchedAt: Date, fresh: Bool, correctionMs: Int = 0) {
        self.durationMs = durationMs
        self.progressMs = progressMs
        self.rate = rate
        self.progressTs = progressTs
        self.baseAgeMs = baseAgeMs
        self.fetchedAt = fetchedAt
        self.fresh = fresh
        self.correctionMs = correctionMs
    }

    public var correctionEndDate: Date? {
        guard correctionMs != 0, rate > 0 else { return nil }
        return fetchedAt.addingTimeInterval(Double(abs(correctionMs)) / (1000 * rate * 0.2))
    }

    public func instantaneousRate(now: Date = Date()) -> Double {
        guard let end = correctionEndDate, now < end else { return rate }
        return rate * (correctionMs < 0 ? 0.8 : 1.2)
    }

    public static func correctionForContinuousPlayback(
        displayedMs: Int?, targetMs: Int, continuous: Bool
    ) -> Int {
        guard continuous, let displayedMs, abs(targetMs - displayedMs) <= 2000 else { return 0 }
        return targetMs - displayedMs
    }

    public func extrapolatedPositionMs(now: Date = Date()) -> Int {
        let ageMs: Double
        if let base = baseAgeMs {

            ageMs = Double(base) + now.timeIntervalSince(fetchedAt) * 1000
        } else if let ts = progressTs {

            ageMs = now.timeIntervalSince1970 * 1000 - Double(ts)
        } else {
            ageMs = 0
        }
        let cap: Double = fresh ? .infinity : 90000
        var pos = Double(progressMs)
        if rate > 0, ageMs > 0, ageMs < cap {
            pos += ageMs * rate

            let adjustment = min(Double(abs(correctionMs)), ageMs * rate * 0.2)
            pos += correctionMs < 0 ? -adjustment : adjustment
        }
        pos = max(0, min(Double(durationMs), pos))
        return Int(pos)
    }
}
