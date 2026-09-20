import Foundation

public struct PlatformLinks: Sendable, Equatable {

    public let appleMusic: URL?

    public let qqSong: URL?

    public let qqAlbum: URL?
    public let qqArtist: URL?

    public let neteaseSong: URL?

    public let spotifySong: URL?

    public var isEmpty: Bool {
        appleMusic == nil && qqSong == nil && qqAlbum == nil && qqArtist == nil && neteaseSong == nil && spotifySong == nil
    }

    public init(appleMusic: URL?, qqSong: URL?, qqAlbum: URL?, qqArtist: URL?, neteaseSong: URL?, spotifySong: URL? = nil) {
        self.appleMusic = appleMusic
        self.qqSong = qqSong
        self.qqAlbum = qqAlbum
        self.qqArtist = qqArtist
        self.neteaseSong = neteaseSong
        self.spotifySong = spotifySong
    }

    public enum Platform: String, Sendable, Equatable {
        case appleMusic, qqMusic, netease, spotify
    }

    public func songLink(forPlayerBundleID bundleID: String?, webPlatformID: String? = nil) -> (platform: Platform, url: URL)? {
        if webPlatformID == "spotifyWeb" {
            return spotifySong.map { (.spotify, $0) }
        }
        guard let bundleID, !bundleID.isEmpty else { return nil }
        switch bundleID {
        case PlaybackPlayer.appleMusic.bundleIdentifier: return appleMusic.map { (.appleMusic, $0) }
        case PlaybackPlayer.qqMusic.bundleIdentifier: return qqSong.map { (.qqMusic, $0) }
        case PlaybackPlayer.netease.bundleIdentifier: return neteaseSong.map { (.netease, $0) }
        case PlaybackPlayer.spotify.bundleIdentifier: return spotifySong.map { (.spotify, $0) }
        default: return nil
        }
    }

    public static func spotifyTrackURL(id: String) -> URL? {
        guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return URL(string: "https://open.spotify.com/track/" + id)
    }

    public static func isQQSearchFallback(_ raw: String) -> Bool {
        raw.hasPrefix("https://y.qq.com/n/ryqq/search?")
    }

    public static func qqAlbumURL(mid: String) -> URL? {
        guard isPlausibleQQMid(mid) else { return nil }
        return URL(string: "https://y.qq.com/n/ryqq/albumDetail/" + mid)
    }

    public static func qqArtistURL(mid: String) -> URL? {
        guard isPlausibleQQMid(mid) else { return nil }
        return URL(string: "https://y.qq.com/n/ryqq/singer/" + mid)
    }

    public static func isPlausibleQQMid(_ mid: String) -> Bool {
        guard !mid.isEmpty, mid.count <= 32 else { return false }
        return mid.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
