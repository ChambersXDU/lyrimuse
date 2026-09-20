import Foundation

public enum UILanguage {
    public static let traditionalRegions = ["-tw", "-hk", "-mo"]

    public static func resolve(preferred: String) -> String {
        let tag = preferred.lowercased()
        if tag.hasPrefix("en") { return "en" }
        guard tag.hasPrefix("zh") else { return "zh-hans" }
        return isTraditionalChineseTag(tag) ? "zh-hant" : "zh-hans"
    }

    public static func isTraditionalChineseTag(_ tag: String) -> Bool {
        let t = tag.lowercased()
        guard t.hasPrefix("zh") else { return false }
        if t.contains("hans") { return false }
        if t.contains("hant") { return true }
        return traditionalRegions.contains { t.contains($0) }
    }
}
