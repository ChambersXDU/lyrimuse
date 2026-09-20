import Foundation
import Darwin

public enum EnrichCachePersistence {
    public struct Saved: Sendable {
        public let data: Data
        public let pulledNewKeys: Bool
    }

    // Keep this sidecar in place: locking the JSON inode would not survive atomic replacement.
    public static func withLock<T>(cacheURL: URL, timeout: TimeInterval = 10,
                                   _ body: () throws -> T) throws -> T {
        let fd = open(cacheURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw POSIXError(.ETIMEDOUT) }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    public static func save(cacheURL: URL, memoryData: Data, baselineData: Data? = nil,
                            edited: Set<String>, deleted: Set<String>, replacingEverything: Bool = false,
                            fileChanges: [ReversibleFileChanges.Change] = [],
                            clearLyricsDirectory: URL? = nil,
                            exportKeys: Set<String> = [], lyricsDirectory: URL? = nil) throws -> Saved {
        try withLock(cacheURL: cacheURL) {
            let memory = try decode(memoryData)
            let baseline = try baselineData.map(decode)
            let disk: [String: [String: Any]]
            do {
                disk = try decode(Data(contentsOf: cacheURL))
            } catch CocoaError.fileReadNoSuchFile {
                disk = [:]
            }
            let target = replacingEverything ? memory : EnrichCacheMerge.merge(
                disk: disk, memory: memory, edited: edited, deleted: deleted, baseline: baseline)
            let data = try JSONSerialization.data(withJSONObject: target, options: [.sortedKeys])
            var changes: [URL: ReversibleFileChanges.Change] = [:]
            if let directory = clearLyricsDirectory {
                let urls: [URL]
                do {
                    urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                } catch CocoaError.fileReadNoSuchFile {
                    urls = []
                }
                for url in urls where EnrichCacheKeys.lyricsFileSuffixes.contains(where: { url.lastPathComponent.hasSuffix($0) }) {
                    changes[url] = .init(url: url, content: nil)
                }
            }
            for change in fileChanges { changes[change.url] = change }
            if let directory = lyricsDirectory {
                for key in exportKeys {
                    for change in exportChanges(key: key, entries: target, directory: directory) {
                        changes[change.url] = change
                    }
                }
            }
            try ReversibleFileChanges.apply(changes.values.sorted { $0.url.path < $1.url.path }) {
                try data.write(to: cacheURL, options: .atomic)
            }
            return Saved(data: data, pulledNewKeys: !Set(target.keys).subtracting(memory.keys).isEmpty)
        }
    }

    private static func decode(_ data: Data) throws -> [String: [String: Any]] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    private static func exportChanges(key: String, entries: [String: [String: Any]],
                                      directory: URL) -> [ReversibleFileChanges.Change] {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let entry = entries[key] else { return [] }
        let plain = EnrichCacheKeys.sanitizeFilename(key)
        let hashed = EnrichCacheKeys.disambiguatedName(forKey: key)
        let collides = entries.keys.contains {
            $0 != key && EnrichCacheKeys.sanitizeFilename($0).lowercased() == plain.lowercased()
        }
        let base = collides ? hashed : plain
        let stale = collides ? plain : hashed
        var changes = EnrichCacheKeys.lyricsFileSuffixes.map {
            ReversibleFileChanges.Change(url: directory.appendingPathComponent(stale + $0), content: nil)
        }
        var header = "[ar:\(parts[0])]\n[ti:\(parts[1])]\n[al:\(parts[2])]\n"
        if let source = entry["lyrics_source"] as? String, !source.isEmpty { header += "[source:\(source)]\n" }
        if entry["manual_lyrics"] as? Bool == true { header += "[manual:1]\n" }
        header += "\n"
        for (field, suffix) in zip(["lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc"], EnrichCacheKeys.lyricsFileSuffixes) {
            let text = entry[field] as? String ?? ""
            changes.append(.init(url: directory.appendingPathComponent(base + suffix),
                                 content: text.isEmpty ? nil : Data((header + text).utf8)))
        }
        return changes
    }
}
