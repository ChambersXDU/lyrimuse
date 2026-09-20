import Foundation

public enum MusicPlaybackController {
    @MainActor
    public static func playPause() {
        dispatch(appleScript: #"tell application "Music" to playpause"#, mediaControlCommand: "toggle-play-pause")
    }

    @MainActor
    public static func nextTrack() {
        dispatch(appleScript: #"tell application "Music" to next track"#, mediaControlCommand: "next-track")
    }

    @MainActor
    public static func previousTrack() {
        dispatch(appleScript: #"tell application "Music" to previous track"#, mediaControlCommand: "previous-track")
    }

    private static let favoritedPropertyNames = ["favorited", "loved"]

    public static func favoritedState() -> Bool? {
        for name in favoritedPropertyNames {
            guard let out = runAppleScriptCapturing(
                #"tell application "Music" to get \#(name) of current track"#
            ) else { continue }
            switch out.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "true": return true
            case "false": return false
            default: continue
            }
        }
        return nil
    }

    @discardableResult
    public static func setFavorited(_ value: Bool) -> Bool {
        for name in favoritedPropertyNames {
            if runAppleScriptCapturing(
                #"tell application "Music" to set \#(name) of current track to \#(value)"#
            ) != nil {
                return true
            }
        }
        return false
    }

    @discardableResult
    public static func addCurrentTrackToLibrary() -> Bool {
        runAppleScriptCapturing(#"""
        tell application "Music"
            try
                duplicate current track to source 1
            on error
                duplicate current track to library playlist 1
            end try
            return "ok"
        end tell
        """#) != nil
    }

    public static func currentTrackIsInLibrary() -> Bool? {
        guard let out = runAppleScriptCapturing(#"""
        tell application "Music"
            set t to current track
            set tName to name of t
            set tArtist to artist of t
            set tAlbum to album of t
            if tAlbum is not "" then
                return (count of (every track of library playlist 1 whose name is tName and artist is tArtist and album is tAlbum)) > 0
            end if
            return (count of (every track of library playlist 1 whose name is tName and artist is tArtist)) > 0
        end tell
        """#) else { return nil }
        if out.contains("true") { return true }
        if out.contains("false") { return false }
        return nil
    }

    @discardableResult
    public static func removeCurrentTrackFromLibrary() -> Bool {
        runAppleScriptCapturing(#"""
        tell application "Music"
            set t to current track
            set tName to name of t
            set tArtist to artist of t
            set tAlbum to album of t
            set matches to {}
            if tAlbum is not "" then
                set matches to (every track of library playlist 1 whose name is tName and artist is tArtist and album is tAlbum)
            end if
            if (count of matches) is 0 then
                set matches to (every track of library playlist 1 whose name is tName and artist is tArtist)
            end if
            if (count of matches) is 0 then error "not in library"
            delete (item 1 of matches)
            return "ok"
        end tell
        """#) != nil
    }

    public static func resumePlayback(lastTitle: String?, lastArtist: String?) -> Bool {
        _ = runAppleScriptCapturing(#"tell application "Music" to play"#)
        if let state = runAppleScriptCapturing(#"tell application "Music" to player state as text"#),
           state.contains("playing") {
            return true
        }
        guard let title = lastTitle, !title.isEmpty else { return false }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        var whose = "name is \"\(esc(title))\""
        if let artist = lastArtist, !artist.isEmpty {
            whose += " and artist is \"\(esc(artist))\""
        }
        return runAppleScriptCapturing("""
        tell application "Music"
            play (first track of library playlist 1 whose \(whose))
            return "ok"
        end tell
        """) != nil
    }

    @discardableResult
    public static func resumeSpotifyPlayback() -> Bool {
        runAppleScriptCapturing(#"tell application "Spotify" to play"#) != nil
    }

    @discardableResult
    public static func setDisliked(_ value: Bool) -> Bool {
        runAppleScriptCapturing(
            #"tell application "Music" to set disliked of current track to \#(value)"#
        ) != nil
    }

    public static func currentTrackDisliked() -> Bool? {
        guard let out = runAppleScriptCapturing(
            #"tell application "Music" to get disliked of current track"#
        ) else { return nil }
        if out.contains("true") { return true }
        if out.contains("false") { return false }
        return nil
    }

    @discardableResult
    public static func revealCurrentTrack() -> Bool {
        runAppleScriptCapturing(#"""
        tell application "Music"
            reveal current track
            activate
        end tell
        """#) != nil
    }

    public static func spotifyCurrentTrackURI() -> String? {
        guard let out = runAppleScriptCapturing(
            spotifyRunningGuard + #"tell application "Spotify" to return (spotify url of current track) as text"#
        ) else { return nil }
        let uri = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return uri.isEmpty ? nil : uri
    }

    public enum MusicPlaybackMode: String, CaseIterable, Sendable {
        case list
        case shuffle
        case repeatOne

        case repeatAll

        public func next(allowsRepeatOne: Bool) -> MusicPlaybackMode {
            switch self {
            case .list: return .shuffle
            case .shuffle: return allowsRepeatOne ? .repeatOne : .list
            case .repeatOne: return .list

            case .repeatAll: return allowsRepeatOne ? .repeatOne : .list
            }
        }
    }

    public static func supportsExtendedControls(_ player: PlaybackPlayer) -> Bool {
        player == .appleMusic || player == .spotify
    }

    public static func supportsRepeatOne(_ player: PlaybackPlayer) -> Bool {
        player == .appleMusic
    }

    private static let spotifyRunningGuard = #"""
        if application "Spotify" is not running then
            return ""
        end if

        """#

    private static let spotifyModePartScript = #"""
        tell application "Spotify"
            set modePart to "nil"
            try
                set modePart to (shuffling as text)
            end try
            set gatePart to "true"
            try
                set gatePart to (shuffling enabled as text)
            end try
            return modePart & ";" & gatePart
        end tell
        """#

    public struct ExtendedControlsState {
        public let favorited: Bool?
        public let mode: MusicPlaybackMode?
        public let volume: Int?
        public static let empty = ExtendedControlsState(favorited: nil, mode: nil, volume: nil)
    }

    public static func extendedControlsState(
        for player: PlaybackPlayer, includeFavorited: Bool
    ) -> ExtendedControlsState {
        let script: String
        switch player {
        case .appleMusic:
            script = #"""
                tell application "Music"
                    set favPart to "nil"
                    try
                        set favPart to ((favorited of current track) as text)
                    on error
                        try
                            set favPart to ((loved of current track) as text)
                        end try
                    end try
                    set modePart to "nil"
                    try
                        set modePart to (shuffle enabled as text) & ";" & (song repeat as text)
                    end try
                    set volPart to "nil"
                    try
                        set volPart to (sound volume as text)
                    end try
                    return favPart & "|" & modePart & "|" & volPart
                end tell
                """#
        case .spotify:

            script = spotifyRunningGuard + #"""
                tell application "Spotify"
                    set modePart to "nil"
                    try
                        set modePart to (shuffling as text)
                    end try
                    set gatePart to "true"
                    try
                        set gatePart to (shuffling enabled as text)
                    end try
                    set volPart to "nil"
                    try
                        set volPart to (sound volume as text)
                    end try
                    return "nil|" & modePart & ";" & gatePart & "|" & volPart
                end tell
                """#
        case .qqMusic, .netease, .kugou, .auto:
            return .empty
        }
        guard let out = runAppleScriptCapturing(script) else { return .empty }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "|")
        guard parts.count == 3 else { return .empty }
        var favorited: Bool?
        if includeFavorited {

            if parts[0] == "true" { favorited = true } else if parts[0] == "false" { favorited = false }
        }
        var mode: MusicPlaybackMode?
        switch player {
        case .appleMusic:

            let m = parts[1].split(separator: ";")
            if m.count == 2 {
                if m[1] == "one" {
                    mode = .repeatOne
                } else if m[0] == "true" {
                    mode = .shuffle
                } else if m[1] == "all" {
                    mode = .repeatAll
                } else {
                    mode = .list
                }
            }
        case .spotify:
            mode = spotifyPlaybackMode(fromModePart: parts[1])
        default:
            break
        }
        return ExtendedControlsState(favorited: favorited, mode: mode, volume: Int(parts[2]))
    }

    public static func spotifyPlaybackMode(fromModePart part: String) -> MusicPlaybackMode? {
        let fields = part.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let shuffling = fields.first else { return nil }
        if fields.count >= 2, fields[1] == "false" { return nil }
        switch shuffling {
        case "true": return .shuffle
        case "false": return .list
        default: return nil
        }
    }

    public static func playbackMode(for player: PlaybackPlayer) -> MusicPlaybackMode? {
        switch player {
        case .appleMusic:
            guard let out = runAppleScriptCapturing(
                #"tell application "Music" to return (shuffle enabled as text) & "," & (song repeat as text)"#
            ) else { return nil }
            let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
            guard parts.count == 2 else { return nil }
            if parts[1] == "one" { return .repeatOne }
            if parts[0] == "true" { return .shuffle }
            if parts[1] == "all" { return .repeatAll }
            return .list
        case .spotify:

            guard let out = runAppleScriptCapturing(spotifyRunningGuard + spotifyModePartScript) else { return nil }
            return spotifyPlaybackMode(fromModePart: out.trimmingCharacters(in: .whitespacesAndNewlines))
        case .qqMusic, .netease, .kugou, .auto:
            return nil
        }
    }

    @discardableResult
    public static func setPlaybackMode(_ mode: MusicPlaybackMode, for player: PlaybackPlayer) -> Bool {
        switch player {
        case .appleMusic:
            let script: String
            switch mode {
            case .list:
                script = #"""
                    tell application "Music"
                        set shuffle enabled to false
                        if song repeat is one then set song repeat to off
                    end tell
                    """#
            case .shuffle:
                script = #"""
                    tell application "Music"
                        set shuffle enabled to true
                        if song repeat is one then set song repeat to off
                    end tell
                    """#
            case .repeatOne:
                script = #"""
                    tell application "Music"
                        set shuffle enabled to false
                        set song repeat to one
                    end tell
                    """#
            case .repeatAll:

                script = #"""
                    tell application "Music"
                        set shuffle enabled to false
                        set song repeat to all
                    end tell
                    """#
            }
            return runAppleScriptCapturing(script) != nil
        case .spotify:

            guard mode != .repeatOne, mode != .repeatAll else {

                return false
            }
            return runAppleScriptCapturing(
                spotifyRunningGuard
                    + #"tell application "Spotify" to set shuffling to "#
                    + (mode == .shuffle ? "true" : "false")
            ) != nil
        case .qqMusic, .netease, .kugou, .auto:
            return false
        }
    }

    public static func soundVolume(for player: PlaybackPlayer) -> Int? {
        let script: String
        switch player {
        case .appleMusic:
            script = #"tell application "Music" to get sound volume"#
        case .spotify:

            script = spotifyRunningGuard + #"tell application "Spotify" to get sound volume"#
        case .qqMusic, .netease, .kugou, .auto:
            return nil
        }
        guard let out = runAppleScriptCapturing(script) else { return nil }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    public static func setSoundVolume(_ value: Int, for player: PlaybackPlayer) -> Bool {
        let v = min(100, max(0, value))
        switch player {
        case .appleMusic:
            return runAppleScriptCapturing(
                #"tell application "Music" to set sound volume to \#(v)"#) != nil
        case .spotify:
            return runAppleScriptCapturing(
                spotifyRunningGuard + #"tell application "Spotify" to set sound volume to \#(v)"#) != nil
        case .qqMusic, .netease, .kugou, .auto:
            return false
        }
    }

    @MainActor
    public static func seek(toSeconds seconds: Double, preferAppleScript: Bool = false) {
        let value = seekArgument(forSeconds: seconds)
        let script = #"tell application "Music" to set player position to "# + value
        if preferAppleScript {
            runAppleScript(script)
            return
        }
        dispatch(appleScript: script, mediaControlCommand: "seek", mediaControlArguments: [value])
    }

    public static func seekArgument(forSeconds seconds: Double) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), clamped)
    }

    public static func controlTargetBundleID(
        players: Set<PlaybackPlayer>, resolvedBundleID: String?, trusted: [String: String]
    ) -> String? {
        if players == [.appleMusic] { return PlaybackPlayer.appleMusic.bundleIdentifier }
        if let id = resolvedBundleID, !id.isEmpty {
            let known = PlaybackPlayer.allCases.contains { $0 != .auto && $0.bundleIdentifier == id }
            if (players.contains(.auto) && known)
                || players.contains(where: { $0 != .auto && $0.bundleIdentifier == id })
                || TrustedPlayers.isTrusted(id, trusted: trusted) { return id }
        }
        return players.contains(.auto) ? nil : players.soleExplicitPlayer?.bundleIdentifier
    }

    @MainActor
    public static var currentControlTargetBundleID: String? {
        controlTargetBundleID(players: PlaybackPlayerPreference.selected,
            resolvedBundleID: LocalPlaybackSource.shared.lastResolvedBundleID, trusted: TrustedPlayers.current)
    }

    @MainActor
    private static func dispatch(appleScript: String, mediaControlCommand: String, mediaControlArguments: [String] = []) {
        guard let target = currentControlTargetBundleID else { return }
        if target == PlaybackPlayer.appleMusic.bundleIdentifier {
            runAppleScript(appleScript)
        } else if target == PlaybackPlayer.spotify.bundleIdentifier {
            let command: String
            switch mediaControlCommand {
            case "toggle-play-pause": command = "playpause"
            case "next-track": command = "next track"
            case "previous-track": command = "previous track"
            case "seek": command = "set player position to " + (mediaControlArguments.first ?? "0")
            default: return
            }
            runAppleScript(spotifyRunningGuard + "tell application \"Spotify\" to " + command)
        } else {
            // The helper only supports global commands. Refuse them after a focus change.
            Task.detached {
                guard MediaControlClient.systemPlaybackBundleID() == target else { return }
                runMediaControl(mediaControlCommand, arguments: mediaControlArguments)
            }
        }
    }

    static let appleScriptTimeout: TimeInterval = 5

    private static func runAppleScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func runAppleScriptCapturing(_ script: String) -> String? {

        guard let r = ProcessRunner.run(
            "/usr/bin/osascript", ["-e", script], timeout: appleScriptTimeout),
            r.succeeded
        else { return nil }
        return r.stdoutText
    }

    private static func runMediaControl(_ command: String, arguments: [String] = []) {
        guard let binaryPath = MediaControlClient.binaryPath() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [command] + arguments
        try? process.run()
    }
}
