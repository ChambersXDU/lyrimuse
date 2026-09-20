import Foundation

public enum SpotifyArtworkURL {
    public enum Variant: String, CaseIterable, Sendable {
        case tiny = "4851"
        case small = "1e02"
        case large = "b273"
        case original = "82c1"
    }

    static let exactHosts: Set<String> = ["i.scdn.co"]
    static let hostSuffix = ".spotifycdn.com"

    static let pathPrefix = "/image/ab67616d0000"

    static let minHashLength = 16

    public static func parse(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let url = URL(string: s),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), isSpotifyImageHost(host),
              components(ofPath: url.path) != nil
        else { return nil }
        return url
    }

    public static func isSpotifyImageHost(_ host: String) -> Bool {
        exactHosts.contains(host) || (host.hasSuffix(hostSuffix) && host.count > hostSuffix.count)
    }

    static func components(ofPath path: String) -> (variant: String, hash: String)? {
        guard path.hasPrefix(pathPrefix) else { return nil }
        let rest = path.dropFirst(pathPrefix.count)
        guard rest.count >= 4 + minHashLength else { return nil }
        let variant = String(rest.prefix(4))
        let hash = String(rest.dropFirst(4))
        guard isHex(variant), isHex(hash) else { return nil }
        return (variant, hash)
    }

    private static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    public static func variant(_ url: URL, _ v: Variant) -> URL? {
        guard let host = url.host?.lowercased(), isSpotifyImageHost(host),
              let parts = components(ofPath: url.path),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        comps.path = pathPrefix + v.rawValue + parts.hash
        return comps.url
    }

    public static func downloadCandidates(for url: URL) -> [URL] {
        var out: [URL] = []
        for v in [Variant.original, .large] {
            if let u = variant(url, v), !out.contains(u) { out.append(u) }
        }
        return out
    }

    public static func isTrackURI(_ uri: String) -> Bool {
        uri.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("spotify:track:")
    }
}

public enum SpotifyURI {
    static let deepLinkKinds: Set<String> = ["track", "episode"]
    static let idLength = 22

    public static func deepLink(_ uri: String) -> URL? {
        let parts = uri.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify",
              deepLinkKinds.contains(String(parts[1])), isBase62ID(parts[2])
        else { return nil }
        return URL(string: "spotify:\(parts[1]):\(parts[2])")
    }

    static func isBase62ID(_ s: Substring) -> Bool {
        s.count == idLength
            && s.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
}
