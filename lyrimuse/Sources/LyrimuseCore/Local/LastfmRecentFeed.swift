import Foundation

public struct LastfmRecentFeed: Equatable, Decodable, Sendable {
    public struct Track: Equatable, Decodable, Sendable {
        public let artist: String
        public let title: String
        public let album: String?

        public let image: String?

        public let uts: TimeInterval?

        public init(artist: String, title: String, album: String? = nil, image: String? = nil, uts: TimeInterval?) {
            self.artist = artist
            self.title = title
            self.album = album
            self.image = image
            self.uts = uts
        }
    }

    public let username: String

    public let fetchedAt: TimeInterval

    public let total: Int
    public let nowPlaying: Track?

    public let tracks: [Track]

    public init(username: String, fetchedAt: TimeInterval, total: Int, nowPlaying: Track?, tracks: [Track]) {
        self.username = username
        self.fetchedAt = fetchedAt
        self.total = total
        self.nowPlaying = nowPlaying
        self.tracks = tracks
    }

    public static let freshWindow: TimeInterval = 180

    public func isFresh(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince1970 - fetchedAt
        return age >= 0 && age < Self.freshWindow
    }

    public static func decode(_ data: Data) -> LastfmRecentFeed? {
        try? JSONDecoder().decode(LastfmRecentFeed.self, from: data)
    }

    public static func totalPages(total: Int, pageSize: Int) -> Int {
        guard pageSize > 0, total > 0 else { return 1 }
        return (total + pageSize - 1) / pageSize
    }

    public static func todayCount(
        rowUTS: [TimeInterval], todayStart: TimeInterval,
        bucketToday: Int?, syncedThrough: TimeInterval
    ) -> (count: Int, exact: Bool) {
        let todayRows = rowUTS.filter { $0 >= todayStart }.count
        if let oldest = rowUTS.min(), oldest < todayStart {
            return (todayRows, true)
        }
        if syncedThrough >= todayStart {
            let afterSync = rowUTS.filter { $0 > syncedThrough }.count
            return (max((bucketToday ?? 0) + afterSync, todayRows), true)
        }
        return (todayRows, false)
    }
}
