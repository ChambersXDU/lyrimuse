import Foundation

public enum PlaybackPlayer: String, CaseIterable, Identifiable, Codable, Hashable {
    case appleMusic = "apple_music"
    case qqMusic = "qq_music"
    case netease = "netease_music"

    case kugou = "kugou_music"
    case spotify = "spotify"
    case auto = "auto"

    public var id: Self { self }

    public var bundleIdentifier: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .qqMusic: return "com.tencent.QQMusicMac"
        case .netease: return "com.netease.163music"
        case .kugou: return "com.kugou.mac.Music"
        case .spotify: return "com.spotify.client"
        case .auto: return ""
        }
    }
}

extension Set where Element == PlaybackPlayer {

    public var soleExplicitPlayer: PlaybackPlayer? {
        let specific = subtracting([.auto])
        return specific.count == 1 ? specific.first : nil
    }
}

public enum PlaybackPlayerPreference {
    private struct MinimalFeatureFlags: Decodable {

        let player: String?
        let players: [String]?
    }

    private static let featuresURL = LyrimusePaths.configFile("lyrimuse-features.json")

    public static var selected: Set<PlaybackPlayer> {
        guard let data = try? Data(contentsOf: featuresURL),
              let f = try? JSONDecoder().decode(MinimalFeatureFlags.self, from: data) else {
            return [.auto]
        }
        if let list = f.players, !list.isEmpty {
            let known = Set(list.compactMap(PlaybackPlayer.init(rawValue:)))
            if !known.isEmpty { return known }
        }
        if let raw = f.player, let legacy = PlaybackPlayer(rawValue: raw) {
            return [legacy]
        }
        return [.auto]
    }

    public static var isExclusivelyAppleMusic: Bool { selected == [.appleMusic] }

    public static var soleExplicitPlayer: PlaybackPlayer? { selected.soleExplicitPlayer }
}
