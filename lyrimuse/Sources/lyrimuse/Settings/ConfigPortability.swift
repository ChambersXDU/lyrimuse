import Foundation
import AppKit
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "config-portability")

enum ConfigFileSaveError: LocalizedError {
    case refusedCorruptFile
    case notSerializable

    var errorDescription: String? {
        switch self {
        case .refusedCorruptFile: return L10n.t("配置文件无法解析，为避免覆盖已放弃保存")
        case .notSerializable: return L10n.t("内部数据不是合法 JSON，已放弃保存")
        }
    }
}

enum ConfigPortability {
    private static let configDir = LyrimusePaths.configDir

    static var configFolderURL: URL { configDir }
    private static let configURL = configDir.appendingPathComponent("config.json")
    private static let featuresURL = configDir.appendingPathComponent("lyrimuse-features.json")

    private static let machineLocalDefaultsKeys: Set<String> = [
        "np:hasShownOverlayDragHint",
        "np:hasShownMenuBarPositionHint",

        "np:overlayPositionTop",
        "np:overlayPositionOrigin",
        "np:launchAtLoginEnabled",

    ]

    static let obsoleteDefaultsKeys: Set<String> = [

        "np:launchMusicOnLyrimuseOpen",
        "np:dataSourceMode",
        "np:textShadowColorHex",
        "np:textShadowEnabled",
        "np:useSystemTranslationFallback",

        "np:hideWhenFullscreenApp",

        "np:preferWordLevelKaraoke",

        "np:overlayStyle",
        "np:notchScreenID",
        "np:receiveBetaUpdates",
        "np:lyricsWindowFrame",
        "np:lyricsWindowScreenID",
        "np:notchLyricsKaraoke",
        "np:notchContentWidth",
        "np:notchExpandedContentWidth",
        "np:notchHideDuringScreenCapture",
        "np:notchHideWhenNotPlaying",
        "np:notchOverlayEnabled",
        "np:notchCardStyle",
        "np:notchShowLyrics",
        "np:notchCollapsesWhenPaused",
        "np:notchShowsEqualizer",
        "np:notchEqualizerEar",
        "np:notchExpandedShowsNextLine",
        "np:notchExpandedShowsControls",
        "np:notchExpandedShowsLyricsOffset",
        "np:notchExpandedShowsArtwork",
        "np:notchExpandedShowsTrackTitle",
        "np:notchExpandedShowsArtist",
        "np:notchExpandedShowsAlbum",
        "np:notchExpandedShowsQuickActions",
        "np:notchLyricRowShowsArtwork",
        "np:notchLyricRowArtworkPosition",
        "np:notchLyricsAlignment",
        "np:notchSecondaryLine",
        "np:notchFontFamilyName",
        "np:notchFontWeight",
        "np:notchFontSize",
        "np:notchLeftEar",
        "np:notchRightEar",
        "np:notchAllScreens",
        "np:notchOverlayVisible",
        "np:notchVolumeBanner",
        "np:notchShowEqualizer",
    ]

    private static let excludedDefaultsKeys: Set<String> =
        machineLocalDefaultsKeys.union(obsoleteDefaultsKeys)

    static func pruneObsoleteDefaults() {
        let defaults = UserDefaults.standard
        for key in obsoleteDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            logger.notice("pruned obsolete default key \(key, privacy: .public)")
        }
    }

    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Lyrimuse-Config-\(formatter.string(from: Date())).json"
    }

    static let exportFormatVersion = 1

    static func exportableAppSettings() -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            guard key.hasPrefix("np:") || key.hasPrefix("KeyboardShortcuts_") else { continue }
            guard !excludedDefaultsKeys.contains(key) else { continue }
            out[key] = value
        }
        return out
    }

    static func applyAppSettings(_ appSettings: [String: Any]) -> Int {
        var applied = 0
        for (key, value) in appSettings {
            guard !excludedDefaultsKeys.contains(key) else { continue }
            UserDefaults.standard.set(value, forKey: key)
            applied += 1
        }
        return applied
    }

    static func buildExportData() -> Data? {
        var bundle: [String: Any] = [
            "version": exportFormatVersion,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),

            "deviceName": Host.current().localizedName ?? "",
        ]

        if let configData = try? Data(contentsOf: configURL),
           let configObj = try? JSONSerialization.jsonObject(with: configData) {
            bundle["config"] = configObj
        } else {

            logger.notice("buildExportData: no config.json found/parseable at \(configURL.path, privacy: .public)")
        }
        if let featuresData = try? Data(contentsOf: featuresURL),
           let featuresObj = try? JSONSerialization.jsonObject(with: featuresData) {
            bundle["features"] = featuresObj
        } else {
            logger.notice("buildExportData: no features.json found/parseable at \(featuresURL.path, privacy: .public)")
        }

        bundle["appSettings"] = exportableAppSettings()

        return try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
    }

    @discardableResult
    static func importData(_ data: Data) async -> Bool {
        guard let bundle = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("importData: top-level JSON parse failed — not a valid export file")
            return false
        }

        let bundleVersion = bundle["version"] as? Int ?? 0
        if bundleVersion > exportFormatVersion {
            logger.warning("importData: bundle format v\(bundleVersion) is newer than this build's v\(exportFormatVersion) — fields this version doesn't know will be ignored")
        } else if bundleVersion == 0 {
            logger.notice("importData: bundle has no usable 'version' field")
        }

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        } catch {
            logger.error("importData: createDirectory(\(configDir.path, privacy: .public)) failed — \(String(describing: error), privacy: .public)")
        }

        if let configObj = bundle["config"] {
            if let configData = try? JSONSerialization.data(withJSONObject: configObj, options: [.prettyPrinted]) {
                do {

                    try configData.writeSecurely(to: configURL)
                } catch {
                    logger.error("importData: writing config.json failed — \(String(describing: error), privacy: .public)")
                }
            } else {
                logger.error("importData: re-serializing 'config' from the import bundle failed")
            }
        } else {
            logger.notice("importData: import bundle has no 'config' section")
        }
        if let featuresObj = bundle["features"] {
            if let featuresData = try? JSONSerialization.data(withJSONObject: featuresObj, options: [.prettyPrinted]) {
                do {
                    try featuresData.write(to: featuresURL, options: .atomic)
                } catch {
                    logger.error("importData: writing features.json failed — \(String(describing: error), privacy: .public)")
                }
            } else {
                logger.error("importData: re-serializing 'features' from the import bundle failed")
            }
        } else {
            logger.notice("importData: import bundle has no 'features' section")
        }
        if let appSettings = bundle["appSettings"] as? [String: Any] {
            let applied = applyAppSettings(appSettings)
            logger.info("importData: applied \(applied) of \(appSettings.count) appSettings keys")

            AppSettingsMirror.write()
        } else {
            logger.notice("importData: import bundle has no 'appSettings' section")
        }

        return true
    }

    @discardableResult
    static func clearAllConfig() async -> Bool {
        var ok = true
        if FileManager.default.fileExists(atPath: configURL.path) {
            do { try FileManager.default.removeItem(at: configURL) }
            catch {
                logger.error("clearAllConfig: removing config.json failed — \(String(describing: error), privacy: .public)")
                ok = false
            }
        }
        if FileManager.default.fileExists(atPath: featuresURL.path) {
            do { try FileManager.default.removeItem(at: featuresURL) }
            catch {
                logger.error("clearAllConfig: removing features.json failed — \(String(describing: error), privacy: .public)")
                ok = false
            }
        }
        var clearedCount = 0
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            guard key.hasPrefix("np:") || key.hasPrefix("KeyboardShortcuts_") else { continue }
            UserDefaults.standard.removeObject(forKey: key)
            clearedCount += 1
        }

        AppSettingsMirror.remove()

        await LyricsPinStore.shared.removeAll()
        logger.info("clearAllConfig: cleared \(clearedCount) UserDefaults keys, filesRemovedOK=\(ok)")

        return ok
    }

    @MainActor
    static func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }

        AppExit.request(.restartAfterConfigChange)
    }
}
