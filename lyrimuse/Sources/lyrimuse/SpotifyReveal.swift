import AppKit
import LyrimuseCore
import os

enum SpotifyReveal {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "spotify-reveal")

    static func revealCurrentTrack(fallback: @escaping @MainActor @Sendable () -> Void) {
        Task.detached(priority: .userInitiated) {
            let uri = MusicPlaybackController.spotifyCurrentTrackURI()
            let link = uri.flatMap(SpotifyURI.deepLink)
            await MainActor.run {
                guard let link else {
                    logger.notice("spotify reveal: no deep link for uri=\(uri ?? "nil", privacy: .public); activating the app instead")
                    fallback()
                    return
                }
                open(link)
            }
        }
    }

    @MainActor
    private static func open(_ link: URL) {
        let bundleID = PlaybackPlayer.spotify.bundleIdentifier
        let appURL = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let appURL else {
            logger.notice("spotify reveal: Spotify.app not found, opening \(link.absoluteString, privacy: .public) by scheme")
            NSWorkspace.shared.open(link)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error {
                logger.notice("spotify reveal: \(link.absoluteString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            } else {
                logger.notice("spotify reveal: opened \(link.absoluteString, privacy: .public) in \(appURL.path, privacy: .public)")
            }
        }
    }
}
