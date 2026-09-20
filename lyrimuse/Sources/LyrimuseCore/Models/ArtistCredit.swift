import Foundation

public enum ArtistCredit {

    private static let separators: Set<Character> = ["、", "&", ",", "，"]

    private static let featMarkers = ["feat.", "feat ", "ft.", "ft ", "featuring"]

    public static func primary(_ artist: String) -> String? {
        let trimmed = artist.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var head = trimmed

        for marker in featMarkers {
            var from = trimmed.startIndex
            while let r = trimmed.range(of: marker, options: [.caseInsensitive],
                                        range: from..<trimmed.endIndex) {
                from = r.upperBound

                if r.lowerBound > trimmed.startIndex {
                    let prev = trimmed[trimmed.index(before: r.lowerBound)]
                    guard prev.isWhitespace || "([（".contains(prev) else { continue }
                }
                let cut = String(trimmed[trimmed.startIndex..<r.lowerBound])
                if cut.count < head.count { head = cut }
                break
            }
        }
        head = head.trimmingCharacters(in: CharacterSet(charactersIn: " ([（"))
            .trimmingCharacters(in: .whitespaces)

        if let idx = head.firstIndex(where: { separators.contains($0) }) {
            head = String(head[head.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
        } else if let idx = head.firstIndex(of: "/") {
            let candidate = String(head[head.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            if slashHeadIsPlausible(candidate) { head = candidate }
        }
        guard !head.isEmpty, head.count < trimmed.count else { return nil }
        return head
    }

    private static func slashHeadIsPlausible(_ head: String) -> Bool {
        guard !head.isEmpty else { return false }
        let hasHan = head.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return head.count >= (hasHan ? 2 : 3)
    }

    public static func mergeArtist(_ artist: String) -> String {
        primary(artist) ?? artist.trimmingCharacters(in: .whitespaces)
    }

    public static func albumConsensusKey(artist: String, album: String?) -> String? {
        guard let album = album?.trimmingCharacters(in: .whitespaces), !album.isEmpty else { return nil }
        return mergeArtist(artist).lowercased() + "|" + album.lowercased()
    }

    public static func albumConsensusCovers(
        rows: [(artist: String, album: String?, image: URL?)]
    ) -> [String: URL] {
        var tally: [String: [(url: URL, count: Int, firstIndex: Int)]] = [:]
        for (i, row) in rows.enumerated() {
            guard let image = row.image,
                  let key = albumConsensusKey(artist: row.artist, album: row.album) else { continue }
            var bucket = tally[key] ?? []
            if let pos = bucket.firstIndex(where: { $0.url == image }) {
                bucket[pos].count += 1
            } else {
                bucket.append((image, 1, i))
            }
            tally[key] = bucket
        }
        var out: [String: URL] = [:]
        for (key, bucket) in tally {
            guard let best = bucket.max(by: { a, b in
                a.count != b.count ? a.count < b.count : a.firstIndex > b.firstIndex
            }), best.count >= 2 else { continue }
            out[key] = best.url
        }
        return out
    }
}
