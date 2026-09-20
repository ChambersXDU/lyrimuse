import Foundation
import os

public struct RadioStationCard: Codable, Equatable, Sendable {

    public var stationHash: String
    public var name: String

    public var artwork: Data?

    enum CodingKeys: String, CodingKey {
        case stationHash = "station_hash"
        case name
        case artwork
    }

    public init(stationHash: String, name: String, artwork: Data?) {
        self.stationHash = stationHash
        self.name = name
        self.artwork = artwork
    }
}

public enum RadioStationCardFile {
    public static let fileName = "lyrimuse-radio-station.json"
    public static var url: URL { LyrimusePaths.configFile(fileName) }
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "radio-clock")

    public static let maxNameLength = 80

    public static func stationName(isRadio: Bool, stationHash: String?, title: String?, artist: String?) -> String? {
        guard isRadio, let stationHash, !stationHash.isEmpty else { return nil }
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let a = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.isEmpty != a.isEmpty else { return nil }
        let name = t.isEmpty ? a : t
        guard name.count <= maxNameLength else { return nil }
        return name
    }

    public static func card(_ card: RadioStationCard?, forStation hash: String?) -> RadioStationCard? {
        guard let card, let hash, !hash.isEmpty, card.stationHash == hash else { return nil }
        return card
    }

    public static func encode(_ card: RadioStationCard) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(card)
    }

    public static func load() -> RadioStationCard? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RadioStationCard.self, from: data)
    }

    public static func write(_ card: RadioStationCard) {
        do {
            try encode(card).write(to: url, options: .atomic)
        } catch {
            logger.notice("radio station card write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
