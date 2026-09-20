import Foundation

public enum ConfigSnapshotName {
    public static let prefix = "Lyrimuse-Config-"
    public static let suffix = ".json"

    public static func realName(ofDirectoryEntry entryName: String) -> String? {
        var name = entryName
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            name = String(name.dropFirst().dropLast(".icloud".count))
        }
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }

        guard name.count > prefix.count + suffix.count else { return nil }
        return name
    }
}
