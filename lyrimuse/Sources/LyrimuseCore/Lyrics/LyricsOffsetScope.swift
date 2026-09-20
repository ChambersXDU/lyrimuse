import Foundation

public enum LyricsOffsetScope {

    public static let allPlayersTag = ""

    public static func options(builtInOrder: [PlaybackPlayer] = PlaybackPlayer.allCases,
                              trusted: [String: String],
                              configured: Set<String>,
                              nowPlaying: String?) -> [String] {
        var ids: [String] = []
        func append(_ id: String) {
            guard !id.isEmpty, !ids.contains(id) else { return }
            ids.append(id)
        }
        for player in builtInOrder where player != .auto {
            append(player.bundleIdentifier)
        }
        for id in trusted.keys.sorted() { append(id) }
        for id in configured.sorted() { append(id) }
        if let nowPlaying { append(nowPlaying) }
        return ids
    }
}
