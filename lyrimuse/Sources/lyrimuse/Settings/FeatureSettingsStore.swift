import Foundation
import LyrimuseCore
import os
import SwiftUI

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "feature-settings")

public enum LyricsSource: String, CaseIterable, Identifiable, Codable, Hashable {
    case kugou, netease, qq, musixmatch, lrclib, amll, lyricfind, kuwo, migu, deezer
    public var id: Self { self }
    public var displayName: String { sourceDisplayName(rawValue) }
    public var color: Color { sourceColor(rawValue) }
}

public enum MusixmatchTranslationLanguage: String, CaseIterable, Identifiable, Codable {
    case auto
    case en, zh, ja, ko, es, fr, de, pt, it, ru, ar, vi, th, id, nl, pl, tr

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .auto: return L10n.t("跟随系统语言")
        case .en: return "English"
        case .zh: return "简体中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .pt: return "Português"
        case .it: return "Italiano"
        case .ru: return "Русский"
        case .ar: return "العربية"
        case .vi: return "Tiếng Việt"
        case .th: return "ไทย"
        case .id: return "Bahasa Indonesia"
        case .nl: return "Nederlands"
        case .pl: return "Polski"
        case .tr: return "Türkçe"
        }
    }
}

public enum LyricsSourceMode: String, CaseIterable, Identifiable, Codable {
    case smart, priority
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .smart: return L10n.t("智能算法")
        case .priority: return L10n.t("顺序优先")
        }
    }
}

struct FeatureFlagsFile: Codable, Equatable {

    var albumPrefetch: Bool?

    var lyricsAutoUpgrade: Bool?
    var lyricsSources: [String]?

    var amllLyrics: Bool?

    var lyricFindLyrics: Bool?

    var kuwoLyrics: Bool?

    var miguLyrics: Bool?

    var deezerLyrics: Bool?
    var lyricsSourceMode: String?
    var lyricsSourceOrder: [String]?
    var lyricsDir: String?

    var lyricsTranslationLanguage: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case albumPrefetch = "album_prefetch"
        case lyricsAutoUpgrade = "lyrics_auto_upgrade"
        case lyricsSources = "lyrics_sources"
        case amllLyrics = "amll_lyrics"
        case lyricFindLyrics = "lyricfind_lyrics"
        case kuwoLyrics = "kuwo_lyrics"
        case miguLyrics = "migu_lyrics"
        case deezerLyrics = "deezer_lyrics"
        case lyricsSourceMode = "lyrics_source_mode"
        case lyricsSourceOrder = "lyrics_source_order"
        case lyricsDir = "lyrics_dir"
        case lyricsTranslationLanguage = "lyrics_translation_language"
    }

    static let knownFileKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))
}

@MainActor
public final class FeatureSettingsStore: ObservableObject {
    public static let shared = FeatureSettingsStore()

    @Published public var albumPrefetch = true

    @Published public var lyricsAutoUpgrade = true

    @Published public var lyricsSources: Set<LyricsSource> = Set(LyricsSource.allCases)
    @Published public var lyricsSourceMode: LyricsSourceMode = .smart

    @Published public var lyricsSourceOrder: [LyricsSource] = LyricsSource.allCases

    @Published public var lyricsDir = ""

    @Published public var lyricsTranslationLanguage: MusixmatchTranslationLanguage = .auto

    @Published public private(set) var lastError: String?

    @Published public private(set) var pendingUntilServiceEnabled = false

    @Published public private(set) var loadFailure: String?

    static let fileURL = LyrimusePaths.configFile("lyrimuse-features.json")

    private var savedSnapshot = FeatureFlagsFile()
    private var currentSnapshot: FeatureFlagsFile {
        FeatureFlagsFile(

            albumPrefetch: albumPrefetch,
            lyricsAutoUpgrade: lyricsAutoUpgrade,
            lyricsSources: lyricsSources.map(\.rawValue).sorted(),

            amllLyrics: lyricsSources.contains(.amll),

            lyricFindLyrics: lyricsSources.contains(.lyricfind),

            kuwoLyrics: lyricsSources.contains(.kuwo),

            miguLyrics: lyricsSources.contains(.migu),

            deezerLyrics: lyricsSources.contains(.deezer),
            lyricsSourceMode: lyricsSourceMode.rawValue,
            lyricsSourceOrder: lyricsSourceOrder.map(\.rawValue),
            lyricsDir: lyricsDir.isEmpty ? nil : lyricsDir,
            lyricsTranslationLanguage: lyricsTranslationLanguage.rawValue
        )
    }

    public var effectiveLyricsDir: URL {
        if !lyricsDir.isEmpty {
            return URL(fileURLWithPath: lyricsDir)
        }
        return LyrimusePaths.configFile("lyrics")
    }
    public var isDirty: Bool { currentSnapshot != savedSnapshot }

    private init() {
        load()
    }

    private var document = JSONConfigDocument(url: FeatureSettingsStore.fileURL)

    public var fileState: JSONConfigDocument.LoadState { document.state }

    public func load() {
        document = JSONConfigDocument.load(url: Self.fileURL)
        loadFailure = nil
        var decoded: FeatureFlagsFile?
        switch document.state {
        case .missing:
            break
        case .corrupt(let reason):
            loadFailure = reason
            logger.error("features.json is unusable, saves refused until it is fixed or discarded: \(reason, privacy: .public)")
        case .loaded:

            do {
                decoded = try JSONDecoder().decode(FeatureFlagsFile.self, from: JSONConfigDocument.serialize(document.raw))
            } catch {
                let reason = "fields do not decode: \(Self.describeDecodingError(error))"
                document.markCorrupt(reason: reason)
                loadFailure = reason
                logger.error("features.json fields do not decode, saves refused: \(reason, privacy: .public)")
            }
        }
        guard let f = decoded else {

            savedSnapshot = currentSnapshot
            return
        }

        let unknownCount = document.raw.keys.filter { !FeatureFlagsFile.knownFileKeys.contains($0) }.count
        if unknownCount > 0 {
            logger.notice("features.json carries \(unknownCount) key(s) this build doesn't know; they will be preserved on write")
        }

        albumPrefetch = f.albumPrefetch ?? true
        lyricsAutoUpgrade = f.lyricsAutoUpgrade ?? true
        let decodedSources = (f.lyricsSources ?? []).compactMap(LyricsSource.init(rawValue:))
        var enabled = Set(decodedSources)
        if enabled.isEmpty {
            enabled = Set(LyricsSource.allCases)
        } else {

            if f.amllLyrics == nil {

                enabled.insert(.amll)
            }
            if f.lyricFindLyrics == nil {

                enabled.insert(.lyricfind)
            }
            if f.kuwoLyrics == nil {

                enabled.insert(.kuwo)
            }
            if f.miguLyrics == nil {

                enabled.insert(.migu)
            }
            if f.deezerLyrics == nil {

                enabled.insert(.deezer)
            }
        }
        lyricsSources = enabled
        lyricsSourceMode = f.lyricsSourceMode.flatMap(LyricsSourceMode.init(rawValue:)) ?? .smart

        let decodedOrder = (f.lyricsSourceOrder ?? []).compactMap(LyricsSource.init(rawValue:))
        lyricsSourceOrder = decodedOrder.count == LyricsSource.allCases.count ? decodedOrder : LyricsSource.allCases
        lyricsDir = f.lyricsDir ?? ""
        lyricsTranslationLanguage = f.lyricsTranslationLanguage.flatMap(MusixmatchTranslationLanguage.init(rawValue:)) ?? .auto
        savedSnapshot = currentSnapshot
    }

    public func persistFile() throws {

        let encoded = try JSONEncoder().encode(currentSnapshot)
        guard let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw ConfigFileSaveError.notSerializable
        }
        do {

            try document.save(fields: fields, knownKeys: FeatureFlagsFile.knownFileKeys, secure: false)
        } catch JSONConfigDocument.Failure.refusedCorruptFile {
            throw ConfigFileSaveError.refusedCorruptFile
        } catch JSONConfigDocument.Failure.notSerializable {
            throw ConfigFileSaveError.notSerializable
        }
    }

    @discardableResult
    public func discardCorruptFileAndSave() async -> Bool {
        do {
            if let moved = try document.quarantineCorruptFile() {
                logger.notice("corrupt features.json moved aside as \(moved.lastPathComponent, privacy: .public)")
            }
        } catch {
            lastError = String(format: L10n.t("无法移走损坏的配置文件: %@"), error.localizedDescription)
            logger.error("quarantine failed: \(String(describing: error), privacy: .public)")
            return false
        }
        loadFailure = nil
        return await save()
    }

    private static func describeDecodingError(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: error) }
        let context: DecodingError.Context
        switch decoding {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            context = c
        @unknown default:
            return String(describing: error)
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }

    public func commitSnapshot() {
        savedSnapshot = currentSnapshot
    }

    public func clearApplyStatus() {
        lastError = nil
        pendingUntilServiceEnabled = false
    }

    private var changedFileKeysSinceLastSave: Set<String> {
        func fields(_ snapshot: FeatureFlagsFile) -> [String: Any] {
            guard let data = try? JSONEncoder().encode(snapshot),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return dict
        }
        return CollectorRestartPolicy.changedKeys(from: fields(savedSnapshot), to: fields(currentSnapshot))
    }

    @discardableResult
    public func save() async -> Bool {

        let changedKeys = changedFileKeysSinceLastSave
        do {
            try persistFile()
        } catch ConfigFileSaveError.refusedCorruptFile {

            lastError = ConfigFileSaveError.refusedCorruptFile.errorDescription
            logger.notice("save refused: features.json on disk is corrupt")
            return false
        } catch {
            lastError = String(format: L10n.t("写入功能开关文件失败: %@"), error.localizedDescription)
            logger.error("write failed: \(String(describing: error), privacy: .public)")
            return false
        }

        if !CollectorRestartPolicy.needsRestart(changedKeys: changedKeys) {
            logger.notice("collector restart skipped: only hot-reloaded keys changed (\(changedKeys.sorted().joined(separator: ","), privacy: .public))")
            lastError = nil
            pendingUntilServiceEnabled = false
            commitSnapshot()
            return true
        }

        if await CollectorRestartCoordinator.shared.requestRestart() {
            lastError = nil
            pendingUntilServiceEnabled = false
            commitSnapshot()
            return true
        }
        if !AppSettings.shared.collectorServiceEnabled {

            logger.notice("collector restart skipped: service disabled by the user; change applies on next start")
            lastError = nil
            pendingUntilServiceEnabled = true
            commitSnapshot()
            return true
        }

        lastError = L10n.t("已保存，但后台采集服务重启失败，改动要等下次重启才生效")
        return false
    }

}
