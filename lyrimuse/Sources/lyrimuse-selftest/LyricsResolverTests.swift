import Foundation
import LyrimuseCore

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    var current: Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private enum StubProviderError: Error, Sendable {
    case unavailable
}

private struct StubProvider: LyricsProvider {
    let id: String
    let candidates: [LyricsCandidate]
    let fails: Bool
    let delayNanoseconds: UInt64
    let calls: LockedInt?

    func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        calls?.increment()
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if fails { throw StubProviderError.unavailable }
        return candidates
    }
}

private func candidate(
    source: String,
    title: String,
    artist: String,
    album: String? = nil,
    end: Int = 180,
    lyrics: [String] = ["one", "two"]
) -> LyricsCandidate {
    let timedLines = lyrics.enumerated().map { index, text in
        String(format: "[00:%02d.00]%@", index + 1, text)
    }
    let last = String(format: "[%02d:%02d.00]last", end / 60, end % 60)
    return LyricsCandidate(
        source: source,
        lyrics: (timedLines + [last]).joined(separator: "\n"),
        duration: Double(end),
        title: title,
        artist: artist,
        album: album
    )
}

private func resolveSynchronously(
    _ resolver: LyricsResolver,
    query: LyricsQuery,
    enabledIDs: [String]? = nil
) -> LyricsResolution? {
    let result = LockedBox<LyricsResolution>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        result.set(await resolver.resolve(query, enabledIDs: enabledIDs))
        semaphore.signal()
    }
    semaphore.wait()
    return result.current
}

func runLyricsResolverTests() {
    let query = LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: 180)
    let exact = candidate(source: "exact", title: "Song", artist: "Artist", album: "Album")
    let wrongArtist = candidate(source: "wrong-artist", title: "Song", artist: "Someone Else", end: 180)
    let live = candidate(source: "live", title: "Song (Live)", artist: "Artist", end: 178)
    let far = candidate(source: "far", title: "Song", artist: "Artist", end: 360)
    let wrongTitle = candidate(source: "wrong-title", title: "Other Song", artist: "Artist")

    let ranked = LyricsMatcher.rank([wrongArtist, live, far, exact], for: query)
    expectEqual(ranked.first?.source, "exact", "正确候选排第一")
    expectEqual(ranked.first?.isRejected, false)
    expectEqual(ranked.last?.source, "wrong-artist", "明显错误歌手被放到拒绝结果")
    expectEqual(ranked.last?.isRejected, true)

    let versions = LyricsMatcher.rank([live, exact], for: query)
    expectEqual(versions.map(\.source), ["exact", "live"], "原版压过 Live 版本")
    expectEqual(versions.last?.isRejected, false)

    let durations = LyricsMatcher.rank([far, exact], for: query)
    expectEqual(durations.map(\.source), ["exact", "far"], "时长明显不符的候选被压低")
    expectEqual(durations.last?.isRejected, false)

    let titles = LyricsMatcher.rank([wrongTitle, exact], for: query)
    expectEqual(titles.first?.source, "exact", "明显错误 title 不抢占正确结果")
    expectEqual(titles.last?.isRejected, false)

    let disabledCalls = LockedInt()
    let disabled = resolveSynchronously(
        LyricsResolver(providers: [StubProvider(
            id: "disabled",
            candidates: [exact],
            fails: false,
            delayNanoseconds: 0,
            calls: disabledCalls,
        )]),
        query: query,
        enabledIDs: []
    )
    expectEqual(disabled?.sourcesSeen ?? [], [], "零个启用 Provider 不发请求")
    expectEqual(disabled?.sourcesResponded ?? [], [])
    expectEqual(disabledCalls.current, 0)

    let concurrent = resolveSynchronously(
        LyricsResolver(providers: [
            StubProvider(
                id: "one",
                candidates: [candidate(source: "one", title: "Song (Live)", artist: "Artist", end: 178)],
                fails: false,
                delayNanoseconds: 40_000_000,
                calls: nil
            ),
            StubProvider(
                id: "two",
                candidates: [candidate(source: "two", title: "Song (Remastered)", artist: "Artist", end: 179)],
                fails: false,
                delayNanoseconds: 10_000_000,
                calls: nil
            ),
        ]),
        query: query
    )
    expectEqual(concurrent?.sourcesSeen ?? [], ["one", "two"], "多个 Provider 都被纳入搜索")
    expectEqual(concurrent?.sourcesResponded ?? [], ["one", "two"], "多个 Provider 可以并发返回")
    expectEqual(concurrent?.matches.count, 2)

    let healthy = candidate(source: "healthy", title: "Song (Live)", artist: "Artist", end: 178)
    let isolatedFailure = resolveSynchronously(
        LyricsResolver(providers: [
            StubProvider(id: "healthy", candidates: [healthy], fails: false, delayNanoseconds: 10_000_000, calls: nil),
            StubProvider(id: "broken", candidates: [], fails: true, delayNanoseconds: 10_000_000, calls: nil),
        ]),
        query: query
    )
    expectEqual(isolatedFailure?.sourcesResponded ?? [], ["healthy"], "一个 Provider 失败不拖垮其他结果")
    expectEqual(isolatedFailure?.failures.keys.sorted() ?? [], ["broken"])
    expectEqual(isolatedFailure?.winner?.source, "healthy")
    expectEqual(isolatedFailure?.matches.first?.source, "healthy")

    let firstCalls = LockedInt()
    let secondCalls = LockedInt()
    let filtered = resolveSynchronously(
        LyricsResolver(providers: [
            StubProvider(id: "first", candidates: [healthy], fails: false, delayNanoseconds: 0, calls: firstCalls),
            StubProvider(id: "second", candidates: [healthy], fails: false, delayNanoseconds: 0, calls: secondCalls),
        ]),
        query: query,
        enabledIDs: ["first"]
    )
    expectEqual(filtered?.sourcesSeen ?? [], ["first"])
    expectEqual(filtered?.sourcesResponded ?? [], ["first"])
    expectEqual(firstCalls.current, 1)
    expectEqual(secondCalls.current, 0)

    let earlyQuery = LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: 180)
    let started = Date()
    let early = resolveSynchronously(
        LyricsResolver(providers: [
            StubProvider(
                id: "fast",
                candidates: [candidate(source: "fast", title: "Song", artist: "Artist", album: "Album")],
                fails: false,
                delayNanoseconds: 0,
                calls: nil
            ),
            StubProvider(id: "slow", candidates: [], fails: false, delayNanoseconds: 1_000_000_000, calls: nil),
        ]),
        query: earlyQuery
    )
    expectEqual(early?.winner?.source, "fast", "高置信候选可以提前结束")
    expectEqual(early?.sourcesResponded ?? [], ["fast"])
    expectEqual(Date().timeIntervalSince(started) < 0.5, true)
}
