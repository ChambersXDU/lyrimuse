import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lastfm-breakdown")

@MainActor
final class PlayCountBreakdownLoader: ObservableObject {
    enum State: Equatable { case loading, loaded, failed }

    static let pageSize = 200

    let artist: String
    let title: String

    @Published private(set) var state: State = .loading
    @Published private(set) var breakdown: PlayCountBreakdown?
    @Published private(set) var loadingOlder = false

    private var inputs: [PlayCountBreakdownMath.VariantInput] = []

    private var pagesFetched: [Int] = []

    init(artist: String, title: String) {
        self.artist = artist
        self.title = title
    }

    func load() async {
        state = .loading
        let family = LastfmStatsService.shared.playCountFamily(artist: artist, title: title)
        let base = family[0]

        var pages = [LastfmStatsService.TrackScrobblesPage?](repeating: nil, count: family.count)
        await withTaskGroup(of: (Int, LastfmStatsService.TrackScrobblesPage?).self) { group in
            for (i, member) in family.enumerated() {
                group.addTask { @MainActor in
                    (i, await LastfmStatsService.shared.fetchTrackScrobbles(
                        artist: member.artist, title: member.title, page: 1, limit: Self.pageSize))
                }
            }
            for await (i, page) in group { pages[i] = page }
        }
        var built: [PlayCountBreakdownMath.VariantInput] = []
        var fetched: [Int] = []
        for (i, member) in family.enumerated() {
            let isSelf = i == 0
            guard let page = pages[i] else {

                if isSelf {
                    logger.error("breakdown: self fetch failed for \(member.artist, privacy: .public) - \(member.title, privacy: .public)")
                    state = .failed
                    return
                }
                built.append(.init(artist: member.artist, title: member.title, total: 0, isSelf: false,
                                   reasons: PlayCountFoldExplainer.reasons(base: base, variant: member),
                                   plays: [], failed: true))
                fetched.append(0)
                continue
            }

            if !isSelf && page.total == 0 { continue }
            built.append(.init(artist: member.artist, title: member.title, total: page.total, isSelf: isSelf,
                               reasons: isSelf ? [] : PlayCountFoldExplainer.reasons(base: base, variant: member),
                               plays: page.plays))
            fetched.append(1)
        }
        inputs = built
        pagesFetched = fetched
        breakdown = PlayCountBreakdownMath.build(inputs)
        state = .loaded
        logger.notice("breakdown: \(base.artist, privacy: .public) - \(base.title, privacy: .public) → \(built.count, privacy: .public) variants, \(self.breakdown?.plays.count ?? 0, privacy: .public) plays loaded, total \(self.breakdown?.total ?? 0, privacy: .public)")
    }

    func loadOlder() async {
        guard !loadingOlder, let current = breakdown, current.canLoadOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        for (i, variant) in current.variants.enumerated() where !variant.failed && !variant.exhausted {
            let next = pagesFetched[i] + 1
            guard let page = await LastfmStatsService.shared.fetchTrackScrobbles(
                artist: variant.artist, title: variant.title, page: next, limit: Self.pageSize)
            else { continue }
            inputs[i].plays.append(contentsOf: page.plays)

            inputs[i].total = page.total
            pagesFetched[i] = next
        }
        breakdown = PlayCountBreakdownMath.build(inputs)
    }
}
