import Foundation

public enum CollectorRestartPolicy {

    public static let hotReloadedKeys: Set<String> = []

    public static func needsRestart(changedKeys: Set<String>) -> Bool {
        guard !changedKeys.isEmpty else { return true }
        return true
    }

    public static func changedKeys(from old: [String: Any], to new: [String: Any]) -> Set<String> {
        var changed: Set<String> = []
        for key in Set(old.keys).union(new.keys) {
            let a = old[key] as? NSObject
            let b = new[key] as? NSObject
            if let a, let b, a.isEqual(b) { continue }
            if a == nil, b == nil { continue }
            changed.insert(key)
        }
        return changed
    }
}
