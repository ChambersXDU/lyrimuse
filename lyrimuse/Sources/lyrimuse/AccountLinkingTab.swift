import AppKit
import Combine
import LyrimuseCore
import SwiftUI

enum DestinationStatus {
    case disabled

    case notConfigured(String)
    case missingCreds(String)
    case active(String? = nil)
    case error(String)

    var label: some View {

        DestinationStatusLabel(status: self)
            .id(L10n.current)
    }

    var indicator: some View {
        DestinationStatusIndicator(status: self)
    }
}

private struct DestinationStatusLabel: View {
    let status: DestinationStatus
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var dimmed: Bool { backgroundProminence == .increased }

    var body: some View {

        Group {
            switch status {
            case .disabled:
                Label(L10n.t("未启用"), systemImage: "circle").foregroundStyle(.secondary)
            case .notConfigured(let hint):

                Label(hint, systemImage: "circle").foregroundStyle(.secondary)
            case .missingCreds(let hint):
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(dimmed ? Color.primary : Color.orange)
            case .active(let detail):
                Label(detail ?? L10n.t("正在生效"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(dimmed ? Color.primary : Color.green)
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(dimmed ? Color.primary : Color.red)
            }
        }
    }
}

private struct DestinationStatusIndicator: View {
    let status: DestinationStatus
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var dimmed: Bool { backgroundProminence == .increased }

    var body: some View {
        switch status {
        case .disabled:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .notConfigured:

            EmptyView()
        case .missingCreds:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(dimmed ? Color.primary : Color.orange)
        case .active:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(dimmed ? Color.primary : Color.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(dimmed ? Color.primary : Color.red)
        }
    }
}

private struct SecretFieldRow: View {
    let label: String
    @Binding var value: String
    var prompt: String? = nil

    @State private var isEditing: Bool

    init(_ label: String, value: Binding<String>, prompt: String? = nil) {
        self.label = label
        self._value = value
        self.prompt = prompt
        self._isEditing = State(initialValue: value.wrappedValue.isEmpty)
    }

    var body: some View {
        if isEditing {
            HStack {
                SecureField(label, text: $value, prompt: prompt.map(Text.init))
                if !value.isEmpty {
                    Button(L10n.t("完成")) { isEditing = false }
                        .buttonStyle(.link)
                }
            }
        } else {
            HStack {
                Text(label)
                Spacer()
                Label(L10n.t("已设置"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                Button(L10n.t("更改")) { isEditing = true }
                    .buttonStyle(.link)
            }
        }
    }
}

enum AccountDestination: Hashable, CaseIterable, Identifiable {
    case listenBrainz, stateRelay, bark
    var id: Self { self }

    var title: String {
        switch self {
        case .listenBrainz: return "ListenBrainz"
        case .stateRelay: return L10n.t("网页推送")
        case .bark: return L10n.t("推送提醒")
        }
    }

}

@ViewBuilder
func accountIconBadge(_ destination: AccountDestination, size: CGFloat = 20, cornerRadius: CGFloat = 5) -> some View {
    switch destination {
    case .listenBrainz:
        Image(nsImage: listenBrainzBadgeImage)
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    case .stateRelay:
        iconBadge("dot.radiowaves.left.and.right", tint: .blue, size: size, cornerRadius: cornerRadius)
    case .bark:
        iconBadge("bell.badge.fill", tint: .red, size: size, cornerRadius: cornerRadius)
    }
}

private let listenBrainzBadgeImage: NSImage = {
    guard let path = Bundle.main.path(forResource: "ListenBrainzIcon", ofType: "png"),
          let image = NSImage(contentsOfFile: path) else {

        return NSImage(
            systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil) ?? NSImage()
    }
    return image
}()

@MainActor
func destinationStatus(for destination: AccountDestination, config: ConfigStore) -> DestinationStatus {
    switch destination {
    case .listenBrainz:

        if config.isListenBrainzReadable {
            return .active(String(format: L10n.t("已连接为 @%@"), config.listenbrainzUser))
        }

        if config.isListenBrainzConfigured {
            return .missingCreds(L10n.t("还缺用户名，听歌报告用不了"))
        }
        return .notConfigured(L10n.t("未配置（可选）"))
    case .stateRelay:

        if config.isStateRelayUntouched { return .notConfigured(L10n.t("未配置（可选）")) }
        if let hint = config.stateRelayMissingHint() { return .missingCreds(hint) }
        return .active()
    case .bark:

        if let hint = config.pushMissingHint() { return .notConfigured(hint) }
        return .active(config.notificationPlatform.displayName)
    }
}

struct AccountSidebarRow: View {
    let destination: AccountDestination

    @ObservedObject private var config = ConfigStore.shared

    @ObservedObject private var languageSettings = AppSettings.shared

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(destination.title)
                destinationStatus(for: destination, config: config)
                    .indicator
            }
        } icon: {
            accountIconBadge(destination)
        }
        .padding(.vertical, 2)
    }
}

struct AccountLinkingTab: View {
    let destination: AccountDestination

    var onJumpToAccount: (AccountDestination) -> Void = { _ in }

    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var features = FeatureSettingsStore.shared

    @ObservedObject private var languageSettings = AppSettings.shared

    @State private var isSaving = false
    @State private var lastSavedAt: Date?

    private struct MissingPrereqAlert: Identifiable {
        let id = UUID()
        let message: String
        let jumpTarget: AccountDestination?
    }
    @State private var missingPrereqAlert: MissingPrereqAlert?
    @StateObject private var tokenCheck = ListenBrainzTokenCheck()

    var body: some View {

        VStack(spacing: 0) {
            SettingsPageCustomHeader {
                VStack(spacing: 6) {
                    accountIconBadge(destination, size: 52, cornerRadius: 12)
                        .padding(.bottom, 2)
                    Text(destination.title)
                        .font(.system(size: 22, weight: .bold))
                    if let intro = cardIntroText {
                        Text(intro)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } content: {
                fields
            }
            Divider()
            autosaveStatusBar
        }

        .onReceive(config.objectWillChange.debounce(for: .milliseconds(1200), scheduler: DispatchQueue.main)) {
            Task { await performAutoSave() }
        }

        .onDisappear {
            if config.isDirty {
                Task { await performAutoSave() }
            }
        }
        .alert(
            L10n.t("还差一步"),
            isPresented: Binding(
                get: { missingPrereqAlert != nil },
                set: { if !$0 { missingPrereqAlert = nil } }
            ),
            presenting: missingPrereqAlert
        ) { alert in
            if let target = alert.jumpTarget {
                Button(String(format: L10n.t("去配置「%@」"), target.title)) { onJumpToAccount(target) }
                Button(L10n.t("取消"), role: .cancel) {}
            } else {
                Button(L10n.t("好的"), role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
        }

        .id(L10n.current)
    }

    private func toggleGuarded(
        _ newValue: Bool,
        sameCardHint: String?,
        crossCard: (hint: String?, target: AccountDestination)? = nil,
        apply: (Bool) -> Void
    ) {
        guard newValue else { apply(false); return }
        if let sameCardHint {
            missingPrereqAlert = MissingPrereqAlert(message: String(format: L10n.t("请先在这张卡上填好：%@"), sameCardHint), jumpTarget: nil)
            return
        }
        if let crossCard, let hint = crossCard.hint {
            missingPrereqAlert = MissingPrereqAlert(message: String(format: L10n.t("需要先配置「%@」（%@）"), crossCard.target.title, hint), jumpTarget: crossCard.target)
            return
        }
        apply(true)
    }

    private var cardIntroText: String? {
        switch destination {
        case .listenBrainz:

            return L10n.t("把你播放的歌同步到 ListenBrainz")
        case .stateRelay:
            return L10n.t("用来把当前播放状态推送到网页小组件和状态徽章")
        case .bark:
            return L10n.t("接收 Lyrimuse 的推送通知")
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch destination {
        case .listenBrainz: listenBrainzFields
        case .stateRelay: stateRelayFields
        case .bark: barkFields
        }
    }

    private func checkListenBrainzToken() {
        tokenCheck.tokenChanged(config.listenbrainzToken, knownUser: config.listenbrainzUser) { user in

            if config.listenbrainzUser != user { config.listenbrainzUser = user }
        }
    }

    @ViewBuilder
    private var listenBrainzTokenStatus: some View {
        switch tokenCheck.state {
        case .empty:
            EmptyView()
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(L10n.t("正在验证…")).foregroundStyle(.secondary)
            }
        case .valid(let user):
            Label(String(format: L10n.t("已连接：%@"), user), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid:
            Label(L10n.t("Token 无效，请重新复制一次"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .unreachable:

            Label(L10n.t("连不上 ListenBrainz，稍后会自动重试"), systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        }
    }

    private var listenBrainzFields: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("账户信息"))
            CardDivider()
            SettingsRawRow(insetToText: true, icon: "key.fill") {
                VStack(alignment: .leading, spacing: 8) {
                    SecretFieldRow(L10n.t("账户 Token"), value: $config.listenbrainzToken)
                    HStack(spacing: 8) {
                        listenBrainzTokenStatus
                        Spacer(minLength: 0)
                        Link(
                            L10n.t("获取 Token →"),
                            destination: URL(string: "https://listenbrainz.org/settings/")!)
                    }
                    .font(.caption)
                }
            }
            .onAppear { checkListenBrainzToken() }
            .onChange(of: config.listenbrainzToken) { _, _ in checkListenBrainzToken() }
        }
    }

    @ViewBuilder
    private var stateRelayFields: some View {
        SettingsCard {
            SettingsCardHeader(
                title: L10n.t("连接信息"),
                help: L10n.t("要先把网页端部署好并拿到访问令牌。部署步骤见项目 README 的「网页端」一节：https://github.com/Yudaotor/lyrimuse#网页端")
            )
            CardDivider()
            SettingsRawRow(insetToText: true) {
                VStack(alignment: .leading, spacing: 8) {
            TextField(text: $config.stateRelayURL, prompt: Text(L10n.t("例如 https://yourdomain.com/api/state"))) {
                HStack(spacing: 4) {
                    Text(L10n.t("同步服务地址"))
                    HelpButton(
                        text: L10n.t("自己用 Cloudflare Worker + KV 搭建的 state-worker 服务（独立公开仓库 Yudaotor/nowplaying-workers）。不想自建也行：配好「ListenBrainz」也能让网页兜底显示「正在播放」，两者配一个就够。效果截图 + 完整从零搭建步骤见该仓库自己的 README"),
                        docTitle: L10n.t("查看效果 + 教程 →"),

                        docURL: URL(string: "https://github.com/Yudaotor/nowplaying-workers#readme")!
                    )
                }
            }
            SecretFieldRow(L10n.t("访问令牌"), value: $config.stateRelayToken)
                }
            }
        }
    }

    @ViewBuilder
    private var barkFields: some View {
        SettingsCard {

            SettingsRawRow {
                HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: SettingsRowMetrics.iconWidth)
                    Text(L10n.t("通知平台"))
                        .font(.system(size: 13))
                    HelpButton(
                        text: config.notificationPlatform.setupGuide,
                        docTitle: L10n.t("查看官方文档 →"),
                        docURL: config.notificationPlatform.setupDocURL
                    )
                    Spacer(minLength: 12)
                    Picker("", selection: $config.notificationPlatform) {
                        ForEach(NotificationPlatform.allCases) { platform in
                            Text(platform.displayName).tag(platform)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            CardDivider()
            SettingsRawRow(insetToText: true) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        L10n.t("Webhook 地址"), text: $config.notificationWebhookURL,
                        prompt: Text(config.notificationPlatform.urlPlaceholder)
                    )
                    if config.notificationPlatform == .dingtalk {
                        SecretFieldRow(L10n.t("加签密钥（可选）"), value: $config.dingtalkSignSecret)
                        Text(L10n.t("机器人安全设置选了「加签」才需要填，留空按未加签处理"))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if config.notificationPlatform == .feishu {
                        SecretFieldRow(L10n.t("签名密钥（可选）"), value: $config.feishuSignSecret)
                        Text(L10n.t("机器人安全设置开了「签名校验」才需要填，不开也能收到消息"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }

        SettingsCard {
            SettingsCardHeader(
                title: L10n.t("提醒")
            )
            CardDivider()

            SettingsRow(
                icon: "calendar",
                title: L10n.t("每周听歌小结"),
            ) {
                Toggle("", isOn: Binding(
                        get: { features.weeklyDigest },
                        set: { newValue in
                            let sourceHint = config.isListenBrainzReadable ? nil : L10n.t("还缺用户名")
                            toggleGuarded(newValue,
                                sameCardHint: config.pushMissingHint(),
                                crossCard: (hint: sourceHint, target: .listenBrainz)
                            ) { v in
                                features.weeklyDigest = v
                                features.weeklyDigestSource = "listenbrainz"
                                Task { await features.save() }
                            }
                        }
                    ))
            }
            CardDivider()
            SettingsRow(
                icon: "sun.max",
                title: L10n.t("每日听歌报告")
            ) {
                Toggle("", isOn: Binding(
                        get: { features.dailyDigest },
                        set: { newValue in
                            let sourceHint = config.isListenBrainzReadable ? nil : L10n.t("还缺用户名")
                            toggleGuarded(newValue,
                                sameCardHint: config.pushMissingHint(),
                                crossCard: (hint: sourceHint, target: .listenBrainz)
                            ) { v in
                                features.dailyDigest = v
                                features.dailyDigestSource = "listenbrainz"
                                Task { await features.save() }
                            }
                        }
                    ))
            }
        }
    }

    private var autosaveStatusBar: some View {
        HStack(spacing: 8) {
            if isSaving {
                ProgressView().controlSize(.small)
                Text(L10n.t("正在自动保存…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                saveStatusText
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var saveStatusText: some View {
        if let error = config.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        } else if let lastSavedAt {
            Text(String(format: L10n.t("上次保存：%@ · 采集器已重启"), lastSavedAt.formatted(date: .omitted, time: .shortened)))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func performAutoSave() async {
        guard config.isDirty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        if await config.save() {
            lastSavedAt = Date()
        }
    }
}
