import Foundation
import LyrimuseCore
import os
import SwiftUI

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "feature-settings")

public enum LyricsSource: String, CaseIterable, Identifiable, Codable, Hashable {
    case lrclib, kuwo, netease, kugou, qq
    public var id: Self { self }
    public var displayName: String { sourceDisplayName(rawValue) }
    public var color: Color { sourceColor(rawValue) }
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

    var lyricsSources: [String]?

    var lyricsSourceMode: String?
    var lyricsSourceOrder: [String]?
    var lyricsDir: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case lyricsSources = "lyrics_sources"
        case lyricsSourceMode = "lyrics_source_mode"
        case lyricsSourceOrder = "lyrics_source_order"
        case lyricsDir = "lyrics_dir"
    }

    static let knownFileKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))
}

@MainActor
public final class FeatureSettingsStore: ObservableObject {
    public static let shared = FeatureSettingsStore()

    @Published public var lyricsSources: Set<LyricsSource> = Set(LyricsSource.allCases)
    @Published public var lyricsSourceMode: LyricsSourceMode = .smart

    @Published public var lyricsSourceOrder: [LyricsSource] = LyricsSource.allCases

    @Published public var lyricsDir = ""

    @Published public private(set) var lastError: String?

    static let fileURL = LyrimusePaths.configFile("lyrimuse-features.json")

    private var savedSnapshot = FeatureFlagsFile()
    private var currentSnapshot: FeatureFlagsFile {
        FeatureFlagsFile(

            lyricsSources: lyricsSources.map(\.rawValue).sorted(),

            lyricsSourceMode: lyricsSourceMode.rawValue,
            lyricsSourceOrder: lyricsSourceOrder.map(\.rawValue),
            lyricsDir: lyricsDir.isEmpty ? nil : lyricsDir
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

    private func load() {
        document = JSONConfigDocument.load(url: Self.fileURL)
        var decoded: FeatureFlagsFile?
        switch document.state {
        case .missing:
            break
        case .corrupt(let reason):
            logger.error("features.json is unusable, saves refused until it is fixed or discarded: \(reason, privacy: .public)")
        case .loaded:

            do {
                decoded = try JSONDecoder().decode(FeatureFlagsFile.self, from: JSONConfigDocument.serialize(document.raw))
            } catch {
                let reason = "fields do not decode: \(Self.describeDecodingError(error))"
                document.markCorrupt(reason: reason)
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

        let decodedSources = (f.lyricsSources ?? []).compactMap(LyricsSource.init(rawValue:))
        let enabled = decodedSources.isEmpty ? Set(LyricsSource.allCases) : Set(decodedSources)
        lyricsSources = enabled
        lyricsSourceMode = f.lyricsSourceMode.flatMap(LyricsSourceMode.init(rawValue:)) ?? .smart

        let decodedOrder = (f.lyricsSourceOrder ?? []).compactMap(LyricsSource.init(rawValue:))
        lyricsSourceOrder = decodedOrder.count == LyricsSource.allCases.count ? decodedOrder : LyricsSource.allCases
        lyricsDir = f.lyricsDir ?? ""
        savedSnapshot = currentSnapshot
    }

    private func persistFile() throws {

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

    private func commitSnapshot() {
        savedSnapshot = currentSnapshot
    }

    @discardableResult
    public func save() async -> Bool {

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

        lastError = nil
        commitSnapshot()
        return true
    }

}
