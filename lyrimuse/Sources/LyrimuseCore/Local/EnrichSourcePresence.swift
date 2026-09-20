import Foundation

public enum EnrichSourcePresence {
    public static func knownOnSources(neteaseURL: String?, qqMusicURL: String?) -> Bool {
        if let n = neteaseURL, !n.isEmpty { return true }
        if let q = qqMusicURL, q.contains("/songDetail/") { return true }
        return false
    }

    public static func lastRoundHadNoResponder(hasDecisionRecord: Bool, respondedCount: Int) -> Bool {
        hasDecisionRecord && respondedCount == 0
    }
}
