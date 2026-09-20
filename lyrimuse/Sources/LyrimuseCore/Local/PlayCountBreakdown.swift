import Foundation

public struct PlayCountBreakdown: Equatable {
    public struct Variant: Equatable, Identifiable {
        public let artist: String
        public let title: String

        public let total: Int

        public let isSelf: Bool
        public let reasons: [PlayCountFoldReason]

        public let loaded: Int

        public let failed: Bool

        public var id: String { artist.lowercased() + "|" + title.lowercased() }

        public var exhausted: Bool { !failed && loaded >= total }
        public init(artist: String, title: String, total: Int, isSelf: Bool,
                    reasons: [PlayCountFoldReason], loaded: Int, failed: Bool) {
            self.artist = artist
            self.title = title
            self.total = total
            self.isSelf = isSelf
            self.reasons = reasons
            self.loaded = loaded
            self.failed = failed
        }
    }

    public struct Play: Equatable, Identifiable {
        public let date: Date

        public let variantIndex: Int
        public let album: String?

        public let dup: Int
        public var id: String { "\(date.timeIntervalSince1970)|\(variantIndex)|\(dup)" }

        public init(date: Date, variantIndex: Int, album: String?, dup: Int) {
            self.date = date
            self.variantIndex = variantIndex
            self.album = album
            self.dup = dup
        }
    }

    public let variants: [Variant]

    public let plays: [Play]

    public let ordinalCutoff: Date?

    public var total: Int { variants.reduce(0) { $0 + $1.total } }
    public var canLoadOlder: Bool { variants.contains { !$0.failed && !$0.exhausted } }
    public var hasFailure: Bool { variants.contains { $0.failed } }

    public struct AlbumGroup: Equatable {
        public let album: String?
        public let count: Int
        public init(album: String?, count: Int) {
            self.album = album
            self.count = count
        }
    }

    public func albumGroups(variantIndex: Int) -> [AlbumGroup] {
        var counts: [String?: Int] = [:]
        for p in plays where p.variantIndex == variantIndex {
            let key = p.album?.trimmingCharacters(in: .whitespaces)
            counts[key.flatMap { $0.isEmpty ? nil : $0 }, default: 0] += 1
        }
        return counts.map { AlbumGroup(album: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return ($0.album ?? "") < ($1.album ?? "")
            }
    }

    public var ordinals: [Int?] {
        let total = total
        return plays.enumerated().map { i, p in
            if let cutoff = ordinalCutoff, p.date < cutoff { return nil }
            let n = total - i
            return n > 0 ? n : nil
        }
    }

    public init(variants: [Variant], plays: [Play], ordinalCutoff: Date?) {
        self.variants = variants
        self.plays = plays
        self.ordinalCutoff = ordinalCutoff
    }
}

public enum PlayCountBreakdownMath {

    public struct VariantInput {
        public var artist: String
        public var title: String
        public var total: Int
        public var isSelf: Bool
        public var reasons: [PlayCountFoldReason]
        public var plays: [(date: Date, album: String?)]
        public var failed: Bool

        public init(artist: String, title: String, total: Int, isSelf: Bool,
                    reasons: [PlayCountFoldReason], plays: [(date: Date, album: String?)],
                    failed: Bool = false) {
            self.artist = artist
            self.title = title
            self.total = total
            self.isSelf = isSelf
            self.reasons = reasons
            self.plays = plays
            self.failed = failed
        }
    }

    public static func build(_ inputs: [VariantInput]) -> PlayCountBreakdown {
        var variants: [PlayCountBreakdown.Variant] = []
        var plays: [PlayCountBreakdown.Play] = []

        var cutoff: Date?
        for (index, input) in inputs.enumerated() {
            var dupCount: [TimeInterval: Int] = [:]
            for p in input.plays {
                let uts = p.date.timeIntervalSince1970
                let dup = dupCount[uts, default: 0]
                dupCount[uts] = dup + 1
                plays.append(.init(date: p.date, variantIndex: index, album: p.album, dup: dup))
            }
            let variant = PlayCountBreakdown.Variant(
                artist: input.artist, title: input.title, total: input.total, isSelf: input.isSelf,
                reasons: input.reasons, loaded: input.plays.count, failed: input.failed)
            variants.append(variant)
            if !variant.exhausted {
                let oldestLoaded = input.plays.map(\.date).min() ?? Date.distantFuture
                cutoff = max(cutoff ?? .distantPast, oldestLoaded)
            }
        }

        plays.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.variantIndex != $1.variantIndex { return $0.variantIndex < $1.variantIndex }
            return $0.dup < $1.dup
        }
        return PlayCountBreakdown(variants: variants, plays: plays, ordinalCutoff: cutoff)
    }
}
