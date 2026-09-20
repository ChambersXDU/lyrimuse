import Foundation
import LyrimuseCore

enum L10n {

    private static let languageOverrideKey = "np:appLanguage"

    static var current: String {
        let override = UserDefaults.standard.string(forKey: languageOverrideKey) ?? "system"
        if override == "en" || override == "zh-hans" || override == "zh-hant" { return override }
        return resolveSystem(Locale.preferredLanguages.first ?? "zh-hans")
    }

    static func resolveSystem(_ preferred: String) -> String {
        UILanguage.resolve(preferred: preferred)
    }

    static func localeIdentifier(for lang: String) -> String {
        switch lang {
        case "en": return "en"
        case "zh-hant": return "zh-Hant"
        default: return "zh-Hans"
        }
    }

    static var locale: Locale { Locale(identifier: localeIdentifier(for: current)) }

    private static var cached: (lang: String, bundle: Bundle)?

    private static var bundle: Bundle {
        let lang = current
        if let cached, cached.lang == lang { return cached.bundle }
        let resolved: Bundle
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let b = Bundle(path: path) {
            resolved = b
        } else {
            resolved = Bundle.main
        }
        cached = (lang, resolved)
        return resolved
    }

    static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
