import Foundation

public struct LyricsResolver: Sendable {
    private static let earlyReturnScore = 600

    private let providers: [any LyricsProvider]

    public init(providers: [any LyricsProvider] = LyricsResolver.defaultProviders()) {
        self.providers = providers
    }

    public static func defaultProviders() -> [any LyricsProvider] {
        [LRCLIBProvider(), KuwoProvider(), NeteaseProvider(), KugouProvider(), QQMusicProvider()]
    }

    public func resolve(_ query: LyricsQuery, enabledIDs: [String]? = nil) async -> LyricsResolution {
        struct Result: Sendable {
            let id: String
            let candidates: [LyricsCandidate]
            let error: String?
        }

        let providersToUse = enabledIDs.map { ids in
            providers.filter { ids.contains($0.id) }
        } ?? providers

        let results = await withTaskGroup(of: Result.self, returning: [Result].self) { group in
            for provider in providersToUse {
                group.addTask {
                    do {
                        return Result(id: provider.id, candidates: try await provider.search(query), error: nil)
                    } catch {
                        return Result(id: provider.id, candidates: [], error: error.localizedDescription)
                    }
                }
            }
            var values: [Result] = []
            var candidates: [LyricsCandidate] = []
            for await result in group {
                values.append(result)
                candidates.append(contentsOf: result.candidates)
                if Self.isHighConfidence(LyricsMatcher.rank(candidates, for: query)) {
                    group.cancelAll()
                    break
                }
            }
            return values
        }

        let sourcesSeen = providersToUse.map(\.id)
        let sourcesResponded = results.filter { $0.error == nil }.map(\.id).sorted()
        let failures = Dictionary(uniqueKeysWithValues: results.compactMap { result in
            result.error.map { (result.id, $0) }
        })
        let candidates = results.flatMap(\.candidates)
        let matches = LyricsMatcher.rank(candidates, for: query)
        let instrumental = candidates.contains { $0.instrumental }
        return LyricsResolution(matches: matches, sourcesSeen: sourcesSeen,
                                sourcesResponded: sourcesResponded, failures: failures,
                                instrumental: instrumental)
    }

    private static func isHighConfidence(_ matches: [LyricsMatch]) -> Bool {
        let viable = matches.filter { !$0.isRejected && !$0.candidate.instrumental }
        guard let best = viable.first, best.score >= earlyReturnScore else { return false }

        let titleScore = best.terms.first { $0.kind == "titleMatch" }?.points ?? 0
        let artistScore = best.terms.first { $0.kind == "artistMatch" }?.points ?? 0
        guard titleScore >= 100, artistScore >= 100 else { return false }

        let hasDurationConflict = best.terms.contains { term in
            term.kind == "durationOff" || term.kind == "durationOvershoot" || term.kind == "sourceDurationOff"
        }
        guard !hasDurationConflict else { return false }

        if let second = viable.dropFirst().first, best.score - second.score < 100 {
            return false
        }
        return true
    }
}
