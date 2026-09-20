import Foundation
import os

public struct RadioClockRecord: Codable, Equatable, Sendable {
    public var trackKey: String
    public var position: Double
    public var tickedAtMs: Int64
    public var playing: Bool

    enum CodingKeys: String, CodingKey {
        case trackKey = "track_key"
        case position
        case tickedAtMs = "ticked_at_ms"
        case playing
    }

    public init(trackKey: String, position: Double, tickedAtMs: Int64, playing: Bool) {
        self.trackKey = trackKey
        self.position = position
        self.tickedAtMs = tickedAtMs
        self.playing = playing
    }
}

public enum RadioClockFile {
    public static let fileName = "lyrimuse-radio-clock.json"
    public static var url: URL { LyrimusePaths.configFile(fileName) }
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "radio-clock")

    public static let maxRestoreGap: TimeInterval = 60

    public static let minWriteInterval: TimeInterval = 15

    public static func encode(_ record: RadioClockRecord) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(record)
    }

    public static func decode(_ data: Data) -> RadioClockRecord? {
        try? JSONDecoder().decode(RadioClockRecord.self, from: data)
    }

    public static func restorable(_ record: RadioClockRecord?, trackKey: String, now: Date) -> RadioTrackClock.State? {
        guard let record, record.trackKey == trackKey, record.playing else { return nil }
        let tickedAt = Date(timeIntervalSince1970: Double(record.tickedAtMs) / 1000)
        let gap = now.timeIntervalSince(tickedAt)
        guard gap >= 0, gap <= maxRestoreGap else { return nil }
        return RadioTrackClock.State(trackKey: record.trackKey, position: record.position,
                                     tickedAt: tickedAt, playing: true)
    }

    public static func shouldWrite(previous: RadioClockRecord?, next: RadioClockRecord, now: Date) -> Bool {
        guard let previous else { return true }
        if previous.trackKey != next.trackKey || previous.playing != next.playing { return true }
        let since = now.timeIntervalSince(Date(timeIntervalSince1970: Double(previous.tickedAtMs) / 1000))
        return since >= minWriteInterval || since < 0
    }

    public static func load() -> RadioClockRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    public static func write(_ record: RadioClockRecord) {
        do {
            try encode(record).write(to: url, options: .atomic)
        } catch {
            logger.notice("radio clock file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
