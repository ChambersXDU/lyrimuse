import Foundation

public struct EnrichCacheEntry: Decodable, Equatable {
    public let lyrics: String?
    public let lyricsTr: String?
    public let lyricsRoma: String?
    public let lyricsYRC: String?
    public let lyricsSource: String?
    public let coverSource: String?

    public let coverURL: String?

    public let coverAlbum: String?

    public let instrumental: Bool?

    public let ts: Int64?

    public let appleMusicURL: String?
    public let qqMusicURL: String?
    public let neteaseURL: String?
    public let qqAlbumMid: String?
    public let qqSingerMid: String?

    public let songLanguage: String?

    public let plainLyrics: String?

    public let durationSecs: Double?

    public let resolvedDurationSecs: Double?

    public let lyricsSourcesSkipped: [String]?
    public let lyricsSourcesFailed: [String]?
    public let lyricsFillCount: Int?

    public init(
        lyrics: String? = nil,
        lyricsTr: String? = nil,
        lyricsRoma: String? = nil,
        lyricsYRC: String? = nil,
        lyricsSource: String? = nil,
        coverSource: String? = nil,
        coverURL: String? = nil,
        coverAlbum: String? = nil,
        instrumental: Bool? = nil,
        ts: Int64? = nil,
        appleMusicURL: String? = nil,
        qqMusicURL: String? = nil,
        neteaseURL: String? = nil,
        qqAlbumMid: String? = nil,
        qqSingerMid: String? = nil,
        songLanguage: String? = nil,
        plainLyrics: String? = nil,
        durationSecs: Double? = nil,
        resolvedDurationSecs: Double? = nil,
        lyricsSourcesSkipped: [String]? = nil,
        lyricsSourcesFailed: [String]? = nil,
        lyricsFillCount: Int? = nil
    ) {
        self.lyrics = lyrics
        self.lyricsTr = lyricsTr
        self.lyricsRoma = lyricsRoma
        self.lyricsYRC = lyricsYRC
        self.lyricsSource = lyricsSource
        self.coverSource = coverSource
        self.coverURL = coverURL
        self.coverAlbum = coverAlbum
        self.instrumental = instrumental
        self.ts = ts
        self.appleMusicURL = appleMusicURL
        self.qqMusicURL = qqMusicURL
        self.neteaseURL = neteaseURL
        self.qqAlbumMid = qqAlbumMid
        self.qqSingerMid = qqSingerMid
        self.songLanguage = songLanguage
        self.plainLyrics = plainLyrics
        self.durationSecs = durationSecs
        self.resolvedDurationSecs = resolvedDurationSecs
        self.lyricsSourcesSkipped = lyricsSourcesSkipped
        self.lyricsSourcesFailed = lyricsSourcesFailed
        self.lyricsFillCount = lyricsFillCount
    }

    enum CodingKeys: String, CodingKey {
        case lyrics
        case lyricsTr = "lyrics_tr"
        case lyricsRoma = "lyrics_roma"
        case lyricsYRC = "lyrics_yrc"
        case lyricsSource = "lyrics_source"
        case coverSource = "cover_source"
        case coverURL = "cover_url"
        case coverAlbum = "cover_album"
        case instrumental
        case ts
        case appleMusicURL = "apple_music_url"
        case qqMusicURL = "qq_music_url"
        case neteaseURL = "netease_url"
        case qqAlbumMid = "qq_album_mid"
        case qqSingerMid = "qq_singer_mid"
        case songLanguage = "song_language"
        case plainLyrics = "plain_lyrics"
        case durationSecs = "duration_secs"
        case resolvedDurationSecs = "resolved_duration_secs"
        case lyricsSourcesSkipped = "lyrics_sources_skipped"
        case lyricsSourcesFailed = "lyrics_sources_failed"
        case lyricsFillCount = "lyrics_fill_count"
    }
}

public func enrichLyricsSearchIncomplete(lyrics: String, sourcesSkipped: [String], fillCount: Int, sourcesFailed: [String] = []) -> Bool {
    lyrics.isEmpty && (!sourcesSkipped.isEmpty || !sourcesFailed.isEmpty) && fillCount == 0
}

public struct EnrichCacheLyrics: Equatable {
    public let lyrics: String
    public let lyricsTr: String
    public let lyricsRoma: String
    public let lyricsYRC: String
    public let instrumental: Bool

    public let resolved: Bool

    public let plainLyrics: String

    public let searchIncomplete: Bool
}

@MainActor
public enum EnrichCacheReader {
    private static let cacheURL = LyrimusePaths.configFile("lyrimuse-enrich-cache.json")

    private static var cachedMTime: Date?
    private static var cachedEntries: [String: EnrichCacheEntry]?

    private static var cachedCoverIndex: [String: String]?

    private static var cachedLooseIndex: [String: String]?

    private static var cachedEntryIndex: [String: EnrichCacheEntry]?
    private static var cachedResolvedKeyIndex: [String: String]?

    private static var decodeGeneration = 0
    private static var inFlightGeneration: Int?
    private static var memoryPressureSource: DispatchSourceMemoryPressure?

    public struct SourceInfo: Sendable, Equatable {
        public let lyricsSource: String?
        public let coverSource: String?
    }

    public static func sourceInfo(artist: String, title: String, album: String) -> SourceInfo? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        let atKey = artistTitleKey(artist: artist, title: title)
        let entries = entryByArtistTitle()
        guard let entry = all[key]
            ?? looseMatch(key, in: all)
            ?? entries[atKey]
            ?? entryForArtistTitle(in: entries, artist: artist, title: title)
        else { return nil }
        return SourceInfo(lyricsSource: entry.lyricsSource, coverSource: entry.coverSource)
    }

    public static func trackDurationSecs(artist: String, title: String, album: String) -> Double? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        let atKey = artistTitleKey(artist: artist, title: title)
        let entries = entryByArtistTitle()
        guard let entry = all[key]
            ?? looseMatch(key, in: all)
            ?? entries[atKey]
            ?? entryForArtistTitle(in: entries, artist: artist, title: title)
        else { return nil }
        for candidate in [entry.resolvedDurationSecs, entry.durationSecs] {
            if let candidate, candidate > 0 { return candidate }
        }
        return nil
    }

    public static func resolvedKey(artist: String, title: String, album: String) -> String? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        if all[key] != nil { return key }
        if let loose = looseIndex(in: all)[EnrichCacheKeys.looseKey(key)] { return loose }
        let atKey = artistTitleKey(artist: artist, title: title)
        let keys = resolvedKeyByArtistTitle()
        return keys[atKey] ?? resolvedKeyForArtistTitle(in: keys, artist: artist, title: title)
    }

    public static var fileModificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate]
            as? Date
    }

    public static func lookup(artist: String, title: String, album: String) -> EnrichCacheLyrics? {
        guard let all = loadEntries() else { return nil }

        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        let atKey = artistTitleKey(artist: artist, title: title)
        let entries = entryByArtistTitle()
        guard let entry = all[key]
            ?? looseMatch(key, in: all)
            ?? entries[atKey]
            ?? entryForArtistTitle(in: entries, artist: artist, title: title)
        else { return nil }
        return EnrichCacheLyrics(
            lyrics: entry.lyrics ?? "",
            lyricsTr: entry.lyricsTr ?? "",
            lyricsRoma: entry.lyricsRoma ?? "",
            lyricsYRC: entry.lyricsYRC ?? "",
            instrumental: entry.instrumental ?? false,
            resolved: (entry.ts ?? 0) > 0,
            plainLyrics: entry.plainLyrics ?? "",
            searchIncomplete: enrichLyricsSearchIncomplete(
                lyrics: entry.lyrics ?? "",
                sourcesSkipped: entry.lyricsSourcesSkipped ?? [],
                fillCount: entry.lyricsFillCount ?? 0,
                sourcesFailed: entry.lyricsSourcesFailed ?? [])
        )
    }

    private static func looseMatch(_ key: String, in all: [String: EnrichCacheEntry]) -> EnrichCacheEntry? {

        guard let bestKey = looseIndex(in: all)[EnrichCacheKeys.looseKey(key)] else { return nil }
        return all[bestKey]
    }

    private static func looseIndex(in all: [String: EnrichCacheEntry]) -> [String: String] {
        if let cachedLooseIndex { return cachedLooseIndex }
        var index: [String: String] = [:]
        index.reserveCapacity(all.count)
        for k in all.keys {
            let loose = EnrichCacheKeys.looseKey(k)
            if let existing = index[loose] {
                if k < existing { index[loose] = k }
            } else {
                index[loose] = k
            }
        }
        cachedLooseIndex = index
        return index
    }

    public static func albumMatchedCoverURL(artist: String, title: String, album: String) -> URL? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        if let s = all[key]?.coverURL, let url = URL(string: s) { return url }
        if let s = looseMatch(key, in: all)?.coverURL, let url = URL(string: s) { return url }
        return nil
    }

    public static func albumVerifiedCoverURL(artist: String, title: String, album: String) -> URL? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        let entry = all[key] ?? looseMatch(key, in: all)
        guard let entry, coverAlbumVerified(coverAlbum: entry.coverAlbum, requestedAlbum: album),
              let s = entry.coverURL, let url = URL(string: s) else { return nil }
        return url
    }

    public nonisolated static func coverAlbumVerified(coverAlbum: String?, requestedAlbum: String) -> Bool {
        guard let ca = coverAlbum?.trimmingCharacters(in: .whitespaces), !ca.isEmpty else { return false }
        let ra = requestedAlbum.trimmingCharacters(in: .whitespaces)
        guard !ra.isEmpty else { return false }
        return EnrichCacheKeys.looseKey(ca) == EnrichCacheKeys.looseKey(ra)
    }

    public static func coverURL(artist: String, title: String, album: String) -> URL? {
        if let url = albumMatchedCoverURL(artist: artist, title: title, album: album) {
            return url
        }
        guard loadEntries() != nil else { return nil }
        if let s = Self.coverURLString(in: coverByArtistTitle(), artist: artist, title: title),
           let url = URL(string: s) {
            return url
        }
        return nil
    }

    public nonisolated static func coverURLString(in index: [String: String],
                                                  artist: String, title: String) -> String? {
        if let s = index[artistTitleKey(artist: artist, title: title)] { return s }
        let merged = ArtistCredit.mergeArtist(artist)
        guard merged != artist else { return nil }
        return index[artistTitleKey(artist: merged, title: title)]
    }

    public nonisolated static func nativeSizedCoverURL(_ url: URL) -> URL {
        if let u = neteaseNativeCoverURL(url) { return u }
        if let u = qqUpscaledCoverURL(url) { return u }
        if let u = appleUpscaledCoverURL(url) { return u }
        return url
    }

    nonisolated private static let qqCoverMaxEdge = 800

    nonisolated private static let appleCoverTargetEdge = 1200

    private nonisolated static func neteaseNativeCoverURL(_ url: URL) -> URL? {

        guard let host = url.host,
              host == "music.126.net" || host.hasSuffix(".music.126.net")
        else { return nil }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty
        else { return nil }
        let kept = items.filter { $0.name != "param" }
        guard kept.count != items.count else { return nil }

        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url
    }

    private nonisolated static func qqUpscaledCoverURL(_ url: URL) -> URL? {

        guard let host = url.host, host == "y.qq.com" || host == "y.gtimg.cn" else { return nil }
        guard url.path.hasPrefix("/music/photo_new/") else { return nil }
        let s = url.absoluteString

        guard let seg = s.range(of: "T[0-9]+R[0-9]+x[0-9]+M", options: .regularExpression),
              let size = s[seg].range(of: "[0-9]+x[0-9]+", options: .regularExpression)
        else { return nil }
        let edge = Int(s[size].prefix { $0.isNumber }) ?? 0
        guard edge > 0, edge < qqCoverMaxEdge else { return nil }
        return URL(string: s.replacingCharacters(in: size,
                                                 with: "\(qqCoverMaxEdge)x\(qqCoverMaxEdge)"))
    }

    private nonisolated static func appleUpscaledCoverURL(_ url: URL) -> URL? {
        guard let host = url.host,
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
        else { return nil }

        let last = url.lastPathComponent
        guard last.range(of: "^[0-9]+x[0-9]+bb\\.(jpg|png)$", options: .regularExpression) != nil
        else { return nil }
        let edge = Int(last.prefix { $0.isNumber }) ?? 0
        guard edge > 0, edge < appleCoverTargetEdge else { return nil }
        let ext = last.hasSuffix(".png") ? "png" : "jpg"
        let bumped = "\(appleCoverTargetEdge)x\(appleCoverTargetEdge)bb.\(ext)"

        let s = url.absoluteString
        guard let r = s.range(of: last, options: .backwards) else { return nil }
        return URL(string: s.replacingCharacters(in: r, with: bumped))
    }

    public nonisolated static func artistTitleKey(artist: String, title: String) -> String {
        artist.trimmingCharacters(in: .whitespaces).lowercased()
            + "|" + EnrichCacheKeys.normalizedTitle(title).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func coverByArtistTitle() -> [String: String] {
        if let cachedCoverIndex { return cachedCoverIndex }
        var covers: [String: String] = [:]
        for (key, entry) in cachedEntries ?? [:] {
            guard let cover = entry.coverURL, !cover.isEmpty else { continue }
            covers[key] = cover
        }
        let index = Self.coverIndexByArtistTitle(covers)
        cachedCoverIndex = index
        return index
    }

    public nonisolated static func coverIndexByArtistTitle(_ covers: [String: String]) -> [String: String] {
        var index: [String: String] = [:]
        var aliases: [String: String] = [:]
        for key in covers.keys.sorted() {
            guard let cover = covers[key], !cover.isEmpty else { continue }
            let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let artist = String(parts[0]), title = String(parts[1])
            let exact = artistTitleKey(artist: artist, title: title)
            if index[exact] == nil { index[exact] = cover }
            let alias = artistTitleKey(artist: ArtistCredit.mergeArtist(artist), title: title)
            if alias != exact, aliases[alias] == nil { aliases[alias] = cover }
        }
        for (key, cover) in aliases where index[key] == nil { index[key] = cover }
        return index
    }

    private static func entryByArtistTitle() -> [String: EnrichCacheEntry] {
        if let cachedEntryIndex { return cachedEntryIndex }
        buildArtistTitleIndices()
        return cachedEntryIndex ?? [:]
    }

    private static func resolvedKeyByArtistTitle() -> [String: String] {
        if let cachedResolvedKeyIndex { return cachedResolvedKeyIndex }
        buildArtistTitleIndices()
        return cachedResolvedKeyIndex ?? [:]
    }

    private static func buildArtistTitleIndices() {
        let (entries, keys) = Self.entryIndicesByArtistTitle(cachedEntries ?? [:])
        cachedEntryIndex = entries
        cachedResolvedKeyIndex = keys
    }

    public nonisolated static func entryForArtistTitle(
        in index: [String: EnrichCacheEntry],
        artist: String,
        title: String
    ) -> EnrichCacheEntry? {
        if let entry = index[artistTitleKey(artist: artist, title: title)] { return entry }
        let merged = ArtistCredit.mergeArtist(artist)
        guard merged != artist else { return nil }
        return index[artistTitleKey(artist: merged, title: title)]
    }

    public nonisolated static func resolvedKeyForArtistTitle(
        in index: [String: String],
        artist: String,
        title: String
    ) -> String? {
        if let key = index[artistTitleKey(artist: artist, title: title)] { return key }
        let merged = ArtistCredit.mergeArtist(artist)
        guard merged != artist else { return nil }
        return index[artistTitleKey(artist: merged, title: title)]
    }

    public nonisolated static func entryIndicesByArtistTitle(
        _ all: [String: EnrichCacheEntry]
    ) -> (entries: [String: EnrichCacheEntry], keys: [String: String]) {
        func entryRank(_ e: EnrichCacheEntry) -> Int {
            if !(e.lyrics?.isEmpty ?? true) || !(e.lyricsYRC?.isEmpty ?? true) {
                return 3
            }
            if !(e.plainLyrics?.isEmpty ?? true) || (e.instrumental ?? false) {
                return 2
            }
            if (e.ts ?? 0) > 0 {
                return 1
            }
            return 0
        }

        var entries: [String: EnrichCacheEntry] = [:]
        var keys: [String: String] = [:]
        var aliasEntries: [String: EnrichCacheEntry] = [:]
        var aliasKeys: [String: String] = [:]

        for key in all.keys.sorted() {
            guard let entry = all[key] else { continue }
            let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let artist = String(parts[0]), title = String(parts[1])
            let exact = artistTitleKey(artist: artist, title: title)
            if entries[exact] == nil {
                entries[exact] = entry
                keys[exact] = key
            } else if let existing = entries[exact], entryRank(entry) > entryRank(existing) {
                entries[exact] = entry
                keys[exact] = key
            }

            let alias = artistTitleKey(artist: ArtistCredit.mergeArtist(artist), title: title)
            if alias != exact {
                if aliasEntries[alias] == nil {
                    aliasEntries[alias] = entry
                    aliasKeys[alias] = key
                } else if let existing = aliasEntries[alias], entryRank(entry) > entryRank(existing) {
                    aliasEntries[alias] = entry
                    aliasKeys[alias] = key
                }
            }
        }

        for (key, entry) in aliasEntries where entries[key] == nil {
            entries[key] = entry
            keys[key] = aliasKeys[key]!
        }
        return (entries, keys)
    }

    public static func cacheModifiedAt() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
    }

    public static var decodedContentVersion: Date? { cachedMTime }

    public static func refreshIfNeeded() {
        let mtime = fileModificationDate
        if mtime == cachedMTime { return }
        guard mtime != nil else {

            cachedMTime = nil
            cachedEntries = nil
            cachedCoverIndex = nil
            cachedLooseIndex = nil
            cachedEntryIndex = nil
            cachedResolvedKeyIndex = nil
            return
        }
        if cachedEntries == nil {
            decodeSynchronously()
        } else {
            kickBackgroundDecode()
        }
    }

    public static func reloadNow() {
        decodeGeneration += 1
        inFlightGeneration = nil
        decodeSynchronously()
    }

    private static func decodeSynchronously() {

        let mtime = fileModificationDate
        guard let data = try? Data(contentsOf: cacheURL),
              let all = try? JSONDecoder().decode([String: EnrichCacheEntry].self, from: data)
        else {
            cachedMTime = nil
            cachedEntries = nil
            cachedCoverIndex = nil
            cachedLooseIndex = nil
            cachedEntryIndex = nil
            cachedResolvedKeyIndex = nil
            return
        }
        adopt(entries: all, mtime: mtime)
    }

    private static func kickBackgroundDecode() {
        guard inFlightGeneration == nil else { return }
        decodeGeneration += 1
        let gen = decodeGeneration
        inFlightGeneration = gen
        let url = cacheURL
        Task.detached(priority: .utility) {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let decoded: [String: EnrichCacheEntry]? = (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode([String: EnrichCacheEntry].self, from: $0) }
            await MainActor.run {
                if inFlightGeneration == gen { inFlightGeneration = nil }
                guard gen == decodeGeneration else { return }
                guard let decoded else { return }
                adopt(entries: decoded, mtime: mtime)
                if fileModificationDate != mtime { refreshIfNeeded() }
            }
        }
    }

    private static func adopt(entries: [String: EnrichCacheEntry], mtime: Date?) {
        cachedMTime = mtime
        cachedEntries = entries
        cachedCoverIndex = nil
        cachedLooseIndex = nil
        cachedEntryIndex = nil
        cachedResolvedKeyIndex = nil
    }

    public static func installMemoryPressureRelief() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                decodeGeneration += 1
                inFlightGeneration = nil
                cachedMTime = nil
                cachedEntries = nil
                cachedCoverIndex = nil
                cachedLooseIndex = nil
                cachedEntryIndex = nil
                cachedResolvedKeyIndex = nil
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private static func loadEntries() -> [String: EnrichCacheEntry]? {

        if cachedEntries == nil { decodeSynchronously() }
        return cachedEntries
    }
}
