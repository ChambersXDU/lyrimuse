import Foundation

public enum CompactLyricLead {

    public static let revealMs = 5000

    public enum Outcome: Equatable {

        case line(Int)

        case placeholder
    }

    public static func resolve(activeIdx: Int, posMs: Int,
                               lineEndMs: Int?, nextStartMs: Int?) -> Outcome {

        guard activeIdx >= 0 else { return .line(activeIdx) }

        guard let end = lineEndMs, posMs >= end else { return .line(activeIdx) }

        guard let next = nextStartMs else { return .line(activeIdx) }

        if posMs >= next - revealMs { return .line(activeIdx + 1) }

        return .placeholder
    }

    public static func displayDurationMs(prevLineEndMs: Int?, startMs: Int,
                                         lineEndMs: Int?, nextStartMs: Int?,
                                         fallbackEndMs: Int?) -> Int? {
        let appear = appearMs(prevLineEndMs: prevLineEndMs, startMs: startMs)
        let vanish: Int?
        if let end = lineEndMs, nextStartMs != nil {
            vanish = end
        } else if let next = nextStartMs {
            vanish = next
        } else {
            vanish = fallbackEndMs
        }
        guard let v = vanish, v > appear else { return nil }
        return v - appear
    }

    static func appearMs(prevLineEndMs: Int?, startMs: Int) -> Int {

        guard let prevEnd = prevLineEndMs else { return startMs }
        return min(startMs, max(prevEnd, startMs - revealMs))
    }

    public static func leadInMs(prevLineEndMs: Int?, startMs: Int) -> Int {
        max(0, startMs - appearMs(prevLineEndMs: prevLineEndMs, startMs: startMs))
    }
}
