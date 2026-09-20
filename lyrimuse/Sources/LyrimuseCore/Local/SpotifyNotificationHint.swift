import Foundation

public struct SpotifyNotificationHint: Equatable, Sendable {
    public let trackID: String
    public let name: String
    public let artist: String
    public let receivedAt: Date

    public init(trackID: String, name: String, artist: String, receivedAt: Date = Date()) {
        self.trackID = trackID
        self.name = name
        self.artist = artist
        self.receivedAt = receivedAt
    }

    public init?(userInfo: [AnyHashable: Any]?, receivedAt: Date = Date()) {
        guard let info = userInfo, let id = info["Track ID"] as? String,
              !id.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        self.init(trackID: id.trimmingCharacters(in: .whitespaces),
                  name: (info["Name"] as? String) ?? "",
                  artist: (info["Artist"] as? String) ?? "",
                  receivedAt: receivedAt)
    }

    public var isAd: Bool { trackID.hasPrefix("spotify:ad") }

    public func matches(title: String?, artist snapshotArtist: String?) -> Bool {
        let a = Self.fold(name), b = Self.fold(title ?? "")
        guard !a.isEmpty, a == b else { return false }
        let x = Self.fold(artist), y = Self.fold(snapshotArtist ?? "")
        return x.isEmpty || y.isEmpty || x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }

    static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
