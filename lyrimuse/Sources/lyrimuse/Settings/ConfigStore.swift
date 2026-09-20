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

    public var setupGuide: String {
        switch self {
        case .bark:
            return L10n.t("在 iPhone 上安装 Bark App，首页显示的就是你的专属推送地址，复制粘贴过来即可，不需要额外设置")
        case .dingtalk:
            return L10n.t("在钉钉群里：群设置 → 智能群助手 → 添加机器人 → 自定义，创建后复制 Webhook 地址。安全设置建议选「加签」，把生成的密钥填进下面的「加签密钥」")
        case .wecom:
            return L10n.t("在企业微信群里：群设置 → 群机器人 → 添加机器人，创建后复制 Webhook 地址，不需要额外的签名设置")
        case .discord:
            return L10n.t("服务器设置 → 整合(Integrations) → Webhook → 新建 Webhook，选好要发到的频道后复制 Webhook URL")
        case .feishu:
            return L10n.t("在飞书群里：设置 → 群机器人 → 添加机器人 → 自定义机器人，创建后复制 Webhook 地址。想加一层校验可以开启「签名校验」，把密钥填进下面的「签名密钥」")
        case .serverchan:
            return L10n.t("打开 sct.ftqq.com，用微信扫码登录，首页会显示你的 SendKey，完整地址是 https://sctapi.ftqq.com/你的SendKey.send，把这一整串填进上面")
        }
    }

    public var setupDocURL: URL {
        switch self {
        case .bark: return URL(string: "https://bark.day.app/")!
        case .dingtalk: return URL(string: "https://open.dingtalk.com/document/group/custom-robot-access")!
        case .wecom: return URL(string: "https://developer.work.weixin.qq.com/document/path/91770")!
        case .discord: return URL(string: "https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks")!
        case .feishu: return URL(string: "https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot?lang=zh-CN")!
        case .serverchan: return URL(string: "https://sct.ftqq.com/")!
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
    @Published public var lastfmUser = ""

    @Published public var lastfmAPIKey = ""
    @Published public var lastfmScrobbleAPIKey = ""
    @Published public var lastfmScrobbleSecret = ""
    @Published public var lastfmScrobbleSessionKey = ""

    @Published public var lastfmScrobbleUsername = ""
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
        var lastfmUser, lastfmAPIKey: String
        var lastfmScrobbleAPIKey, lastfmScrobbleSecret, lastfmScrobbleSessionKey, lastfmScrobbleUsername: String
        var notificationPlatform: NotificationPlatform
        var notificationWebhookURL: String
        var dingtalkSignSecret: String
        var feishuSignSecret: String
    }
    private var savedSnapshot = Snapshot(
        listenbrainzToken: "", listenbrainzUser: "", stateRelayURL: "", stateRelayToken: "",
        lastfmUser: "", lastfmAPIKey: "", lastfmScrobbleAPIKey: "", lastfmScrobbleSecret: "",
        lastfmScrobbleSessionKey: "", lastfmScrobbleUsername: "",
        notificationPlatform: .bark, notificationWebhookURL: "", dingtalkSignSecret: "", feishuSignSecret: ""
    )
    private var currentSnapshot: Snapshot {
        Snapshot(
            listenbrainzToken: listenbrainzToken, listenbrainzUser: listenbrainzUser,
            stateRelayURL: stateRelayURL, stateRelayToken: stateRelayToken,
            lastfmUser: lastfmUser, lastfmAPIKey: lastfmAPIKey,
            lastfmScrobbleAPIKey: lastfmScrobbleAPIKey, lastfmScrobbleSecret: lastfmScrobbleSecret,
            lastfmScrobbleSessionKey: lastfmScrobbleSessionKey, lastfmScrobbleUsername: lastfmScrobbleUsername,
            notificationPlatform: notificationPlatform, notificationWebhookURL: notificationWebhookURL,
            dingtalkSignSecret: dingtalkSignSecret, feishuSignSecret: feishuSignSecret
        )
    }
    public var isDirty: Bool { currentSnapshot != savedSnapshot }

    public var secretsForRedaction: [String: String] {
        [
            "listenbrainzToken": listenbrainzToken,
            "stateRelayToken": stateRelayToken,
            "lastfmAPIKey": lastfmAPIKey,
            "lastfmScrobbleAPIKey": lastfmScrobbleAPIKey,
            "lastfmScrobbleSecret": lastfmScrobbleSecret,
            "lastfmScrobbleSessionKey": lastfmScrobbleSessionKey,
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

    public func lastfmBridgeMissingHint() -> String? {

        if savedSnapshot.lastfmUser.isEmpty
            || (savedSnapshot.lastfmScrobbleAPIKey.isEmpty && savedSnapshot.lastfmAPIKey.isEmpty) {
            return L10n.t("还没连接 Last.fm 账号")
        }
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
        lastfmUser = raw["lastfm_user"] as? String ?? ""
        lastfmAPIKey = raw["lastfm_api_key"] as? String ?? ""
        lastfmScrobbleAPIKey = raw["lastfm_scrobble_api_key"] as? String ?? ""
        lastfmScrobbleSecret = raw["lastfm_scrobble_secret"] as? String ?? ""
        lastfmScrobbleSessionKey = raw["lastfm_scrobble_session_key"] as? String ?? ""
        lastfmScrobbleUsername = raw["lastfm_scrobble_username"] as? String ?? ""

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
            "lastfm_user": lastfmUser,
            "lastfm_api_key": lastfmAPIKey,
            "lastfm_scrobble_api_key": lastfmScrobbleAPIKey,
            "lastfm_scrobble_secret": lastfmScrobbleSecret,
            "lastfm_scrobble_session_key": lastfmScrobbleSessionKey,
            "lastfm_scrobble_username": lastfmScrobbleUsername,
            "notification_platform": notificationPlatform.rawValue,
            "bark_url": notificationWebhookURL,
            "dingtalk_sign_secret": dingtalkSignSecret,
            "feishu_sign_secret": feishuSignSecret,
        ]
        do {

            try document.save(fields: fields, secure: true)
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
