import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lastfm-stats")

@MainActor
final class LastfmStatsService: ObservableObject {
    static let shared = LastfmStatsService()

    private init() {
        loadSnapshot()

        loadRecentPageCache()

        startFeedWatcher()
    }

    private static let feedURL = LyrimusePaths.configFile("lyrimuse-lastfm-recent-feed.json")
    private var feedTimer: Timer?
    private var feedMTime: Date?
    private var lastFeed: LastfmRecentFeed?

    private var feedCompletedRows: [RecentTrack] = []

    var feedIsFresh: Bool { lastFeed?.isFresh() ?? false }

    private func startFeedWatcher() {
        pollFeedFile()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollFeedFile() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        feedTimer = t
    }

    private func pollFeedFile() {
        guard credentials != nil else { return }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: Self.feedURL.path))?[.modificationDate] as? Date
        guard let mtime, mtime != feedMTime else { return }
        feedMTime = mtime
        guard let data = try? Data(contentsOf: Self.feedURL),
              let feed = LastfmRecentFeed.decode(data) else { return }
        ingestFeed(feed)
    }

    private static func filteredImageURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, !raw.contains("2a96cbd8b46e442fc41c2b86b821562f") else { return nil }
        return URL(string: raw)
    }

    func fetchUserAvatarURL(user: String) async -> URL? {
        guard let cred = credentials, cred.user == user else { return nil }
        guard let json = await request(method: "user.getinfo", cred: cred),
              let userObject = json["user"] as? [String: Any],
              let images = userObject["image"] as? [[String: Any]] else { return nil }
        for size in ["extralarge", "large", "medium", "small"] {
            if let raw = images.first(where: { ($0["size"] as? String) == size })?["#text"] as? String,
               let url = Self.filteredImageURL(raw) {
                return url
            }
        }
        return nil
    }

    private func ingestFeed(_ feed: LastfmRecentFeed) {
        guard let cred = credentials, feed.username == cred.user else { return }
        let fresh = feed.isFresh()

        if !dailyLoaded { loadDailySnapshot() }
        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let today = LastfmRecentFeed.todayCount(
            rowUTS: feed.tracks.compactMap(\.uts), todayStart: todayStart,
            bucketToday: dailyCounts[Self.dayKey(now)], syncedThrough: dailySyncedThrough)
        if let prev = lastFeed, prev.total == feed.total, prev.nowPlaying == feed.nowPlaying,
           prev.tracks == feed.tracks {
            lastFeed = feed
            mergeOverview(total: nil, today: today.exact ? today.count : nil, week: nil)
            if fresh, overview != nil { fetchedAt["baseline"] = Date() }
            return
        }
        lastFeed = feed

        var dupCount: [String: Int] = [:]
        let toRow: (LastfmRecentFeed.Track) -> RecentTrack = { t in
            let dupKey = "\(t.uts.map { String(Int($0)) } ?? "np")|\(t.artist)|\(t.title)"
            let dup = dupCount[dupKey, default: 0]
            dupCount[dupKey] = dup + 1
            return RecentTrack(dup: dup, title: t.title, artist: t.artist, album: t.album,
                               imageURL: Self.filteredImageURL(t.image),
                               date: t.uts.map { Date(timeIntervalSince1970: $0) })
        }
        let completed = feed.tracks.filter { !$0.title.isEmpty }.map(toRow)
        feedCompletedRows = completed
        var page1 = Array(completed.prefix(Self.recentPageSize))
        if let np = feed.nowPlaying, !np.title.isEmpty { page1.insert(toRow(np), at: 0) }

        for r in completed where !r.artist.isEmpty { harvestTitleForm(artist: r.artist, title: r.title) }

        recentPageCache[1] = page1
        recentPageCacheTotal[1] = feed.total
        fetchedAt[Self.recentPageCacheKey(1)] = Date()
        if completed.count >= Self.recentPageSize * 2 {
            recentPageCache[2] = Array(completed[Self.recentPageSize ..< Self.recentPageSize * 2])
            recentPageCacheTotal[2] = feed.total
            fetchedAt[Self.recentPageCacheKey(2)] = Date()
        }

        mergeOverview(total: feed.total, today: today.count, week: nil)
        recentTotalPages = LastfmRecentFeed.totalPages(total: feed.total, pageSize: Self.recentPageSize)
        if !today.exact { refreshTodayCountIfNeeded() }

        if recentPage == 1 {

            baselineGen += 1
            applyRecent(page1)
        }

        if fresh, overview != nil { fetchedAt["baseline"] = now }
        scheduleSnapshotSave()
        scheduleRecentPageCacheSave()
    }

    private func refreshTodayCountIfNeeded() {
        guard !fresh("todaycount", ttl: baselineTTL), let cred = credentials else { return }
        fetchedAt["todaycount"] = Date()
        Task {
            let dayStart = Calendar.current.startOfDay(for: Date())
            guard let json = await request(method: "user.getrecenttracks", cred: cred,
                                           extra: ["limit": "1", "from": String(Int(dayStart.timeIntervalSince1970))],
                                           priority: .background)
            else {
                fetchedAt["todaycount"] = nil
                return
            }
            mergeOverview(total: nil, today: attrTotal(json), week: nil)
        }
    }

    enum ChartKind: String, CaseIterable, Identifiable {
        case artists, albums, tracks
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .artists: return L10n.t("歌手")
            case .albums: return L10n.t("专辑")
            case .tracks: return L10n.t("歌曲")
            }
        }
        var method: String {
            switch self {
            case .artists: return "user.gettopartists"
            case .albums: return "user.gettopalbums"
            case .tracks: return "user.gettoptracks"
            }
        }

        var listPath: (String, String) {
            switch self {
            case .artists: return ("topartists", "artist")
            case .albums: return ("topalbums", "album")
            case .tracks: return ("toptracks", "track")
            }
        }
    }

    enum Period: String, CaseIterable, Identifiable {
        case week = "7day", month = "1month", year = "12month", overall = "overall"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .week: return L10n.t("近 7 天")
            case .month: return L10n.t("近 30 天")
            case .year: return L10n.t("近一年")
            case .overall: return L10n.t("全部")
            }
        }
    }

    struct Overview: Equatable, Codable {
        var total: Int
        var today: Int
        var week: Int
    }

    struct ChartEntry: Identifiable, Equatable, Codable {
        let rank: Int
        let name: String

        let detail: String
        let playcount: Int

        let imageURL: URL?
        var id: Int { rank }
    }

    struct RecentTrack: Identifiable, Equatable, Codable {

        var dup: Int?
        let title: String
        let artist: String

        var album: String?
        let imageURL: URL?

        let date: Date?
        var nowPlaying: Bool { date == nil }
        var id: String { "\(date?.timeIntervalSince1970 ?? -1)|\(artist)|\(title)|\(dup ?? 0)" }
    }

    @Published private(set) var overview: Overview?
    @Published private(set) var recent: [RecentTrack] = []

    static let recentPageSize = 20

    @Published private(set) var recentPage = 1

    @Published private(set) var recentTotalPages = 1

    @Published private(set) var recentPaging = false

    @Published private(set) var recentUpdatedAt: Date?

    private var recentPageCache: [Int: [RecentTrack]] = [:]

    private var recentPageCacheTotal: [Int: Int] = [:]

    private static let recentPageCacheTTL: TimeInterval = 5 * 60

    private static let recentPagePrefetchCount = 10
    private var recentPageCacheLoaded = false
    private var recentPagesPrefetching = false
    private var recentPageCacheSaveTask: Task<Void, Never>?

    private struct RecentPageCacheSnapshot: Codable {
        var username: String

        var pages: [String: [RecentTrack]]

        var playCounts: [String: Int]?

        var playCountUnavailable: [String]?

        var totals: [String: Int]?

        var playCountUnavailableAt: [String: Double]?
        var playCountUnavailableStrikes: [String: Int]?
    }

    private static let recentPageCacheURL = LyrimusePaths.configFile("lyrimuse-lastfm-recent-pages.json")

    private func loadRecentPageCache() {
        recentPageCacheLoaded = true
        guard let cred = credentials,
              let data = try? Data(contentsOf: Self.recentPageCacheURL),
              let snap = try? JSONDecoder().decode(RecentPageCacheSnapshot.self, from: data),
              snap.username == cred.user
        else { return }
        for (k, v) in snap.pages {
            guard let page = Int(k) else { continue }
            recentPageCache[page] = v
            if let t = snap.totals?[k] { recentPageCacheTotal[page] = t }
        }

        if let counts = snap.playCounts, !counts.isEmpty {
            trackPlayCounts.merge(counts) { current, _ in current }
        }
        if let unavailable = snap.playCountUnavailable, !unavailable.isEmpty {
            playCountUnavailable.formUnion(unavailable)
        }
        if let at = snap.playCountUnavailableAt {
            for (k, t) in at where playCountUnavailableAt[k] == nil {
                playCountUnavailableAt[k] = Date(timeIntervalSince1970: t)
            }
        }
        if let strikes = snap.playCountUnavailableStrikes {
            for (k, n) in strikes where playCountUnavailableStrikes[k] == nil { playCountUnavailableStrikes[k] = n }
        }
    }

    private func scheduleRecentPageCacheSave() {
        recentPageCacheSaveTask?.cancel()
        recentPageCacheSaveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let cred = credentials else { return }

            let capped = recentPageCache
                .filter { $0.key >= 1 && $0.key <= Self.recentPagePrefetchCount }
                .mapValues { $0.filter { $0.date != nil } }
            var scopedKeys = Set<String>()
            for rows in capped.values {
                for r in rows { scopedKeys.insert(Self.playCountKey(artist: r.artist, title: r.title)) }
            }
            let scopedCounts = trackPlayCounts.filter { scopedKeys.contains($0.key) }
            let scopedUnavailable = playCountUnavailable.intersection(scopedKeys)
            let snap = RecentPageCacheSnapshot(
                username: cred.user,
                pages: Dictionary(uniqueKeysWithValues: capped.map { (String($0.key), $0.value) }),
                playCounts: scopedCounts,
                playCountUnavailable: Array(scopedUnavailable),
                totals: Dictionary(uniqueKeysWithValues: capped.keys.compactMap { page in
                    recentPageCacheTotal[page].map { (String(page), $0) }
                }),
                playCountUnavailableAt: Dictionary(uniqueKeysWithValues: scopedUnavailable.compactMap { k in
                    playCountUnavailableAt[k].map { (k, $0.timeIntervalSince1970) }
                }),
                playCountUnavailableStrikes: Dictionary(uniqueKeysWithValues: scopedUnavailable.compactMap { k in
                    playCountUnavailableStrikes[k].map { (k, $0) }
                }))
            let url = Self.recentPageCacheURL
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snap) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    private func prefetchRecentPagesIfNeeded() {
        guard let cred = credentials, !recentPagesPrefetching else { return }
        if !recentPageCacheLoaded { loadRecentPageCache() }
        recentPagesPrefetching = true
        Task {
            defer { recentPagesPrefetching = false }
            var totalPages = recentTotalPages
            var fetchedAny = false
            for page in 1...Self.recentPagePrefetchCount {

                if totalPages > 0, page > totalPages { break }

                if let cached = recentPageCache[page], recentPageCacheTotal[page] != nil {
                    resolvePlayCounts(for: cached, priority: .background)
                    continue
                }
                guard let rows = await fetchRawPage(page, cred: cred, priority: .background)
                else { continue }
                if recentTotalPages > 0 { totalPages = recentTotalPages }
                fetchedAny = true
                resolvePlayCounts(for: rows, priority: .background)
            }
            if fetchedAny { scheduleRecentPageCacheSave() }
        }
    }

    private var rawPageFetchesInFlight = Set<Int>()

    private func fetchRawPage(_ page: Int, cred: (user: String, key: String),
                              priority: LastfmRateLimiter.Priority) async -> [RecentTrack]? {
        guard let json = await request(method: "user.getrecenttracks", cred: cred,
                                       extra: ["limit": String(Self.recentPageSize),
                                               "page": String(page)],
                                       priority: priority)
        else { return nil }
        applyRecentPaging(json)
        let rows = parseRecent(json)

        storeFetchedPage(page, rows: rows, json: json)
        return rows
    }

    private func storeFetchedPage(_ page: Int, rows: [RecentTrack], json: [String: Any]) {
        recentPageCache[page] = rows
        let total = attrTotal(json)
        if total > 0 { recentPageCacheTotal[page] = total }
        fetchedAt[Self.recentPageCacheKey(page)] = Date()
    }

    private func composeExactPage(_ page: Int) -> [RecentTrack]? {
        guard page >= 2, let feed = lastFeed, feed.isFresh() else { return nil }
        typealias Src = LastfmPageComposer.Source<RecentTrack>
        var sources = [Src(firstPosition: 0, rows: feedCompletedRows)]

        let cachedPages = recentPageCacheTotal.keys.sorted {
            (fetchedAt[Self.recentPageCacheKey($0)] ?? .distantPast) > (fetchedAt[Self.recentPageCacheKey($1)] ?? .distantPast)
        }
        for p in cachedPages {
            guard let rows = recentPageCache[p], let t = recentPageCacheTotal[p],
                  let first = LastfmPageComposer.firstPosition(page: p, pageSize: Self.recentPageSize,
                                                                totalAtFetch: t, totalNow: feed.total)
            else { continue }
            sources.append(Src(firstPosition: first, rows: rows.filter { $0.date != nil }))
        }
        return LastfmPageComposer.compose(page: page, pageSize: Self.recentPageSize, total: feed.total,
                                          sources: sources) { r in
            "\(r.date?.timeIntervalSince1970 ?? -1)|\(r.artist)|\(r.title)"
        }
    }

    private func prefetchNeighborPage(after page: Int) {
        let next = page + 1
        guard next <= recentTotalPages, recentPageCache[next] == nil,
              !rawPageFetchesInFlight.contains(next), let cred = credentials else { return }
        if composeExactPage(next) != nil { return }
        rawPageFetchesInFlight.insert(next)
        Task {
            defer { rawPageFetchesInFlight.remove(next) }
            _ = await fetchRawPage(next, cred: cred, priority: .background)
        }
    }

    @Published private(set) var charts: [String: [ChartEntry]] = [:]

    @Published private(set) var chartLoadingKeys: Set<String> = []
    @Published private(set) var chartFailedKeys: Set<String> = []

    func chartLoading(_ kind: ChartKind, _ period: Period) -> Bool {
        chartLoadingKeys.contains("\(kind.rawValue)|\(period.rawValue)")
    }
    func chartFailed(_ kind: ChartKind, _ period: Period) -> Bool {
        chartFailedKeys.contains("\(kind.rawValue)|\(period.rawValue)")
    }

    private var baselineGen = 0

    @Published private(set) var artistAvatars: [String: URL] = [:]

    @Published private(set) var trackCovers: [String: URL] = [:]

    @Published private(set) var trackPlayCounts: [String: Int] = [:]

    @Published private(set) var recentTrackCovers: [String: URL] = [:]

    @Published private(set) var recentAlbumCovers: [String: URL] = [:]

    private var playCountUnavailable = Set<String>()

    private var playCountUnavailableAt: [String: Date] = [:]
    private var playCountUnavailableStrikes: [String: Int] = [:]

    private static let playCountZeroGraceSecs: TimeInterval = 15 * 60
    private var coverUnavailable = Set<String>()

    private var lastAppliedRecentPage = 0

    private var playCountsInFlight = Set<String>()

    private var stalePlayCountKeys = Set<String>()
    @Published private(set) var baselineFailed = false
    @Published private(set) var chartFailed = false

    @Published private(set) var apiNowPlaying: RecentTrack?

    @Published private(set) var apiNowPlayingSince: Date?

    @Published private(set) var nowPlayingCount: Int?
    private var nowPlayingCountKey = ""

    private var nowPlayingCountPlayCountKey = ""

    @Published private(set) var nowPlayingSpan: TrackScrobbleSpan?
    private var nowPlayingSpanKey = ""

    struct TrackScrobbleSpan: Equatable {
        let total: Int
        let first: Date?
        let last: Date?
    }

    @Published var liveAbsorbedRecentID: String?

    @Published private(set) var onThisDay: OnThisDayResult?

    enum OnThisDayOutcome: Equatable { case pending, loaded, empty, failed }
    @Published private(set) var onThisDayOutcome: OnThisDayOutcome = .pending

    @Published private(set) var onThisDayUpdatedAt: Date?

    private var onThisDayDay: Date?

    struct OnThisDayResult: Equatable, Codable {

        struct TopTrack: Equatable, Identifiable, Codable {
            let track: RecentTrack
            let count: Int
            let lastPlayed: Date?
            var id: String { track.id }
        }
        let yearsAgo: Int
        let total: Int

        let top: [TopTrack]

        var span: OnThisDayPlanner.Span?
        var isWeek: Bool { span == .week }
    }

    private var fetchedAt: [String: Date] = [:]

    private let ttl: TimeInterval = 15 * 60

    private let baselineTTL: TimeInterval = 110

    func chart(_ kind: ChartKind, _ period: Period) -> [ChartEntry]? {
        charts["\(kind.rawValue)|\(period.rawValue)"]
    }

    func resetAll() {
        baselineGen += 1
        overview = nil
        recent = []
        apiNowPlaying = nil
        apiNowPlayingSince = nil
        nowPlayingCount = nil
        nowPlayingCountKey = ""
        nowPlayingCountPlayCountKey = ""
        onThisDay = nil
        onThisDayUpdatedAt = nil
        onThisDayDay = nil
        onThisDayOutcome = .pending
        snapshotSaveTask?.cancel()
        try? FileManager.default.removeItem(at: Self.snapshotURL)
        titleForms = [:]
        titleFormsSyncedThrough = 0
        titleFormsLoaded = false
        titleFormsLastTopUp = nil
        titleFormsSaveTask?.cancel()
        try? FileManager.default.removeItem(at: Self.titleFormsURL)
        primaryCreditFamilies = [:]
        discoverySaveTask?.cancel()
        try? FileManager.default.removeItem(at: Self.titleAliasDiscoveryURL)
        discoveredTitleAliases = [:]
        discoveredDurations = [:]
        discoveryAttemptedAt = [:]
        discoveryLoaded = false
        PlayCountFold.setDiscoveredTitleAliases([:])

        dailyCounts = [:]
        dailySyncedThrough = 0
        dailyLoaded = false
        dailySyncing = false
        historySyncGeneration += 1
        dailySyncFailed = false
        dailySyncProgress = nil
        pendingDailyRewind = nil
        try? FileManager.default.removeItem(at: Self.dailyURL)
        historyCheckpoint = nil
        historyCheckpointLoaded = false
        try? FileManager.default.removeItem(at: Self.historyCheckpointURL)
        bootstrapState = .notStarted
        charts = [:]
        artistAvatars = [:]
        trackCovers = [:]
        trackPlayCounts = [:]
        recentTrackCovers = [:]
        recentAlbumCovers = [:]
        recentCoverByTrack = [:]
        recentCoverByAlbum = [:]
        localCovers = [:]
        playCountUnavailable = []
        playCountUnavailableAt = [:]
        playCountUnavailableStrikes = [:]
        coverUnavailable = []
        playCountsInFlight = []
        stalePlayCountKeys = []
        playCountFetchedAt = [:]
        newestPlaySeen = [:]
        catalogCovers = [:]
        catalogCoverUnavailable = []
        catalogCoversInFlight = []
        artistCorrections = [:]
        artistCorrectionTasks.values.forEach { $0.cancel() }
        artistCorrectionTasks = [:]
        lastAppliedRecentPage = 0
        chartLoadingKeys = []
        chartFailedKeys = []
        baselineFailed = false
        recentPaging = false
        recentPage = 1
        recentTotalPages = 1
        recentUpdatedAt = nil
        recentPageCache = [:]
        recentPageCacheTotal = [:]
        feedCompletedRows = []
        recentPageCacheLoaded = false
        recentPagesPrefetching = false
        recentPageCacheSaveTask?.cancel()
        try? FileManager.default.removeItem(at: Self.recentPageCacheURL)
        fetchedAt = [:]

        lastFeed = nil
        feedMTime = nil
    }

    func refreshNowPlayingCount(title: String, artist: String) {
        let key = "\(artist)|\(title)"
        guard key != nowPlayingCountKey else { return }
        nowPlayingCountKey = key
        nowPlayingCountPlayCountKey = Self.playCountKey(artist: artist, title: title)

        nowPlayingCount = trackPlayCounts[nowPlayingCountPlayCountKey]
            .map { displayedNowPlayingCount(total: $0, playCountKey: nowPlayingCountPlayCountKey) }
        guard !title.isEmpty, let cred = credentials else { return }
        Task {

            let sibs = playCountSiblings(artist: artist, title: title)
            var results = [Int: (count: Int?, identity: String?)](minimumCapacity: sibs.count + 1)
            await withTaskGroup(of: (Int, (count: Int?, identity: String?)).self) { group in
                group.addTask { [weak self] in
                    (0, await self?.userPlayCount(artist: artist, title: title, cred: cred)
                        ?? (count: nil, identity: nil))
                }
                for (i, sib) in sibs.enumerated() {
                    group.addTask { [weak self] in
                        (i + 1, await self?.userPlayCount(artist: sib.artist, title: sib.title, cred: cred)
                            ?? (count: nil, identity: nil))
                    }
                }
                for await (i, r) in group { results[i] = r }
            }
            var total = results[0]?.count
            var identities = Set<String>()
            if let id = results[0]?.identity { identities.insert(id) }

            for i in sibs.indices {
                guard let r = results[i + 1], let c = r.count, let id = r.identity,
                      identities.insert(id).inserted else { continue }
                total = (total ?? 0) + c
            }
            guard nowPlayingCountKey == key else { return }
            if let total {

                adoptFreshTotal(total, artist: artist, title: title, siblings: sibs)

                nowPlayingCount = displayedNowPlayingCount(
                    total: total, playCountKey: nowPlayingCountPlayCountKey)
            }
        }
    }

    private func reconcileNowPlayingCount(with freshCounts: [String: Int]) {
        guard !nowPlayingCountPlayCountKey.isEmpty,
              let fresh = freshCounts[nowPlayingCountPlayCountKey],
              let updated = PlayCountRecency.reconciledNowPlayingCount(
                current: nowPlayingCount, freshTotal: fresh,
                currentPlayCounted: currentPlayIsScrobbled(playCountKey: nowPlayingCountPlayCountKey))
        else { return }
        nowPlayingCount = updated
    }

    private func displayedNowPlayingCount(total: Int, playCountKey key: String) -> Int {
        total + (currentPlayIsScrobbled(playCountKey: key) ? 0 : 1)
    }

    private func currentPlayIsScrobbled(playCountKey key: String) -> Bool {
        let pc = PlaybackCoordinator.shared
        guard !key.isEmpty, Self.playCountKey(artist: pc.artist, title: pc.title) == key,
              let anchor = pc.anchor else { return false }
        let playStart = anchor.fetchedAt.addingTimeInterval(-Double(anchor.progressMs) / 1000)
        let newest = recent.first {
            !$0.nowPlaying && $0.date != nil
                && Self.playCountKey(artist: $0.artist, title: $0.title) == key
        }?.date
        return PlayCountRecency.currentPlayIsScrobbled(newestScrobbleAt: newest, playStart: playStart)
    }

    func refreshNowPlayingSpan(title: String, artist: String) {
        let key = "\(artist)|\(title)"
        guard key != nowPlayingSpanKey else { return }
        nowPlayingSpanKey = key
        nowPlayingSpan = nil
        guard !title.isEmpty, credentials != nil else { return }
        Task {

            func page(_ n: Int) async -> (dates: [Date], total: Int)? {
                guard let p = await fetchTrackScrobbles(artist: artist, title: title, page: n, limit: 1)
                else { return nil }
                return (p.plays.map(\.date), p.total)
            }
            guard let head = await page(1) else { return }
            var first = head.dates.first
            var last = head.dates.first
            if head.total > 1 {

                first = (await page(head.total))?.dates.first
            }

            if let f = first, let l = last, f > l { swap(&first, &last) }
            guard nowPlayingSpanKey == key else { return }
            nowPlayingSpan = TrackScrobbleSpan(total: head.total, first: first, last: last)
        }
    }

    struct TrackScrobblesPage {
        let total: Int
        let totalPages: Int
        let plays: [(date: Date, album: String?)]
    }

    func fetchTrackScrobbles(artist: String, title: String, page: Int, limit: Int) async -> TrackScrobblesPage? {
        guard let cred = credentials else { return nil }

        guard let json = await request(
            method: "user.gettrackscrobbles", cred: cred,
            extra: ["artist": artist, "track": title, "limit": "\(limit)", "page": "\(page)"])
        else { return nil }

        guard let rt = (json["trackscrobbles"] ?? json["recenttracks"]) as? [String: Any]
        else { return nil }
        let attr = rt["@attr"] as? [String: Any]
        let total = (attr?["total"] as? String).flatMap { Int($0) } ?? 0
        let totalPages = (attr?["totalPages"] as? String).flatMap { Int($0) } ?? 1

        var tracks = (rt["track"] as? [[String: Any]]) ?? []
        if tracks.isEmpty, let single = rt["track"] as? [String: Any] { tracks = [single] }
        let plays = tracks.compactMap { t -> (date: Date, album: String?)? in
            guard let d = t["date"] as? [String: Any],
                  let uts = (d["uts"] as? String).flatMap({ TimeInterval($0) })
            else { return nil }
            let album = ((t["album"] as? [String: Any])?["#text"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            return (Date(timeIntervalSince1970: uts), album)
        }
        return TrackScrobblesPage(total: total, totalPages: totalPages, plays: plays)
    }

    func playCountFamily(artist: String, title: String) -> [(artist: String, title: String)] {
        [(artist, title)] + playCountSiblings(artist: artist, title: title)
    }

    private func userPlayCount(artist: String, title: String,
                               cred: (user: String, key: String),
                               priority: LastfmRateLimiter.Priority = .interactive)
        async -> (count: Int?, identity: String?)
    {
        let json = await request(method: "track.getinfo", cred: cred,
                                 extra: ["artist": artist, "track": title,
                                         "autocorrect": "1", "username": cred.user],
                                 priority: priority)
        guard let json else { return (nil, nil) }
        let count = (dig(json, "track", "userplaycount") as? String).flatMap { Int($0) }
        var identity: String?
        if let name = dig(json, "track", "name") as? String,
           let art = dig(json, "track", "artist", "name") as? String {
            identity = Self.playCountKey(artist: art, title: name)
        }
        return (count, identity)
    }

    func refreshOnThisDay(force: Bool = false) {
        let now = Date()

        if !force {
            guard DailyRefreshGate.needsRefresh(
                lastFetchedAt: fetchedAt["onthisday"], cachedDay: onThisDayDay,
                now: now, ttl: 6 * 3600)
            else { return }
        }
        guard let cred = credentials else { return }

        onThisDayOutcome = .pending

        fetchedAt["onthisday"] = now
        onThisDayDay = now

        if !dailyLoaded { loadDailySnapshot() }
        let windows = OnThisDayPlanner.plan(
            today: now, years: 3, dailyCounts: dailyCounts, synced: dailySyncedThrough > 0,
            dayKey: { Self.dayKey($0) })
        if windows.isEmpty {

            onThisDay = nil
            onThisDayOutcome = .empty
            return
        }
        Task {

            var responses = 0
            for window in windows {
                let yearsAgo = window.yearsAgo
                let base = ["from": String(Int(window.from.timeIntervalSince1970)),
                            "to": String(Int(window.to.timeIntervalSince1970)),
                            "limit": String(onThisDayPageSize)]
                guard let first = await request(method: "user.getrecenttracks", cred: cred, extra: base)
                else { continue }
                responses += 1
                let total = attrTotal(first)
                var rows = parseRecent(first).filter { $0.date != nil }
                guard total > 0, !rows.isEmpty else { continue }

                let totalPages = Int(dig(first, "recenttracks", "@attr", "totalPages") as? String ?? "") ?? 1
                if totalPages > 1 {
                    for page in 2...min(totalPages, onThisDayMaxPages) {
                        guard let more = await request(method: "user.getrecenttracks", cred: cred,
                                                       extra: base.merging(["page": String(page)]) { _, new in new })
                        else { break }
                        rows.append(contentsOf: parseRecent(more).filter { $0.date != nil })
                    }
                }
                var counts: [String: Int] = [:]
                var sample: [String: RecentTrack] = [:]
                var lastPlayed: [String: Date] = [:]
                for r in rows {
                    let k = Self.playCountKey(artist: r.artist, title: r.title)
                    counts[k, default: 0] += 1
                    if sample[k] == nil { sample[k] = r }
                    if let d = r.date, lastPlayed[k] == nil || d > lastPlayed[k]! { lastPlayed[k] = d }
                }

                let ranked = counts.keys.compactMap { key -> OnThisDayResult.TopTrack? in
                    guard let track = sample[key], let n = counts[key] else { return nil }
                    return OnThisDayResult.TopTrack(track: track, count: n, lastPlayed: lastPlayed[key])
                }.sorted { a, b in
                    if a.count != b.count { return a.count > b.count }
                    let ad = a.lastPlayed ?? .distantPast, bd = b.lastPlayed ?? .distantPast
                    if ad != bd { return ad > bd }
                    return a.track.title < b.track.title
                }
                guard !ranked.isEmpty else { continue }
                let top = Array(ranked.prefix(3))
                onThisDay = OnThisDayResult(yearsAgo: yearsAgo, total: total, top: top, span: window.span)
                onThisDayUpdatedAt = Date()
                onThisDayOutcome = .loaded
                scheduleSnapshotSave()

                refreshLocalCovers()
                resolvePlayCounts(for: top.map(\.track))
                return
            }

            if responses == windows.count {
                onThisDay = nil
                onThisDayOutcome = .empty
            } else {
                onThisDayOutcome = .failed
            }
        }
    }

    @Published private(set) var dailyCounts: [String: Int] = [:]
    @Published private(set) var dailySyncing = false

    @Published private(set) var dailySyncProgress: String?
    @Published private(set) var dailySyncFailed = false
    private var dailySyncedThrough: TimeInterval = 0
    private var dailyLoaded = false

    private var historySyncGeneration = 0

    private struct DailySnapshot: Codable {
        var username: String
        var syncedThrough: TimeInterval
        var days: [String: Int]
    }

    private static let dailyURL = LyrimusePaths.configFile("lyrimuse-lastfm-daily-heatmap.json")

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func dayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    private func loadDailySnapshot() {
        dailyLoaded = true
        guard let cred = credentials,
              let data = try? Data(contentsOf: Self.dailyURL),
              let snap = try? JSONDecoder().decode(DailySnapshot.self, from: data),
              snap.username == cred.user
        else { return }
        dailyCounts = snap.days
        dailySyncedThrough = snap.syncedThrough
    }

    private func saveDailySnapshot() {
        guard let cred = credentials else { return }
        let snap = DailySnapshot(username: cred.user, syncedThrough: dailySyncedThrough, days: dailyCounts)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: Self.dailyURL, options: .atomic)
        }
    }

    private var pendingDailyRewind: TimeInterval?

    private struct HistorySyncCheckpoint: Codable {
        var username: String
        var page: Int
        var from: TimeInterval
        var startedAt: TimeInterval
    }

    private static let historyCheckpointURL = LyrimusePaths.configFile("lyrimuse-lastfm-history-checkpoint.json")
    private var historyCheckpoint: HistorySyncCheckpoint?
    private var historyCheckpointLoaded = false

    private func loadHistoryCheckpoint() {
        historyCheckpointLoaded = true
        guard let cred = credentials,
              let data = try? Data(contentsOf: Self.historyCheckpointURL),
              let cp = try? JSONDecoder().decode(HistorySyncCheckpoint.self, from: data),
              cp.username == cred.user
        else { return }
        historyCheckpoint = cp
    }

    private func saveHistoryCheckpoint() {
        guard let cp = historyCheckpoint, let data = try? JSONEncoder().encode(cp) else {
            try? FileManager.default.removeItem(at: Self.historyCheckpointURL)
            return
        }
        try? data.write(to: Self.historyCheckpointURL, options: .atomic)
    }

    enum BootstrapState: Equatable {
        case notStarted
        case syncing(page: Int, totalPages: Int)
        case done
        case failed
    }

    @Published private(set) var bootstrapState: BootstrapState = .notStarted

    func ensureFirstSyncBootstrap() {
        guard credentials != nil else { return }
        if !titleFormsLoaded { loadTitleForms() }
        if !dailyLoaded { loadDailySnapshot() }

        if min(titleFormsSyncedThrough, dailySyncedThrough) > 0, !heatmapLooksTruncated() {
            bootstrapState = .done

            prefetchRecentPagesIfNeeded()
            return
        }
        syncHistoryIfNeeded()
    }

    func rewindDailySyncForBackfill() {
        if !dailyLoaded { loadDailySnapshot() }
        let target = Date().timeIntervalSince1970 - 14 * 86400
        guard dailySyncedThrough > target else { return }
        if dailySyncing {
            pendingDailyRewind = target
            return
        }
        dailySyncedThrough = target
        saveDailySnapshot()
    }

    private func applyPendingDailyRewind() {
        guard let target = pendingDailyRewind else { return }
        pendingDailyRewind = nil
        if dailySyncedThrough > target {
            dailySyncedThrough = target
            saveDailySnapshot()
        }
    }

    private func heatmapLooksTruncated() -> Bool {

        guard !truncationRescanAttempted else { return false }
        guard let total = overview?.total, total > 0 else { return false }
        return Double(dailyCounts.values.reduce(0, +)) < Double(total) * 0.7
    }
    private var truncationRescanAttempted = false

    func refreshDailyCounts() {
        syncHistoryIfNeeded()
    }

    private func syncHistoryIfNeeded() {
        guard !dailySyncing else { return }
        guard let cred = credentials else { return }
        if !dailyLoaded { loadDailySnapshot() }
        if !titleFormsLoaded { loadTitleForms() }
        if !historyCheckpointLoaded { loadHistoryCheckpoint() }

        var priorWatermark = min(titleFormsSyncedThrough, dailySyncedThrough)

        if priorWatermark > 0, heatmapLooksTruncated() {
            logger.notice("history sync: daily counts \(self.dailyCounts.values.reduce(0, +), privacy: .public) vs Last.fm total \(self.overview?.total ?? -1, privacy: .public) — heatmap truncated, forcing a full rescan")
            truncationRescanAttempted = true
            dailyCounts = [:]
            dailySyncedThrough = 0
            titleFormsSyncedThrough = 0
            historyCheckpoint = nil
            saveHistoryCheckpoint()
            priorWatermark = 0
        }
        let full = priorWatermark <= 0
        if !full, let last = titleFormsLastTopUp, Date().timeIntervalSince(last) < 15 * 60 { return }

        dailySyncing = true
        dailySyncFailed = false
        titleFormsLastTopUp = Date()
        let syncStartedAt = Date().timeIntervalSince1970
        var from: TimeInterval = 1
        var wipeFromDay: String?
        if !full {
            let lastDayStart = Calendar.current.startOfDay(
                for: Date(timeIntervalSince1970: priorWatermark))
            from = lastDayStart.timeIntervalSince1970
            wipeFromDay = Self.dayKey(lastDayStart)
        } else if let cp = historyCheckpoint, cp.username == cred.user {

            from = cp.from
        }

        let generation = historySyncGeneration
        Task {

            defer { if generation == historySyncGeneration { dailySyncing = false } }
            var page = (full ? historyCheckpoint?.page : nil).map { $0 + 1 } ?? 1
            var totalPages = 1
            var failed = false
            var fresh: [String: Int] = [:]

            while page <= totalPages && page <= 400 {
                let response = await request(
                    method: "user.getrecenttracks", cred: cred,
                    extra: ["limit": "200", "page": "\(page)", "from": "\(Int(from))"],
                    priority: .background)

                guard generation == historySyncGeneration else {
                    logger.notice("history sync: generation changed mid-flight (reset), abandoning this run")
                    return
                }
                guard let obj = response, let (rows, pages) = LastfmRecentTracksPage.parse(obj) else {
                    failed = true
                    break
                }
                totalPages = pages
                var pageCounts: [String: Int] = [:]
                for row in rows {

                    harvestTitleForm(artist: row.artist, title: row.title)
                    guard let uts = row.uts else { continue }
                    pageCounts[Self.dayKey(Date(timeIntervalSince1970: uts)), default: 0] += 1
                }
                if full {
                    for (k, v) in pageCounts { dailyCounts[k, default: 0] += v }
                } else {
                    for (k, v) in pageCounts { fresh[k, default: 0] += v }
                }
                if totalPages > 3 {
                    dailySyncProgress = String(
                        format: L10n.t("正在同步历史（%1$@/%2$@ 页）"), "\(page)", "\(totalPages)")
                }

                if full { bootstrapState = .syncing(page: page, totalPages: totalPages) }
                if full {

                    if page % 10 == 0 {
                        historyCheckpoint = HistorySyncCheckpoint(
                            username: cred.user, page: page, from: from, startedAt: syncStartedAt)
                        saveHistoryCheckpoint()
                        saveDailySnapshot()
                    }
                }
                page += 1

            }
            dailySyncProgress = nil
            if failed {
                dailySyncFailed = true
                if full {

                    if page > 1 {
                        historyCheckpoint = HistorySyncCheckpoint(
                            username: cred.user, page: page - 1, from: from, startedAt: syncStartedAt)
                        saveHistoryCheckpoint()
                    }
                    saveDailySnapshot()
                    bootstrapState = .failed
                }
                applyPendingDailyRewind()
                return
            }
            if !full {
                var days = dailyCounts
                if let wipe = wipeFromDay {

                    for k in days.keys where k >= wipe { days.removeValue(forKey: k) }
                }
                for (k, v) in fresh { days[k, default: 0] += v }
                dailyCounts = days
            }
            dailySyncedThrough = syncStartedAt
            titleFormsSyncedThrough = syncStartedAt
            scheduleTitleFormsSave()

            discoverTitleAliasesIfNeeded()
            applyPendingDailyRewind()
            saveDailySnapshot()
            if full {
                historyCheckpoint = nil
                saveHistoryCheckpoint()

                stalePlayCountKeys.formUnion(trackPlayCounts.keys)
                playCountUnavailable = []
                playCountUnavailableAt = [:]
                playCountUnavailableStrikes = [:]
                resolvePlayCounts(for: recent)

                refreshBaseline(force: true)
                for kind in ChartKind.allCases {
                    for period in Period.allCases { refreshChart(kind: kind, period: period) }
                }

                prefetchRecentPagesIfNeeded()
                bootstrapState = .done
            }
        }
    }

    struct TitleForm: Codable, Equatable {
        var artist: String
        var title: String
    }

    private struct TitleFormsSnapshot: Codable {
        var username: String
        var syncedThrough: TimeInterval
        var forms: [String: [TitleForm]]

        var foldVersion: Int?

        var lastTopUp: Date?
    }

    private static let titleFormsURL = LyrimusePaths.configFile("lyrimuse-lastfm-title-forms.json")

    private var titleForms: [String: [TitleForm]] = [:]

    private var titleFormsSyncedThrough: TimeInterval = 0
    private var titleFormsLoaded = false
    private var titleFormsSyncing = false
    private var titleFormsLastTopUp: Date?
    private var titleFormsSaveTask: Task<Void, Never>?

    private var primaryCreditFamilies: [String: [TitleForm]] = [:]

    private func rebuildPrimaryCreditFamilies() {
        var out: [String: [TitleForm]] = [:]
        for family in titleForms.values {
            for form in family { Self.insertForm(form, into: &out) }
        }
        primaryCreditFamilies = out
    }

    private static func insertForm(_ form: TitleForm, into index: inout [String: [TitleForm]]) {
        let key = PlayCountFold.familyKey(artist: form.artist, title: form.title)
        let raw = playCountKey(artist: form.artist, title: form.title)
        var fam = index[key] ?? []
        guard !fam.contains(where: { playCountKey(artist: $0.artist, title: $0.title) == raw })
        else { return }
        fam.append(form)
        index[key] = fam
    }

    private func adoptFreshTotal(_ total: Int, artist: String, title: String,
                                 siblings: [(artist: String, title: String)]) {
        var keys = [Self.playCountKey(artist: artist, title: title)]
        keys += siblings.map { Self.playCountKey(artist: $0.artist, title: $0.title) }
        for k in Set(keys) {
            trackPlayCounts[k] = total
            newestPlaySeen[k] = nil

            clearPlayCountUnavailable(k)
            stalePlayCountKeys.remove(k)
        }
        scheduleSnapshotSave()
    }

    private func playCountSiblings(artist: String, title: String) -> [(artist: String, title: String)] {
        if !titleFormsLoaded { loadTitleForms() }
        guard titleFormsSyncedThrough > 0 else {
            return PlayCountVariants.siblings(artist: artist, title: title)
        }
        let selfKey = Self.playCountKey(artist: artist, title: title)

        let family = primaryCreditFamilies[
            PlayCountFold.familyKey(artist: artist, title: title)] ?? []
        return family
            .filter { Self.playCountKey(artist: $0.artist, title: $0.title) != selfKey }
            .prefix(8)
            .map { ($0.artist, $0.title) }
    }

    private func harvestTitleForm(artist: String, title: String) {
        guard !artist.isEmpty, !title.isEmpty else { return }
        if !titleFormsLoaded { loadTitleForms() }
        let key = PlayCountFold.key(artist: artist, title: title)
        let raw = Self.playCountKey(artist: artist, title: title)
        var family = titleForms[key] ?? []
        guard !family.contains(where: { Self.playCountKey(artist: $0.artist, title: $0.title) == raw })
        else { return }
        let form = TitleForm(artist: artist, title: title)
        family.append(form)
        titleForms[key] = family

        Self.insertForm(form, into: &primaryCreditFamilies)
        scheduleTitleFormsSave()
    }

    private func loadTitleForms() {
        titleFormsLoaded = true

        if !discoveryLoaded { loadTitleAliasDiscovery() }

        refreshLocalAliases(rebuildFamilies: false)
        guard let cred = credentials,
              let data = try? Data(contentsOf: Self.titleFormsURL),
              let snap = try? JSONDecoder().decode(TitleFormsSnapshot.self, from: data),
              snap.username == cred.user
        else { return }
        if snap.foldVersion == PlayCountFold.foldVersion {

            titleForms = snap.forms
            rebuildPrimaryCreditFamilies()
            flushLocalAliasStaleMarks()
        } else {

            var refolded: [String: [TitleForm]] = [:]
            for family in snap.forms.values {
                for form in family {
                    let key = PlayCountFold.key(artist: form.artist, title: form.title)
                    let raw = Self.playCountKey(artist: form.artist, title: form.title)
                    var fam = refolded[key] ?? []
                    guard !fam.contains(where: { Self.playCountKey(artist: $0.artist, title: $0.title) == raw })
                    else { continue }
                    fam.append(form)
                    refolded[key] = fam
                }
            }
            titleForms = refolded
            rebuildPrimaryCreditFamilies()
            flushLocalAliasStaleMarks()
            scheduleTitleFormsSave()
        }
        titleFormsSyncedThrough = snap.syncedThrough

        if let last = snap.lastTopUp, last <= Date() { titleFormsLastTopUp = last }
    }

    private func scheduleTitleFormsSave() {
        titleFormsSaveTask?.cancel()
        titleFormsSaveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let cred = credentials else { return }
            let snap = TitleFormsSnapshot(
                username: cred.user, syncedThrough: titleFormsSyncedThrough, forms: titleForms,
                foldVersion: PlayCountFold.foldVersion, lastTopUp: titleFormsLastTopUp)
            let url = Self.titleFormsURL
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snap) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    private static let discoveryRuleVersion = 2

    struct TitleAliasDiscoverySnapshot: Codable {
        var username: String

        var ruleVersion: Int?

        var albums: [String: String]?
        var mbids: [String: String]?

        var aliases: [String: [String: String]]

        var durations: [String: Int]

        var attemptedAt: [String: TimeInterval]
    }

    private static let titleAliasDiscoveryURL = LyrimusePaths.configFile("lyrimuse-lastfm-title-aliases-discovered.json")

    private var discoveredTitleAliases: [String: [String: String]] = [:]
    private var discoveredDurations: [String: Int] = [:]

    private var discoveredAlbums: [String: String] = [:]
    private var discoveredMbids: [String: String] = [:]
    private var discoveryAttemptedAt: [String: Date] = [:]
    private var discoveryLoaded = false
    private var discoveryScanning = false
    private var discoverySaveTask: Task<Void, Never>?

    private static let discoveryRetryAfter: TimeInterval = 30 * 24 * 60 * 60

    private static let discoveryRequestBudget = 40

    private static let discoveryQuietSecs: TimeInterval = 60

    private func loadTitleAliasDiscovery() {
        discoveryLoaded = true
        guard let cred = credentials,
              let data = try? Data(contentsOf: Self.titleAliasDiscoveryURL),
              let snap = try? JSONDecoder().decode(TitleAliasDiscoverySnapshot.self, from: data),
              snap.username == cred.user
        else { return }

        discoveredDurations = snap.durations
        discoveredAlbums = snap.albums ?? [:]
        discoveredMbids = snap.mbids ?? [:]

        if (snap.ruleVersion ?? 1) == Self.discoveryRuleVersion {
            discoveredTitleAliases = snap.aliases
            discoveryAttemptedAt = snap.attemptedAt.mapValues { Date(timeIntervalSince1970: $0) }
        } else {

            logger.notice("title alias discovery: rule version \(snap.ruleVersion ?? 1, privacy: .public) -> \(Self.discoveryRuleVersion, privacy: .public), dropping \(snap.aliases.values.reduce(0) { $0 + $1.count }, privacy: .public) stale alias(es) for rescan")
            discoveredTitleAliases = [:]
            discoveryAttemptedAt = [:]

            trackPlayCounts = [:]
            scheduleTitleAliasDiscoverySave()
        }
        PlayCountFold.setDiscoveredTitleAliases(discoveredTitleAliases)
    }

    private func scheduleTitleAliasDiscoverySave() {
        discoverySaveTask?.cancel()
        discoverySaveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let cred = credentials else { return }
            let snap = TitleAliasDiscoverySnapshot(
                username: cred.user, ruleVersion: Self.discoveryRuleVersion,
                albums: discoveredAlbums, mbids: discoveredMbids,
                aliases: discoveredTitleAliases, durations: discoveredDurations,
                attemptedAt: discoveryAttemptedAt.mapValues { $0.timeIntervalSince1970 })
            let url = Self.titleAliasDiscoveryURL
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snap) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    private func discoverTitleAliasesIfNeeded() {
        guard let cred = credentials, !discoveryScanning else { return }
        if !discoveryLoaded { loadTitleAliasDiscovery() }

        struct FamilyRep { let artist: String; let title: String }
        var byArtist: [String: (han: [FamilyRep], nonHan: [FamilyRep])] = [:]
        for forms in primaryCreditFamilies.values {
            guard let rep = forms.first else { continue }
            let artistKey = PlayCountFold.canonicalArtistKey(rep.artist)
            var bucket = byArtist[artistKey] ?? ([], [])
            let entry = FamilyRep(artist: rep.artist, title: rep.title)
            if PlayCountFold.hasNoHanLikeChars(rep.title) { bucket.nonHan.append(entry) }
            else { bucket.han.append(entry) }
            byArtist[artistKey] = bucket
        }

        struct Candidate { let artist: String; let title: String; let hanCandidates: [FamilyRep] }
        var candidates: [Candidate] = []
        let now = Date()
        for bucket in byArtist.values {
            guard !bucket.han.isEmpty else { continue }
            for nonHan in bucket.nonHan {
                let attemptKey = Self.playCountKey(artist: nonHan.artist, title: nonHan.title)
                if let last = discoveryAttemptedAt[attemptKey],
                   now.timeIntervalSince(last) < Self.discoveryRetryAfter { continue }
                candidates.append(Candidate(artist: nonHan.artist, title: nonHan.title,
                                            hanCandidates: bucket.han))
            }
        }
        guard !candidates.isEmpty else { return }

        discoveryScanning = true
        Task {
            defer { discoveryScanning = false }

            guard await LastfmRateLimiter.shared.interactiveIdle(for: Self.discoveryQuietSecs) else {
                logger.debug("title alias discovery: foreground requests not quiet, skipping this round")
                return
            }

            var requestsLeft = Self.discoveryRequestBudget

            let canAfford: (String, String) -> Bool = { artist, title in
                if self.discoveredDurations[Self.playCountKey(artist: artist, title: title)] != nil { return true }
                guard requestsLeft > 0 else { return false }
                requestsLeft -= 1
                return true
            }
            scan: for candidate in candidates {
                let ownKey = Self.playCountKey(artist: candidate.artist, title: candidate.title)
                guard canAfford(candidate.artist, candidate.title) else { break }

                for han in candidate.hanCandidates where !canAfford(han.artist, han.title) {
                    break scan
                }
                guard let own = await trackFactsFor(artist: candidate.artist, title: candidate.title,
                                                    cred: cred)
                else { continue }
                discoveryAttemptedAt[ownKey] = Date()
                guard own.duration > 0 else { continue }

                var matches: [FamilyRep] = []
                for han in candidate.hanCandidates {
                    guard let hanFacts = await trackFactsFor(artist: han.artist, title: han.title, cred: cred),
                          hanFacts.duration > 0 else { continue }
                    guard hanFacts.duration == own.duration else { continue }
                    guard Self.evidenceAgrees(own, hanFacts) else { continue }
                    matches.append(han)
                }
                guard matches.count == 1, let matched = matches.first else { continue }

                let artistKey = PlayCountFold.canonicalArtistKey(candidate.artist)
                let foldedTitle = PlayCountFold.foldTitle(candidate.title)

                if let claimedBy = forArtistClaimants(artistKey: artistKey, target: matched.title),
                   claimedBy != foldedTitle {
                    var forArtist = discoveredTitleAliases[artistKey] ?? [:]
                    forArtist.removeValue(forKey: claimedBy)
                    discoveredTitleAliases[artistKey] = forArtist
                    PlayCountFold.setDiscoveredTitleAliases(discoveredTitleAliases)
                    rebuildPrimaryCreditFamilies()
                    logger.notice("title alias discovery: dropped both claims on one target (reverse collision)")
                    continue
                }
                var forArtist = discoveredTitleAliases[artistKey] ?? [:]
                forArtist[foldedTitle] = matched.title
                discoveredTitleAliases[artistKey] = forArtist
                PlayCountFold.setDiscoveredTitleAliases(discoveredTitleAliases)
                rebuildPrimaryCreditFamilies()
                let newFamKey = PlayCountFold.familyKey(artist: candidate.artist, title: candidate.title)
                for form in primaryCreditFamilies[newFamKey] ?? [] {

                    stalePlayCountKeys.insert(Self.playCountKey(artist: form.artist, title: form.title))
                }
            }
            scheduleTitleAliasDiscoverySave()
            scheduleSnapshotSave()
        }
    }

    private var localAliasTables = EnrichCacheReader.LocalAliasTables.empty
    private var localAliasRefreshTask: Task<Void, Never>?

    private func refreshLocalAliases(rebuildFamilies: Bool) {
        if let ready = EnrichCacheReader.localAliasTablesIfComputed {
            applyLocalAliases(ready, rebuildFamilies: rebuildFamilies)
            return
        }
        localAliasRefreshTask?.cancel()
        localAliasRefreshTask = Task { @MainActor [weak self] in
            let tables = await EnrichCacheReader.computeLocalAliasTables()
            guard let self, !Task.isCancelled else { return }

            self.applyLocalAliases(tables, rebuildFamilies: self.titleFormsLoaded)
        }
    }

    private func applyLocalAliases(_ tables: EnrichCacheReader.LocalAliasTables, rebuildFamilies: Bool) {
        guard tables != localAliasTables else { return }
        let old = localAliasTables
        localAliasTables = tables
        PlayCountFold.setLocalArtistAliases(tables.artists)
        PlayCountFold.setLocalTitleAliases(tables.titles)

        for key in Set(old.artists.keys).union(tables.artists.keys) where old.artists[key] != tables.artists[key] {
            pendingLocalArtistTouched.insert(key)
            if let v = old.artists[key] { pendingLocalArtistTouched.insert(LocalArtistAliases.artistKey(v)) }
            if let v = tables.artists[key] { pendingLocalArtistTouched.insert(LocalArtistAliases.artistKey(v)) }
        }
        for artistKey in Set(old.titles.keys).union(tables.titles.keys) {
            let before = old.titles[artistKey] ?? [:], after = tables.titles[artistKey] ?? [:]
            for eng in Set(before.keys).union(after.keys) where before[eng] != after[eng] {
                pendingLocalAliasTouched[artistKey, default: []].insert(eng)
                if let h = before[eng] { pendingLocalAliasTouched[artistKey, default: []].insert(PlayCountFold.foldTitle(h)) }
                if let h = after[eng] { pendingLocalAliasTouched[artistKey, default: []].insert(PlayCountFold.foldTitle(h)) }
            }
        }
        logger.notice("local aliases: \(tables.artists.count, privacy: .public) artist + \(tables.titles.values.reduce(0) { $0 + $1.count }, privacy: .public) title alias(es) inferred from local caches")

        let artistItems = tables.artists.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" }
        let titleItems = tables.titles.sorted { $0.key < $1.key }
            .flatMap { a, m in m.sorted { $0.key < $1.key }.map { "\(a)|\($0.key)→\($0.value)" } }
        for (label, items) in [("artists", artistItems), ("titles", titleItems)] {
            var start = 0
            while start < items.count {
                let chunk = items[start..<min(start + 12, items.count)].joined(separator: "; ")
                logger.notice("local aliases · \(label, privacy: .public) [\(start, privacy: .public)+]: \(chunk, privacy: .public)")
                start += 12
            }
        }
        guard rebuildFamilies else { return }
        rebuildPrimaryCreditFamilies()
        flushLocalAliasStaleMarks()
    }

    private var pendingLocalAliasTouched: [String: Set<String>] = [:]
    private var pendingLocalArtistTouched: Set<String> = []

    private func flushLocalAliasStaleMarks() {
        guard !primaryCreditFamilies.isEmpty,
              !(pendingLocalAliasTouched.isEmpty && pendingLocalArtistTouched.isEmpty) else { return }
        let touchedTitles = pendingLocalAliasTouched, touchedArtists = pendingLocalArtistTouched
        pendingLocalAliasTouched = [:]
        pendingLocalArtistTouched = []
        var marked = 0
        for family in primaryCreditFamilies.values {
            for form in family {
                let canonKey = PlayCountFold.canonicalArtistKey(form.artist)
                var hit = touchedArtists.contains(canonKey) || touchedArtists.contains(LocalArtistAliases.artistKey(form.artist))
                if !hit, let folded = touchedTitles[canonKey], folded.contains(PlayCountFold.foldTitle(form.title)) { hit = true }
                guard hit else { continue }
                stalePlayCountKeys.insert(Self.playCountKey(artist: form.artist, title: form.title))
                marked += 1
            }
        }
        if marked > 0 {
            logger.notice("local aliases: \(marked, privacy: .public) play-count key(s) marked stale")
        }
    }

    private static func evidenceAgrees(_ a: TrackFacts, _ b: TrackFacts) -> Bool {
        TitleAliasEvidence.agrees(mbidA: a.mbid, albumA: a.album, mbidB: b.mbid, albumB: b.album)
    }

    private func forArtistClaimants(artistKey: String, target: String) -> String? {
        discoveredTitleAliases[artistKey]?.first { $0.value == target }?.key
    }

    private func durationFor(artist: String, title: String,
                             cred: (user: String, key: String)) async -> Int? {
        await trackFactsFor(artist: artist, title: title, cred: cred)?.duration
    }

    private struct TrackFacts {
        var duration: Int
        var album: String
        var mbid: String
    }

    private func trackFactsFor(artist: String, title: String,
                               cred: (user: String, key: String)) async -> TrackFacts? {
        let key = Self.playCountKey(artist: artist, title: title)
        if let d = discoveredDurations[key] {
            return TrackFacts(duration: d,
                              album: discoveredAlbums[key] ?? "",
                              mbid: discoveredMbids[key] ?? "")
        }
        guard let json = await request(method: "track.getinfo", cred: cred,
                                       extra: ["artist": artist, "track": title, "autocorrect": "1"],
                                       priority: .background)
        else { return nil }
        let duration = (dig(json, "track", "duration") as? String).flatMap { Int($0) } ?? 0
        let album = (dig(json, "track", "album", "title") as? String) ?? ""
        let mbid = (dig(json, "track", "mbid") as? String) ?? ""
        discoveredDurations[key] = duration
        discoveredAlbums[key] = album
        discoveredMbids[key] = mbid
        return TrackFacts(duration: duration, album: album, mbid: mbid)
    }

    private struct StatsSnapshot: Codable {
        var username: String
        var overview: Overview?
        var recent: [RecentTrack]

        var recentLimit: Int?
        var charts: [String: [ChartEntry]]
        var artistAvatars: [String: URL]
        var trackCovers: [String: URL]

        var trackPlayCounts: [String: Int]?
        var recentTrackCovers: [String: URL]?
        var recentAlbumCovers: [String: URL]?

        var catalogCovers: [String: URL]?

        var playCountVerifiedAt: [String: Date]?

        var mergedCountsVersion: Int?

        var recentTotalPages: Int?

        var onThisDay: OnThisDayResult?
        var onThisDayDay: Date?
        var onThisDayUpdatedAt: Date?

        var fetchedAt: [String: Date]?
    }

    private static let persistedFetchedAtKeys: Set<String> = {
        var keys: Set<String> = ["baseline", "onthisday"]
        for kind in ChartKind.allCases {
            for period in Period.allCases { keys.insert("\(kind.rawValue)|\(period.rawValue)") }
        }
        return keys
    }()

    private static let snapshotURL = LyrimusePaths.configFile("lyrimuse-lastfm-stats-cache.json")
    private var snapshotSaveTask: Task<Void, Never>?

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snap = try? JSONDecoder().decode(StatsSnapshot.self, from: data) else { return }

        guard let cred = credentials, cred.user == snap.username else { return }
        overview = snap.overview
        recent = snap.recent

        recentPage = 1

        recentTotalPages = snap.recentTotalPages ?? 1
        charts = snap.charts
        artistAvatars = snap.artistAvatars
        trackCovers = snap.trackCovers

        trackPlayCounts = snap.mergedCountsVersion == 15 ? (snap.trackPlayCounts ?? [:]) : [:]

        playCountVerifiedAt = trackPlayCounts.isEmpty ? [:] : (snap.playCountVerifiedAt ?? [:])
        recentTrackCovers = snap.recentTrackCovers ?? [:]
        recentAlbumCovers = snap.recentAlbumCovers ?? [:]
        catalogCovers = snap.catalogCovers ?? [:]

        if let day = snap.onThisDay {
            onThisDay = day
            onThisDayDay = snap.onThisDayDay
            onThisDayUpdatedAt = snap.onThisDayUpdatedAt
            onThisDayOutcome = .loaded
        }

        if let saved = snap.fetchedAt {
            for (k, v) in saved where Self.persistedFetchedAtKeys.contains(k) {

                switch k {
                case "onthisday": if snap.onThisDay == nil { continue }
                case "baseline": if snap.recent.isEmpty && snap.overview == nil { continue }
                default: if snap.charts[k] == nil { continue }
                }
                fetchedAt[k] = v
            }
        }

        refreshLocalCovers()

        rebuildRecentCoverIndex()

        var urlsToPrewarm: [URL] = []
        urlsToPrewarm.append(contentsOf: artistAvatars.values)
        urlsToPrewarm.append(contentsOf: recentTrackCovers.values)
        urlsToPrewarm.append(contentsOf: recentAlbumCovers.values)
        urlsToPrewarm.append(contentsOf: catalogCovers.values)
        urlsToPrewarm.append(contentsOf: charts.values.flatMap { $0.compactMap(\.imageURL) })
        urlsToPrewarm.append(contentsOf: recent.compactMap(\.imageURL))
        if let top = onThisDay?.top {
            urlsToPrewarm.append(contentsOf: top.compactMap(\.track.imageURL))
        }
        ImageMemoryCache.shared.prewarm(urlsToPrewarm)

    }

    private func scheduleSnapshotSave() {
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let cred = credentials else { return }

            guard recentPage == 1 else { return }

            let rows = recent.filter { $0.date != nil }
            var keptCounts: [String: Int] = [:]
            var keptCovers: [String: URL] = [:]
            var keptAlbumCovers: [String: URL] = [:]
            var keptCatalogCovers: [String: URL] = [:]
            var keptVerifiedAt: [String: Date] = [:]
            for r in rows {
                let key = Self.playCountKey(artist: r.artist, title: r.title)
                if let n = trackPlayCounts[key] { keptCounts[key] = n }
                if let c = recentTrackCovers[key] { keptCovers[key] = c }
                if let c = catalogCovers[key] { keptCatalogCovers[key] = c }
                if let t = playCountVerifiedAt[key] { keptVerifiedAt[key] = t }
                if let ak = Self.albumKey(artist: r.artist, album: r.album), let c = recentAlbumCovers[ak] {
                    keptAlbumCovers[ak] = c
                }
            }

            for t in onThisDay?.top.map(\.track) ?? [] {
                let key = Self.playCountKey(artist: t.artist, title: t.title)
                if let c = recentTrackCovers[key] { keptCovers[key] = c }
                if let c = catalogCovers[key] { keptCatalogCovers[key] = c }
                if let ak = Self.albumKey(artist: t.artist, album: t.album), let c = recentAlbumCovers[ak] {
                    keptAlbumCovers[ak] = c
                }
            }
            let snap = StatsSnapshot(
                username: cred.user, overview: overview,
                recent: rows,
                recentLimit: nil,
                charts: charts, artistAvatars: artistAvatars, trackCovers: trackCovers,
                trackPlayCounts: keptCounts,
                recentTrackCovers: keptCovers, recentAlbumCovers: keptAlbumCovers,
                catalogCovers: keptCatalogCovers,
                playCountVerifiedAt: keptVerifiedAt,
                mergedCountsVersion: 15,
                recentTotalPages: recentTotalPages,
                onThisDay: onThisDayOutcome == .loaded ? onThisDay : nil,
                onThisDayDay: onThisDayOutcome == .loaded ? onThisDayDay : nil,
                onThisDayUpdatedAt: onThisDayOutcome == .loaded ? onThisDayUpdatedAt : nil,
                fetchedAt: fetchedAt.filter { Self.persistedFetchedAtKeys.contains($0.key) })

            let url = Self.snapshotURL
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snap) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    private var credentials: (user: String, key: String)? {
        let c = ConfigStore.shared
        let user = c.lastfmScrobbleUsername.isEmpty ? c.lastfmUser : c.lastfmScrobbleUsername
        let key = c.lastfmScrobbleAPIKey.isEmpty ? c.lastfmAPIKey : c.lastfmScrobbleAPIKey
        guard !user.isEmpty, !key.isEmpty else { return nil }
        return (user, key)
    }

    var isConnected: Bool { credentials != nil }

    func refreshBaselineAndWait(force: Bool = true) async {
        let before = recentUpdatedAt
        refreshBaseline(force: force)
        guard credentials != nil else { return }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if baselineFailed || recentUpdatedAt != before { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    func refreshBaseline(force: Bool = false) {

        ensureFirstSyncBootstrap()
        if force { fetchedAt["baseline"] = nil }

        guard fresh("baseline", ttl: baselineTTL) == false else {
            logger.debug("refreshBaseline early exit: TTL not expired (baselineTTL=\(self.baselineTTL, privacy: .public)s, force=\(force, privacy: .public))")
            return
        }
        guard let cred = credentials else {
            logger.debug("refreshBaseline early exit: no account credentials")
            return
        }
        fetchedAt["baseline"] = Date()
        baselineGen += 1
        let gen = baselineGen

        let requestedPage = recentPage
        Task {
            baselineFailed = false

            async let recentJSON = request(method: "user.getrecenttracks", cred: cred,
                                           extra: ["limit": String(Self.recentPageSize),
                                                   "page": String(requestedPage)])

            let dayStart = Calendar.current.startOfDay(for: Date())
            async let todayJSON = request(method: "user.getrecenttracks", cred: cred,
                                          extra: ["limit": "1", "from": String(Int(dayStart.timeIntervalSince1970))])
            async let weekJSON = request(method: "user.getrecenttracks", cred: cred,
                                         extra: ["limit": "1", "from": String(Int(Date().timeIntervalSince1970 - 7 * 86400))])
            let (r, t, w) = await (recentJSON, todayJSON, weekJSON)
            guard gen == baselineGen else { return }

            if let r {
                let rows = parseRecent(r)
                applyRecent(rows)
                applyRecentPaging(r)

                storeFetchedPage(requestedPage, rows: rows, json: r)
            }
            mergeOverview(total: r.map(attrTotal), today: t.map(attrTotal), week: w.map(attrTotal))
            if r == nil || t == nil || w == nil {
                fetchedAt["baseline"] = nil
                logger.warning("refreshBaseline partially failed: recent=\(r != nil, privacy: .public) today=\(t != nil, privacy: .public) week=\(w != nil, privacy: .public)")
            }
            if r == nil {
                baselineFailed = true
                return
            }
            scheduleSnapshotSave()
        }
    }

    private func mergeOverview(total: Int?, today: Int?, week: Int?) {
        if var ov = overview {
            if let total { ov.total = total }
            if let today { ov.today = today }
            if let week { ov.week = week }
            overview = ov
        } else if let total, let today, let week {
            overview = Overview(total: total, today: today, week: week)
        }
    }

    nonisolated static func albumKey(artist: String, album: String?) -> String? {
        guard let a = album?.trimmingCharacters(in: .whitespaces), !a.isEmpty else { return nil }
        return artist.trimmingCharacters(in: .whitespaces).lowercased() + "|" + a.lowercased()
    }

    func coverURL(for track: RecentTrack) -> URL? {
        if let own = track.imageURL {

            if let verified = localAlbumVerifiedCovers[Self.playCountKey(artist: track.artist, title: track.title)],
               verified != own {
                return verified
            }

            if let key = ArtistCredit.albumConsensusKey(artist: track.artist, album: track.album),
               let consensus = albumConsensusCovers[key], consensus != own {
                return consensus
            }
            return own
        }
        if let local = localCovers[Self.playCountKey(artist: track.artist, title: track.title)] {
            return local
        }
        if let byTrack = recentTrackCovers[Self.playCountKey(artist: track.artist, title: track.title)] {
            return byTrack
        }
        if let key = Self.albumKey(artist: track.artist, album: track.album),
           let byAlbum = recentAlbumCovers[key] { return byAlbum }

        return catalogCovers[Self.playCountKey(artist: track.artist, title: track.title)]
    }

    @Published private(set) var catalogCovers: [String: URL] = [:]

    private var catalogCoverUnavailable = Set<String>()
    private var catalogCoversInFlight = Set<String>()

    private static let catalogCoverBatch = 6

    private(set) var localCovers: [String: URL] = [:]

    private(set) var localAlbumVerifiedCovers: [String: URL] = [:]

    private var localCoversStamp: Date?

    func refreshLocalCoversIfCacheChanged() {
        EnrichCacheReader.refreshIfNeeded()
        let stamp = EnrichCacheReader.decodedContentVersion
        guard stamp != localCoversStamp else { return }
        localCoversStamp = stamp
        refreshLocalCovers()

        if titleFormsLoaded { refreshLocalAliases(rebuildFamilies: true) }
    }

    private func refreshLocalCovers() {
        var out: [String: URL] = [:]
        var verified: [String: URL] = [:]
        for r in recent + (onThisDay?.top.map(\.track) ?? []) {
            let key = Self.playCountKey(artist: r.artist, title: r.title)
            if out[key] == nil,
               let url = EnrichCacheReader.coverURL(artist: r.artist, title: r.title, album: r.album ?? "") {
                out[key] = url
            }

            if verified[key] == nil, let album = r.album, !album.isEmpty,
               let url = EnrichCacheReader.albumVerifiedCoverURL(artist: r.artist, title: r.title, album: album) {
                verified[key] = url
            }
        }
        localCovers = out
        localAlbumVerifiedCovers = verified
    }

    private(set) var recentCoverByTrack: [String: URL] = [:]
    private(set) var recentCoverByAlbum: [String: URL] = [:]

    private var albumConsensusCovers: [String: URL] = [:]

    private func rebuildRecentCoverIndex() {

        albumConsensusCovers = ArtistCredit.albumConsensusCovers(
            rows: recent.map { (artist: $0.artist, album: $0.album, image: $0.imageURL) })
        var byTrack: [String: URL] = [:]
        var byAlbum: [String: URL] = [:]
        for r in recent where !r.nowPlaying {
            guard let url = coverURL(for: r) else { continue }
            let key = Self.playCountKey(artist: r.artist, title: r.title)
            if byTrack[key] == nil { byTrack[key] = url }

            if let ak = Self.albumKey(artist: r.artist, album: r.album), byAlbum[ak] == nil {
                byAlbum[ak] = url
            }
        }
        recentCoverByTrack = byTrack
        recentCoverByAlbum = byAlbum
    }

    func liveCoverURL(artist: String, title: String, album: String) -> URL? {
        if let url = recentCoverByTrack[Self.playCountKey(artist: artist, title: title)] { return url }
        if let ak = Self.albumKey(artist: artist, album: album) { return recentCoverByAlbum[ak] }
        return nil
    }

    nonisolated static func playCountKey(artist: String, title: String) -> String {
        artist.trimmingCharacters(in: .whitespaces).lowercased()
            + "|" + title.trimmingCharacters(in: .whitespaces).lowercased()
    }

    func isPlayCountUnavailable(artist: String, title: String) -> Bool {
        playCountUnavailable.contains(Self.playCountKey(artist: artist, title: title))
    }

    private func playCountUnavailableDue(_ key: String, now: Date) -> Bool {
        guard playCountUnavailable.contains(key) else { return true }
        guard let at = playCountUnavailableAt[key] else { return true }
        return PlayCountUnavailableBackoff.isDue(markedAt: at, strikes: playCountUnavailableStrikes[key] ?? 1, now: now)
    }

    private func markPlayCountUnavailable(_ key: String, at stamp: Date) {
        playCountUnavailable.insert(key)
        playCountUnavailableAt[key] = stamp
        playCountUnavailableStrikes[key] = (playCountUnavailableStrikes[key] ?? 0) + 1
    }

    private func clearPlayCountUnavailable(_ key: String) {
        playCountUnavailable.remove(key)
        playCountUnavailableAt[key] = nil
        playCountUnavailableStrikes[key] = nil
    }

    private func applyRecent(_ rows: [RecentTrack]) {

        let localAdKey: String? = {
            let pc = PlaybackCoordinator.shared
            guard pc.isCurrentTrackAdBreak else { return nil }
            return Self.playCountKey(artist: pc.artist, title: pc.title)
        }()
        let rows = rows.filter { r in
            guard r.nowPlaying else { return true }
            if r.artist.isEmpty || r.title == "—" { return false }
            if let localAdKey, Self.playCountKey(artist: r.artist, title: r.title) == localAdKey {
                return false
            }
            return true
        }

        for r in rows where !r.artist.isEmpty && !r.title.isEmpty {
            harvestTitleForm(artist: r.artist, title: r.title)
        }

        var sample: [String: RecentTrack] = [:]
        for r in rows where !r.nowPlaying {
            let k = Self.playCountKey(artist: r.artist, title: r.title)
            if sample[k] == nil { sample[k] = r }
        }
        let newestNow = Self.newestPlayByKey(rows)
        var staleKeys = Set<String>()

        if lastAppliedRecentPage == recentPage {
            let before = countByKey(recent)

            staleKeys.formUnion(countByKey(rows).compactMap { key, n in
                n > (before[key] ?? 0) ? key : nil
            })

            for (key, newest) in newestNow {
                guard let seen = newestPlaySeen[key], newest > seen else { continue }
                staleKeys.insert(key)
            }
        }

        staleKeys.formUnion(contradictedPlayCountKeys(rows, now: Date()))

        staleKeys.formUnion(staleByAgePlayCountKeys(rows, now: Date()))

        for (key, newest) in newestNow where (newestPlaySeen[key] ?? .distantPast) < newest {
            newestPlaySeen[key] = newest
        }
        for key in staleKeys {

            stalePlayCountKeys.insert(key)

            if let r = sample[key] {
                for sib in playCountSiblings(artist: r.artist, title: r.title) {
                    stalePlayCountKeys.insert(Self.playCountKey(artist: sib.artist, title: sib.title))
                }
            }
        }
        lastAppliedRecentPage = recentPage
        recentUpdatedAt = Date()
        recent = rows

        refreshLocalCovers()
        rebuildRecentCoverIndex()
        let next = rows.first(where: \.nowPlaying)
        let nextKey = next.map { "\($0.artist)|\($0.title)" }
        let prevKey = apiNowPlaying.map { "\($0.artist)|\($0.title)" }
        if nextKey != prevKey {
            apiNowPlayingSince = next == nil ? nil : Date()
        }
        apiNowPlaying = next
        resolvePlayCounts(for: rows)

        resolveCatalogCovers(for: rows)
    }

    nonisolated static func newestPlayByKey(_ rows: [RecentTrack]) -> [String: Date] {
        PlayCountRecency.newest(rows.filter { !$0.nowPlaying }.map {
            (key: playCountKey(artist: $0.artist, title: $0.title), date: $0.date)
        })
    }

    private var newestPlaySeen: [String: Date] = [:]

    private func resolveCatalogCovers(for rows: [RecentTrack]) {
        let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
        var seen = Set<String>()
        let all = rows.compactMap { r -> (key: String, artist: String, title: String, album: String?)? in
            guard !r.nowPlaying, !r.artist.isEmpty, !r.title.isEmpty else { return nil }
            let key = Self.playCountKey(artist: r.artist, title: r.title)
            guard coverURL(for: r) == nil,
                  coverUnavailable.contains(key),
                  !catalogCoverUnavailable.contains(key),
                  !catalogCoversInFlight.contains(key),
                  seen.insert(key).inserted
            else { return nil }
            return (key, r.artist, r.title, r.album)
        }

        let targets = Array(all.prefix(Self.catalogCoverBatch))
        guard !targets.isEmpty else { return }
        targets.forEach { catalogCoversInFlight.insert($0.key) }
        Task {
            defer { targets.forEach { catalogCoversInFlight.remove($0.key) } }
            var found: [String: URL] = [:]
            var missed = Set<String>()

            await withTaskGroup(of: (String, MusicCatalogSearch.ArtworkMatch?, Bool).self) { group in
                var index = 0
                func addNext() {
                    guard index < targets.count else { return }
                    let item = targets[index]
                    index += 1
                    group.addTask {
                        let hit = await MusicCatalogSearch.resolveArtwork(
                            title: item.title, artist: item.artist, album: item.album,
                            storefront: storefront)
                        return (item.key, hit, true)
                    }
                }
                for _ in 0..<min(2, targets.count) { addNext() }
                for await (key, hit, ok) in group {
                    if let hit {
                        found[key] = hit.url
                        logger.notice("catalog cover: \(hit.confidence.rawValue, privacy: .public) for \(key, privacy: .public)")
                    } else if ok {

                        missed.insert(key)
                    }
                    addNext()
                }
            }
            if !found.isEmpty {
                catalogCovers.merge(found) { _, new in new }

                rebuildRecentCoverIndex()
                scheduleSnapshotSave()
            }
            catalogCoverUnavailable.formUnion(missed)
        }
    }

    private var playCountFetchedAt: [String: Date] = [:]

    private var playCountVerifiedAt: [String: Date] = [:]

    private static let playCountStaleAfter: TimeInterval = 24 * 60 * 60

    private static let playCountContradictionRecheckSecs: TimeInterval = 5 * 60

    private func contradictedPlayCountKeys(_ rows: [RecentTrack], now: Date) -> Set<String> {
        var onPage: [String: Int] = [:]
        for r in rows where !r.nowPlaying {
            onPage[PlayCountFold.familyKey(artist: r.artist, title: r.title), default: 0] += 1
        }
        var out = Set<String>()
        for r in rows where !r.nowPlaying {
            let key = Self.playCountKey(artist: r.artist, title: r.title)
            guard let cached = trackPlayCounts[key], !out.contains(key) else { continue }
            let family = PlayCountFold.familyKey(artist: r.artist, title: r.title)
            guard PlayCountRecency.contradicted(
                    onPage: onPage[family] ?? 0, cachedTotal: cached,
                    lastFetched: playCountFetchedAt[key], now: now,
                    recheckAfter: Self.playCountContradictionRecheckSecs)
            else { continue }
            out.insert(key)
        }
        return out
    }

    private func staleByAgePlayCountKeys(_ rows: [RecentTrack], now: Date) -> Set<String> {
        var out = Set<String>()
        for r in rows where !r.nowPlaying {
            let key = Self.playCountKey(artist: r.artist, title: r.title)

            guard trackPlayCounts[key] != nil else { continue }
            if PlayCountRecency.stale(lastFetched: playCountVerifiedAt[key], now: now,
                                       maxAge: Self.playCountStaleAfter) {
                out.insert(key)
            }
        }
        return out
    }

    private func countByKey(_ rows: [RecentTrack]) -> [String: Int] {
        var out: [String: Int] = [:]
        for r in rows where !r.nowPlaying {
            out[Self.playCountKey(artist: r.artist, title: r.title), default: 0] += 1
        }
        return out
    }

    private func resolvePlayCounts(for rows: [RecentTrack], priority: LastfmRateLimiter.Priority = .interactive) {
        guard let cred = credentials else { return }
        var seen = Set<String>()
        let now = Date()
        let missing = rows.compactMap { r -> (key: String, artist: String, title: String,
                                              album: String?, wantsCount: Bool,
                                              zeroIsFinal: Bool)? in
            let key = Self.playCountKey(artist: r.artist, title: r.title)

            let needsCount = (trackPlayCounts[key] == nil || stalePlayCountKeys.contains(key))
                && playCountUnavailableDue(key, now: now)

            let hasCover = r.imageURL != nil || localCovers[key] != nil || recentTrackCovers[key] != nil
                || catalogCovers[key] != nil
                || Self.albumKey(artist: r.artist, album: r.album).map { recentAlbumCovers[$0] != nil } ?? false
            let needsCover = !hasCover && !coverUnavailable.contains(key)
            guard needsCount || needsCover, !playCountsInFlight.contains(key),
                  seen.insert(key).inserted, !r.artist.isEmpty, !r.title.isEmpty else { return nil }

            let age = r.date.map { now.timeIntervalSince($0) } ?? 0
            return (key, r.artist, r.title, r.album, needsCount,
                    age >= Self.playCountZeroGraceSecs)
        }
        guard !missing.isEmpty else { return }
        missing.forEach { playCountsInFlight.insert($0.key) }
        Task {
            defer { missing.forEach { playCountsInFlight.remove($0.key) } }
            var index = 0

            await withTaskGroup(of: (String, String, String?, Bool, Int?, URL?, Bool, Bool).self) { group in
                let maxConcurrent = 4
                func addNext() {
                    guard index < missing.count else { return }
                    let item = missing[index]
                    index += 1
                    group.addTask { [weak self] in
                        guard let self else {
                            return (item.key, item.artist, item.album, false, nil, nil,
                                    item.wantsCount, item.zeroIsFinal)
                        }
                        let res = await self.requestDetailed(method: "track.getinfo", cred: cred,
                                                             extra: ["artist": item.artist, "track": item.title,
                                                                     "autocorrect": "1", "username": cred.user],
                                                             priority: priority)
                        guard let json = res.json else {

                            return (item.key, item.artist, item.album, res.notFound,
                                    res.notFound ? 0 : nil, nil,
                                    item.wantsCount, item.zeroIsFinal)
                        }
                        let parsed = await MainActor.run { () -> (Int?, URL?, String?) in

                            let n = (self.dig(json, "track", "userplaycount") as? String).flatMap { Int($0) }

                            var identity: String?
                            if let name = self.dig(json, "track", "name") as? String,
                               let art = self.dig(json, "track", "artist", "name") as? String {
                                identity = Self.playCountKey(artist: art, title: name)
                            }

                            return (n, self.imageURL(self.dig(json, "track", "album", "image")), identity)
                        }

                        var count = parsed.0
                        if item.wantsCount {
                            var identities = Set<String>()
                            if let id = parsed.2 { identities.insert(id) }
                            for sib in await self.playCountSiblings(artist: item.artist, title: item.title) {
                                let twin = await self.userPlayCount(artist: sib.artist, title: sib.title,
                                                                    cred: cred, priority: priority)
                                guard let tc = twin.count, let tid = twin.identity,
                                      identities.insert(tid).inserted else { continue }

                                if count == nil && tc == 0 { continue }
                                count = (count ?? 0) + tc
                            }
                        }

                        var cover = parsed.1
                        if cover == nil {
                            cover = await self.coverByCorrectedArtist(
                                artist: item.artist, title: item.title, cred: cred, priority: priority)
                        }
                        return (item.key, item.artist, item.album, true, count, cover,
                                item.wantsCount, item.zeroIsFinal)
                    }
                }

                var counts: [String: Int] = [:]
                var covers: [String: URL] = [:]
                var albumCovers: [String: URL] = [:]
                var noCount = Set<String>()
                var noCover = Set<String>()
                var countFetched = Set<String>()
                for _ in 0..<min(maxConcurrent, missing.count) { addNext() }
                for await (key, artist, album, ok, n, cover, wantsCount, zeroIsFinal) in group {

                    if wantsCount {

                        if ok { countFetched.insert(key) }

                        switch PlayCountOutcome.classify(requestSucceeded: ok, reportedCount: n,
                                                         rowIsOldEnough: zeroIsFinal) {
                        case .counted(let resolved):
                            counts[key] = resolved
                        case .definitivelyNone:

                            noCount.insert(key)
                        case .unanswered:

                            break
                        }
                    }
                    if let cover {
                        covers[key] = cover

                        if let ak = Self.albumKey(artist: artist, album: album) { albumCovers[ak] = cover }
                    } else if ok {
                        noCover.insert(key)
                    }
                    addNext()
                }

                let unresolved = missing.filter { $0.wantsCount && counts[$0.key] == nil }.map(\.key)
                let unresolvedNote = unresolved.isEmpty ? "" :
                    " (unresolved: \(unresolved.prefix(6).joined(separator: ", "))\(unresolved.count > 6 ? ", …" : ""))"
                logger.notice("resolvePlayCounts: resolved \(counts.count, privacy: .public)/\(missing.count, privacy: .public) counts\(unresolvedNote, privacy: .public)")
                if !counts.isEmpty {
                    trackPlayCounts.merge(counts) { _, new in new }

                    stalePlayCountKeys.subtract(counts.keys)

                    for k in counts.keys { clearPlayCountUnavailable(k) }
                    reconcileNowPlayingCount(with: counts)
                }
                if !covers.isEmpty { recentTrackCovers.merge(covers) { _, new in new } }
                if !albumCovers.isEmpty { recentAlbumCovers.merge(albumCovers) { _, new in new } }

                let markedAt = Date()
                for k in noCount { markPlayCountUnavailable(k, at: markedAt) }

                stalePlayCountKeys.subtract(noCount)
                for k in noCount { trackPlayCounts[k] = nil }
                coverUnavailable.formUnion(noCover)

                if !counts.isEmpty || !noCount.isEmpty { scheduleRecentPageCacheSave() }
                if !countFetched.isEmpty {
                    let stamp = Date()
                    for key in countFetched {
                        playCountFetchedAt[key] = stamp

                        playCountVerifiedAt[key] = stamp
                    }
                }

                if !noCover.isEmpty { resolveCatalogCovers(for: rows) }

                if !covers.isEmpty || !albumCovers.isEmpty { rebuildRecentCoverIndex() }
            }
            scheduleSnapshotSave()
        }
    }

    private var artistCorrections: [String: String] = [:]

    private var artistCorrectionTasks: [String: Task<String, Never>] = [:]

    private func coverByCorrectedArtist(artist: String, title: String,
                                        cred: (user: String, key: String),
                                        priority: LastfmRateLimiter.Priority = .interactive) async -> URL? {
        let corrected = await correctedArtistName(artist, cred: cred, priority: priority)
        guard !corrected.isEmpty, corrected != artist else { return nil }
        guard let json = await request(method: "track.getinfo", cred: cred,
                                       extra: ["artist": corrected, "track": title,
                                               "autocorrect": "1"],
                                       priority: priority)
        else { return nil }
        return imageURL(dig(json, "track", "album", "image"))
    }

    private func correctedArtistName(_ artist: String,
                                     cred: (user: String, key: String),
                                     priority: LastfmRateLimiter.Priority = .interactive) async -> String {
        if let cached = artistCorrections[artist] { return cached }
        if let running = artistCorrectionTasks[artist] { return await running.value }
        let task = Task { [weak self] () -> String in
            guard let self else { return "" }
            let json = await self.request(method: "artist.getcorrection", cred: cred,
                                          extra: ["artist": artist], priority: priority)
            guard let json else { return "" }
            return self.dig(json, "corrections", "correction", "artist", "name") as? String ?? ""
        }
        artistCorrectionTasks[artist] = task
        let name = await task.value

        artistCorrections[artist] = name
        artistCorrectionTasks[artist] = nil
        return name
    }

    static let apiNowPlayingMaxAge: TimeInterval = 15 * 60

    private let onThisDayPageSize = 200
    private let onThisDayMaxPages = 3
    var apiNowPlayingIsFresh: Bool {
        guard apiNowPlaying != nil, let since = apiNowPlayingSince else { return false }
        return Date().timeIntervalSince(since) < Self.apiNowPlayingMaxAge
    }

    func goToPage(_ page: Int) {
        let target = max(1, min(page, max(recentTotalPages, 1)))
        guard target != recentPage, !recentPaging else { return }
        if !recentPageCacheLoaded { loadRecentPageCache() }

        if let feed = lastFeed, feed.isFresh() {
            var exact = target == 1 ? recentPageCache[1] : composeExactPage(target)
            if target >= 2, exact != nil, let np = recentPageCache[1]?.first(where: \.nowPlaying) {

                exact?.insert(np, at: 0)
            }
            if let exact {
                recentPage = target
                if target >= 2 {
                    recentPageCache[target] = exact
                    recentPageCacheTotal[target] = feed.total
                    fetchedAt[Self.recentPageCacheKey(target)] = Date()
                }
                applyRecent(exact)
                prefetchNeighborPage(after: target)
                return
            }
        } else if let cached = recentPageCache[target] {

            recentPage = target
            applyRecent(cached)
            if !fresh(Self.recentPageCacheKey(target), ttl: Self.recentPageCacheTTL) {
                revalidateRecentPage(target)
            }
            prefetchNeighborPage(after: target)
            return
        }
        let prev = recentPage
        recentPage = target
        recentPaging = true
        baselineGen += 1
        let gen = baselineGen
        Task {
            defer { recentPaging = false }
            guard let cred = credentials,
                  let json = await request(method: "user.getrecenttracks", cred: cred,
                                           extra: ["limit": String(Self.recentPageSize),
                                                   "page": String(target)])
            else {
                if gen == baselineGen { recentPage = prev }
                return
            }
            guard gen == baselineGen else { return }
            let rows = parseRecent(json)
            applyRecent(rows)
            applyRecentPaging(json)
            storeFetchedPage(target, rows: rows, json: json)
            scheduleSnapshotSave()
            scheduleRecentPageCacheSave()
            fetchedAt["baseline"] = Date()
            prefetchNeighborPage(after: target)
        }
    }

    private func revalidateRecentPage(_ target: Int) {
        guard let cred = credentials else { return }
        baselineGen += 1
        let gen = baselineGen
        Task {
            guard let json = await request(method: "user.getrecenttracks", cred: cred,
                                           extra: ["limit": String(Self.recentPageSize),
                                                   "page": String(target)])
            else { return }
            let rows = parseRecent(json)
            storeFetchedPage(target, rows: rows, json: json)
            scheduleRecentPageCacheSave()
            guard gen == baselineGen, recentPage == target else { return }
            applyRecent(rows)
            applyRecentPaging(json)
            scheduleSnapshotSave()
        }
    }

    private static func recentPageCacheKey(_ page: Int) -> String { "recent-page-\(page)" }

    private func applyRecentPaging(_ json: [String: Any]) {
        if let s = dig(json, "recenttracks", "@attr", "totalPages") as? String, let n = Int(s), n > 0 {
            recentTotalPages = n
        }
    }

    func refreshChart(kind: ChartKind, period: Period) {
        let key = "\(kind.rawValue)|\(period.rawValue)"
        guard fresh(key) == false else { return }
        guard let cred = credentials else { return }
        fetchedAt[key] = Date()

        if kind == .artists {
            refreshMergedArtistChart(cacheKey: key, period: period)
            return
        }
        Task {
            chartLoadingKeys.insert(key)
            chartFailedKeys.remove(key)
            defer { chartLoadingKeys.remove(key) }
            if !(await fetchChartDirect(kind: kind, period: period, key: key, cred: cred)) {
                chartFailedKeys.insert(key)
                fetchedAt[key] = nil
            }
        }
    }

    private func fetchChartDirect(kind: ChartKind, period: Period, key: String,
                                  cred: (user: String, key: String)) async -> Bool {
        guard let json = await request(method: kind.method, cred: cred,
                                       extra: ["period": period.rawValue, "limit": "10"])
        else { return false }
        let (outer, inner) = kind.listPath
        let items = (dig(json, outer, inner) as? [[String: Any]]) ?? []
        var entries: [ChartEntry] = []
        entries.reserveCapacity(items.count)
        for (idx, item) in items.enumerated() {
            let name = item["name"] as? String ?? ""
            guard !name.isEmpty else { continue }
            let detail = dig(item, "artist", "name") as? String ?? ""
            let count = Int(item["playcount"] as? String ?? "") ?? 0

            let image = kind == .albums ? imageURL(item["image"]) : nil
            entries.append(ChartEntry(rank: idx + 1, name: name, detail: detail,
                                      playcount: count, imageURL: image))
        }
        charts[key] = entries
        scheduleSnapshotSave()
        switch kind {
        case .tracks: resolveTrackCovers(entries, cred: cred)
        case .artists: resolveAvatars(names: entries.map(\.name))
        case .albums: break
        }
        return true
    }

    private func resolveTrackCovers(_ entries: [ChartEntry], cred: (user: String, key: String)) {
        let missing = entries.filter { trackCovers["\($0.detail)|\($0.name)"] == nil }
        guard !missing.isEmpty else { return }
        Task {
            await withTaskGroup(of: (String, URL?).self) { group in
                for e in missing {
                    group.addTask { [weak self] in
                        let key = "\(e.detail)|\(e.name)"
                        guard let self else { return (key, nil) }
                        let json = await self.request(method: "track.getinfo", cred: cred,
                                                      extra: ["artist": e.detail, "track": e.name,
                                                              "autocorrect": "1"])
                        guard let json else { return (key, nil) }
                        let image = await MainActor.run {
                            self.imageURL(self.dig(json, "track", "album", "image"))
                        }
                        return (key, image)
                    }
                }
                for await (key, url) in group {
                    if let url { trackCovers[key] = url }
                }
            }
            scheduleSnapshotSave()
        }
    }

    private func refreshMergedArtistChart(cacheKey: String, period: Period) {
        let collectorPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/collector").path
        chartLoadingKeys.insert(cacheKey)
        chartFailedKeys.remove(cacheKey)
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: collectorPath)

            process.environment = LyrimusePaths.collectorProcessEnvironment()

            process.arguments = ["top-artists", "-all-periods", "-limit", "10"]
            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe
            var rows: [String: [[String: Any]]] = [:]
            do {
                try process.run()

                let watchdog = Task.detached {
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    if !Task.isCancelled, process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                guard process.terminationStatus == 0,
                      let arr = try JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]]
                else {

                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8)?.prefix(300) ?? ""
                    logger.notice("top-artists failed (exit \(process.terminationStatus)): \(String(err), privacy: .public)")
                    throw CocoaError(.fileReadCorruptFile)
                }
                rows = arr
            } catch {

                await MainActor.run {
                    let svc = LastfmStatsService.shared
                    Task {
                        defer { svc.chartLoadingKeys.remove(cacheKey) }
                        guard let cred = svc.credentials else {
                            svc.chartFailedKeys.insert(cacheKey)
                            svc.fetchedAt[cacheKey] = nil
                            return
                        }
                        if !(await svc.fetchChartDirect(kind: .artists, period: period, key: cacheKey, cred: cred)) {
                            svc.chartFailedKeys.insert(cacheKey)
                            svc.fetchedAt[cacheKey] = nil
                        }
                    }
                }
                return
            }
            var byKey: [String: [ChartEntry]] = [:]
            for (pd, periodRows) in rows {
                byKey["\(ChartKind.artists.rawValue)|\(pd)"] = periodRows.enumerated().compactMap { idx, row -> ChartEntry? in
                    guard let name = row["name"] as? String, !name.isEmpty else { return nil }
                    let count = row["playCount"] as? Int ?? 0
                    return ChartEntry(rank: idx + 1, name: name, detail: "", playcount: count, imageURL: nil)
                }
            }
            let filled = byKey
            await MainActor.run {
                let svc = LastfmStatsService.shared
                svc.chartLoadingKeys.remove(cacheKey)
                let now = Date()
                for (key, entries) in filled {
                    svc.charts[key] = entries
                    svc.fetchedAt[key] = now
                }

                if filled[cacheKey] == nil {
                    svc.chartFailedKeys.insert(cacheKey)
                    svc.fetchedAt[cacheKey] = nil
                }

                if let visible = filled[cacheKey] {
                    svc.resolveAvatars(names: visible.map(\.name))
                }
                svc.scheduleSnapshotSave()
            }
        }
    }

    private func resolveAvatars(names: [String]) {
        let missing = names.filter { artistAvatars[$0] == nil }
        guard !missing.isEmpty else { return }
        let collectorPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/collector").path
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: collectorPath)

            process.environment = LyrimusePaths.collectorProcessEnvironment()
            process.arguments = ["artist-avatars"] + missing
            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                logger.notice("artist-avatars: launch failed: \(error.localizedDescription, privacy: .public)")
                return
            }

            let watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: 75_000_000_000)
                if !Task.isCancelled, process.isRunning { process.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            guard let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?.prefix(300) ?? ""
                logger.notice("artist-avatars failed (exit \(process.terminationStatus)): \(String(err), privacy: .public)")
                return
            }
            await MainActor.run {
                for (name, url) in map where !url.isEmpty {
                    if let u = URL(string: url) { LastfmStatsService.shared.artistAvatars[name] = u }
                }
                LastfmStatsService.shared.scheduleSnapshotSave()
            }
        }
    }

    private func parseRecent(_ json: [String: Any]) -> [RecentTrack] {
        let items = (dig(json, "recenttracks", "track") as? [[String: Any]]) ?? []
        var dupCount: [String: Int] = [:]
        return items.compactMap { item in
            let title = item["name"] as? String ?? ""
            guard !title.isEmpty else { return nil }
            let artist = dig(item, "artist", "#text") as? String ?? ""
            let uts = dig(item, "date", "uts") as? String

            let dupKey = "\(uts ?? "np")|\(artist)|\(title)"
            let dup = dupCount[dupKey, default: 0]
            dupCount[dupKey] = dup + 1
            return RecentTrack(
                dup: dup,
                title: title,
                artist: artist,
                album: dig(item, "album", "#text") as? String,
                imageURL: imageURL(item["image"]),
                date: uts.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    private func attrTotal(_ json: [String: Any]) -> Int {
        Int(dig(json, "recenttracks", "@attr", "total") as? String ?? "") ?? 0
    }

    private func imageURL(_ value: Any?) -> URL? {
        guard let arr = value as? [[String: Any]] else { return nil }
        let by = { (size: String) in arr.first { ($0["size"] as? String) == size } }
        let url = (by("large") ?? by("extralarge") ?? arr.last)?["#text"] as? String ?? ""
        guard !url.isEmpty else { return nil }

        guard !url.contains("2a96cbd8b46e442fc41c2b86b821562f") else { return nil }
        return URL(string: url)
    }

    private func dig(_ dict: [String: Any], _ path: String...) -> Any? {
        var cur: Any? = dict
        for key in path {
            cur = (cur as? [String: Any])?[key]
        }
        return cur
    }

    private func fresh(_ key: String, ttl overrideTTL: TimeInterval? = nil) -> Bool {
        guard let at = fetchedAt[key] else { return false }
        let age = Date().timeIntervalSince(at)

        guard age >= 0 else {
            logger.warning("fresh(\(key, privacy: .public)): fetchedAt is \(-age, privacy: .public)s in the future, treating as expired (system clock rolled back?)")
            return false
        }
        return age < (overrideTTL ?? ttl)
    }

    private func request(method: String, cred: (user: String, key: String),
                         extra: [String: String] = [:],
                         priority: LastfmRateLimiter.Priority = .interactive) async -> [String: Any]? {
        await requestDetailed(method: method, cred: cred, extra: extra, priority: priority).json
    }

    private func requestDetailed(method: String, cred: (user: String, key: String),
                                 extra: [String: String] = [:],
                                 priority: LastfmRateLimiter.Priority = .interactive)
        async -> (json: [String: Any]?, notFound: Bool)
    {
        var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        var pairs: [(name: String, value: String)] = [
            ("method", method),
            ("user", cred.user),
            ("api_key", cred.key),
            ("format", "json"),
        ]

        for k in extra.keys.sorted() { pairs.append((k, extra[k]!)) }

        comps.percentEncodedQuery = LastfmQuery.queryString(pairs)
        guard let url = comps.url else { return (nil, false) }
        var req = URLRequest(url: url)

        req.timeoutInterval = priority == .background ? 20 : 10

        let backoffCooldowns: [TimeInterval] = [1, 2, 4]
        for attempt in 0...backoffCooldowns.count {
            await LastfmRateLimiter.shared.acquire(priority: priority)

            let requestStart = Date()
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                NetworkAuditLog.record(service: "lastfm", operation: method, host: url.host ?? "ws.audioscrobbler.com",
                                       statusCode: status, durationMs: Date().timeIntervalSince(requestStart) * 1000, error: nil)
                if status == 429 {
                    logger.notice("\(method, privacy: .public): http 429, backing off (attempt \(attempt, privacy: .public))")
                    await LastfmRateLimiter.shared.reportThrottled(cooldown: backoffCooldowns[min(attempt, backoffCooldowns.count - 1)])
                    if attempt < backoffCooldowns.count { continue }
                    return (nil, false)
                }
                guard status == 200 else {
                    logger.notice("\(method, privacy: .public): http \(status)")
                    return (nil, false)
                }
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                if let errCode = obj?["error"] as? Int {
                    if errCode == 29 {
                        logger.notice("\(method, privacy: .public): api error 29 (rate limit), backing off (attempt \(attempt, privacy: .public))")
                        await LastfmRateLimiter.shared.reportThrottled(cooldown: backoffCooldowns[min(attempt, backoffCooldowns.count - 1)])
                        if attempt < backoffCooldowns.count { continue }
                        return (nil, false)
                    }
                    logger.notice("\(method, privacy: .public): api error \(errCode) \((obj?["message"] as? String) ?? "", privacy: .public)")
                    return (nil, errCode == 6)
                }
                return (obj, false)
            } catch {
                NetworkAuditLog.record(service: "lastfm", operation: method, host: url.host ?? "ws.audioscrobbler.com",
                                       statusCode: nil, durationMs: Date().timeIntervalSince(requestStart) * 1000, error: error)
                logger.notice("\(method, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return (nil, false)
            }
        }
        return (nil, false)
    }
}
