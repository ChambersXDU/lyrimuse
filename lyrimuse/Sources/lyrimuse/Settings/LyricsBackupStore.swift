import Foundation
import LyrimuseCore
import OSLog

@MainActor
enum LyricsBackupStore {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-backup")

    private static let enrichCacheURL = LyrimusePaths.configFile("lyrimuse-enrich-cache.json")

    private static let enrichRestoreURL = LyrimusePaths.configFile("lyrimuse-enrich-restore.json")

    static func currentSize() -> (files: Int, bytes: Int) {
        let dir = FeatureSettingsStore.shared.effectiveLyricsDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return (0, 0)
        }
        var count = 0
        var bytes = 0
        for name in names where EnrichCacheKeys.lyricsFileSuffixes.contains(where: { name.hasSuffix($0) }) {
            let path = dir.appendingPathComponent(name).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int else { continue }
            count += 1
            bytes += size
        }
        return (count, bytes)
    }

    static func buildArchive() async -> Data? {
        let dir = FeatureSettingsStore.shared.effectiveLyricsDir
        let pins = LyricsPinStore.shared.pins
        let cacheURL = enrichCacheURL
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
                logger.notice("buildArchive: no lyrics dir at \(dir.path, privacy: .public)")
                return nil
            }
            var files: [String: String] = [:]
            for name in names {
                guard LyricsBackupArchive.sanitizedFileName(name) != nil else { continue }
                guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                else { continue }
                files[name] = text
            }
            guard !files.isEmpty else { return nil }

            var meta: Data?
            if let cacheData = try? Data(contentsOf: cacheURL) {
                meta = LyricsBackupArchive.strippedMeta(fromCacheJSON: cacheData)
                if meta == nil {
                    logger.error("buildArchive: enrich cache present (\(cacheData.count) bytes) but strippedMeta returned nil")
                }
            } else {
                logger.notice("buildArchive: no enrich cache at \(cacheURL.path, privacy: .public)")
            }

            let payload = LyricsBackupArchive.Payload(
                at: ISO8601DateFormatter().string(from: Date()),
                device: Host.current().localizedName ?? "",
                files: files,
                pins: pins,
                meta: meta
            )
            let out = LyricsBackupArchive.encode(payload)
            logger.notice("buildArchive: \(files.count) files, meta \(meta?.count ?? 0) bytes → \(out?.count ?? 0) bytes")
            return out
        }.value
    }

    static func peek(_ data: Data) async -> (files: Int, pins: Int)? {
        await Task.detached(priority: .userInitiated) { () -> (files: Int, pins: Int)? in
            guard let payload = LyricsBackupArchive.decode(data) else { return nil }
            return (payload.files.count, payload.pins.count)
        }.value
    }

    struct RestoreResult {
        var added = 0
        var overwritten = 0
        var rejected = 0
        var failed = 0
        var pinsAdded = 0

        var metaBytes = 0
        var total: Int { added + overwritten }
    }

    static func restore(from data: Data) async -> RestoreResult? {

        let dir = FeatureSettingsStore.shared.effectiveLyricsDir
        let restoreURL = enrichRestoreURL
        let outcome = await Task.detached(priority: .userInitiated) { () -> (RestoreResult, [String: Int])? in
            guard let payload = LyricsBackupArchive.decode(data) else {
                logger.error("restore: payload decode failed (\(data.count) bytes)")
                return nil
            }
            if payload.v > LyricsBackupArchive.payloadVersion {

                logger.warning("restore: archive v\(payload.v) newer than v\(LyricsBackupArchive.payloadVersion)")
            }
            var result = RestoreResult()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            let plan = LyricsBackupArchive.plan(incoming: Array(payload.files.keys), existing: existing)
            result.rejected = plan.rejected.count
            if !plan.rejected.isEmpty {
                logger.error("restore: rejected \(plan.rejected.count) unsafe names, first=\(plan.rejected[0], privacy: .public)")
            }

            let dirPath = dir.standardizedFileURL.path
            for (name, isNew) in plan.added.map({ ($0, true) }) + plan.overwritten.map({ ($0, false) }) {
                guard let text = payload.files[name] else { continue }
                let target = dir.appendingPathComponent(name).standardizedFileURL
                guard target.deletingLastPathComponent().path == dirPath else {
                    result.rejected += 1
                    logger.error("restore: path escapes lyrics dir, refused: \(name, privacy: .public)")
                    continue
                }
                do {
                    try text.write(to: target, atomically: true, encoding: .utf8)
                    if isNew { result.added += 1 } else { result.overwritten += 1 }
                } catch {
                    result.failed += 1
                    logger.error("restore: write failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            if let meta = payload.meta, !meta.isEmpty {
                do {

                    try meta.writeSecurely(to: restoreURL)
                    result.metaBytes = meta.count
                } catch {
                    logger.error("restore: writing enrich-restore file failed — \(error.localizedDescription, privacy: .public)")
                }
            }
            return (result, payload.pins)
        }.value
        guard var result = outcome?.0, let pins = outcome?.1 else { return nil }

        result.pinsAdded = LyricsPinStore.shared.merge(pins)
        logger.notice("restore: +\(result.added) ~\(result.overwritten) !\(result.failed) x\(result.rejected) pins+\(result.pinsAdded) meta=\(result.metaBytes)B")
        return result
    }

    static var autoSnapshotDir: URL {
        LyrimusePaths.configFile("lyrics-backups")
    }

    static let autoSnapshotKeepCount = 3

    struct Snapshot: Identifiable, Hashable {
        var url: URL
        var date: Date
        var bytes: Int
        var id: URL { url }
    }

    static func writeAutoSnapshot(reason: String) async -> URL? {
        guard let data = await buildArchive() else {
            logger.notice("autoSnapshot(\(reason, privacy: .public)): nothing to back up")
            return nil
        }
        let dir = autoSnapshotDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("auto-\(reason)-\(formatter.string(from: Date())).lyrimusebak")
        do {

            try data.writeSecurely(to: url)
        } catch {
            logger.error("autoSnapshot(\(reason, privacy: .public)): write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        logger.notice("autoSnapshot(\(reason, privacy: .public)): wrote \(data.count) bytes to \(url.lastPathComponent, privacy: .public)")
        pruneAutoSnapshots()
        return url
    }

    static func autoSnapshots() -> [Snapshot] {
        let dir = autoSnapshotDir
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return [] }
        return urls
            .filter { $0.pathExtension == "lyrimusebak" }
            .compactMap { url -> Snapshot? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = values.contentModificationDate else { return nil }
                return Snapshot(url: url, date: date, bytes: values.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date }
    }

    private static func pruneAutoSnapshots() {
        let snapshots = autoSnapshots()
        guard snapshots.count > autoSnapshotKeepCount else { return }
        for snapshot in snapshots[autoSnapshotKeepCount...] {
            try? FileManager.default.removeItem(at: snapshot.url)
            logger.notice("autoSnapshot: pruned \(snapshot.url.lastPathComponent, privacy: .public)")
        }
    }

    static func restoreAutoSnapshot(_ snapshot: Snapshot) async -> RestoreResult? {
        guard let data = try? Data(contentsOf: snapshot.url) else {
            logger.error("restoreAutoSnapshot: cannot read \(snapshot.url.lastPathComponent, privacy: .public)")
            return nil
        }
        return await restore(from: data)
    }
}
