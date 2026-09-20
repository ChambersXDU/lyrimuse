import AppKit
import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "icloud-config")

enum ICloudConfigStore {

    private static var cloudDocsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    static let customFolderKey = "np:backupFolderPath"

    static var customFolderPath: String? {
        let raw = UserDefaults.standard.string(forKey: customFolderKey) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func setCustomFolder(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: customFolderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: customFolderKey)
        }
    }

    static var usingCustomFolder: Bool { customFolderPath != nil }

    static func adoptFolder(_ sourceFolder: URL) {
        let cloudDefault = cloudDocsURL.appendingPathComponent("Lyrimuse").standardizedFileURL
        let source = sourceFolder.standardizedFileURL
        if source == cloudDefault {
            if customFolderPath != nil { setCustomFolder(nil) }
            return
        }
        guard source != folderURL.standardizedFileURL else { return }
        setCustomFolder(source)
    }

    static var folderURL: URL {
        if let path = customFolderPath { return URL(fileURLWithPath: path) }
        return cloudDocsURL.appendingPathComponent("Lyrimuse")
    }

    static var isAvailable: Bool {
        if let path = customFolderPath { return isDirectory(atPath: path) }
        if FileManager.default.fileExists(atPath: cloudDocsURL.path) { return true }

        return !knownCloudFolders().isEmpty
    }

    private static func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    private static func knownCloudFolders() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let subs = try? FileManager.default.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
            roots.append(contentsOf: subs.filter { isDirectory(atPath: $0.path) })
        }
        for legacy in ["Dropbox", "OneDrive"] {
            let url = home.appendingPathComponent(legacy)
            if isDirectory(atPath: url.path) { roots.append(url) }
        }
        return roots
    }

    static func searchFolders() -> [URL] {
        var out: [URL] = [folderURL]
        let cloudDefault = cloudDocsURL.appendingPathComponent("Lyrimuse")
        if !out.contains(cloudDefault) { out.append(cloudDefault) }
        for root in knownCloudFolders() {
            out.append(root.appendingPathComponent("Lyrimuse"))
        }

        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func preparedFolderURL() -> URL {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        ensureFolderIcon(at: folderURL)
        return folderURL
    }

    static func ensureFolderIcon(at folder: URL) {

        let marker = folder.appendingPathComponent("Icon\r")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        guard let icon = NSImage(named: NSImage.applicationIconName) else { return }
        let ok = NSWorkspace.shared.setIcon(icon, forFile: folder.path, options: [])
        logger.info("folder icon applied to \(folder.lastPathComponent, privacy: .public): \(ok, privacy: .public)")
    }

    static func ensureFolderIconIfPresent() {
        guard isAvailable else { return }
        let url = folderURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        ensureFolderIcon(at: url)
    }

    struct Snapshot {

        let url: URL

        let modifiedAt: Date

        let folderURL: URL

        var exportedAt: Date?
        var deviceName: String?
    }

    static func latestSnapshot() -> Snapshot? {
        let folders = searchFolders()
        let hit = BackupDiscovery.latest(in: folders)

        logger.info("""
            snapshot scan: \(folders.count, privacy: .public) folder(s), \
            picked \(hit?.folder.lastPathComponent ?? "none", privacy: .public)
            """)
        let best = hit.map {
            Snapshot(url: $0.url, modifiedAt: $0.modifiedAt, folderURL: $0.folder)
        }
        guard var found = best else { return nil }

        if isMaterialized(found.url), let data = try? Data(contentsOf: found.url) {
            let meta = metadata(in: data)
            found.exportedAt = meta.exportedAt
            found.deviceName = meta.deviceName
        }
        return found
    }

    static func metadata(in data: Data) -> (exportedAt: Date?, deviceName: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let date = (obj["exportedAt"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return (date, obj["deviceName"] as? String)
    }

    static func isMaterialized(_ url: URL) -> Bool {
        var probe = url

        probe.removeCachedResourceValue(forKey: .ubiquitousItemDownloadingStatusKey)
        let status = (try? probe.resourceValues(
            forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        return ICloudFileReadiness.isReadyToRead(
            downloadingStatus: status,
            realPathExists: FileManager.default.fileExists(atPath: url.path))
    }

    static func read(_ url: URL, timeout: TimeInterval = 20) async -> Data? {
        if case .data(let data) = await readOutcome(url, timeout: timeout) { return data }
        return nil
    }

    enum ReadOutcome {
        case data(Data)

        case downloading

        case unavailable
    }

    static func readOutcome(_ url: URL, timeout: TimeInterval = 20) async -> ReadOutcome {
        if isMaterialized(url) {
            guard let data = await loadOffCallerThread(url) else { return .unavailable }
            return .data(data)
        }

        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            logger.notice("read: startDownloading failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if isMaterialized(url) {
                guard let data = await loadOffCallerThread(url) else { return .unavailable }
                return .data(data)
            }
        }
        logger.notice("read: timed out waiting for iCloud download")
        return .downloading
    }

    private static func loadOffCallerThread(_ url: URL) async -> Data? {
        await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
    }

    @discardableResult
    static func write(_ data: Data, filename: String) -> URL? {
        guard isAvailable else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: folderURL, withIntermediateDirectories: true)
            let url = folderURL.appendingPathComponent(filename)

            try data.writeSecurely(to: url)
            return url
        } catch {
            logger.error("write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

}
