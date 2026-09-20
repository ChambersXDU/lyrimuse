import Foundation

public enum RecentPlayOrdinal {

    public static func ordinals(
        rows: [(artist: String, title: String)],
        totals: [String: Int],
        playCountKey: (String, String) -> String
    ) -> [Int?] {
        var newerSame: [String: Int] = [:]
        return rows.map { row in
            let familyKey = PlayCountFold.familyKey(artist: row.artist, title: row.title)
            let newer = newerSame[familyKey, default: 0]
            newerSame[familyKey] = newer + 1
            guard let total = totals[playCountKey(row.artist, row.title)] else { return nil }
            let n = total - newer
            return n > 0 ? n : nil
        }
    }
}
