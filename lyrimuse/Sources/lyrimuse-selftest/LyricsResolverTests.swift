import Foundation
import LyrimuseCore

private struct StubProvider: LyricsProvider {
    let id: String
    let candidates: [LyricsCandidate]
    let fails: Bool
    let delayNanoseconds: UInt64
    let callCount: LockedValue<Int>?

    init(
        id: String, candidates: [LyricsCandidate], fails: Bool,
        delayNanoseconds: UInt64 = 0, callCount: LockedValue<Int>? = nil
    ) {
        self.id = id
        self.candidates = candidates
        self.fails = fails
        self.delayNanoseconds = delayNanoseconds
        self.callCount = callCount
    }

    func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        callCount?.increment()
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if fails { throw StubProviderError.unavailable }
        return candidates
    }
}

private enum StubProviderError: Error, Sendable {
    case unavailable
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() where Value == Int {
        lock.lock()
        value = (value ?? 0) + 1
        lock.unlock()
    }
}

private func timedCandidate(
    source: String, title: String, artist: String, album: String? = nil,
    end: Int = 180, lyrics: String = "one\ntwo"
) -> LyricsCandidate {
    LyricsCandidate(
        source: source,
        lyrics: "[00:01.00]\(lyrics.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).joined(separator: "\n[00:02.00]"))\n[00:\(String(format: "%02d", end / 60)).\(String(format: "%02d", end % 60))]last",
        duration: Double(end), title: title, artist: artist, album: album)
}

private func resolveSynchronously(
    _ resolver: LyricsResolver, query: LyricsQuery, enabledIDs: [String]? = nil
) -> LyricsResolution? {
    let result = LockedValue<LyricsResolution>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        result.set(await resolver.resolve(query, enabledIDs: enabledIDs))
        semaphore.signal()
    }
    semaphore.wait()
    return result.get()
}

@MainActor
func runLyricsResolverTests() {
    let chineseQuery = LyricsQuery(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 240)
    let chinese = timedCandidate(
        source: "lrclib", title: "晴天 (Remastered 2024)", artist: "周杰伦", album: "叶惠美", end: 238)
    let wrongArtist = timedCandidate(source: "qq", title: "晴天", artist: "陈奕迅", end: 239)
    let rankedChinese = LyricsMatcher.rank([wrongArtist, chinese, chinese], for: chineseQuery)
    expectEqual(rankedChinese.count, 2, "同一源重复歌词去重")
    expectEqual(rankedChinese.first?.source, "lrclib", "中文标题、专辑与歌手匹配")
    expectEqual(rankedChinese.first?.isRejected, false)

    let featQuery = LyricsQuery(title: "Love Story", artist: "Taylor Swift feat. Ed Sheeran", duration: 210)
    let feat = timedCandidate(source: "kuwo", title: "Love Story (Live)", artist: "Taylor Swift", end: 208)
    let multiArtist = timedCandidate(source: "netease", title: "Love Story", artist: "Taylor Swift & Ed Sheeran", end: 209)
    let featMatches = LyricsMatcher.rank([feat, multiArtist], for: featQuery)
    expectEqual(featMatches.allSatisfy { !$0.isRejected }, true, "feat 与多歌手匹配")
    expectEqual(featMatches.first?.candidate.artist, "Taylor Swift & Ed Sheeran")

    let versionQuery = LyricsQuery(title: "Song", artist: "Artist", duration: 180)

    let disabledCalls = LockedValue<Int>()
    let disabledResolution = resolveSynchronously(
        LyricsResolver(providers: [
            StubProvider(
                id: "disabled", candidates: [timedCandidate(source: "disabled", title: "Song", artist: "Artist")],
                fails: false, callCount: disabledCalls)
        ]), query: versionQuery, enabledIDs: [])
    expectEqual(disabledResolution?.sourcesSeen, [], "没有启用歌词源时不恢复全部源")
    expectEqual(disabledResolution?.sourcesResponded, [])
    expectEqual(disabledCalls.get() ?? 0, 0, "没有启用歌词源时不发起搜索")

    let exact = timedCandidate(source: "lrclib", title: "Song", artist: "Artist", end: 178)
    let live = timedCandidate(source: "kugou", title: "Song (Live)", artist: "Artist", end: 178)
    let remaster = timedCandidate(source: "netease", title: "Song (Remastered 2024)", artist: "Artist", end: 179)
    let versions = LyricsMatcher.rank([live, remaster, exact], for: versionQuery)
    expectEqual(versions.first?.candidate.title, "Song", "同名歌曲优先原版")
    expectEqual(versions.filter { !$0.isRejected }.count, 3, "Live / Remaster 仍可用")

    let close = timedCandidate(source: "lrclib", title: "Song", artist: "Artist", end: 178)
    let far = timedCandidate(source: "kuwo", title: "Song", artist: "Artist", end: 400)
    let durationMatches = LyricsMatcher.rank([far, close], for: versionQuery)
    expectEqual(durationMatches.first?.candidate.source, "lrclib", "时长接近的候选优先")

    let sameTitle = LyricsMatcher.rank([
        timedCandidate(source: "qq", title: "Song", artist: "Another Artist", end: 178),
        exact,
    ], for: versionQuery)
    expectEqual(sameTitle.first?.candidate.artist, "Artist", "同名歌曲按歌手区分")
    expectEqual(sameTitle.last?.isRejected, true)

    let sharedLyrics = "[00:01.00]one\n[00:02.00]two\n[02:58.00]last"
    let resolver = LyricsResolver(providers: [
        StubProvider(id: "lrclib", candidates: [LyricsCandidate(source: "lrclib", lyrics: sharedLyrics, duration: 178, title: "Song", artist: "Artist")], fails: false),
        StubProvider(id: "kuwo", candidates: [LyricsCandidate(source: "kuwo", lyrics: sharedLyrics, duration: 178, title: "Song", artist: "Artist")], fails: false),
        StubProvider(id: "netease", candidates: [timedCandidate(source: "netease", title: "Song", artist: "Artist", end: 400, lyrics: "different\nlyrics")], fails: false),
        StubProvider(id: "kugou", candidates: [], fails: true),
        StubProvider(id: "qq", candidates: [], fails: false),
    ])
    let resolution = resolveSynchronously(resolver, query: versionQuery)
    expectEqual(resolution?.sourcesSeen, ["lrclib", "kuwo", "netease", "kugou", "qq"], "五源并发搜索")
    expectEqual(resolution?.sourcesResponded, ["kuwo", "lrclib", "netease", "qq"], "单源失败不阻断其他源")
    expectEqual(resolution?.failures.keys.sorted(), ["kugou"])
    expectEqual(resolution?.winner?.source, "kuwo", "多源结果由 Matcher 统一排序")

    let fast = LyricsCandidate(
        source: "fast", lyrics: "[02:59.00]one\n[03:00.00]last", duration: 180,
        title: "Song", artist: "Artist", album: "Album")
    let earlyQuery = LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: 180)
    let earlyStarted = Date()
    let earlyResolution = resolveSynchronously(LyricsResolver(providers: [
        StubProvider(id: "fast", candidates: [fast], fails: false),
        StubProvider(id: "slow-a", candidates: [], fails: false, delayNanoseconds: 1_000_000_000),
        StubProvider(id: "slow-b", candidates: [], fails: false, delayNanoseconds: 1_000_000_000),
    ]), query: earlyQuery)
    let earlyElapsed = Date().timeIntervalSince(earlyStarted)
    expectEqual(earlyResolution?.winner?.source, "fast", "高置信候选可以提前结束")
    expectEqual(earlyResolution?.sourcesResponded, ["fast"], "提前结束不等待剩余源")
    expectEqual(earlyElapsed < 0.7, true, "提前结束不受慢源等待影响")

    let lowConfidence = resolveSynchronously(LyricsResolver(providers: [
        StubProvider(id: "one", candidates: [timedCandidate(source: "one", title: "Other", artist: "Artist", end: 180)], fails: false),
        StubProvider(id: "two", candidates: [], fails: false, delayNanoseconds: 100_000_000),
        StubProvider(id: "three", candidates: [], fails: false, delayNanoseconds: 100_000_000),
    ]), query: versionQuery)
    expectEqual(lowConfidence?.sourcesResponded, ["one", "three", "two"], "没有高置信候选时收集全部源")

    expectEqual(LocalPlaybackSource.shouldRunFastTimer(
        isPlaying: true, hasContent: true, screenLocked: false, needsRealtimeLyricsUpdates: false),
        false, "没有实时歌词需求时不启动 fastTimer")
    expectEqual(LocalPlaybackSource.shouldRunFastTimer(
        isPlaying: true, hasContent: true, screenLocked: false, needsRealtimeLyricsUpdates: true),
        true, "实时歌词需求恢复后允许启动 fastTimer")
    expectEqual(LocalPlaybackSource.shouldRunFastTimer(
        isPlaying: false, hasContent: true, screenLocked: false, needsRealtimeLyricsUpdates: true),
        false, "暂停时不启动 fastTimer")
    expectEqual(LocalPlaybackSource.shouldRunFastTimer(
        isPlaying: true, hasContent: false, screenLocked: false, needsRealtimeLyricsUpdates: true),
        false, "无歌词时不启动 fastTimer")
    expectEqual(LocalPlaybackSource.shouldRunFastTimer(
        isPlaying: true, hasContent: true, screenLocked: true, needsRealtimeLyricsUpdates: true),
        false, "锁屏时不启动 fastTimer")

    let instrumental = LyricsMatcher.rank([
        LyricsCandidate(source: "lrclib", lyrics: "", title: "Intro", artist: "Artist", instrumental: true)
    ], for: LyricsQuery(title: "Intro", artist: "Artist", duration: 30))
    expectEqual(instrumental.first?.candidate.instrumental, true, "纯音乐候选保留为结论")
    expectEqual(instrumental.first?.isRejected, false, "纯音乐不是错误候选")
    expectEqual(LyricsResolution(matches: instrumental, sourcesSeen: ["lrclib"], sourcesResponded: ["lrclib"], failures: [:], instrumental: true).winner == nil, true, "纯音乐不会被当成歌词冠军写入")

    let filtered = resolveSynchronously(resolver, query: versionQuery)
    expectEqual(filtered?.matches.isEmpty, false)

    let cacheKey = EnrichCacheKeys.normalizedKey(artist: "Artist", title: "Song", album: "Album")
    EnrichCacheReader.setEntriesForTesting([
        cacheKey: EnrichCacheEntry(lyrics: sharedLyrics, lyricsSource: "lrclib", ts: 1)
    ])
    let cached = EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Album")
    expectEqual(cached?.resolved, true, "缓存命中已解析歌词")
    expectEqual(cached?.lyrics, sharedLyrics)
    EnrichCacheReader.setEntriesForTesting(nil)
}
