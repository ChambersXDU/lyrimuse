import Foundation

public struct LyricsQuery: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let album: String?
    public let duration: TimeInterval?

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

public struct LyricsCandidate: Sendable, Equatable {
    public let source: String
    public let lyrics: String
    public let translation: String?
    public let romanization: String?
    public let wordTiming: String?
    public let duration: TimeInterval?
    public let title: String
    public let artist: String
    public let album: String?
    public let coverURL: URL?
    public let instrumental: Bool
    public let plainTextOnly: Bool

    public init(
        source: String,
        lyrics: String,
        translation: String? = nil,
        romanization: String? = nil,
        wordTiming: String? = nil,
        duration: TimeInterval? = nil,
        title: String = "",
        artist: String = "",
        album: String? = nil,
        coverURL: URL? = nil,
        instrumental: Bool = false,
        plainTextOnly: Bool = false
    ) {
        self.source = source
        self.lyrics = lyrics
        self.translation = translation
        self.romanization = romanization
        self.wordTiming = wordTiming
        self.duration = duration
        self.title = title
        self.artist = artist
        self.album = album
        self.coverURL = coverURL
        self.instrumental = instrumental
        self.plainTextOnly = plainTextOnly
    }

    public var hasWordTiming: Bool { !(wordTiming?.isEmpty ?? true) }
    public var hasTranslation: Bool { !(translation?.isEmpty ?? true) }
    public var hasRomanization: Bool { !(romanization?.isEmpty ?? true) }
}

public protocol LyricsProvider: Sendable {
    var id: String { get }
    func search(_ query: LyricsQuery) async throws -> [LyricsCandidate]
}

public struct LyricsResolution: Sendable {
    public let matches: [LyricsMatch]
    public let sourcesSeen: [String]
    public let sourcesResponded: [String]
    public let failures: [String: String]
    public let instrumental: Bool

    public var winner: LyricsMatch? {
        matches.first(where: { !$0.isRejected && !$0.candidate.instrumental })
    }

    public init(
        matches: [LyricsMatch], sourcesSeen: [String], sourcesResponded: [String],
        failures: [String: String], instrumental: Bool
    ) {
        self.matches = matches
        self.sourcesSeen = sourcesSeen
        self.sourcesResponded = sourcesResponded
        self.failures = failures
        self.instrumental = instrumental
    }
}
