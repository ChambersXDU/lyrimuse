import Foundation

public struct LyricsSortKey: Sendable, Equatable {

    public let normPrimaryArtist: String

    public let normAlbum: String

    public let title: String

    public let searchTitleLower: String

    public let sourceDisplayName: String

    public let hasSource: Bool

    public let lyricsUpdatedAt: Date?

    public let resolvedAt: Date?

    public let sourcesRespondedCount: Int

    public init(
        normPrimaryArtist: String,
        normAlbum: String,
        title: String,
        searchTitleLower: String,
        sourceDisplayName: String,
        hasSource: Bool,
        lyricsUpdatedAt: Date?,
        resolvedAt: Date?,
        sourcesRespondedCount: Int = 0
    ) {
        self.normPrimaryArtist = normPrimaryArtist
        self.normAlbum = normAlbum
        self.title = title
        self.searchTitleLower = searchTitleLower
        self.sourceDisplayName = sourceDisplayName
        self.hasSource = hasSource
        self.lyricsUpdatedAt = lyricsUpdatedAt
        self.resolvedAt = resolvedAt
        self.sourcesRespondedCount = sourcesRespondedCount
    }
}

public enum LyricsSortOrder: Sendable, Equatable {
    case defaultOrder
    case title(ascending: Bool)
    case artist(ascending: Bool)
    case album(ascending: Bool)
    case source(ascending: Bool)
    case updated(ascending: Bool)

    case evidence(ascending: Bool)

    public func less(_ a: LyricsSortKey, _ b: LyricsSortKey) -> Bool {
        switch self {
        case .defaultOrder:
            break

        case .title(let ascending):
            if a.searchTitleLower != b.searchTitleLower {
                return ascending
                    ? a.searchTitleLower < b.searchTitleLower
                    : a.searchTitleLower > b.searchTitleLower
            }

        case .artist(let ascending):
            if a.normPrimaryArtist != b.normPrimaryArtist {
                return ascending
                    ? a.normPrimaryArtist < b.normPrimaryArtist
                    : a.normPrimaryArtist > b.normPrimaryArtist
            }

        case .album(let ascending):
            if a.normAlbum != b.normAlbum {
                return ascending ? a.normAlbum < b.normAlbum : a.normAlbum > b.normAlbum
            }

        case .source(let ascending):

            switch (a.hasSource, b.hasSource) {
            case (true, false):
                return true
            case (false, true):
                return false
            case (true, true):
                if a.sourceDisplayName != b.sourceDisplayName {
                    return ascending
                        ? a.sourceDisplayName < b.sourceDisplayName
                        : a.sourceDisplayName > b.sourceDisplayName
                }
            case (false, false):

                if let r = Self.compareOptional(a.resolvedAt, b.resolvedAt, ascending: ascending) {
                    return r
                }
            }

        case .evidence(let ascending):

            switch (a.sourcesRespondedCount > 0, b.sourcesRespondedCount > 0) {
            case (true, false):
                return true
            case (false, true):
                return false
            case (true, true):
                if a.sourcesRespondedCount != b.sourcesRespondedCount {
                    return ascending
                        ? a.sourcesRespondedCount < b.sourcesRespondedCount
                        : a.sourcesRespondedCount > b.sourcesRespondedCount
                }
            case (false, false):
                if let r = Self.compareOptional(a.resolvedAt, b.resolvedAt, ascending: ascending) {
                    return r
                }
            }

        case .updated(let ascending):
            switch (a.lyricsUpdatedAt, b.lyricsUpdatedAt) {
            case (nil, nil):

                if let r = Self.compareOptional(a.resolvedAt, b.resolvedAt, ascending: ascending) {
                    return r
                }
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (x?, y?):

                if x != y { return ascending ? x < y : x > y }
            }
        }
        return Self.fallbackLess(a, b)
    }

    static func compareOptional(_ a: Date?, _ b: Date?, ascending: Bool) -> Bool? {
        switch (a, b) {
        case (nil, nil):
            return nil
        case (nil, _):
            return false
        case (_, nil):
            return true
        case let (x?, y?):
            if x == y { return nil }
            return ascending ? x < y : x > y
        }
    }

    static func fallbackLess(_ a: LyricsSortKey, _ b: LyricsSortKey) -> Bool {
        (a.normPrimaryArtist, a.normAlbum, a.title)
            < (b.normPrimaryArtist, b.normAlbum, b.title)
    }
}
