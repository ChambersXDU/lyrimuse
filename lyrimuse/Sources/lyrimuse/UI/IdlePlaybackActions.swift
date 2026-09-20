import AppKit
import LyrimuseCore

@MainActor
enum IdlePlaybackActions {

    static func canResume(_ player: PlaybackPlayer = .appleMusic) -> Bool { player == .appleMusic }

    static func resume(player: PlaybackPlayer = .appleMusic) {
        let lastTitle = UserDefaults.standard.string(forKey: "np:lastTrackTitle")
        let lastArtist = UserDefaults.standard.string(forKey: "np:lastTrackArtist")
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else { return }
            _ = MusicPlaybackController.resumePlayback(lastTitle: lastTitle, lastArtist: lastArtist)
        }
    }

    static func openPlayerApp(_ player: PlaybackPlayer = .appleMusic) {
        guard player == .appleMusic,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
