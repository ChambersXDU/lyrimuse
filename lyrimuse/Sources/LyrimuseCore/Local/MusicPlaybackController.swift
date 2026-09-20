import Foundation

public enum MusicPlaybackController {
    @MainActor
    public static func playPause() { runAppleScript(#"tell application "Music" to playpause"#) }

    @MainActor
    public static func nextTrack() { runAppleScript(#"tell application "Music" to next track"#) }

    @MainActor
    public static func previousTrack() { runAppleScript(#"tell application "Music" to previous track"#) }

    private static let favoritedPropertyNames = ["favorited", "loved"]

    public static func favoritedState() -> Bool? {
        for name in favoritedPropertyNames {
            guard let output = runAppleScriptCapturing(#"tell application "Music" to get \#(name) of current track"#) else { continue }
            switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "true": return true
            case "false": return false
            default: continue
            }
        }
        return nil
    }

    @discardableResult
    public static func setFavorited(_ value: Bool) -> Bool {
        favoritedPropertyNames.contains { runAppleScriptCapturing(#"tell application "Music" to set \#($0) of current track to \#(value)"#) != nil }
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
        guard let output = runAppleScriptCapturing(#"""
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
        if output.contains("true") { return true }
        if output.contains("false") { return false }
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
        guard let state = runAppleScriptCapturing(#"tell application "Music" to player state as text"#), state.contains("playing") else { return false }
        return true
    }

    @discardableResult
    public static func setDisliked(_ value: Bool) -> Bool {
        runAppleScriptCapturing(#"tell application "Music" to set disliked of current track to \#(value)"#) != nil
    }

    public static func currentTrackDisliked() -> Bool? {
        guard let output = runAppleScriptCapturing(#"tell application "Music" to get disliked of current track"#) else { return nil }
        if output.contains("true") { return true }
        if output.contains("false") { return false }
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

    public enum MusicPlaybackMode: String, CaseIterable, Sendable {
        case list, shuffle, repeatOne, repeatAll

        public func next(allowsRepeatOne: Bool) -> MusicPlaybackMode {
            switch self {
            case .list: return .shuffle
            case .shuffle: return allowsRepeatOne ? .repeatOne : .list
            case .repeatOne: return .list
            case .repeatAll: return allowsRepeatOne ? .repeatOne : .list
            }
        }
    }

    public static func supportsExtendedControls(_ player: PlaybackPlayer) -> Bool { player == .appleMusic }
    public static func supportsRepeatOne(_ player: PlaybackPlayer) -> Bool { player == .appleMusic }

    public struct ExtendedControlsState {
        public let favorited: Bool?
        public let mode: MusicPlaybackMode?
        public let volume: Int?
        public static let empty = ExtendedControlsState(favorited: nil, mode: nil, volume: nil)
    }

    public static func extendedControlsState(for player: PlaybackPlayer, includeFavorited: Bool) -> ExtendedControlsState {
        guard player == .appleMusic,
              let output = runAppleScriptCapturing(#"""
              tell application "Music"
                  set favPart to "nil"
                  try
                      set favPart to ((favorited of current track) as text)
                  on error
                      try
                          set favPart to ((loved of current track) as text)
                      end try
                  end try
                  set modePart to (shuffle enabled as text) & ";" & (song repeat as text)
                  set volPart to (sound volume as text)
                  return favPart & "|" & modePart & "|" & volPart
              end tell
              """#) else { return .empty }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard parts.count == 3 else { return .empty }
        let favorite: Bool? = includeFavorited ? (parts[0] == "true" ? true : parts[0] == "false" ? false : nil) : nil
        let mode = parseMusicMode(parts[1])
        return ExtendedControlsState(favorited: favorite, mode: mode, volume: Int(parts[2]))
    }

    public static func playbackMode(for player: PlaybackPlayer) -> MusicPlaybackMode? {
        guard player == .appleMusic,
              let output = runAppleScriptCapturing(#"tell application "Music" to return (shuffle enabled as text) & "," & (song repeat as text)"#) else { return nil }
        return parseMusicMode(output.replacingOccurrences(of: ",", with: ";"))
    }

    @discardableResult
    public static func setPlaybackMode(_ mode: MusicPlaybackMode, for player: PlaybackPlayer) -> Bool {
        guard player == .appleMusic else { return false }
        let script: String
        switch mode {
        case .list: script = #"tell application "Music" to set {shuffle enabled, song repeat} to {false, off}"#
        case .shuffle: script = #"tell application "Music" to set {shuffle enabled, song repeat} to {true, off}"#
        case .repeatOne: script = #"tell application "Music" to set {shuffle enabled, song repeat} to {false, one}"#
        case .repeatAll: script = #"tell application "Music" to set {shuffle enabled, song repeat} to {false, all}"#
        }
        return runAppleScriptCapturing(script) != nil
    }

    public static func soundVolume(for player: PlaybackPlayer) -> Int? {
        guard player == .appleMusic, let output = runAppleScriptCapturing(#"tell application "Music" to get sound volume"#) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    public static func setSoundVolume(_ value: Int, for player: PlaybackPlayer) -> Bool {
        guard player == .appleMusic else { return false }
        let volume = min(100, max(0, value))
        return runAppleScriptCapturing(#"tell application "Music" to set sound volume to \#(volume)"#) != nil
    }

    @MainActor
    public static func seek(toSeconds seconds: Double, preferAppleScript: Bool = true) {
        let value = seekArgument(forSeconds: seconds)
        runAppleScript(#"tell application "Music" to set player position to \#(value)"#)
    }

    public static func seekArgument(forSeconds seconds: Double) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), clamped)
    }

    public static func controlTargetBundleID(players: Set<PlaybackPlayer>, resolvedBundleID: String?, trusted: [String: String]) -> String? {
        guard resolvedBundleID == nil || resolvedBundleID == PlaybackPlayer.appleMusic.bundleIdentifier else { return nil }
        return PlaybackPlayer.appleMusic.bundleIdentifier
    }

    @MainActor
    public static var currentControlTargetBundleID: String? { PlaybackPlayer.appleMusic.bundleIdentifier }

    public static let appleScriptTimeout: TimeInterval = 5

    private static func parseMusicMode(_ value: String) -> MusicPlaybackMode? {
        let fields = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ";")
        guard fields.count >= 2 else { return nil }
        if fields[1] == "one" { return .repeatOne }
        if fields[0] == "true" { return .shuffle }
        if fields[1] == "all" { return .repeatAll }
        return .list
    }

    private static func runAppleScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func runAppleScriptCapturing(_ script: String) -> String? {
        guard let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: appleScriptTimeout), result.succeeded else { return nil }
        return result.stdoutText
    }
}
