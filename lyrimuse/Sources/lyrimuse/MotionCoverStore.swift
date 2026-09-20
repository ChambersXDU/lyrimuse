import CryptoKit
import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "motion-cover")

@MainActor
final class MotionCoverStore {
    static let shared = MotionCoverStore()

    static let targetPixelWidth = 920

    private static let diskBudgetBytes: Int64 = 400 << 20

    private let fm = FileManager.default

    private var inflight: [String: Task<URL?, Never>] = [:]

    private var failed: Set<String> = []

    private var directory: URL { LyrimusePaths.configFile("motion-covers") }

    func cachedFile(master: URL) -> URL? {
        let url = fileURL(for: master)
        guard fm.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    func prepare(master: URL) async -> URL? {
        if let hit = cachedFile(master: master) { return hit }
        let key = cacheKey(for: master)
        if failed.contains(key) { return nil }
        if let running = inflight[key] { return await running.value }

        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            let result = await self.download(master: master)
            await MainActor.run {
                self.inflight[key] = nil
                if result == nil { self.failed.insert(key) }
            }
            return result
        }
        inflight[key] = task
        return await task.value
    }

    private nonisolated func download(master: URL) async -> URL? {
        do {

            let masterText = try await text(from: master)
            let variants = MotionCoverManifest.parseVariants(master: masterText)
            guard let picked = MotionCoverManifest.pick(variants, minimumWidth: Self.targetPixelWidth),
                  let variantURL = MotionCoverManifest.absolute(picked.uri, relativeTo: master) else {
                logger.info("motion cover: no usable variant in master playlist")
                return nil
            }

            let variantText = try await text(from: variantURL)
            guard let name = MotionCoverManifest.mediaFileName(fromVariant: variantText),
                  let mediaURL = MotionCoverManifest.absolute(name, relativeTo: variantURL) else {
                logger.info("motion cover: variant has no EXT-X-MAP single file")
                return nil
            }

            let (data, response) = try await URLSession.shared.data(from: mediaURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.info("motion cover: media http \(http.statusCode, privacy: .public)")
                return nil
            }
            guard Self.looksLikeMP4(data) else {
                logger.info("motion cover: payload is not an mp4 (\(data.count, privacy: .public) bytes)")
                return nil
            }
            return try await MainActor.run { try self.store(data, master: master, width: picked.width) }
        } catch {
            logger.info("motion cover: fetch failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated func text(from url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CocoaError(.fileReadUnknown)
        }
        guard let s = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return s
    }

    private func store(_ data: Data, master: URL, width: Int) throws -> URL {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let final = fileURL(for: master)
        let tmp = final.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: final.path) { try? fm.removeItem(at: final) }
        try fm.moveItem(at: tmp, to: final)
        logger.info("motion cover: stored \(width, privacy: .public)px \(data.count / 1024, privacy: .public)KB")
        pruneIfNeeded()
        return final
    }

    private func fileURL(for master: URL) -> URL {
        directory.appendingPathComponent("\(cacheKey(for: master)).mp4")
    }

    private func cacheKey(for master: URL) -> String {
        let seed = "\(master.absoluteString)|w\(Self.targetPixelWidth)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private nonisolated static func looksLikeMP4(_ data: Data) -> Bool {
        guard data.count > 64 * 1024 else { return false }
        return data[4..<8].elementsEqual([0x66, 0x74, 0x79, 0x70])
    }

    private func touch(_ url: URL) {
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func pruneIfNeeded() {
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in items where url.pathExtension == "mp4" {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = v.fileSize, let date = v.contentModificationDate else { continue }
            files.append((url, Int64(size), date))
            total += Int64(size)
        }
        guard total > Self.diskBudgetBytes else { return }
        for f in files.sorted(by: { $0.date < $1.date }) {
            guard total > Self.diskBudgetBytes else { break }
            try? fm.removeItem(at: f.url)
            total -= f.size
            logger.info("motion cover: pruned \(f.size / 1024, privacy: .public)KB")
        }
    }
}
