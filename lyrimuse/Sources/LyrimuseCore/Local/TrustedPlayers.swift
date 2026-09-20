import Foundation

public enum TrustedPlayers {
    private struct MinimalFeatureFlags: Decodable {
        let trusted_players: [String: String]?
    }

    private static let featuresURL = LyrimusePaths.configFile("lyrimuse-features.json")

    public static var current: [String: String] {
        guard let data = try? Data(contentsOf: featuresURL),
              let f = try? JSONDecoder().decode(MinimalFeatureFlags.self, from: data),
              let map = f.trusted_players
        else { return [:] }
        return map
    }

    public static func isTrusted(_ bundleID: String?) -> Bool {
        isTrusted(bundleID, trusted: current)
    }

    public static func isTrusted(_ bundleID: String?, trusted: [String: String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if trusted[bundleID] != nil { return true }
        if let owner = mediaProxyOwner(of: bundleID), trusted[owner] != nil { return true }
        return false
    }

    public static func isAccepted(_ bundleID: String?) -> Bool {
        isAccepted(bundleID, trusted: current)
    }

    public static func isAccepted(_ bundleID: String?, trusted: [String: String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if PlaybackPlayer.allCases.contains(where: { $0 != .auto && $0.bundleIdentifier == bundleID }) {
            return true
        }
        return isTrusted(bundleID, trusted: trusted)
    }

    public static let mediaProxyOwners: [String: String] = [
        "com.apple.WebKit.GPU": "com.apple.Safari",
    ]

    public static func mediaProxyOwner(of bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return mediaProxyOwners[bundleID]
    }

    public static func notASong(bundleID: String?, artist: String?, album: String?) -> Bool {
        notASong(bundleID: bundleID, artist: artist, album: album, trusted: current)
    }

    public static func notASong(bundleID: String?, artist: String?, album: String?,
                                trusted: [String: String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }

        if PlaybackPlayer.allCases.contains(where: { $0 != .auto && $0.bundleIdentifier == bundleID }) {
            return false
        }

        guard isTrusted(bundleID, trusted: trusted) else { return false }
        func blank(_ s: String?) -> Bool {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return blank(artist) || blank(album)
    }
}
