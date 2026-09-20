import Foundation

public enum MusicCatalogSearch {
    public struct Item: Decodable, Sendable {
        public let trackName: String?
        public let artistName: String?
        public let collectionName: String?
        public let trackViewUrl: String?
        public let artistViewUrl: String?
        public let collectionViewUrl: String?

        public let artworkUrl100: String?

        public init(trackName: String?, artistName: String?, collectionName: String?,
                    trackViewUrl: String?, artistViewUrl: String?, collectionViewUrl: String?,
                    artworkUrl100: String? = nil) {
            self.trackName = trackName
            self.artistName = artistName
            self.collectionName = collectionName
            self.trackViewUrl = trackViewUrl
            self.artistViewUrl = artistViewUrl
            self.collectionViewUrl = collectionViewUrl
            self.artworkUrl100 = artworkUrl100
        }
    }

    struct Response: Decodable { let results: [Item] }

    public static func searchURL(title: String, artist: String, storefront: String,
                                 limit: Int = 8) -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")
        c?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "country", value: storefront),
        ]
        return c?.url
    }

    public static func pickBest(_ items: [Item], title: String, artist: String) -> Item? {
        func norm(_ s: String?) -> String {
            (s ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        }
        func looseContains(_ a: String, _ b: String) -> Bool {
            guard !a.isEmpty, !b.isEmpty else { return false }
            return a.contains(b) || b.contains(a)
        }
        let t = norm(title), a = norm(artist)
        if let hit = items.first(where: {
            looseContains(norm($0.trackName), t) && looseContains(norm($0.artistName), a)
        }) { return hit }

        if let hit = items.first(where: { norm($0.artistName) == a }) { return hit }
        if let hit = items.first(where: { looseContains(norm($0.artistName), a) }) { return hit }
        return items.first
    }

    public enum ArtworkConfidence: String, Sendable {

        case albumMatch

        case trackOnly
    }

    public struct ArtworkMatch: Sendable {
        public let url: URL
        public let confidence: ArtworkConfidence
        public let matchedAlbum: String?
    }

    public static func upscaleArtwork(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    public static func pickArtwork(_ items: [Item], title: String, artist: String,
                                   album: String?) -> ArtworkMatch? {
        let want = PlayCountFold.familyKey(artist: artist, title: title)
        let wantAlbum = album.map { PlayCountFold.foldTitle($0) } ?? ""
        var fallback: ArtworkMatch?
        for item in items {
            guard let itemArtist = item.artistName, let itemTitle = item.trackName,
                  PlayCountFold.familyKey(artist: itemArtist, title: itemTitle) == want,
                  let url = upscaleArtwork(item.artworkUrl100)
            else { continue }
            if !wantAlbum.isEmpty, PlayCountFold.foldTitle(item.collectionName ?? "") == wantAlbum {
                return ArtworkMatch(url: url, confidence: .albumMatch,
                                    matchedAlbum: item.collectionName)
            }

            if fallback == nil {
                fallback = ArtworkMatch(url: url, confidence: .trackOnly,
                                        matchedAlbum: item.collectionName)
            }
        }
        return fallback
    }

    public static func resolveArtwork(title: String, artist: String, album: String?,
                                      storefront: String) async -> ArtworkMatch? {
        guard let url = searchURL(title: title, artist: artist, storefront: storefront, limit: 12)
        else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let start = Date()
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            NetworkAuditLog.record(service: "itunes", operation: "itunes.search", host: url.host ?? "itunes.apple.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
        let status = (resp as? HTTPURLResponse)?.statusCode
        NetworkAuditLog.record(service: "itunes", operation: "itunes.search", host: url.host ?? "itunes.apple.com",
                               statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
        guard status == 200, let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        return pickArtwork(decoded.results, title: title, artist: artist, album: album)
    }

    public static func musicSchemeURL(_ httpsURL: String?) -> URL? {
        guard let httpsURL, httpsURL.hasPrefix("https://music.apple.com/") else { return nil }
        return URL(string: "music" + httpsURL.dropFirst("https".count))
    }

    public static func resolve(title: String, artist: String, storefront: String) async -> Item? {
        guard let url = searchURL(title: title, artist: artist, storefront: storefront) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let start = Date()
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            NetworkAuditLog.record(service: "itunes", operation: "itunes.search", host: url.host ?? "itunes.apple.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
        let status = (resp as? HTTPURLResponse)?.statusCode
        NetworkAuditLog.record(service: "itunes", operation: "itunes.search", host: url.host ?? "itunes.apple.com",
                               statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
        guard status == 200, let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        return pickBest(decoded.results, title: title, artist: artist)
    }
}
