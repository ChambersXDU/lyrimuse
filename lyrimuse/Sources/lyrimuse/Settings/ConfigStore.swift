import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "config-store")

public enum NotificationPlatform: String, CaseIterable, Identifiable, Codable {
    case bark, dingtalk, wecom, discord, feishu, serverchan
    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .bark: return "Bark"
        case .dingtalk: return L10n.t("钉钉")
        case .wecom: return L10n.t("企业微信")
        case .discord: return "Discord"
        case .feishu: return L10n.t("飞书")
        case .serverchan: return L10n.t("Server酱")
        }
    }

    public var urlPlaceholder: String {
        switch self {
        case .bark: return L10n.t("https://api.day.app/你的Key")
        case .dingtalk: return "https://oapi.dingtalk.com/robot/send?access_token=..."
        case .wecom: return "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=..."
        case .discord: return "https://discord.com/api/webhooks/..."
        case .feishu: return "https://open.feishu.cn/open-apis/bot/v2/hook/..."
        case .serverchan: return L10n.t("https://sctapi.ftqq.com/你的SendKey.send")
        }
    }

}

@MainActor
public final class ConfigStore: ObservableObject {
    public static let shared = ConfigStore()

    @Published public var listenbrainzToken = ""
    @Published public var listenbrainzUser = ""
    @Published public var stateRelayURL = ""
    @Published public var stateRelayToken = ""
    @Published public var notificationPlatform: NotificationPlatform = .bark
    @Published public var notificationWebhookURL = ""

    @Published public var dingtalkSignSecret = ""
    @Published public var feishuSignSecret = ""

    @Published public private(set) var lastError: String?

    @Published public private(set) var pendingUntilServiceEnabled = false

    @Published public private(set) var loadFailure: String?

    static let fileURL = LyrimusePaths.configFile("config.json")

    private var document = JSONConfigDocument(url: ConfigStore.fileURL)

    public var fileState: JSONConfigDocument.LoadState { document.state }

    private struct Snapshot: Equatable {
        var listenbrainzToken, listenbrainzUser: String
        var stateRelayURL, stateRelayToken: String
        var notificationPlatform: NotificationPlatform
        var notificationWebhookURL: String
        var dingtalkSignSecret: String
        var feishuSignSecret: String
    }
    private var savedSnapshot = Snapshot(
        listenbrainzToken: "", listenbrainzUser: "", stateRelayURL: "", stateRelayToken: "",
        notificationPlatform: .bark, notificationWebhookURL: "", dingtalkSignSecret: "", feishuSignSecret: ""
    )
    private var currentSnapshot: Snapshot {
        Snapshot(
            listenbrainzToken: listenbrainzToken, listenbrainzUser: listenbrainzUser,
            stateRelayURL: stateRelayURL, stateRelayToken: stateRelayToken,
            notificationPlatform: notificationPlatform, notificationWebhookURL: notificationWebhookURL,
            dingtalkSignSecret: dingtalkSignSecret, feishuSignSecret: feishuSignSecret
        )
    }
    public var isDirty: Bool { currentSnapshot != savedSnapshot }

    public var secretsForRedaction: [String: String] {
        [
            "listenbrainzToken": listenbrainzToken,
            "stateRelayToken": stateRelayToken,
            "notificationWebhookURL": notificationWebhookURL,
            "dingtalkSignSecret": dingtalkSignSecret,
            "feishuSignSecret": feishuSignSecret,
        ].filter { !$0.value.isEmpty }
    }

    public var isListenBrainzConfigured: Bool { !savedSnapshot.listenbrainzToken.isEmpty }

    public var isListenBrainzReadable: Bool {
        !savedSnapshot.listenbrainzToken.isEmpty && !savedSnapshot.listenbrainzUser.isEmpty
    }

    public var isStateRelayUntouched: Bool {
        savedSnapshot.stateRelayURL.isEmpty && savedSnapshot.stateRelayToken.isEmpty
    }

    public func stateRelayMissingHint() -> String? {
        if savedSnapshot.stateRelayURL.isEmpty { return L10n.t("还没填服务地址（可选）") }
        if savedSnapshot.stateRelayToken.isEmpty { return L10n.t("还没填访问令牌（可选）") }
        return nil
    }

    public func pushMissingHint() -> String? {
        savedSnapshot.notificationWebhookURL.isEmpty ? L10n.t("还没填 webhook 地址") : nil
    }

    private init() {
        load()
    }

    public func load() {
        document = JSONConfigDocument.load(url: Self.fileURL)
        switch document.state {
        case .loaded, .missing:

            loadFailure = nil
        case .corrupt(let reason):

            loadFailure = reason
            logger.error("config.json is unusable, saves refused until it is fixed or discarded: \(reason, privacy: .public)")
        }
        let raw = document.raw
        listenbrainzToken = raw["listenbrainz_token"] as? String ?? ""
        listenbrainzUser = raw["listenbrainz_user"] as? String ?? ""
        stateRelayURL = raw["state_relay_url"] as? String ?? ""
        stateRelayToken = raw["state_relay_token"] as? String ?? ""

        notificationPlatform = (raw["notification_platform"] as? String).flatMap(NotificationPlatform.init) ?? .bark

        notificationWebhookURL = raw["bark_url"] as? String ?? ""
        dingtalkSignSecret = raw["dingtalk_sign_secret"] as? String ?? ""
        feishuSignSecret = raw["feishu_sign_secret"] as? String ?? ""
        savedSnapshot = currentSnapshot
    }

    public func persistFile() throws {
        let fields: [String: Any] = [
            "listenbrainz_token": listenbrainzToken,
            "listenbrainz_user": listenbrainzUser,
            "state_relay_url": stateRelayURL,
            "state_relay_token": stateRelayToken,
            "notification_platform": notificationPlatform.rawValue,
            "bark_url": notificationWebhookURL,
            "dingtalk_sign_secret": dingtalkSignSecret,
            "feishu_sign_secret": feishuSignSecret,
        ]
        do {

            let knownKeys = Set(fields.keys).union([
                "lastfm_user", "lastfm_api_key", "lastfm_scrobble_api_key",
                "lastfm_scrobble_secret", "lastfm_scrobble_session_key", "lastfm_scrobble_username",
            ])
            try document.save(fields: fields, knownKeys: knownKeys, secure: true)
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
                logger.notice("corrupt config.json moved aside as \(moved.lastPathComponent, privacy: .public)")
            }
        } catch {
            lastError = String(format: L10n.t("无法移走损坏的配置文件: %@"), error.localizedDescription)
            logger.error("quarantine failed: \(String(describing: error), privacy: .public)")
            return false
        }
        loadFailure = nil
        return await save()
    }

    public func commitSnapshot() {
        savedSnapshot = currentSnapshot
    }

    public func clearApplyStatus() {
        lastError = nil
        pendingUntilServiceEnabled = false
    }

    @discardableResult
    public func save() async -> Bool {
        do {
            try persistFile()
        } catch ConfigFileSaveError.refusedCorruptFile {

            lastError = ConfigFileSaveError.refusedCorruptFile.errorDescription
            logger.notice("save refused: config.json on disk is corrupt")
            return false
        } catch {
            lastError = String(format: L10n.t("写入 config.json 失败: %@"), error.localizedDescription)
            logger.error("write failed: \(String(describing: error), privacy: .public)")
            return false
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

public enum ConfigFileSaveError: LocalizedError {

    case refusedCorruptFile

    case notSerializable

    public var errorDescription: String? {
        switch self {
        case .refusedCorruptFile: return L10n.t("配置文件无法解析，为避免覆盖已放弃保存")
        case .notSerializable: return L10n.t("内部数据不是合法 JSON,已放弃保存")
        }
    }
}
