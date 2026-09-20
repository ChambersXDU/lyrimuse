import Foundation

public enum LyricsBackupArchive {

    public static let payloadVersion = 2

    public static let lyricFieldKeys = [
        "lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc", "lyrics_source", "manual_lyrics",
    ]

    public static func strippedMeta(fromCacheJSON data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: Any] = [:]
        out.reserveCapacity(root.count)
        for (key, value) in root {
            guard var entry = value as? [String: Any] else { continue }
            for field in lyricFieldKeys { entry.removeValue(forKey: field) }
            guard !entry.isEmpty else { continue }
            out[key] = entry
        }
        guard !out.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    public static let configNameMarker = "-Config-"
    public static let lyricsNameMarker = "-Lyrics-"

    public static let fileExtension = "json.z"

    public static func sidecarName(forConfigName name: String) -> String {
        let stem = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        if let range = stem.range(of: configNameMarker) {
            return stem.replacingCharacters(in: range, with: lyricsNameMarker) + "." + fileExtension
        }
        return stem + lyricsNameMarker.dropLast() + "." + fileExtension
    }

    public struct Payload: Codable, Equatable {

        public var v: Int

        public var at: String

        public var device: String

        public var files: [String: String]

        public var pins: [String: Int]

        public var meta: Data?

        public init(v: Int = LyricsBackupArchive.payloadVersion, at: String, device: String,
                    files: [String: String], pins: [String: Int], meta: Data? = nil) {
            self.v = v
            self.at = at
            self.device = device
            self.files = files
            self.pins = pins
            self.meta = meta
        }
    }

    public static func encode(_ payload: Payload) -> Data? {
        guard let raw = try? JSONEncoder().encode(payload) else { return nil }
        return ((try? (raw as NSData).compressed(using: .zlib)) as Data?) ?? raw
    }

    public static func decode(_ data: Data) -> Payload? {
        let raw = ((try? (data as NSData).decompressed(using: .zlib)) as Data?) ?? data
        return try? JSONDecoder().decode(Payload.self, from: raw)
    }

    public static func sanitizedFileName(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 255 else { return nil }
        guard !raw.contains("/"), !raw.contains("\\") else { return nil }
        guard !raw.hasPrefix(".") else { return nil }
        guard EnrichCacheKeys.lyricsFileSuffixes.contains(where: { raw.hasSuffix($0) }) else { return nil }
        return raw
    }

    public struct Plan: Equatable {
        public var added: [String] = []
        public var overwritten: [String] = []
        public var rejected: [String] = []
        public init() {}
    }

    public static func plan(incoming: [String], existing: Set<String>) -> Plan {
        var plan = Plan()
        for raw in incoming.sorted() {
            guard let name = sanitizedFileName(raw) else {
                plan.rejected.append(raw)
                continue
            }
            if existing.contains(name) {
                plan.overwritten.append(name)
            } else {
                plan.added.append(name)
            }
        }
        return plan
    }
}
