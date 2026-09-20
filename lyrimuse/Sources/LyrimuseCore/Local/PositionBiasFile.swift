import Foundation
import os

public struct PositionBiasRecord: Codable, Equatable, Sendable {
    public var artist: String
    public var title: String
    public var bundleID: String

    public var anchorElapsed: Double?

    public var biasSecs: Double
    public var writtenAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case artist, title
        case bundleID = "bundle_id"
        case anchorElapsed = "anchor_elapsed"
        case biasSecs = "bias_secs"
        case writtenAtMs = "written_at_ms"
    }

    public init(artist: String, title: String, bundleID: String, anchorElapsed: Double?, biasSecs: Double, writtenAtMs: Int64) {
        self.artist = artist
        self.title = title
        self.bundleID = bundleID
        self.anchorElapsed = anchorElapsed
        self.biasSecs = biasSecs
        self.writtenAtMs = writtenAtMs
    }

    public func sameContent(as other: PositionBiasRecord) -> Bool {
        artist == other.artist && title == other.title && bundleID == other.bundleID
            && anchorElapsed == other.anchorElapsed && biasSecs == other.biasSecs
    }
}

public enum PositionBiasFile {

    public static let fileName = "lyrimuse-position-bias.json"
    public static var url: URL { LyrimusePaths.configFile(fileName) }
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "position-bias")

    public static func encode(_ record: PositionBiasRecord) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(record)
    }

    public static func write(_ record: PositionBiasRecord) {
        do {
            try encode(record).write(to: url, options: .atomic)
        } catch {
            logger.notice("position bias file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
