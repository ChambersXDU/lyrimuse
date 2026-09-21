import Foundation

struct AppleMusicPlaybackSnapshot: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let playing: Bool?
    let playbackRate: Double?
    var trackKey: String { Self.trackKey(artist: artist, title: title) }

    static func trackKey(artist: String?, title: String?) -> String {
        "\(artist ?? "")|\(title ?? "")"
    }
}

public enum MusicPlaybackController {
    public static let appleMusicBundleIdentifier = "com.apple.Music"
    static let appleScriptTimeout: TimeInterval = 5

    private static let snapshotScript = #"""
    (() => {
        const music = Application("Music");
        try {
            if (!music.running()) return JSON.stringify(null);
            const state = music.playerState();
            if (state === "stopped") return JSON.stringify(null);
            const track = music.currentTrack;
            if (!track.exists()) return JSON.stringify(null);
            return JSON.stringify({
                title: track.name(),
                artist: track.artist(),
                album: track.album(),
                duration: track.duration(),
                elapsedTime: music.playerPosition(),
                playing: state === "playing",
                playbackRate: state === "playing" ? 1 : 0
            });
        } catch (error) {
            return JSON.stringify(null);
        }
    })()
    """#

    static func fetchSnapshot() -> AppleMusicPlaybackSnapshot? {
        guard let result = ProcessRunner.run(
            "/usr/bin/osascript", ["-l", "JavaScript", "-e", snapshotScript],
            timeout: appleScriptTimeout), result.succeeded else { return nil }
        return try? JSONDecoder().decode(AppleMusicPlaybackSnapshot.self, from: result.stdout)
    }

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
        favoritedPropertyNames.contains {
            runAppleScriptCapturing(#"tell application "Music" to set \#($0) of current track to \#(value)"#) != nil
        }
    }

    public enum MusicPlaybackMode: String, Sendable {
        case list, shuffle, repeatOne, repeatAll

        public func next() -> MusicPlaybackMode {
            switch self {
            case .list: return .shuffle
            case .shuffle: return .repeatOne
            case .repeatOne: return .list
            case .repeatAll: return .repeatOne
            }
        }
    }

    public struct ExtendedControlsState {
        public let favorited: Bool?
        public let mode: MusicPlaybackMode?
        public let volume: Int?
        public static let empty = ExtendedControlsState(favorited: nil, mode: nil, volume: nil)
    }

    public static func extendedControlsState() -> ExtendedControlsState {
        guard let output = runAppleScriptCapturing(#"""
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
        let favorite: Bool? = parts[0] == "true" ? true : parts[0] == "false" ? false : nil
        return ExtendedControlsState(favorited: favorite, mode: parseMusicMode(parts[1]), volume: Int(parts[2]))
    }

    public static func playbackMode() -> MusicPlaybackMode? {
        guard let output = runAppleScriptCapturing(
            #"tell application "Music" to return (shuffle enabled as text) & "," & (song repeat as text)"#) else { return nil }
        return parseMusicMode(output.replacingOccurrences(of: ",", with: ";"))
    }

    @discardableResult
    public static func setPlaybackMode(_ mode: MusicPlaybackMode) -> Bool {
        let script: String
        switch mode {
        case .list: script = #"tell application "Music" to set {shuffle enabled, song repeat} to {false, off}"#
        case .shuffle: script = #"tell application "Music" to set {shuffle enabled, song repeat} to {true, off}"#
        case .repeatOne: script = #"tell application "Music" to set {shuffle enabled, song repeat} to {false, one}"#
        case .repeatAll: script = #"tell application "Music" to set {shuffle enabled, song repeat} to {false, all}"#
        }
        return runAppleScriptCapturing(script) != nil
    }

    public static func soundVolume() -> Int? {
        guard let output = runAppleScriptCapturing(#"tell application "Music" to get sound volume"#) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    public static func setSoundVolume(_ value: Int) -> Bool {
        let volume = min(100, max(0, value))
        return runAppleScriptCapturing(#"tell application "Music" to set sound volume to \#(volume)"#) != nil
    }

    @MainActor
    public static func seek(toSeconds seconds: Double) {
        let value = seconds.isFinite ? max(0, seconds) : 0
        runAppleScript(#"tell application "Music" to set player position to \#(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value))"#)
    }

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
