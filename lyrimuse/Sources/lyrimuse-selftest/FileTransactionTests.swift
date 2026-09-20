import Foundation
import LyrimuseCore

@MainActor
func runFileTransactionTests() {
    do {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lyrimuse-file-transaction-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("existing.lrc")
        let deleted = dir.appendingPathComponent("deleted.lrc")
        let added = dir.appendingPathComponent("added.lrc")
        try Data("old".utf8).write(to: existing)
        try Data("keep".utf8).write(to: deleted)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: existing.path)
        let changes: [ReversibleFileChanges.Change] = [
            .init(url: existing, content: Data("new".utf8)),
            .init(url: deleted, content: nil),
            .init(url: added, content: Data("added".utf8))
        ]
        enum CommitError: Error { case failed }
        do {
            try ReversibleFileChanges.apply(changes) {
                expectEqual(try String(contentsOf: existing), "new")
                expectEqual(fm.fileExists(atPath: deleted.path), false)
                throw CommitError.failed
            }
            expectEqual(false, true, "failed commit must throw")
        } catch CommitError.failed {}
        expectEqual(try String(contentsOf: existing), "old")
        expectEqual(try String(contentsOf: deleted), "keep")
        expectEqual(fm.fileExists(atPath: added.path), false)
        expectEqual(try fm.attributesOfItem(atPath: existing.path)[.posixPermissions] as? Int, 0o600)
        expectEqual(try fm.contentsOfDirectory(atPath: dir.path).sorted(), ["deleted.lrc", "existing.lrc"])

        let invalid = dir.appendingPathComponent("directory.lrc")
        try fm.createDirectory(at: invalid, withIntermediateDirectories: true)
        do {
            try ReversibleFileChanges.apply(changes + [.init(url: invalid, content: nil)]) {}
            expectEqual(false, true, "directories must be rejected before any changes")
        } catch {}
        expectEqual(try String(contentsOf: existing), "old")
        expectEqual(try String(contentsOf: deleted), "keep")
        let symbolic = dir.appendingPathComponent("link.lrc")
        try fm.createSymbolicLink(at: symbolic, withDestinationURL: existing)
        do {
            try ReversibleFileChanges.apply([.init(url: symbolic, content: Data("bad".utf8))]) {}
            expectEqual(false, true, "symbolic links must not overwrite their target")
        } catch {}
        expectEqual(try String(contentsOf: existing), "old")

        // Force a failure after the first file changed, without depending on permission behavior as root.
        let parent = dir.appendingPathComponent("vanishing")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let marker = parent.appendingPathComponent("marker")
        try Data("marker".utf8).write(to: marker)
        do {
            try ReversibleFileChanges.apply(changes) {
                // A directory cannot replace the cache file; emulate that commit failure with real I/O.
                try Data("index".utf8).write(to: parent, options: .atomic)
            }
            expectEqual(false, true, "real commit I/O failure must throw")
        } catch {}
        expectEqual(try String(contentsOf: existing), "old")
        expectEqual(try String(contentsOf: deleted), "keep")
        expectEqual(fm.fileExists(atPath: added.path), false)

        let committed = try ReversibleFileChanges.apply(changes) { 42 }
        expectEqual(committed, 42)
        expectEqual(try String(contentsOf: existing), "new")
        expectEqual(fm.fileExists(atPath: deleted.path), false)
        expectEqual(try String(contentsOf: added), "added")
        expectEqual(try fm.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".lyrimuse-backup-") }, false)
    } catch {
        expectEqual(String(describing: error), "no error", "reversible file transaction regression")
    }
}
