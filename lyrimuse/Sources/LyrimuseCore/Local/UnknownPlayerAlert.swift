import Foundation

public enum UnknownPlayerAlert {

    public static let freshWindow: TimeInterval = 15

    public static func shouldOffer(
        bundleID: String, artist: String, album: String, observedAt: Date,
        isAutoDetect: Bool, now: Date, isAccepted: (String) -> Bool
    ) -> Bool {
        guard isAutoDetect else { return false }
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }

        guard now.timeIntervalSince(observedAt) < freshWindow else { return false }

        guard !artist.trimmingCharacters(in: .whitespaces).isEmpty,
              !album.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !isAccepted(id)
    }

    public static let mutedForAnnounce: Set<String> = [
        "com.apple.podcasts", "com.apple.TV", "com.apple.iBooksX", "com.apple.news",
        "com.apple.MobileSMS", "com.apple.FaceTime", "com.apple.QuickTimePlayerX",
        "com.apple.Preview", "com.apple.Photos", "com.apple.VoiceMemos",
        "com.apple.WebKit.GPU", "com.apple.controlcenter",
        "com.tencent.xinWeChat",
    ]

    public static let maxAnnounces = 3
    public static let announceCooldown: TimeInterval = 24 * 3600

    public struct AnnounceLog: Codable, Equatable, Sendable {
        public var count: Int
        public var lastAt: Date
        public init(count: Int, lastAt: Date) { self.count = count; self.lastAt = lastAt }
    }

    public static func shouldAnnounce(
        bundleID: String, artist: String, album: String, observedAt: Date,
        isAutoDetect: Bool, now: Date, isAccepted: (String) -> Bool,
        hasDisplayName: Bool, stableFor: TimeInterval, stableHits: Int,
        log: [String: AnnounceLog]
    ) -> Bool {
        guard qualifiesForAnnounce(bundleID: bundleID, artist: artist, album: album,
                                   observedAt: observedAt, isAutoDetect: isAutoDetect, now: now,
                                   isAccepted: isAccepted, hasDisplayName: hasDisplayName,
                                   stableFor: stableFor, stableHits: stableHits) else { return false }
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard let seen = log[id] else { return true }
        guard seen.count < maxAnnounces else { return false }
        return now.timeIntervalSince(seen.lastAt) >= announceCooldown
    }

    public static func qualifiesForAnnounce(
        bundleID: String, artist: String, album: String, observedAt: Date,
        isAutoDetect: Bool, now: Date, isAccepted: (String) -> Bool,
        hasDisplayName: Bool, stableFor: TimeInterval, stableHits: Int
    ) -> Bool {
        guard shouldOffer(bundleID: bundleID, artist: artist, album: album,
                          observedAt: observedAt, isAutoDetect: isAutoDetect, now: now,
                          isAccepted: isAccepted) else { return false }
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !mutedForAnnounce.contains(id) else { return false }
        guard hasDisplayName else { return false }
        return stableFor >= stableWindow && stableHits >= stableHitsNeeded
    }

    public static func nowPlayingDescription(artist: String, title: String) -> String? {
        let parts = [artist, title].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    public static let notchAlertDuration: TimeInterval = 8

    public static let stableWindow: TimeInterval = 6
    public static let stableHitsNeeded = 3
}
