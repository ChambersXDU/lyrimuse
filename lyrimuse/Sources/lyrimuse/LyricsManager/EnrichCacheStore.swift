import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-manager")

@MainActor
public final class EnrichCacheStore: ObservableObject {
    public static let shared = EnrichCacheStore()

    public struct Summary: Identifiable {
        public var id: String { key }
        public let key: String
        public let artist: String

        public let canonicalArtist: String

        public let durationSecs: Double
        public let title: String
        public let album: String
        public let lyricsSource: String
        public let hasWordTiming: Bool
        public let isManual: Bool

        public let sourceChoice: String

        public let offsetMs: Int

        public let lyricsTrSource: String
        public let hasTranslation: Bool

        public let hasRomanization: Bool
        public let hasLyrics: Bool

        public let isInstrumental: Bool

        public let hasPlainTextFallback: Bool

        public let knownOnSources: Bool

        public let lastRoundHadNoResponder: Bool

        public let sourcesRespondedCount: Int

        public var thinEvidence: Bool { (1...3).contains(sourcesRespondedCount) }

        public let isSearching: Bool

        let hasDecision: Bool

        let lyricsUpdatedAt: Date?

        let resolvedAt: Date?

        let normPrimaryArtist: String

        let normAlbum: String

        let searchArtistLower: String
        let searchDisplayArtistLower: String
        let searchTitleLower: String
        let searchAlbumLower: String

        var displayArtist: String { canonicalArtist.isEmpty ? artist : canonicalArtist }
    }

    @Published public private(set) var summaries: [Summary] = []

    @Published public private(set) var isLoading = false

    private(set) var summariesGeneration = 0

    @Published private(set) var albumDisplayMap: [String: String] = [:]

    @Published private(set) var distinctArtists: [String] = []
    @Published private(set) var distinctAlbums: [String] = []
    @Published public private(set) var lastError: String?

    @Published public private(set) var totalSizeBytes: Int64 = 0

    static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    @Published private(set) var lastAutoSnapshotURL: URL?

    private static let cacheURL = LyrimusePaths.configFile("lyrimuse-enrich-cache.json")

    private static var lyricsDir: URL { FeatureSettingsStore.shared.effectiveLyricsDir }

    private var raw: [String: [String: Any]] = [:]
    private var persistedRaw: [String: [String: Any]] = [:]

    private var knownKeys: Set<String> = []

    private var locallyEditedKeys: Set<String> = []
    private var locallyDeletedKeys: Set<String> = []
    private var pendingExportKeys: Set<String> = []
    private var pendingFileChanges: [URL: ReversibleFileChanges.Change] = [:]
    private var pendingPersistCount = 0
    private var editGeneration = 0

    private var lastPersistPulledInNewKeys = false

    private init() {}

    private func markLocallyEdited(_ key: String) {
        editGeneration += 1
        locallyEditedKeys.insert(key)
        locallyDeletedKeys.remove(key)
    }

    private var lastLoadedFingerprint: FileFingerprint?

    struct FileFingerprint: Equatable {
        var mtime: Date
        var size: Int64
    }

    private nonisolated static func fileFingerprint(_ url: URL) -> FileFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return FileFingerprint(mtime: mtime, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0)
    }

    public func reload(onlyIfChanged: Bool = false) async {
        guard pendingPersistCount == 0, locallyEditedKeys.isEmpty, locallyDeletedKeys.isEmpty else { return }
        let generation = editGeneration
        let cacheURL = Self.cacheURL
        if onlyIfChanged,
           let fp = Self.fileFingerprint(cacheURL),
           fp == lastLoadedFingerprint {
            return
        }

        refreshSizeBytes()
        isLoading = summaries.isEmpty
        defer { isLoading = false }
        final class ResultBox: @unchecked Sendable {
            var obj: [String: [String: Any]]?
            var bundle: SummariesBundle?
            var fingerprint: FileFingerprint?
            var errorMessage: String?
        }
        let box = ResultBox()

        let offsetsSnapshot = LyricsOffsetStore.shared.offsetsSnapshot

        let lyricsDir = Self.lyricsDir
        await Task.detached(priority: .userInitiated) {
            box.fingerprint = Self.fileFingerprint(cacheURL)
            guard let data = try? Data(contentsOf: cacheURL) else {
                box.errorMessage = L10n.t("读取本地记录文件失败")
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
                box.errorMessage = L10n.t("解析本地记录文件失败")
                return
            }
            box.obj = obj

            box.bundle = Self.buildSummaries(from: obj, offsetsSnapshot: offsetsSnapshot, lyricsDir: lyricsDir)
        }.value
        guard generation == editGeneration, pendingPersistCount == 0 else { return }
        if let obj = box.obj, let bundle = box.bundle {
            raw = obj
            persistedRaw = obj
            knownKeys = Set(obj.keys)
            lastLoadedFingerprint = box.fingerprint

            locallyEditedKeys.removeAll()
            locallyDeletedKeys.removeAll()
            lastError = nil
            applySummaries(bundle)
        } else {
            raw = [:]
            lastLoadedFingerprint = nil
            lastError = box.errorMessage ?? L10n.t("读取本地记录文件失败")
            applySummaries(Self.buildSummaries(from: [:], offsetsSnapshot: offsetsSnapshot, lyricsDir: Self.lyricsDir))
        }
    }

    private nonisolated static func fileSizeBytes(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private nonisolated static func directorySizeBytes(_ dir: URL) -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return urls.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    private static func decodeDecision(_ value: Any?) -> LyricsResolutionDecision? {
        guard let dict = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(LyricsResolutionDecision.self, from: data)
    }

    private nonisolated static func splitKey(_ key: String) -> (artist: String, title: String, album: String)? {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    private struct SummariesBundle {
        var summaries: [Summary]
        var albumDisplayMap: [String: String]
        var distinctArtists: [String]
        var distinctAlbums: [String]
    }

    private func applySummaries(_ bundle: SummariesBundle) {
        summaries = bundle.summaries
        summariesGeneration &+= 1
        albumDisplayMap = bundle.albumDisplayMap
        distinctArtists = bundle.distinctArtists
        distinctAlbums = bundle.distinctAlbums
    }

    public func rebuildSummaries() {
        applySummaries(Self.buildSummaries(from: raw, offsetsSnapshot: LyricsOffsetStore.shared.offsetsSnapshot,
                                           lyricsDir: Self.lyricsDir))
    }

    private nonisolated static func lyricsFileModificationDates(in dir: URL) -> [String: Date] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [:] }
        var dates: [String: Date] = [:]
        dates.reserveCapacity(entries.count)
        for url in entries {
            let name = url.lastPathComponent

            guard let suffix = Self.lyricsFileSuffixesLongestFirst.first(where: { name.hasSuffix($0) })
            else { continue }
            let base = String(name.dropLast(suffix.count)).lowercased()
            guard !base.isEmpty,
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate
            else { continue }
            if let known = dates[base], known >= date { continue }
            dates[base] = date
        }
        return dates
    }

    nonisolated private static let lyricsFileSuffixesLongestFirst =
        EnrichCacheKeys.lyricsFileSuffixes.sorted { $0.count > $1.count }

    private nonisolated static func buildSummaries(
        from raw: [String: [String: Any]], offsetsSnapshot: [String: Int], lyricsDir: URL
    ) -> SummariesBundle {
        let lyricsFileDates = Self.lyricsFileModificationDates(in: lyricsDir)

        let offsetPrefixes: Set<String> = Set(offsetsSnapshot.keys.compactMap { key in
            guard let sep = key.range(of: "|", options: .backwards) else { return nil }
            return String(key[..<sep.lowerBound])
        })
        var items = raw.keys.compactMap { key -> Summary? in
            guard let parts = Self.splitKey(key) else { return nil }
            let entry = raw[key] ?? [:]
            let lyrics = entry["lyrics"] as? String ?? ""
            let lyricsYRC = entry["lyrics_yrc"] as? String ?? ""
            let canonical = entry["canonical_artist"] as? String ?? ""
            let display = canonical.isEmpty ? parts.artist : canonical

            let offsetPrefix = "\(EnrichCacheKeys.cleanTag(parts.artist))|\(EnrichCacheKeys.normalizedTitle(parts.title))"
            let offsetMs: Int
            if offsetPrefixes.contains(offsetPrefix) {
                let offsetKey = LyricsOffsetStore.trackKey(artist: parts.artist, title: parts.title,
                                                            lyrics: lyrics, lyricsYRC: lyricsYRC)
                offsetMs = offsetsSnapshot[offsetKey] ?? 0
            } else {
                offsetMs = 0
            }
            return Summary(
                key: key,
                artist: parts.artist,
                canonicalArtist: canonical,

                durationSecs: (entry["resolved_duration_secs"] as? Double).flatMap { $0 > 0 ? $0 : nil }
                    ?? entry["duration_secs"] as? Double ?? 0,
                title: parts.title,
                album: parts.album,
                lyricsSource: entry["lyrics_source"] as? String ?? "",
                hasWordTiming: !lyricsYRC.isEmpty,
                isManual: entry["manual_lyrics"] as? Bool ?? false,
                sourceChoice: entry["lyrics_source_choice"] as? String ?? "",
                offsetMs: offsetMs,
                lyricsTrSource: entry["lyrics_tr_source"] as? String ?? "",
                hasTranslation: !((entry["lyrics_tr"] as? String ?? "").isEmpty),
                hasRomanization: !((entry["lyrics_roma"] as? String ?? "").isEmpty),
                hasLyrics: !lyrics.isEmpty,
                isInstrumental: entry["instrumental"] as? Bool ?? false,
                hasPlainTextFallback: !((entry["plain_lyrics"] as? String ?? "").isEmpty),
                knownOnSources: Self.knownOnSources(entry),
                lastRoundHadNoResponder: Self.lastRoundHadNoResponder(entry),
                sourcesRespondedCount: (entry["lyrics_sources_responded"] as? [Any])?.count ?? 0,
                isSearching: false,
                hasDecision: entry["lyrics_decision"] != nil || entry["lyrics_decision_applied"] != nil,

                lyricsUpdatedAt: lyricsFileDates[EnrichCacheKeys.sanitizeFilename(key).lowercased()]
                    ?? lyricsFileDates[EnrichCacheKeys.disambiguatedName(forKey: key).lowercased()],

                resolvedAt: {
                    let ts = (entry["ts"] as? Double) ?? 0
                    return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
                }(),
                normPrimaryArtist: toSimplified(primaryArtist(display)).lowercased(),
                normAlbum: toSimplified(parts.album).lowercased(),
                searchArtistLower: parts.artist.lowercased(),
                searchDisplayArtistLower: display.lowercased(),
                searchTitleLower: parts.title.lowercased(),
                searchAlbumLower: parts.album.lowercased()
            )
        }
        items.sort {
            ($0.normPrimaryArtist, $0.normAlbum, $0.title) < ($1.normPrimaryArtist, $1.normAlbum, $1.title)
        }

        var albumMap: [String: String] = [:]
        var artistMap: [String: String] = [:]
        for s in items {
            if !s.album.isEmpty, albumMap[s.normAlbum] == nil { albumMap[s.normAlbum] = s.album }
            let rawArtist = primaryArtist(s.displayArtist)
            if !rawArtist.isEmpty, artistMap[s.normPrimaryArtist] == nil {
                artistMap[s.normPrimaryArtist] = rawArtist
            }
        }
        return SummariesBundle(
            summaries: items,
            albumDisplayMap: albumMap,
            distinctArtists: Array(Set(artistMap.values)).sorted(),
            distinctAlbums: Array(Set(albumMap.values)).sorted()
        )
    }

    public func resolvedDurationSecs(for key: String) -> Double {
        raw[key]?["resolved_duration_secs"] as? Double ?? 0
    }

    public func hasEntry(forKey key: String) -> Bool {
        if raw[key] != nil { return true }
        let loose = EnrichCacheKeys.looseKey(key)
        return raw.keys.contains { EnrichCacheKeys.looseKey($0) == loose }
    }

    func decodedDecision(for key: String) -> LyricsResolutionDecision? {
        Self.decodeDecision(raw[key]?["lyrics_decision"])
    }

    func decodedAppliedDecision(for key: String) -> LyricsResolutionDecision? {
        Self.decodeDecision(raw[key]?["lyrics_decision_applied"])
    }

    public func detail(for key: String) -> (lyrics: String, tr: String, roma: String, yrc: String) {
        let entry = raw[key] ?? [:]
        return (
            entry["lyrics"] as? String ?? "",
            entry["lyrics_tr"] as? String ?? "",
            entry["lyrics_roma"] as? String ?? "",
            entry["lyrics_yrc"] as? String ?? ""
        )
    }

    @discardableResult
    public func saveEdit(key: String, lyrics: String, tr: String, roma: String, yrc: String? = nil,
                         source: String? = nil, markManual: Bool = true,
                         sourceChoice: String? = nil, fromManualPick: Bool = false,
                         score: Int? = nil, scoringVersion: Int? = nil,
                         resolvedDurationSecs: Double? = nil,
                         sourcesSeen: [String]? = nil, sourcesResponded: [String]? = nil,
                         decision: [String: Any]? = nil) async -> Bool {
        var entry = raw[key] ?? [:]

        let previousTr = raw[key]?["lyrics_tr"] as? String ?? ""
        if tr != previousTr {
            for stale in ["lyrics_tr_lang", "lyrics_tr_source",
                          "translation_ts", "translation_retry_count"] {
                entry.removeValue(forKey: stale)
            }
        }

        let previousLyrics = raw[key]?["lyrics"] as? String ?? ""
        let previousRoma = raw[key]?["lyrics_roma"] as? String ?? ""
        let romaDescribesOldLyrics =
            !roma.isEmpty && lyrics != previousLyrics && roma == previousRoma
        let effectiveRoma = romaDescribesOldLyrics ? "" : roma
        entry["lyrics"] = lyrics
        entry["lyrics_tr"] = tr
        entry["lyrics_roma"] = effectiveRoma
        if markManual {
            entry["manual_lyrics"] = true
        } else {
            entry.removeValue(forKey: "manual_lyrics")
        }

        if let sourceChoice {
            if sourceChoice.isEmpty {
                entry.removeValue(forKey: "lyrics_source_choice")
            } else {
                entry["lyrics_source_choice"] = sourceChoice
            }
        }

        if let score, let scoringVersion {
            entry["lyrics_score"] = score
            entry["lyrics_scoring_version"] = scoringVersion
        }
        if let resolvedDurationSecs, resolvedDurationSecs > 0 {
            entry["resolved_duration_secs"] = resolvedDurationSecs
        }
        if let sourcesSeen, !sourcesSeen.isEmpty { entry["lyrics_sources_seen"] = sourcesSeen }
        if let sourcesResponded, !sourcesResponded.isEmpty {
            entry["lyrics_sources_responded"] = sourcesResponded
        }

        if let decision {
            entry["lyrics_decision"] = decision
            entry["lyrics_decision_applied"] = decision
        }
        if let yrc {
            if yrc.isEmpty {
                entry.removeValue(forKey: "lyrics_yrc")
            } else {
                entry["lyrics_yrc"] = yrc
            }
        }
        if let source, !source.isEmpty {
            entry["lyrics_source"] = source
        } else {
            entry.removeValue(forKey: "lyrics_source")
        }

        let pickSHA = fromManualPick ? ManualPickLock.fingerprint(lyrics: lyrics) : ""
        if pickSHA.isEmpty {
            entry.removeValue(forKey: "manual_pick_sha")
        } else {
            entry["manual_pick_sha"] = pickSHA
        }
        raw[key] = entry
        markLocallyEdited(key)
        pendingExportKeys.insert(key)

        rebuildSummaries()
        guard await persist() else { return false }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
        return true
    }

    public struct ManualPickLockStats: Sendable {

        public var picked = 0

        public var stillOriginal = 0

        public var targets = 0
    }

    public func manualPickLockStats(locking: Bool) -> ManualPickLockStats {
        var stats = ManualPickLockStats()
        for entry in raw.values {
            let state = ManualPickLock.state(
                sha: entry["manual_pick_sha"] as? String,
                lyrics: entry["lyrics"] as? String ?? "")
            guard state != .neverPicked else { continue }
            stats.picked += 1
            guard state == .original else { continue }
            stats.stillOriginal += 1
            if ((entry["manual_lyrics"] as? Bool) ?? false) != locking { stats.targets += 1 }
        }
        return stats
    }

    public func manualPickLockTargets(locking: Bool) -> [String] {
        raw.compactMap { key, entry in
            ManualPickLock.shouldFlip(
                sha: entry["manual_pick_sha"] as? String,
                lyrics: entry["lyrics"] as? String ?? "",
                isLocked: (entry["manual_lyrics"] as? Bool) ?? false,
                locking: locking
            ) ? key : nil
        }
    }

    @discardableResult
    public func applyManualPickLock(_ locking: Bool) async -> Int {
        let targets = manualPickLockTargets(locking: locking)
        guard !targets.isEmpty else { return 0 }
        for key in targets {
            guard var entry = raw[key] else { continue }
            if locking {
                entry["manual_lyrics"] = true
            } else {
                entry.removeValue(forKey: "manual_lyrics")
            }
            raw[key] = entry
            markLocallyEdited(key)
            pendingExportKeys.insert(key)
        }
        rebuildSummaries()
        guard await persist() else { return 0 }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
        return targets.count
    }

    @discardableResult
    public func savePlainTextEdit(key: String, plainLyrics: String, source: String) async -> Bool {
        var entry = raw[key] ?? [:]
        entry["plain_lyrics"] = plainLyrics
        if source.isEmpty {
            entry.removeValue(forKey: "plain_lyrics_source")
        } else {
            entry["plain_lyrics_source"] = source
        }
        raw[key] = entry
        markLocallyEdited(key)
        rebuildSummaries()
        guard await persist() else { return false }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
        return true
    }

    public func markInstrumental(key: String) async {
        await setInstrumental(key: key, true)
    }

    public func setInstrumental(key: String, _ value: Bool) async {
        var entry = raw[key] ?? [:]
        if value {
            entry["instrumental"] = true
        } else {
            entry.removeValue(forKey: "instrumental")
        }
        raw[key] = entry
        markLocallyEdited(key)
        rebuildSummaries()
        guard await persist() else { return }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
    }

    nonisolated static func isFillSweepRetryable(_ s: Summary) -> Bool {
        !s.hasLyrics && !s.isInstrumental && !s.isManual && !s.isSearching
    }

    nonisolated static func knownOnSources(_ entry: [String: Any]) -> Bool {
        EnrichSourcePresence.knownOnSources(
            neteaseURL: entry["netease_url"] as? String,
            qqMusicURL: entry["qq_music_url"] as? String)
    }

    nonisolated static func lastRoundHadNoResponder(_ entry: [String: Any]) -> Bool {
        let last = entry["lyrics_decision"] as? [String: Any]
        return EnrichSourcePresence.lastRoundHadNoResponder(
            hasDecisionRecord: last != nil,
            respondedCount: (last?["sources_responded"] as? [Any])?.count ?? 0)
    }

    public func recordUnchangedRematchDecision(key: String, decisionJSON: String) async {
        guard let data = decisionJSON.data(using: .utf8),
              let decision = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var entry = raw[key] ?? [:]
        entry["lyrics_decision"] = decision
        entry["lyrics_decision_applied"] = decision
        raw[key] = entry
        markLocallyEdited(key)
        rebuildSummaries()
        guard await persist() else { return }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
    }

    public func delete(key: String) async {
        await delete(keys: [key])
    }

    public func delete(keys: Set<String>) async {

        let victims = EnrichCacheKeys.deletionPlan(selected: keys, existing: Set(raw.keys))
        guard !victims.isEmpty else { return }

        if victims.count >= Self.autoSnapshotDeleteThreshold {
            lastAutoSnapshotURL = await LyricsBackupStore.writeAutoSnapshot(reason: "delete")
        }
        editGeneration += 1
        var removed: [String: [String: Any]] = [:]
        removed.reserveCapacity(victims.count)
        for key in victims {
            if let entry = raw.removeValue(forKey: key) { removed[key] = entry }
            locallyDeletedKeys.insert(key)
            locallyEditedKeys.remove(key)
            pendingExportKeys.remove(key)
            stageExportedLyricsDeletion(forKey: key)
        }
        rebuildSummaries()
        guard await persist() else {

            restoreFailedDeletion(removed)
            return
        }

        if lastPersistPulledInNewKeys { rebuildSummaries() }

        LyricsPinStore.shared.remove(keys: Set(victims))
        scheduleCollectorRestart()
        refreshSizeBytes()
    }

    public func clearAll() async {
        lastAutoSnapshotURL = await LyricsBackupStore.writeAutoSnapshot(reason: "clear")
        let removed = raw
        editGeneration += 1
        raw = [:]
        locallyDeletedKeys.formUnion(removed.keys)
        locallyEditedKeys.subtract(removed.keys)
        pendingFileChanges.removeAll()
        pendingExportKeys.removeAll()
        rebuildSummaries()
        guard await persist(replacingEverything: true) else {
            restoreFailedDeletion(removed)
            return
        }
        LyricsPinStore.shared.removeAll()
        scheduleCollectorRestart()
        refreshSizeBytes()
    }

    private func restoreFailedDeletion(_ removed: [String: [String: Any]]) {
        for (key, entry) in removed where raw[key] == nil && locallyDeletedKeys.contains(key) {
            raw[key] = entry
            locallyDeletedKeys.remove(key)
            for name in EnrichCacheKeys.exportedFileNames(forKey: key) {
                let url = Self.lyricsDir.appendingPathComponent(name)
                if let change = pendingFileChanges[url], change.content == nil {
                    pendingFileChanges.removeValue(forKey: url)
                }
            }
        }
        rebuildSummaries()
    }

    static let autoSnapshotDeleteThreshold = 5

    func restoreFromAutoSnapshot(_ snapshot: LyricsBackupStore.Snapshot) async -> String? {
        guard let result = await LyricsBackupStore.restoreAutoSnapshot(snapshot) else { return nil }
        _ = await CollectorControl.restartAndWaitAsync()
        await reload()
        PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
        refreshSizeBytes()
        return String(format: L10n.t("已恢复 %d 个歌词文件（新增 %d、覆盖 %d）"),
                      result.total, result.added, result.overwritten)
    }

    private func stageExportedLyricsDeletion(forKey key: String) {
        for name in EnrichCacheKeys.exportedFileNames(forKey: key) {
            let url = Self.lyricsDir.appendingPathComponent(name)

            pendingFileChanges[url] = .init(url: url, content: nil)
        }
    }

    private var persistChain: Task<Bool, Never>?

    @discardableResult
    private func persist(replacingEverything: Bool = false) async -> Bool {
        pendingPersistCount += 1
        defer { pendingPersistCount -= 1 }
        let previous = persistChain
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.performPersist(replacingEverything: replacingEverything)
        }
        persistChain = task
        return await task.value
    }

    private func performPersist(replacingEverything: Bool) async -> Bool {
        guard JSONSerialization.isValidJSONObject(raw),
              let memoryData = try? JSONSerialization.data(withJSONObject: raw),
              let baselineData = try? JSONSerialization.data(withJSONObject: persistedRaw) else {
            lastError = L10n.t("内部数据不是合法 JSON,已放弃保存")
            logger.error("raw dict is not valid JSON, aborting save")
            return false
        }

        let edited = locallyEditedKeys
        let deleted = locallyDeletedKeys
        let fileChanges = pendingFileChanges
        let exportKeys = pendingExportKeys
        pendingExportKeys.removeAll()
        pendingFileChanges.removeAll()
        locallyEditedKeys.removeAll()
        locallyDeletedKeys.removeAll()
        let cacheURL = Self.cacheURL

        struct PersistResult: Sendable {
            var mergedData: Data?
            var pulledNew: Bool = false
            var errorMessage: String?
            var ok: Bool = false
        }

        let lyricsDir = Self.lyricsDir
        let result = await Task.detached(priority: .userInitiated) { () -> PersistResult in
            do {
                let saved = try EnrichCachePersistence.save(
                    cacheURL: cacheURL, memoryData: memoryData, baselineData: baselineData,
                    edited: edited, deleted: deleted,
                    replacingEverything: replacingEverything, fileChanges: Array(fileChanges.values),
                    clearLyricsDirectory: replacingEverything ? lyricsDir : nil,
                    exportKeys: exportKeys, lyricsDirectory: lyricsDir)
                return PersistResult(mergedData: saved.data, pulledNew: saved.pulledNewKeys, ok: true)
            } catch {
                return PersistResult(errorMessage: error.localizedDescription, ok: false)
            }
        }.value

        guard result.ok else {

            // Newer edits/deletions queued while this save ran take precedence on retry.
            pendingExportKeys.formUnion(exportKeys.subtracting(locallyDeletedKeys))
            locallyEditedKeys.formUnion(edited.subtracting(locallyDeletedKeys))
            locallyDeletedKeys.formUnion(deleted.subtracting(locallyEditedKeys))
            for (url, change) in fileChanges where pendingFileChanges[url] == nil {
                pendingFileChanges[url] = change
            }
            lastError = String(format: L10n.t("写入本地记录文件失败: %@"), result.errorMessage ?? "")
            logger.error("write failed: \(result.errorMessage ?? "", privacy: .public)")
            lastPersistPulledInNewKeys = false
            return false
        }
        lastError = nil
        lastLoadedFingerprint = nil
        lastPersistPulledInNewKeys = result.pulledNew
        if let data = result.mergedData,
           let merged = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] {
            let snapshot = (try? JSONSerialization.jsonObject(with: memoryData)) as? [String: [String: Any]]
            raw = EnrichCacheMerge.merge(disk: merged, memory: raw, edited: locallyEditedKeys,
                                        deleted: locallyDeletedKeys, baseline: snapshot)
            persistedRaw = merged
            knownKeys = Set(raw.keys)
        }
        return true
    }

    private func refreshSizeBytes() {
        let cacheURL = Self.cacheURL
        let lyricsDir = Self.lyricsDir
        Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                Self.directorySizeBytes(lyricsDir) + Self.fileSizeBytes(cacheURL)
            }.value
            self?.totalSizeBytes = bytes
        }
    }

    private var pendingRestart: Task<Void, Never>?

    private var needsFollowUpRestart = false

    private func scheduleCollectorRestart() {
        if pendingRestart != nil {

            needsFollowUpRestart = true
            return
        }
        pendingRestart = Task { [weak self] in
            let ok = await CollectorControl.restartAndWaitAsync()
            guard let self else { return }
            self.pendingRestart = nil
            if !ok { self.lastError = L10n.t("后台采集服务重启失败") }
            PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
            if self.needsFollowUpRestart {
                self.needsFollowUpRestart = false
                self.scheduleCollectorRestart()
            }
        }
    }

}

struct LyricsResolutionDecision: Decodable {
    let path: String
    let decidedAt: Int?
    let scoringVersion: Int?
    let queryArtist: String?
    let queryTitle: String?
    let queryAlbum: String?
    let durationSecs: Double?
    let sourcesResponded: [String]?
    let winner: String?
    let applied: Bool?
    let candidates: [Candidate]?

    let retryMethod: String?
    let correctedTitle: String?

    let queriesTried: [TriedQuery]?

    struct TriedQuery: Decodable, Identifiable {
        var id: String { "\(reason ?? "")|\(artist)|\(title ?? "")|\((sources ?? []).joined(separator: ","))" }
        let artist: String
        let title: String?

        let reason: String?

        let sources: [String]?
    }

    struct Candidate: Decodable, Identifiable {
        var id: String { source }
        let source: String
        let score: Int
        let scoreTerms: [LyricsSearchService.ScoreTerm]?
        let title: String?
        let artist: String?
        let album: String?

        let coverUrl: String?
        let sourceReportedDurationSecs: Double?
        let hasWordTiming: Bool?
        let instrumental: Bool?

        let consensusPeers: [String]?
    }
}
