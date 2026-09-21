import Foundation
import Compression
import CommonCrypto

private enum LyricsProviderError: LocalizedError {
    case invalidURL
    case http(Int)
    case invalidResponse
    case noLyrics

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "invalid URL"
        case .http(let code): return "HTTP \(code)"
        case .invalidResponse: return "invalid response"
        case .noLyrics: return "lyrics not found"
        }
    }
}

private func makeURL(_ base: String, _ query: [(String, String)]) throws -> URL {
    guard var components = URLComponents(string: base) else { throw LyricsProviderError.invalidURL }
    components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
    guard let url = components.url else { throw LyricsProviderError.invalidURL }
    return url
}

private func requestData(
    _ url: URL, method: String = "GET", headers: [String: String] = [:],
    body: Data? = nil, timeout: TimeInterval = 8
) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.httpBody = body
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw LyricsProviderError.invalidResponse }
    guard 200..<300 ~= response.statusCode else { throw LyricsProviderError.http(response.statusCode) }
    return data
}

private func requestJSON<T: Decodable>(
    _ type: T.Type, _ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 8
) async throws -> T {
    let data = try await requestData(url, headers: headers, timeout: timeout)
    return try JSONDecoder().decode(type, from: data)
}

private func normalizeTitleVariants(_ title: String) -> [String] {
    var values = [title]
    if let open = title.firstIndex(of: "("), let close = title.lastIndex(of: ")"), open < close {
        let stripped = String(title[..<open]).trimmingCharacters(in: .whitespaces)
        if !stripped.isEmpty { values.append(stripped) }
    }
    let normalized = LyricsMatcher.normalizedTitle(title)
    if !normalized.isEmpty { values.append(normalized) }
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

private func roughTitleMatch(_ candidate: String, _ query: String) -> Bool {
    let a = LyricsMatcher.normalizedTitle(candidate).replacingOccurrences(of: " ", with: "")
    let b = LyricsMatcher.normalizedTitle(query).replacingOccurrences(of: " ", with: "")
    return !a.isEmpty && !b.isEmpty && (a == b || a.contains(b) || b.contains(a))
}

private func roughArtistMatch(_ candidate: String, _ query: String) -> Bool {
    let a = LyricsMatcher.normalizedArtist(candidate)
    let b = LyricsMatcher.normalizedArtist(query)
    return !a.isEmpty && !b.isEmpty && (a == b || a.contains(b) || b.contains(a)
        || a.split { "/&、,，".contains($0) }.contains { b.contains($0) })
}

private func zlibDecompress(_ data: Data) -> Data? {
    guard !data.isEmpty else { return nil }
    var capacity = max(data.count * 4, 64 * 1024)
    for _ in 0..<6 {
        var output = Data(count: capacity)
        let decoded = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        if decoded > 0 {
            output.removeSubrange(decoded..<output.count)
            return output
        }
        capacity *= 2
    }
    return nil
}

public struct LRCLIBProvider: LyricsProvider {
    public let id = "lrclib"

    public init() {}

    public func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        var lastError: Error?
        for title in normalizeTitleVariants(query.title) {
            do {
                let url = try makeURL("https://lrclib.net/api/get", [
                    ("artist_name", query.artist), ("track_name", title),
                ] + (query.album.map { [("album_name", $0)] } ?? []))
                let item: LRCLIBItem = try await requestJSON(LRCLIBItem.self, url,
                                                               headers: ["User-Agent": "Lyrimuse/1.0"], timeout: 8)
                if let candidate = makeCandidate(item, query: query) { return [candidate] }
            } catch { lastError = error }
        }

        var all: [LRCLIBItem] = []
        for title in normalizeTitleVariants(query.title) {
            do {
                let url = try makeURL("https://lrclib.net/api/search", [
                    ("artist_name", query.artist), ("track_name", title),
                ])
                let items: [LRCLIBItem] = try await requestJSON([LRCLIBItem].self, url,
                                                                  headers: ["User-Agent": "Lyrimuse/1.0"], timeout: 8)
                all.append(contentsOf: items)
            } catch { lastError = error }
        }
        var candidates = all.compactMap { makeCandidate($0, query: query) }
        if candidates.isEmpty, let lastError { throw lastError }
        candidates = Array(candidates.prefix(3))
        return candidates
    }

    private func makeCandidate(_ item: LRCLIBItem, query: LyricsQuery) -> LyricsCandidate? {
        guard roughTitleMatch(item.trackName, query.title),
              roughArtistMatch(item.artistName, query.artist) else { return nil }
        if let duration = query.duration, duration > 0, item.duration > 0,
           abs(item.duration - duration) / duration > 0.25 { return nil }
        if item.instrumental {
            return LyricsCandidate(source: id, lyrics: "", duration: item.duration,
                                   title: item.trackName, artist: item.artistName,
                                   album: item.albumName, instrumental: true)
        }
        if LyricsMatcher.isValidTimedLyrics(item.syncedLyrics) {
            return LyricsCandidate(source: id, lyrics: item.syncedLyrics, duration: item.duration,
                                   title: item.trackName, artist: item.artistName, album: item.albumName)
        }
        guard !item.plainLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LyricsCandidate(source: id, lyrics: item.plainLyrics, duration: item.duration,
                               title: item.trackName, artist: item.artistName, album: item.albumName,
                               plainTextOnly: true)
    }

    private struct LRCLIBItem: Decodable {
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: Double
        let instrumental: Bool
        let syncedLyrics: String
        let plainLyrics: String

        enum CodingKeys: String, CodingKey {
            case trackName, artistName, albumName, duration, instrumental
            case syncedLyrics, plainLyrics
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            trackName = try c.decodeIfPresent(String.self, forKey: .trackName) ?? ""
            artistName = try c.decodeIfPresent(String.self, forKey: .artistName) ?? ""
            albumName = try c.decodeIfPresent(String.self, forKey: .albumName) ?? ""
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            instrumental = try c.decodeIfPresent(Bool.self, forKey: .instrumental) ?? false
            syncedLyrics = try c.decodeIfPresent(String.self, forKey: .syncedLyrics) ?? ""
            plainLyrics = try c.decodeIfPresent(String.self, forKey: .plainLyrics) ?? ""
        }
    }
}

public struct KuwoProvider: LyricsProvider {
    public let id = "kuwo"
    public init() {}

    public func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        let url = try makeURL("https://search.kuwo.cn/r.s", [
            ("all", "\(query.title) \(query.artist)"), ("ft", "music"),
            ("itemset", "web_2013"), ("client", "kt"), ("pn", "0"), ("rn", "10"),
            ("rformat", "json"), ("encoding", "utf8"), ("pcjson", "1"),
        ])
        let result: SearchResult = try await requestJSON(SearchResult.self, url,
                                                          headers: ["Referer": "https://www.kuwo.cn/", "User-Agent": "Mozilla/5.0"], timeout: 8)
        var output: [LyricsCandidate] = []
        for item in result.items where !item.musicRID.isEmpty && roughTitleMatch(item.songName, query.title)
            && roughArtistMatch(item.artist, query.artist) {
            guard let musicID = item.musicRID.split(separator: "_").last, !musicID.isEmpty else { continue }
            let lyricURL = try makeURL("https://kuwo.cn/openapi/v1/www/lyric/getlyric", [("musicId", String(musicID))])
            guard let lyric: LyricResult = try? await requestJSON(LyricResult.self, lyricURL,
                                                                  headers: ["Referer": "https://www.kuwo.cn/", "User-Agent": "Mozilla/5.0"], timeout: 8) else { continue }
            let lrc = lyric.data.lyricList.compactMap { line -> String? in
                guard let time = Double(line.time), let text = line.lineLyric.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return nil }
                return String(format: "[%02d:%05.2f]%@", Int(time / 60), time.truncatingRemainder(dividingBy: 60), text)
            }.joined(separator: "\n")
            guard LyricsMatcher.isValidTimedLyrics(lrc) else { continue }
            let parts = item.cover.split(separator: "/", maxSplits: 1).map(String.init)
            let path = parts.count == 2 ? "500/\(parts[1])" : item.cover
            let cover = item.cover.isEmpty ? nil : URL(string: "https://img1.kuwo.cn/star/albumcover/\(path)")
            output.append(LyricsCandidate(source: self.id, lyrics: lrc, duration: parseDuration(item.duration),
                                          title: item.songName, artist: item.artist, album: item.album,
                                          coverURL: cover))
            if output.count == 3 { break }
        }
        return output
    }

    private struct SearchResult: Decodable {
        let items: [Item]
        enum CodingKeys: String, CodingKey { case items = "abslist" }
        struct Item: Decodable {
            let musicRID: String
            let songName: String
            let artist: String
            let album: String
            let duration: String
            let cover: String
            enum CodingKeys: String, CodingKey {
                case musicRID = "MUSICRID", songName = "SONGNAME", artist = "ARTIST", album = "ALBUM"
                case duration = "DURATION", cover = "web_albumpic_short"
            }
        }
    }

    private struct LyricResult: Decodable {
        let data: Data
        struct Data: Decodable {
            let lyricList: [Line]
            enum CodingKeys: String, CodingKey { case lyricList = "lrclist" }
        }
        struct Line: Decodable { let time: String; let lineLyric: String }
    }

    private func parseDuration(_ value: String) -> Double? {
        if let number = Double(value) { return number }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let minute = Double(parts[0]), let second = Double(parts[1]) else { return nil }
        return minute * 60 + second
    }
}

public struct NeteaseProvider: LyricsProvider {
    public let id = "netease"
    public init() {}

    public func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        var songs: [Song] = []
        var lastError: Error?
        let queries = [
            "\(query.artist) \(query.title)",
            "\(query.artist) \(LyricsMatcher.normalizedTitle(query.title))",
        ]
        for q in queries {
            do {
                let items = try await fetchSongs(q)
                songs.append(contentsOf: items)
                if !items.isEmpty { break }
            } catch { lastError = error }
        }
        var output: [LyricsCandidate] = []
        var seen = Set<Int64>()
        for song in songs where seen.insert(song.id).inserted
            && roughTitleMatch(song.name, query.title)
            && song.artists.contains(where: { roughArtistMatch($0.name, query.artist) }) {
            if let candidate = try? await fetchCandidate(song, query: query) {
                output.append(candidate)
            }
            if output.count == 3 { break }
        }
        if output.isEmpty, let lastError, songs.isEmpty { throw lastError }
        return output
    }

    private func fetchSongs(_ query: String) async throws -> [Song] {
        let items = [("type", "1"), ("limit", "30"), ("s", query)]
        var lastError: Error?
        for endpoint in ["https://music.163.com/api/search/get", "https://music.163.com/api/search/get/web"] {
            do {
                let url = try makeURL(endpoint, items)
                let response: SearchResponse = try await requestJSON(SearchResponse.self, url,
                                                                      headers: ["Referer": "https://music.163.com/", "User-Agent": "Mozilla/5.0"], timeout: 8)
                return response.result.songs
            } catch { lastError = error }
        }
        throw lastError ?? LyricsProviderError.invalidResponse
    }

    private func fetchCandidate(_ song: Song, query: LyricsQuery) async throws -> LyricsCandidate {
        let lrcURL = try makeURL("https://music.163.com/api/song/lyric", [
            ("id", String(song.id)), ("lv", "-1"), ("kv", "-1"), ("tv", "-1"), ("rv", "-1"),
        ])
        let bundle: LyricsBundle = try await requestJSON(LyricsBundle.self, lrcURL,
                                                          headers: ["Referer": "https://music.163.com/", "User-Agent": "Mozilla/5.0"], timeout: 8)
        let lyrics = bundle.lrc.lyric.replacingOccurrences(of: "\\'", with: "'")
        if isNeteaseInstrumental(lyrics) {
            return LyricsCandidate(source: id, lyrics: "", duration: song.duration,
                                   title: song.name, artist: song.artists.map(\.name).joined(separator: " & "),
                                   album: song.album, instrumental: true)
        }
        guard LyricsMatcher.isValidTimedLyrics(lyrics) else { throw LyricsProviderError.noLyrics }
        var yrc = ""
        if let yrcURL = try? makeURL("https://music.163.com/api/song/lyric/v1", [("id", String(song.id)), ("yv", "-1")]),
           let response = try? await requestJSON(YRCBundle.self, yrcURL,
                                                  headers: ["Referer": "https://music.163.com/", "User-Agent": "Mozilla/5.0"], timeout: 8) {
            let value = response.yrc.lyric.replacingOccurrences(of: "\\'", with: "'")
            if value.contains("[") && value.count < 40_000 { yrc = value }
        }
        var cover: URL?
        if let detailURL = try? makeURL("https://music.163.com/api/song/detail", [("ids", "[\(song.id)]")]),
           let detail: DetailResponse = try? await requestJSON(DetailResponse.self, detailURL,
                                                                  headers: ["Referer": "https://music.163.com/", "User-Agent": "Mozilla/5.0"], timeout: 8) {
            cover = detail.songs.first?.album.picURL.flatMap { URL(string: "\($0)?param=800y800") }
        }
        return LyricsCandidate(source: id, lyrics: lyrics,
                               translation: timedOrNil(bundle.tlyric.lyric), romanization: timedOrNil(bundle.romalrc.lyric),
                               wordTiming: yrc, duration: song.duration, title: song.name,
                               artist: song.artists.map(\.name).joined(separator: " & "), album: song.album, coverURL: cover)
    }

    private func timedOrNil(_ value: String) -> String? {
        let text = value.replacingOccurrences(of: "\\'", with: "'")
        return LyricsMatcher.isValidTimedLyrics(text) ? text : nil
    }

    private func isNeteaseInstrumental(_ value: String) -> Bool {
        let bodies = value.split(separator: "\n").map { line in
            line.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return !bodies.isEmpty && bodies.allSatisfy { $0.contains("纯音乐") || $0.lowercased().contains("instrumental") }
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable { let songs: [Song] }
        let result: Result
    }

    private struct Song: Decodable {
        let id: Int64
        let name: String
        let artists: [Artist]
        let albumInfo: Album
        let duration: Double
        var album: String { albumInfo.name }
        enum CodingKeys: String, CodingKey { case id, name, artists, albumInfo = "album", duration = "duration" }
        struct Artist: Decodable { let name: String }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int64.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            artists = try c.decodeIfPresent([Artist].self, forKey: .artists) ?? []
            albumInfo = try c.decodeIfPresent(Album.self, forKey: .albumInfo) ?? Album(name: "", picURL: nil)
            let raw = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            duration = raw > 1000 ? raw / 1000 : raw
        }
    }

    private struct Album: Decodable {
        let name: String
        let picURL: String?
        enum CodingKeys: String, CodingKey { case name, picURL = "picUrl" }
    }

    private struct LyricsBundle: Decodable {
        struct Text: Decodable { let lyric: String }
        let lrc: Text
        let tlyric: Text
        let romalrc: Text
        enum CodingKeys: String, CodingKey { case lrc, tlyric, romalrc }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lrc = try c.decodeIfPresent(Text.self, forKey: .lrc) ?? Text(lyric: "")
            tlyric = try c.decodeIfPresent(Text.self, forKey: .tlyric) ?? Text(lyric: "")
            romalrc = try c.decodeIfPresent(Text.self, forKey: .romalrc) ?? Text(lyric: "")
        }
    }

    private struct YRCBundle: Decodable {
        struct Text: Decodable { let lyric: String }
        let yrc: Text
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            yrc = try c.decodeIfPresent(Text.self, forKey: .yrc) ?? Text(lyric: "")
        }
        enum CodingKeys: String, CodingKey { case yrc }
    }

    private struct DetailResponse: Decodable {
        struct Song: Decodable { let album: Album }
        let songs: [Song]
    }
}

public struct KugouProvider: LyricsProvider {
    public let id = "kugou"
    public init() {}

    public func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        let url = try makeURL("https://mobilecdn.kugou.com/api/v3/search/song", [
            ("format", "json"), ("keyword", "\(query.artist) \(query.title)"),
            ("page", "1"), ("pagesize", "10"), ("showtype", "1"),
        ])
        let response: SearchResponse = try await requestJSON(SearchResponse.self, url,
                                                              headers: ["User-Agent": "Mozilla/5.0"], timeout: 8)
        var output: [LyricsCandidate] = []
        for song in response.data.info where !song.hash.isEmpty
            && roughTitleMatch(song.songName, query.title)
            && roughArtistMatch(song.singerName, query.artist) {
            let durationMs = Int((song.duration * 1000).rounded())
            guard let lyricURL = try? makeURL("https://krcs.kugou.com/search", [
                ("ver", "1"), ("man", "yes"), ("client", "mobi"),
                ("keyword", "\(query.artist) - \(query.title)"), ("duration", String(durationMs)), ("hash", song.hash),
            ]), let search: LyricSearchResponse = try? await requestJSON(LyricSearchResponse.self, lyricURL,
                                                                           headers: ["User-Agent": "Mozilla/5.0"], timeout: 8),
                let lyric = search.candidates.first, !lyric.id.isEmpty, !lyric.accessKey.isEmpty else { continue }
            guard let lrcURL = try? makeURL("https://lyrics.kugou.com/download", [
                ("ver", "1"), ("client", "pc"), ("id", lyric.id), ("accesskey", lyric.accessKey),
                ("fmt", "lrc"), ("charset", "utf8"),
            ]), let lrcResponse: DownloadResponse = try? await requestJSON(DownloadResponse.self, lrcURL,
                                                                              headers: ["User-Agent": "Mozilla/5.0"], timeout: 8),
                let rawLRC = Data(base64Encoded: lrcResponse.content),
                let lrc = String(data: rawLRC, encoding: .utf8), LyricsMatcher.isValidTimedLyrics(lrc) else { continue }

            var yrc = "", translation: String?, romanization: String?
            if let krcURL = try? makeURL("https://lyrics.kugou.com/download", [
                ("ver", "1"), ("client", "pc"), ("id", lyric.id), ("accesskey", lyric.accessKey),
                ("fmt", "krc"), ("charset", "utf8"),
            ]), let krcResponse = try? await requestJSON(DownloadResponse.self, krcURL,
                                                           headers: ["User-Agent": "Mozilla/5.0"], timeout: 8),
               let decoded = decryptKRC(krcResponse.content) {
                let parts = splitLanguageLine(decoded)
                yrc = krcToYRC(parts.body)
                let tracks = languageTracks(parts.language, krc: parts.body)
                translation = tracks.translation
                romanization = tracks.romanization
            }
            var cover: URL?
            if !song.albumID.isEmpty,
               let albumURL = try? makeURL("https://mobilecdn.kugou.com/api/v3/album/info", [("albumid", song.albumID)]),
               let album: AlbumResponse = try? await requestJSON(AlbumResponse.self, albumURL,
                                                                  headers: ["User-Agent": "Mozilla/5.0"], timeout: 8) {
                let value = album.data.imgURL.replacingOccurrences(of: "{size}", with: "480")
                    .replacingOccurrences(of: "http://", with: "https://")
                cover = URL(string: value)
            }
            output.append(LyricsCandidate(source: id, lyrics: lrc, translation: translation, romanization: romanization,
                                          wordTiming: yrc, duration: song.duration, title: song.songName,
                                          artist: song.singerName, album: song.albumName, coverURL: cover))
            if output.count == 3 { break }
        }
        return output
    }

    private struct SearchResponse: Decodable {
        struct DataPart: Decodable { let info: [Song] }
        let data: DataPart
    }
    private struct Song: Decodable {
        let hash: String
        let songName: String
        let singerName: String
        let albumName: String
        let albumID: String
        let duration: Double
        enum CodingKeys: String, CodingKey {
            case hash, songName = "songname", singerName = "singername", albumName = "album_name"
            case albumID = "album_id", duration
        }
    }
    private struct LyricSearchResponse: Decodable {
        struct Item: Decodable { let id: String; let accessKey: String; enum CodingKeys: String, CodingKey { case id; case accessKey = "accesskey" } }
        let candidates: [Item]
    }
    private struct DownloadResponse: Decodable { let content: String }
    private struct AlbumResponse: Decodable {
        struct DataPart: Decodable { let imgURL: String; enum CodingKeys: String, CodingKey { case imgURL = "imgurl" } }
        let data: DataPart
    }

    private let krcKey: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47,
                                   0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69]

    private func decryptKRC(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), data.count > 4 else { return nil }
        var xored = Data(data.dropFirst(4))
        for index in xored.indices { xored[index] ^= krcKey[index % krcKey.count] }
        return zlibDecompress(xored).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func splitLanguageLine(_ text: String) -> (language: String, body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[language:") }) else {
            return ("", lines.joined(separator: "\n"))
        }
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        let language = String(line.dropFirst("[language:".count).dropLast())
        var remaining = lines
        remaining.remove(at: index)
        return (language, remaining.joined(separator: "\n"))
    }

    private func krcToYRC(_ text: String) -> String {
        let lineRegex = try! NSRegularExpression(pattern: #"^\[(\d+),\d+\](.*)$"#)
        let wordRegex = try! NSRegularExpression(pattern: #"<(\d+),(\d+),(\d+)>"#)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw), ns = line as NSString
            guard let lineMatch = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let start = Int(ns.substring(with: lineMatch.range(at: 1))) else { return line }
            let bodyRange = lineMatch.range(at: 2)
            let body = ns.substring(with: bodyRange)
            let bodyNS = body as NSString
            let replacement = wordRegex.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)).reversed().reduce(body) { result, match in
                let wordNS = result as NSString
                guard match.range.location + match.range.length <= wordNS.length else { return result }
                let offset = Int(wordNS.substring(with: match.range(at: 1))) ?? 0
                let duration = wordNS.substring(with: match.range(at: 2))
                let flag = wordNS.substring(with: match.range(at: 3))
                let replacement = "(\(start + offset),\(duration),\(flag))"
                return wordNS.replacingCharacters(in: match.range, with: replacement)
            }
            return ns.replacingCharacters(in: lineMatch.range(at: 2), with: replacement)
        }.joined(separator: "\n")
    }

    private func languageTracks(_ encoded: String, krc: String) -> (translation: String?, romanization: String?) {
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else { return (nil, nil) }
        let starts = krc.split(separator: "\n").compactMap { line -> Int? in
            let ns = String(line) as NSString
            guard let range = ns.range(of: #"^\[(\d+),"#, options: .regularExpression).location == NSNotFound ? nil : ns.range(of: #"^\[(\d+),"#, options: .regularExpression),
                  let text = ns.substring(with: range).split(separator: "[", maxSplits: 1).last,
                  let value = Int(text.split(separator: ",").first ?? "") else { return nil }
            return value
        }
        func makeTrack(_ rows: [[String]]) -> String? {
            guard rows.count == starts.count else { return nil }
            let lines = zip(starts, rows).compactMap { start, fragments -> String? in
                let text = fragments.joined().split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
                guard !text.isEmpty, text != "//" else { return nil }
                return String(format: "[%02d:%02d.%03d]%@", start / 60000, (start / 1000) % 60, start % 1000, text)
            }.joined(separator: "\n")
            return LyricsMatcher.isValidTimedLyrics(lines) ? lines : nil
        }
        var translation: String?, romanization: String?
        for item in content {
            guard let type = item["type"] as? Int, let rows = item["lyricContent"] as? [[String]] else { continue }
            if type == 1, translation == nil { translation = makeTrack(rows) }
            if type == 0, romanization == nil { romanization = makeTrack(rows) }
        }
        if let value = romanization, hanRatio(value) > 0.3 { romanization = nil }
        return (translation, romanization)
    }

    private func hanRatio(_ text: String) -> Double {
        let stripped = text.replacingOccurrences(of: #"\[\d{1,2}:\d{2}[.:]\d{1,3}\]"#, with: "", options: .regularExpression)
        let characters = stripped.filter { !$0.isWhitespace }
        guard !characters.isEmpty else { return 0 }
        let han = characters.reduce(into: 0) { count, character in
            if Romanizer.containsHan(String(character)) { count += 1 }
        }
        return Double(han) / Double(characters.count)
    }
}

public struct QQMusicProvider: LyricsProvider {
    public let id = "qq"
    public init() {}

    public func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        var items: [SearchItem] = []
        var lastError: Error?
        for title in normalizeTitleVariants(query.title) {
            do {
                let url = try makeURL("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", [
                    ("format", "json"), ("new_json", "1"), ("t", "0"), ("aggr", "1"),
                    ("cr", "1"), ("p", "1"), ("n", "10"), ("w", "\(query.artist) \(title)"),
                ])
                let response: SearchResponse = try await requestJSON(SearchResponse.self, url,
                                                                      headers: ["Referer": "https://y.qq.com/", "User-Agent": Self.userAgent], timeout: 8)
                items.append(contentsOf: response.data.song.list.map { item in
                    SearchItem(mid: item.mid, title: item.title, artist: item.singers.map(\.name).joined(separator: "/"),
                               album: item.album.name, albumMid: item.album.mid, duration: item.interval)
                })
            } catch { lastError = error }
            if items.contains(where: { roughTitleMatch($0.title, query.title) }) { break }
        }
        var seen = Set<String>()
        var output: [LyricsCandidate] = []
        for item in items where seen.insert(item.mid).inserted
            && roughTitleMatch(item.title, query.title) && roughArtistMatch(item.artist, query.artist) {
            if let candidate = try? await fetchCandidate(item, query: query) { output.append(candidate) }
            if output.count == 3 { break }
        }
        if output.isEmpty, let lastError, items.isEmpty { throw lastError }
        return output
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

    private func fetchCandidate(_ item: SearchItem, query: LyricsQuery) async throws -> LyricsCandidate {
        let lyricURL = try makeURL("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", [
            ("format", "json"), ("nobase64", "1"), ("g_tk", "5381"), ("songmid", item.mid),
        ])
        let raw = try await requestData(lyricURL, headers: ["Referer": "https://y.qq.com/", "User-Agent": Self.userAgent], timeout: 8)
        let wrapper = String(data: raw, encoding: .utf8) ?? ""
        guard let start = wrapper.firstIndex(of: "{"), let end = wrapper.lastIndex(of: "}"), start < end,
              let result = try? JSONDecoder().decode(SimpleLyric.self, from: Data(wrapper[start...end].utf8)) else {
            throw LyricsProviderError.invalidResponse
        }
        if qqInstrumental(result.lyric) {
            return LyricsCandidate(source: id, lyrics: "", duration: item.duration,
                                   title: item.title, artist: item.artist, album: item.album, instrumental: true)
        }
        guard LyricsMatcher.isValidTimedLyrics(result.lyric) else { throw LyricsProviderError.noLyrics }

        let extras = await fetchQRC(item, query: query)
        let cover = item.albumMid.isEmpty ? nil : URL(string: "https://y.qq.com/music/photo_new/T002R800x800M000\(item.albumMid).jpg")
        return LyricsCandidate(source: id, lyrics: result.lyric, translation: extras.translation,
                               romanization: extras.romanization, wordTiming: extras.yrc,
                               duration: item.duration, title: item.title, artist: item.artist,
                               album: item.album, coverURL: cover)
    }

    private func qqInstrumental(_ lyrics: String) -> Bool {
        let lines = lyrics.split(separator: "\n").map { line in
            line.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return !lines.isEmpty && lines.allSatisfy { $0.contains("纯音乐") || $0.lowercased().contains("instrumental") }
    }

    private func fetchQRC(_ item: SearchItem, query: LyricsQuery) async -> (yrc: String?, translation: String?, romanization: String?) {
        guard let session = try? await fetchSession(), !session.sid.isEmpty,
              let meta = try? await fetchMeta(item.mid), meta.id > 0 else { return (nil, nil, nil) }
        let parameter: [String: Any] = [
            "albumName": Data((item.album.isEmpty ? (query.album ?? "") : item.album).utf8).base64EncodedString(),
            "crypt": 1, "ct": 19, "cv": 2111, "interval": Int(meta.interval),
            "lrc_t": 0, "qrc": 1, "qrc_t": 0, "roma": 1, "roma_t": 0,
            "singerName": Data(item.artist.utf8).base64EncodedString(), "songID": meta.id,
            "songName": Data(item.title.utf8).base64EncodedString(), "trans": 1,
            "trans_t": 0, "type": 0,
        ]
        guard let data = try? await musicuPost(method: "GetPlayLyricInfo", module: "music.musichallSong.PlayLyricInfo", parameter: parameter, session: session),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil, nil) }
        var yrc: String?
        if qqTimingFlag(object["qrc_t"]) || qqTimingFlag(object["lrc_t"]),
           let hex = object["lyric"] as? String, let plaintext = decryptQRC(hex),
           let content = extractLyricContent(plaintext) {
            yrc = qrcToYRC(stripQQKanaLine(content))
        }
        let translation = (object["trans"] as? String).flatMap(auxiliaryLRC)
        let romanization = (object["roma"] as? String).flatMap(auxiliaryLRC)
        return (yrc, translation, romanization)
    }

    private struct SearchResponse: Decodable {
        struct DataPart: Decodable {
            struct SongPart: Decodable {
                struct Item: Decodable {
                    let mid: String
                    let title: String
                    let interval: Double
                    let singers: [Singer]
                    let album: Album
                    struct Singer: Decodable { let name: String }
                    struct Album: Decodable { let name: String; let mid: String }
                }
                let list: [Item]
            }
            let song: SongPart
        }
        let data: DataPart
    }

    private struct SearchItem: Sendable {
        let mid: String
        let title: String
        let artist: String
        let album: String
        let albumMid: String
        let duration: Double
    }

    private struct SimpleLyric: Decodable { let lyric: String }

    private struct Session: Sendable { let uid: String; let sid: String; let userIP: String }
    private struct Meta: Sendable { let id: Int64; let interval: Double }

    private func musicuPost(method: String, module: String, parameter: [String: Any], session: Session?) async throws -> Data {
        var comm: [String: Any] = [
            "ct": 11, "cv": "1003006", "v": "1003006", "os_ver": "15",
            "phonetype": "24122RKC7C", "rom": "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.105.0.VOMCNXM:user/release-keys",
            "tmeAppID": "qqmusiclight", "nettype": "NETWORK_WIFI", "udid": "0",
        ]
        if let session { comm["uid"] = session.uid; comm["sid"] = session.sid; comm["userip"] = session.userIP }
        let body: [String: Any] = [
            "comm": comm,
            "request": ["method": method, "module": module, "param": parameter],
        ]
        guard JSONSerialization.isValidJSONObject(body) else { throw LyricsProviderError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: body)
        let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
        let response = try await requestData(url, method: "POST", headers: [
            "Content-Type": "application/json", "Cookie": "tmeLoginType=-1;", "User-Agent": "okhttp/3.14.9",
        ], body: data, timeout: 8)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              qqInteger(object["code"]) == 0,
              let request = object["request"] as? [String: Any],
              qqInteger(request["code"]) == 0,
              let payload = request["data"] else { throw LyricsProviderError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func fetchSession() async throws -> Session {
        let data = try await musicuPost(method: "GetSession", module: "music.getSession.session",
                                        parameter: ["caller": 0, "uid": "0", "vkey": 0], session: nil)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = object["session"] as? [String: Any],
              let sid = session["sid"] as? String, !sid.isEmpty else { throw LyricsProviderError.invalidResponse }
        let uid: String
        if let value = session["uid"] as? String { uid = value }
        else if let value = session["uid"] as? NSNumber { uid = value.stringValue }
        else { uid = "0" }
        return Session(uid: uid, sid: sid, userIP: session["userip"] as? String ?? "")
    }

    private func fetchMeta(_ mid: String) async throws -> Meta {
        let url = try makeURL("https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg", [
            ("format", "json"), ("platform", "yqq"), ("inCharset", "utf8"),
            ("outCharset", "utf-8"), ("songmid", mid),
        ])
        let response: MetaResponse = try await requestJSON(MetaResponse.self, url,
                                                            headers: ["Referer": "https://y.qq.com/", "User-Agent": Self.userAgent], timeout: 8)
        guard let first = response.data.first else { throw LyricsProviderError.invalidResponse }
        return Meta(id: first.id, interval: first.interval)
    }

    private struct MetaResponse: Decodable {
        struct Item: Decodable { let id: Int64; let interval: Double }
        let data: [Item]
    }

    private func decryptQRC(_ hex: String) -> String? {
        guard let raw = Data(hexString: hex), !raw.isEmpty, raw.count.isMultiple(of: 8) else { return nil }
        let key = Data("!@#)(*$%123ZXC!@!@#)(NHL".utf8)
        var output = Data(count: raw.count)
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithm3DES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, kCCKeySize3DES, nil,
                            source.baseAddress, raw.count, destination.baseAddress, outputCount, nil)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return zlibDecompress(output).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func extractLyricContent(_ text: String) -> String? {
        guard let range = text.range(of: #"(?s)LyricContent=\"(.*)\"\s*/>"#, options: .regularExpression) else { return nil }
        let matched = String(text[range])
        guard let first = matched.firstIndex(of: "\""), let last = matched.lastIndex(of: "\""), first < last else { return nil }
        return htmlUnescape(String(matched[matched.index(after: first)..<last]))
    }

    private func htmlUnescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private func stripQQKanaLine(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !(value.hasPrefix("[kana:") && value.hasSuffix("]"))
            }
            .joined(separator: "\n")
    }

    private func qqTimingFlag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let string = value as? String { return !string.isEmpty && string != "0" }
        return false
    }

    private func qqInteger(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func qrcToYRC(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"([^\[\]()\n]+)\((\d+),(\d+)\)"#)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw), ns = line as NSString
            return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed().reduce(line) { value, match in
                let current = value as NSString
                let word = current.substring(with: match.range(at: 1))
                let start = current.substring(with: match.range(at: 2))
                let duration = current.substring(with: match.range(at: 3))
                return current.replacingCharacters(in: match.range, with: "(\(start),\(duration),0)\(word)")
            }
        }.joined(separator: "\n")
    }

    private func auxiliaryLRC(_ encoded: String) -> String? {
        guard let text = decryptQRC(encoded) else { return nil }
        let content = extractLyricContent(text) ?? text
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let qrcLineRegex = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
        let hasQRCLineTiming = lines.contains { line in
            qrcLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        let wordRegex = try! NSRegularExpression(pattern: #"\(\d+,\d+\)"#)
        let lrcTimestampRegex = try! NSRegularExpression(pattern: #"\[\d{1,2}:\d{2}[.:]\d{1,3}\]"#)
        let normalized = lines.compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.lowercased().hasPrefix("[offset:") { return line }
            let ns = line as NSString
            if hasQRCLineTiming {
                guard let match = qrcLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                      let start = Int(ns.substring(with: match.range(at: 1))) else { return nil }
                var body = ns.substring(from: match.range.location + match.range.length)
                body = wordRegex.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
                body = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                guard !body.isEmpty, body != "//", !isQQTranslationNotice(body) else { return nil }
                return String(format: "[%02d:%02d.%03d]%@", start / 60000, (start / 1000) % 60, start % 1000, body)
            }
            guard line.hasPrefix("["), lrcTimestampRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else { return nil }
            let body = lrcTimestampRegex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, body != "//", !isQQTranslationNotice(body) else { return nil }
            return line
        }.joined(separator: "\n")
        return LyricsMatcher.isValidTimedLyrics(normalized) ? normalized : nil
    }

    private func isQQTranslationNotice(_ text: String) -> Bool {
        text.contains("翻译作品的著作权") || (text.contains("QQ音乐") && text.contains("著作权"))
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            let pair = String(chars[index...index + 1])
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            data.append(byte)
            index += 2
        }
        self = data
    }
}


private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
