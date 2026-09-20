import Foundation

public enum LyricsCandidateDuplicates {

    public static func firstMatches(_ ordered: [(source: String, fingerprint: String)]) -> [String: String] {
        var anchorBySHA: [String: String] = [:]
        var out: [String: String] = [:]
        for item in ordered {
            guard !item.fingerprint.isEmpty, !item.source.isEmpty else { continue }
            if let anchor = anchorBySHA[item.fingerprint] {
                if anchor != item.source, out[item.source] == nil {
                    out[item.source] = anchor
                }
            } else {
                anchorBySHA[item.fingerprint] = item.source
            }
        }
        return out
    }

    public static func isCurrent(candidateSource: String, candidateFingerprint: String,
                                 currentSource: String?, currentFingerprint: String?) -> Bool {
        guard let currentSource, candidateSource == currentSource else { return false }
        guard let currentFingerprint, !currentFingerprint.isEmpty, !candidateFingerprint.isEmpty else {
            return true
        }
        return currentFingerprint == candidateFingerprint
    }
}
