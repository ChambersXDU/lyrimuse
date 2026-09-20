import Foundation
import Darwin
import OSLog

public enum ReversibleFileChanges {
    public struct Change: Sendable {
        public let url: URL
        public let content: Data?

        public init(url: URL, content: Data?) {
            self.url = url
            self.content = content
        }
    }

    // The caller must serialize other writers. The commit closure runs only after all
    // file changes succeed; a failed commit restores the original files and metadata.
    public static func apply<T>(_ changes: [Change], commit: () throws -> T) throws -> T {
        let fm = FileManager.default
        var targets = Set<String>()
        var prepared: [(change: Change, existed: Bool, backup: URL?)] = []
        var retainBackups = false
        defer {
            if !retainBackups {
                for item in prepared {
                    guard let backup = item.backup, fm.fileExists(atPath: backup.path) else { continue }
                    do { try fm.removeItem(at: backup) }
                    catch {
                        // Cleanup cannot turn an already committed transaction into a failed save.
                        logger.error("Cannot remove transaction backup \(backup.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
        for change in changes {
            guard change.url.isFileURL, targets.insert(change.url.standardizedFileURL.path).inserted else {
                throw Failure(message: "Invalid or duplicate file target: \(change.url.path)")
            }
            prepared.append((change, try regularFileExists(change.url), nil))
        }
        for i in prepared.indices where prepared[i].existed {
            let backup = prepared[i].change.url.deletingLastPathComponent()
                .appendingPathComponent(".lyrimuse-backup-" + UUID().uuidString)
            prepared[i].backup = backup
            try fm.copyItem(at: prepared[i].change.url, to: backup)
        }
        var applied: [Int] = []
        do {
            for i in prepared.indices {
                let change = prepared[i].change
                let exists = try regularFileExists(change.url)
                applied.append(i)
                if let content = change.content {
                    try fm.createDirectory(at: change.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try content.write(to: change.url, options: .atomic)
                } else if exists {
                    try fm.removeItem(at: change.url)
                }
            }
            return try commit()
        } catch {
            let original = error
            var failures: [String] = []
            for i in applied.reversed() {
                let item = prepared[i]
                do {
                    let exists = try regularFileExists(item.change.url)
                    if let backup = item.backup {
                        guard rename(backup.path, item.change.url.path) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    } else if exists {
                        try fm.removeItem(at: item.change.url)
                    }
                } catch { failures.append("\(item.change.url.path): \(error.localizedDescription)") }
            }
            if !failures.isEmpty {
                retainBackups = true
                let backups = prepared.compactMap(\.backup).filter { fm.fileExists(atPath: $0.path) }.map(\.path)
                throw Failure(message: "\(original.localizedDescription); rollback failed: \(failures.joined(separator: "; ")); backups: \(backups.joined(separator: ", "))")
            }
            throw original
        }
    }

    private static func regularFileExists(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw Failure(message: "Refusing to replace a non-regular file: \(url.path)")
        }
        return true
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "file-transaction")
}
