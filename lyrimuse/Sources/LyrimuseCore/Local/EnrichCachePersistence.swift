import Foundation

public enum EnrichCachePersistence {
    public static func save(
        cacheURL: URL,
        entries: [String: [String: Any]],
        fileChanges: [ReversibleFileChanges.Change] = [],
        clearLyricsDirectory: URL? = nil,
        exportKeys: Set<String> = [],
        lyricsDirectory: URL? = nil
    ) throws {
        guard JSONSerialization.isValidJSONObject(entries),
              let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]) else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        var changes: [URL: ReversibleFileChanges.Change] = [:]
        if let directory = clearLyricsDirectory {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in urls where EnrichCacheKeys.lyricsFileSuffixes.contains(where: { url.lastPathComponent.hasSuffix($0) }) {
                changes[url] = .init(url: url, content: nil)
            }
        }
        for change in fileChanges { changes[change.url] = change }
        if let directory = lyricsDirectory {
            for key in exportKeys {
                for change in exportChanges(key: key, entries: entries, directory: directory) {
                    changes[change.url] = change
                }
            }
        }
        try ReversibleFileChanges.apply(changes.values.sorted { $0.url.path < $1.url.path }) {
            try data.write(to: cacheURL, options: .atomic)
        }
    }

    private static func exportChanges(
        key: String, entries: [String: [String: Any]], directory: URL
    ) -> [ReversibleFileChanges.Change] {
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
