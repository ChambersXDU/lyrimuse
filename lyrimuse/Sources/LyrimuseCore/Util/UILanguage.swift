import Foundation

public enum UILanguage {
    public static func resolve(preferred: String) -> String {
        let tag = preferred.lowercased()
        if tag.hasPrefix("en") { return "en" }
        return "zh-hans"
    }
}
