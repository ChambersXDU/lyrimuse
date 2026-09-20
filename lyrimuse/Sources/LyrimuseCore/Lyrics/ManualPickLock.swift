import CryptoKit
import Foundation

public enum ManualPickLock {

    public static func canonicalLyrics(_ lyrics: String) -> String {
        var out: [String] = []

        for rawScalars in lyrics.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(String.UnicodeScalarView(rawScalars))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            while line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                line = line[line.index(after: end)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.isEmpty { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    public static func fingerprint(lyrics: String) -> String {
        let canonical = canonicalLyrics(lyrics)

        guard !canonical.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    public enum PickState: Equatable {

        case neverPicked

        case replaced

        case original
    }

    public static func state(sha: String?, lyrics: String) -> PickState {
        guard let sha, !sha.isEmpty else { return .neverPicked }
        return sha == fingerprint(lyrics: lyrics) ? .original : .replaced
    }

    public static func shouldFlip(
        sha: String?, lyrics: String, isLocked: Bool, locking: Bool
    ) -> Bool {
        state(sha: sha, lyrics: lyrics) == .original && isLocked != locking
    }
}
