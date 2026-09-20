import Foundation

public struct LyricsScoreTermValue: Sendable, Equatable, Identifiable {
    public var id: String { kind }

    public let kind: String
    public let points: Int

    public init(kind: String, points: Int) {
        self.kind = kind
        self.points = points
    }
}

public struct LyricsScoredCandidate: Sendable, Equatable {
    public let source: String
    public let score: Int
    public let terms: [LyricsScoreTermValue]

    public let instrumental: Bool?

    public let consensusPeers: [String]

    public init(source: String, score: Int, terms: [LyricsScoreTermValue],
                instrumental: Bool? = nil, consensusPeers: [String] = []) {
        self.source = source
        self.score = score
        self.terms = terms
        self.instrumental = instrumental
        self.consensusPeers = consensusPeers
    }

    public var isInstrumentalMarker: Bool {
        LyricsDecisionRow.isInstrumentalMarker(instrumental: instrumental, score: score)
    }

    public var isRejected: Bool { terms.first?.kind.hasPrefix("reject") ?? false }

    public var isContender: Bool { !isInstrumentalMarker && !isRejected }

    public var rawTermSum: Int { terms.reduce(0) { $0 + $1.points } }

    public var clampedRawSum: Int? { rawTermSum == score ? nil : rawTermSum }
}

public enum LyricsVerdictSeparator: Sendable, Equatable {

    case identical

    case single(LyricsScoreTermValue)

    case multiple
}

public enum LyricsVerdict: Sendable, Equatable {

    case sameLyrics(contenders: Int, gap: Int, gapPercent: Double?, nearTie: Bool,
                    separator: LyricsVerdictSeparator)

    case decisiveNegative(term: LyricsScoreTermValue, loser: String, gap: Int)

    case tooClose(contenders: Int, corroborated: Int, gap: Int, gapPercent: Double?,
                  separator: LyricsVerdictSeparator)
}

public enum LyricsVerdictBuilder {

    public static let vetoKinds: Set<String> = [
        "versionTags", "durationOff", "durationOvershoot",
        "sourceDurationOff", "liveAlbumConflict", "wordTimingOverride",
    ]

    public static func isNearTie(gap: Int, championScore: Int) -> Bool {
        if gap <= 1 { return true }
        guard championScore > 0 else { return false }
        return Double(gap) * 100 / Double(championScore) < 1
    }

    public static func ranked(_ candidates: [LyricsScoredCandidate],
                              winner: String? = nil) -> [LyricsScoredCandidate] {

        let order = candidates.filter(\.isContender)
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.source < $1.source }
        guard let winner, let top = order.first,
              let idx = order.firstIndex(where: { $0.source == winner && $0.score == top.score }),
              idx != 0
        else { return order }
        var moved = order
        moved.insert(moved.remove(at: idx), at: 0)
        return moved
    }

    public static func champion(among candidates: [LyricsScoredCandidate],
                                winner: String?) -> LyricsScoredCandidate? {
        let order = ranked(candidates)
        guard let top = order.first else { return nil }
        return order.first { $0.source == winner && $0.score == top.score } ?? top
    }

    public static func build(candidates: [LyricsScoredCandidate], winner: String?) -> LyricsVerdict? {
        let contenders = ranked(candidates)
        guard contenders.count >= 2,
              let champion = champion(among: candidates, winner: winner),
              let runnerUp = contenders.first(where: { $0.source != champion.source })
        else { return nil }

        let gap = champion.score - runnerUp.score
        let gapPercent: Double? = champion.score > 0
            ? Double(gap) * 100 / Double(champion.score) : nil
        let nearTie = isNearTie(gap: gap, championScore: champion.score)
        let sep = separator(champion: champion, runnerUp: runnerUp)

        let championTerms = Dictionary(champion.terms.map { ($0.kind, $0.points) },
                                       uniquingKeysWith: { a, _ in a })
        let veto = runnerUp.terms
            .filter {
                vetoKinds.contains($0.kind) && $0.points < 0
                    && (championTerms[$0.kind] ?? 0) >= 0 && abs($0.points) >= gap
            }

            .max { a, b in
                a.points.magnitude != b.points.magnitude
                    ? a.points.magnitude < b.points.magnitude
                    : a.kind > b.kind
            }
        if let veto {
            return .decisiveNegative(term: veto, loser: runnerUp.source, gap: gap)
        }

        if contenders.allSatisfy({ c in c.terms.contains { $0.kind == "consensus" } }) {
            return .sameLyrics(contenders: contenders.count, gap: gap, gapPercent: gapPercent,
                               nearTie: nearTie, separator: sep)
        }

        if nearTie {
            let corroborated = contenders.filter { c in
                c.terms.contains { $0.kind == "consensus" }
            }.count
            return .tooClose(contenders: contenders.count, corroborated: corroborated,
                             gap: gap, gapPercent: gapPercent, separator: sep)
        }
        return nil
    }

    static func separator(champion: LyricsScoredCandidate,
                          runnerUp: LyricsScoredCandidate) -> LyricsVerdictSeparator {
        let diffs = termDiffs(of: champion, against: runnerUp)
        if diffs.isEmpty { return .identical }
        if diffs.count == 1 { return .single(diffs[0]) }
        return .multiple
    }
}

public struct LyricsScoreDelta: Sendable, Equatable, Identifiable {
    public var id: String { source }
    public let source: String

    public let scoreGap: Int

    public let terms: [LyricsScoreTermValue]

    public let clampedRawSum: Int?

    public init(source: String, scoreGap: Int, terms: [LyricsScoreTermValue],
                clampedRawSum: Int?) {
        self.source = source
        self.scoreGap = scoreGap
        self.terms = terms
        self.clampedRawSum = clampedRawSum
    }
}

extension LyricsVerdictBuilder {

    static func termDiffs(of lhs: LyricsScoredCandidate,
                          against rhs: LyricsScoredCandidate) -> [LyricsScoreTermValue] {
        let a = Dictionary(lhs.terms.map { ($0.kind, $0.points) }, uniquingKeysWith: { x, _ in x })
        let b = Dictionary(rhs.terms.map { ($0.kind, $0.points) }, uniquingKeysWith: { x, _ in x })
        return Set(a.keys).union(b.keys)
            .map { LyricsScoreTermValue(kind: $0, points: (a[$0] ?? 0) - (b[$0] ?? 0)) }
            .filter { $0.points != 0 }
            .sorted { a, b in
                a.points.magnitude != b.points.magnitude
                    ? a.points.magnitude > b.points.magnitude
                    : a.kind < b.kind
            }
    }

    public static func deltas(champion: LyricsScoredCandidate,
                             others: [LyricsScoredCandidate]) -> [LyricsScoreDelta] {
        others.map { other in
            LyricsScoreDelta(source: other.source,
                             scoreGap: other.score - champion.score,
                             terms: termDiffs(of: other, against: champion),
                             clampedRawSum: other.clampedRawSum)
        }
    }

    public static func sharedTerms(among candidates: [LyricsScoredCandidate]) -> [LyricsScoreTermValue] {
        let contenders = candidates.filter(\.isContender)
        guard let first = contenders.first, contenders.count >= 2 else { return [] }
        let rest = contenders.dropFirst().map {
            Set($0.terms.map { "\($0.kind)\u{1F}\($0.points)" })
        }
        return first.terms.filter { t in
            let key = "\(t.kind)\u{1F}\(t.points)"
            return rest.allSatisfy { $0.contains(key) }
        }
    }
}
