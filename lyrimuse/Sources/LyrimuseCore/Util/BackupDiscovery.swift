import Foundation

public enum BackupDiscovery {
    public struct Found: Equatable {

        public let url: URL

        public let folder: URL
        public let modifiedAt: Date

        public init(url: URL, folder: URL, modifiedAt: Date) {
            self.url = url
            self.folder = folder
            self.modifiedAt = modifiedAt
        }
    }

    public static func latest(in folders: [URL]) -> Found? {
        var best: Found?
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants]
            ) else { continue }

            for entry in entries {

                guard let realName = ConfigSnapshotName.realName(
                    ofDirectoryEntry: entry.lastPathComponent) else { continue }
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if best == nil || modified > best!.modifiedAt {
                    best = Found(
                        url: folder.appendingPathComponent(realName),
                        folder: folder,
                        modifiedAt: modified)
                }
            }
        }
        return best
    }
}
