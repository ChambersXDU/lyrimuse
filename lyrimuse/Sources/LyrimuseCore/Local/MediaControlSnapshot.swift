import Foundation

public struct MediaControlSnapshot: Decodable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: Double?
    public let elapsedTime: Double?
    public let playing: Bool?
    public let playbackRate: Double?

    public let isMusicApp: Bool?

    public let bundleIdentifier: String?

    public let anchorElapsedTime: Double?

    public var trackKey: String { Self.trackKey(artist: artist, title: title) }

    public static func trackKey(artist: String?, title: String?) -> String {
        "\(artist ?? "")|\(title ?? "")"
    }

    public func withAlbum(_ newAlbum: String) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: newAlbum, duration: duration,
            elapsedTime: elapsedTime, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime)
    }

    public func withDuration(_ newDuration: Double) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: album, duration: newDuration,
            elapsedTime: elapsedTime, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime)
    }
}
