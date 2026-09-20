import Foundation

public enum LastfmRecentTracksPage {
    public struct Row: Equatable {
        public let artist: String
        public let title: String

        public let uts: TimeInterval?

        public init(artist: String, title: String, uts: TimeInterval?) {
            self.artist = artist
            self.title = title
            self.uts = uts
        }
    }

    public static func parse(_ json: [String: Any]) -> (rows: [Row], totalPages: Int)? {
        guard let rt = json["recenttracks"] as? [String: Any],
              let attr = rt["@attr"] as? [String: Any]
        else { return nil }
        let totalPages = Int((attr["totalPages"] as? String) ?? "1") ?? 1
        var tracks = (rt["track"] as? [[String: Any]]) ?? []
        if tracks.isEmpty, let single = rt["track"] as? [String: Any] { tracks = [single] }
        let rows: [Row] = tracks.compactMap { t in
            guard let name = t["name"] as? String,
                  let art = (t["artist"] as? [String: Any])?["#text"] as? String
            else { return nil }
            let isNowPlaying = ((t["@attr"] as? [String: Any])?["nowplaying"] as? String) == "true"
            if isNowPlaying { return Row(artist: art, title: name, uts: nil) }
            let uts = (t["date"] as? [String: Any])
                .flatMap { $0["uts"] as? String }
                .flatMap { TimeInterval($0) }
            return Row(artist: art, title: name, uts: uts)
        }
        return (rows, totalPages)
    }
}
