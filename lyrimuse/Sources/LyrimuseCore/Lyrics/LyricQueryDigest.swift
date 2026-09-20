import Foundation

public struct LyricQueryRound: Sendable, Equatable {
    public let artist: String
    public let title: String

    public let reason: String

    public let sources: [String]

    public init(artist: String, title: String, reason: String, sources: [String]) {
        self.artist = artist
        self.title = title
        self.reason = reason
        self.sources = sources
    }
}

public struct LyricQueryPair: Sendable, Equatable {
    public let artist: String

    public let title: String

    public init(artist: String, title: String) {
        self.artist = artist
        self.title = title
    }
}

public struct LyricQueryGroup: Sendable, Equatable, Identifiable {
    public var id: String { reason + "\u{1F}" + sources.joined(separator: ",") }
    public let reason: String
    public let sources: [String]

    public let queries: [LyricQueryPair]

    public init(reason: String, sources: [String], queries: [LyricQueryPair]) {
        self.reason = reason
        self.sources = sources
        self.queries = queries
    }
}

public struct LyricQueryDigest: Sendable, Equatable {

    public let sharedTitle: String?
    public let groups: [LyricQueryGroup]

    public let total: Int

    public init(sharedTitle: String?, groups: [LyricQueryGroup], total: Int) {
        self.sharedTitle = sharedTitle
        self.groups = groups
        self.total = total
    }

    public var queriesFlatCount: Int { groups.reduce(0) { $0 + $1.queries.count } }
}

public enum LyricQueryDigestBuilder {
    public static func build(_ rounds: [LyricQueryRound]) -> LyricQueryDigest {
        guard !rounds.isEmpty else {
            return LyricQueryDigest(sharedTitle: nil, groups: [], total: 0)
        }

        let titles = Set(rounds.map(\.title))
        let shared: String? = (titles.count == 1 && !(titles.first ?? "").isEmpty) ? titles.first : nil

        var order: [String] = []
        var byKey: [String: LyricQueryGroup] = [:]
        for r in rounds {
            let key = r.reason + "\u{1F}" + r.sources.joined(separator: ",")

            let pair = LyricQueryPair(artist: r.artist, title: shared == nil ? r.title : "")
            if var g = byKey[key] {

                guard !g.queries.contains(pair) else { continue }
                g = LyricQueryGroup(reason: g.reason, sources: g.sources, queries: g.queries + [pair])
                byKey[key] = g
            } else {
                order.append(key)
                byKey[key] = LyricQueryGroup(reason: r.reason, sources: r.sources, queries: [pair])
            }
        }
        return LyricQueryDigest(sharedTitle: shared,
                                groups: order.compactMap { byKey[$0] },
                                total: rounds.count)
    }
}
