import AppKit
import LyrimuseCore

@MainActor
enum IdlePlaybackActions {

    static var player: PlaybackPlayer {
        if let only = PlaybackPlayerPreference.soleExplicitPlayer { return only }
        if let bid = UserDefaults.standard.string(forKey: "np:lastPlayerBundleID"),
           let p = PlaybackPlayer.allCases.first(where: { $0 != .auto && $0.bundleIdentifier == bid }) {
            return p
        }
        return .appleMusic
    }

    static func canResume(_ player: PlaybackPlayer) -> Bool {
        player == .appleMusic || player == .spotify
    }

    static func resume(player: PlaybackPlayer) {
        let lastTitle = UserDefaults.standard.string(forKey: "np:lastTrackTitle")
        let lastArtist = UserDefaults.standard.string(forKey: "np:lastTrackArtist")
        Task.detached(priority: .userInitiated) {
            var ok = false
            switch player {
            case .appleMusic:
                if await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                    ok = MusicPlaybackController.resumePlayback(
                        lastTitle: lastTitle, lastArtist: lastArtist)
                }
            case .spotify:
                ok = MusicPlaybackController.resumeSpotifyPlayback()
            default:
                ok = false
            }
            if !ok {
                await MainActor.run { openPlayerApp(player) }
            }
        }
    }

    static func openPlayerApp(_ player: PlaybackPlayer) {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: player.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
