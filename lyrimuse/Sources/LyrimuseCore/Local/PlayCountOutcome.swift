import Foundation

public enum PlayCountOutcome: Equatable {

    case counted(Int)

    case definitivelyNone

    case unanswered

    public static func classify(requestSucceeded: Bool, reportedCount: Int?,
                               rowIsOldEnough: Bool) -> PlayCountOutcome {
        guard requestSucceeded else { return .unanswered }

        guard let n = reportedCount else { return .unanswered }
        if n > 0 { return .counted(n) }
        return rowIsOldEnough ? .definitivelyNone : .unanswered
    }
}
