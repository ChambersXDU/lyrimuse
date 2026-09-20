import Combine
import Foundation
import CryptoKit

@MainActor

public final class LyricsOffsetStore: ObservableObject {
    public static let shared = LyricsOffsetStore()

    private static let defaultsKey = "np:lyricsOffsetsByTrackJSON"
    private static let globalDefaultsKey = "np:lyricsGlobalOffsetMs"

    private static let playerDefaultsKey = "np:lyricsOffsetsByPlayerJSON"

    private var offsets: [String: Int]

    private init() {

        let loaded = Self.load()
        offsets = Self.migratedOffsetKeys(loaded)
        let didMigrateKeys = offsets != loaded
        trackOffsetCount = offsets.count

        globalOffsetMs = UserDefaults.standard.integer(forKey: Self.globalDefaultsKey)
        playerOffsets = Self.loadPlayerOffsets()

        UserDefaults.standard.removeObject(forKey: "np:lyricsPlayerOffsetsJSON")

        if didMigrateKeys { persist() }
    }

    @Published public private(set) var globalOffsetMs: Int

    public func setGlobalOffset(_ ms: Int) {
        guard ms != globalOffsetMs else { return }
        globalOffsetMs = ms
        UserDefaults.standard.set(ms, forKey: Self.globalDefaultsKey)
    }

    @Published public private(set) var playerOffsets: [String: Int]

    public func playerOffset(forBundleID bundleID: String?) -> Int {
        guard let bundleID, !bundleID.isEmpty else { return 0 }
        return playerOffsets[bundleID] ?? 0
    }

    public func setPlayerOffset(_ ms: Int, forBundleID bundleID: String) {
        guard !bundleID.isEmpty else { return }
        guard playerOffsets[bundleID] ?? 0 != ms else { return }
        if ms == 0 {
            playerOffsets.removeValue(forKey: bundleID)
        } else {
            playerOffsets[bundleID] = ms
        }
        persistPlayerOffsets()
    }

    public func baseOffsetMs(forBundleID bundleID: String?) -> Int {
        if let bundleID, !bundleID.isEmpty, let own = playerOffsets[bundleID] { return own }
        return globalOffsetMs
    }

    public func effectiveOffset(forKey key: String, bundleID: String? = nil) -> Int {
        baseOffsetMs(forBundleID: bundleID) + offset(forKey: key)
    }

    public nonisolated static func trackKey(artist: String, title: String, lyrics: String, lyricsYRC: String) -> String {

        "\(EnrichCacheKeys.cleanTag(artist))|\(EnrichCacheKeys.normalizedTitle(title))|\(contentFingerprint(lyrics: lyrics, lyricsYRC: lyricsYRC))"
    }

    public nonisolated static func migratedOffsetKeys(_ stored: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(stored.count)
        var lockedBySelfMapping = Set<String>()
        for key in stored.keys.sorted() {
            guard let value = stored[key] else { continue }
            let target = normalizedTrackKey(key)
            if lockedBySelfMapping.contains(target) { continue }
            if out[target] == nil || target == key { out[target] = value }
            if target == key { lockedBySelfMapping.insert(target) }
        }
        return out
    }

    private nonisolated static func normalizedTrackKey(_ key: String) -> String {
        guard let lastSep = key.lastIndex(of: "|") else { return key }
        let fingerprint = key[key.index(after: lastSep)...]
        let head = key[key.startIndex..<lastSep]
        guard let firstSep = head.firstIndex(of: "|") else { return key }
        let artist = String(head[head.startIndex..<firstSep])
        let title = String(head[head.index(after: firstSep)...])
        return "\(EnrichCacheKeys.cleanTag(artist))|\(EnrichCacheKeys.normalizedTitle(title))|\(fingerprint)"
    }

    private nonisolated static func contentFingerprint(lyrics: String, lyricsYRC: String) -> String {
        let combined = lyrics + "\u{1}" + lyricsYRC
        guard combined != "\u{1}" else { return "" }
        let digest = SHA256.hash(data: Data(combined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    @Published public private(set) var trackOffsetCount: Int

    public func offset(forKey key: String) -> Int {
        guard isValid(key) else { return 0 }
        return offsets[key] ?? 0
    }

    public var offsetsSnapshot: [String: Int] { offsets }

    @discardableResult
    public func nudge(by deltaMs: Int, forKey key: String, pinKey: String) -> Int {
        let newValue = offset(forKey: key) + deltaMs
        set(newValue, forKey: key, pinKey: pinKey)
        return newValue
    }

    public func reset(forKey key: String, pinKey: String) {
        set(0, forKey: key, pinKey: pinKey)
    }

    public func setOffset(_ ms: Int, forKey key: String, pinKey: String) {
        set(ms, forKey: key, pinKey: pinKey)
    }

    public func syncPinToOffset(forKey key: String, pinKey: String) {
        guard !pinKey.isEmpty else { return }
        LyricsPinStore.shared.setPinned(offset(forKey: key) != 0, forKey: pinKey)
    }

    public func clearAllTrackOffsets() {
        if !offsets.isEmpty {
            offsets.removeAll()
            trackOffsetCount = 0
            persist()
        }

        LyricsPinStore.shared.removeAll()
    }

    private func isValid(_ key: String) -> Bool {
        !key.replacingOccurrences(of: "|", with: "").isEmpty
    }

    private func set(_ ms: Int, forKey key: String, pinKey: String) {
        guard isValid(key) else { return }
        if ms == 0 {
            offsets.removeValue(forKey: key)
        } else {
            offsets[key] = ms
        }
        trackOffsetCount = offsets.count
        persist()

        if !pinKey.isEmpty {
            LyricsPinStore.shared.setPinned(ms != 0, forKey: pinKey)
        }
    }

    private func persistPlayerOffsets() {
        guard
            let data = try? JSONEncoder().encode(playerOffsets),
            let json = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(json, forKey: Self.playerDefaultsKey)
    }

    private static func loadPlayerOffsets() -> [String: Int] {
        guard
            let json = UserDefaults.standard.string(forKey: playerDefaultsKey),
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }

        return decoded.filter { $0.value != 0 }
    }

    private func persist() {
        guard
            let data = try? JSONEncoder().encode(offsets),
            let json = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(json, forKey: Self.defaultsKey)
    }

    private static func load() -> [String: Int] {
        guard
            let json = UserDefaults.standard.string(forKey: defaultsKey),
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else {
            return [:]
        }
        return decoded
    }
}
