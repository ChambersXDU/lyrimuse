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
    case listenBrainz, lastfm, stateRelay, bark
    var id: Self { self }

    var title: String {
        switch self {
        case .listenBrainz: return "ListenBrainz"
        case .lastfm: return "Last.fm"
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
    case .lastfm:
        lastfmBadge(size: size, cornerRadius: cornerRadius)
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

func lastfmBadge(size: CGFloat, cornerRadius: CGFloat? = nil) -> some View {
    Image(nsImage: lastfmBadgeImage)
        .resizable()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.22,
                                    style: .continuous))
}

let lastfmBadgeImage: NSImage = {
    guard let path = Bundle.main.path(forResource: "LastfmIcon", ofType: "png"),
          let image = NSImage(contentsOfFile: path) else {

        return NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil) ?? NSImage()
    }
    return image
}()

@MainActor
func lastfmDisplayName(config: ConfigStore) -> String {
    config.lastfmScrobbleUsername.isEmpty ? config.lastfmUser : config.lastfmScrobbleUsername
}

@MainActor

func destinationStatus(for destination: AccountDestination, config: ConfigStore, lastfmConnect: LastfmConnectController, mirrorInfo: LastfmMirrorStatus.Info?) -> DestinationStatus {
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
    case .lastfm:
        if case .failed(let msg) = lastfmConnect.state { return .error(msg) }

        if config.lastfmScrobbleSessionKey.isEmpty { return .notConfigured(L10n.t("未配置（可选）")) }

        if mirrorInfo != nil { return .error(L10n.t("授权已失效")) }
        let name = lastfmDisplayName(config: config)
        return .active(name.isEmpty ? nil : String(format: L10n.t("已连接：%@"), name))
    case .bark:

        if let hint = config.pushMissingHint() { return .notConfigured(hint) }
        return .active(config.notificationPlatform.displayName)
    }
}

struct AccountSidebarRow: View {
    let destination: AccountDestination

    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var lastfmConnect = LastfmConnectController.shared

    @ObservedObject private var mirrorStatus = LastfmMirrorStatusWatcher.shared

    @ObservedObject private var languageSettings = AppSettings.shared

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(destination.title)
                destinationStatus(for: destination, config: config, lastfmConnect: lastfmConnect,
                                  mirrorInfo: mirrorStatus.info)
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
    @ObservedObject private var lastfmConnect = LastfmConnectController.shared
    @ObservedObject private var backfill = ScrobbleBackfillService.shared

    @ObservedObject private var mirrorStatus = LastfmMirrorStatusWatcher.shared

    @State private var pendingListensExpanded = true

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

    @State private var showLastfmWizard = false

    @State private var showLastfmDisconnectConfirm = false

    @State private var showLastfmApplyHint = false

    var body: some View {

        VStack(spacing: 0) {
            SettingsPageCustomHeader {
                if destination == .lastfm {

                    lastfmProfileCard
                } else {
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

    private func resolvedDigestSource(preference: String) -> String {
        let lastfmOK = config.lastfmBridgeMissingHint() == nil

        let lbOK = config.isListenBrainzReadable
        switch preference {
        case "lastfm": if lastfmOK { return "lastfm" }
        case "listenbrainz": if lbOK { return "listenbrainz" }
        default: break
        }
        if lastfmOK { return "lastfm" }
        if lbOK { return "listenbrainz" }
        return ""
    }

    private func digestCrossCard(source: String) -> (hint: String?, target: AccountDestination) {
        switch source {
        case "lastfm": return (hint: config.lastfmBridgeMissingHint(), target: .lastfm)
        case "listenbrainz": return (hint: config.isListenBrainzReadable ? nil : L10n.t("还缺用户名"), target: .listenBrainz)
        default: return (hint: L10n.t("未配置"), target: .listenBrainz)
        }
    }

    private func digestSourcePicked(_ picked: String, current: String, apply: (String) -> Void) {
        guard picked != current else { return }
        let cross = digestCrossCard(source: picked)
        if let hint = cross.hint {
            missingPrereqAlert = MissingPrereqAlert(
                message: String(format: L10n.t("需要先配置「%@」（%@）"), cross.target.title, hint),
                jumpTarget: cross.target
            )
            return
        }
        apply(picked)
    }

    private var cardIntroText: String? {
        switch destination {
        case .listenBrainz:

            return L10n.t("把你播放的歌同步到 ListenBrainz")
        case .stateRelay:
            return L10n.t("用来把当前播放状态推送到网页小组件和状态徽章")
        case .lastfm:

            return L10n.t("把你播放的歌记录到 Last.fm")
        case .bark:
            return L10n.t("接收 Lyrimuse 的推送通知")
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch destination {
        case .listenBrainz: listenBrainzFields
        case .lastfm: lastfmFields
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

    private enum LastfmSection: String, CaseIterable, Identifiable {
        case stats, chart, onThisDay

        case settings
        var id: Self { self }
        var title: String {
            switch self {
            case .stats: return L10n.t("统计")
            case .chart: return L10n.t("榜单")
            case .onThisDay: return L10n.t("足迹")
            case .settings: return L10n.t("设置")
            }
        }
    }

    @AppStorage("np:lastfmDetailSection") private var lastfmSectionRaw = LastfmSection.stats.rawValue
    private var lastfmSection: LastfmSection { LastfmSection(rawValue: lastfmSectionRaw) ?? .stats }

    private var lastfmSectionPicker: some View {
        Picker(
            "",
            selection: Binding(
                get: { lastfmSection },
                set: { next in lastfmSectionRaw = next.rawValue }
            )
        ) {
            ForEach(LastfmSection.allCases) { s in
                Text(s.title).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.bottom, 2)
    }

    private var lastfmStatsTab: LastfmStatsSection.Tab {
        switch lastfmSection {
        case .stats: return .stats
        case .chart: return .chart
        case .onThisDay: return .onThisDay
        case .settings: return .settings
        }
    }

    @ViewBuilder
    private var pendingListensRow: some View {
        let items = backfill.pending?.items ?? []
        SettingsRawRow(insetToText: true) {

            DisclosureGroup(isExpanded: Binding(
                get: { pendingListensExpanded },
                set: { expanded in
                    withAnimation(.settingsCardReveal) { pendingListensExpanded = expanded }
                }
            )) {

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(items, id: \.uts) { item in
                            PendingListenRow(item: item, busy: backfill.busy) {
                                backfill.deleteListen(uts: item.uts)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxHeight: 180)
            } label: {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Label(
                                String(format: L10n.t("本地已记录 %@ 首待补提交"), "\(items.count)"),
                                systemImage: "tray.full"
                            )
                            .font(.callout)

                            HelpButton(text: L10n.t("Last.fm 只接受约两周内的记录，更早的补不上去"))
                        }
                        if let status = backfillStatusLine() {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)

                    if lastfmConnected {
                        if backfill.busy { ProgressView().controlSize(.small) }
                        Button(L10n.t("补提交")) { backfill.runBackfill() }
                            .disabled(backfill.busy || items.isEmpty)
                    }
                }
            }
        }
    }

    fileprivate static func listenTimeText(_ uts: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(uts)))
    }

    private func backfillStatusLine() -> String? {

        if let result = backfillRunResultText() { return result }
        let tooOld = backfill.pending?.skippedTooOld ?? 0
        guard tooOld > 0 else { return nil }
        return String(format: L10n.t("另有 %@ 条太旧、Last.fm 不再接受"), "\(tooOld)")
    }

    private func backfillRunResultText() -> String? {
        if backfill.lastRunFailed { return L10n.t("补提交没能完成，请稍后再试") }
        guard let last = backfill.lastRun else { return nil }

        var parts = [String(format: L10n.t("已补 %@ 条"), "\(last.accepted)")]
        if last.quarantined > 0 {
            parts.append(String(format: L10n.t("%@ 条状态未知，不会自动重试"), "\(last.quarantined)"))
        }
        if last.ignored > 0 {
            parts.append(String(format: L10n.t("%@ 条被 Last.fm 拒绝"), "\(last.ignored)"))
        }
        if let reason = last.abortedReason, !reason.isEmpty {
            parts.append(String(format: L10n.t("已中断：%@"), reason))
        }
        return parts.joined(separator: "，")
    }

    @ViewBuilder
    private func backfillResultRow(_ text: String) -> some View {
        SettingsRawRow(insetToText: true,
                       icon: backfill.lastRunFailed ? "exclamationmark.triangle" : "checkmark.circle") {
            HStack(spacing: 6) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { backfill.dismissLastRun() } label: {

                    Image(systemName: "xmark").environment(\.locale, Locale(identifier: "en"))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel(L10n.t("关闭"))
            }
        }
    }

    @ViewBuilder
    private var lastfmFields: some View {

        if lastfmConnected {
            lastfmSectionPicker

            LastfmStatsSection(selected: lastfmStatsTab)

            if lastfmSection == .settings {
                lastfmScrobbleSettingsCard
            }
        } else {

            lastfmStatsPlaceholderCard
        }
    }

    @ViewBuilder
    private var lastfmScrobbleSettingsCard: some View {
        SettingsCard {

            SettingsCardHeader(title: L10n.t("Scrobble"))
            CardDivider()
            if features.lastfmMirrorScrobble {
                SettingsRow(
                    icon: "person.2",
                    title: L10n.t("合唱歌曲的歌手"),

                    help: L10n.t("合唱时上送给 Last.fm 的歌手名。\n全部：原样整串。\n只发第一位：另一位不出现在记录里。\n智能：Last.fm 已有这个合唱条目就发整串；没有、但第一位名下有这首歌就只发第一位；两边都没有仍发整串。每首歌只判一次。")
                ) {
                    Picker("", selection: Binding(
                        get: { features.lastfmScrobbleArtistMode },
                        set: { features.lastfmScrobbleArtistMode = $0; Task { await features.save() } }
                    )) {
                        ForEach(LastfmScrobbleArtistMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                CardDivider()

                SettingsRow(
                    icon: "hourglass",
                    title: L10n.t("Scrobble 时机"),
                    help: L10n.t("听到哪里才记到 Last.fm。\n50%：曲长一半、最多 4 分钟（官方规则）。\n75% / 90%：听满对应比例。\n曲终：放到结尾才记，中途切歌不记。\n只影响 Last.fm。")
                ) {
                    Picker("", selection: Binding(
                        get: { features.lastfmScrobblePoint },
                        set: { features.lastfmScrobblePoint = $0; Task { await features.save() } }
                    )) {
                        ForEach(LastfmScrobblePoint.allCases) { point in
                            Text(point.displayName).tag(point)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                CardDivider()

                SettingsRow(
                    icon: "timer",
                    title: L10n.t("短于 30 秒的曲目"),
                    help: L10n.t("开：短于 30 秒的曲目也 scrobble，听过一半就记。\n关：不记（Last.fm 官方规则）。")
                ) {
                    Toggle("", isOn: Binding(
                        get: { features.scrobbleShortTracks },
                        set: { features.scrobbleShortTracks = $0; Task { await features.save() } }
                    ))
                }
                CardDivider()

                PlayerBundleChipsRow(
                    icon: "music.note.list",
                    title: L10n.t("Scrobble 的播放器"),
                    help: L10n.t("只有勾选的播放器放的歌才 scrobble 到 Last.fm，也只有它们更新 Last.fm 的正在播放；默认全部勾选。\n不影响 ListenBrainz、网页和歌词。浏览器里的网页播放器按整个浏览器算。"),
                    choices: lastfmPlayerChoices,
                    excluded: features.lastfmExcludedBundles
                ) { bundleID, on in
                    Task { await features.updateLastfmExclusion(scrobbled: on ? [bundleID] : [], excluded: on ? [] : [bundleID]) }
                }
            } else {
                SettingsNote { Text(L10n.t("上面的「Scrobble 到 Last.fm」关着，这里的设置暂时不起作用")) }
            }
        }
    }

    private var lastfmPlayerChoices: [PlayerBundleChoice] {
        let set = PlayerLinkage.candidates(selectedPlayers: features.players)
        let builtIn = PlaybackPlayer.displayOrder.filter { set.contains($0) }
            .map { PlayerBundleChoice(id: $0.bundleIdentifier, name: $0.displayName, player: $0) }
        let trusted = features.trustedPlayers.keys.sorted()
            .map { PlayerBundleChoice(id: $0, name: lastfmTrustedPlayerName($0), player: nil) }
        return builtIn + trusted
    }

    private func lastfmTrustedPlayerName(_ bundleID: String) -> String {
        if let stored = features.trustedPlayers[bundleID], !stored.isEmpty { return stored }
        return FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID
    }

    private var lastfmProfileCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 14) {
                accountIconBadge(.lastfm, size: 44, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.title)
                        .font(.system(size: 17, weight: .semibold))
                    if lastfmConnected {

                        HStack(spacing: 5) {
                            Text(lastfmDisplayName.isEmpty ? L10n.t("已连接 Last.fm 账号") : lastfmDisplayName)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            lastfmProfileLinkButton
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else if let intro = cardIntroText {
                        Text(intro)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 8) {

                    HStack(spacing: 10) {
                        Text(L10n.t("Scrobble 到 Last.fm"))
                            .font(.system(size: 13))
                        Toggle("", isOn: Binding(
                            get: { lastfmConnected && features.lastfmMirrorScrobble },
                            set: { on in
                                if on {
                                    if lastfmConnected {
                                        features.lastfmMirrorScrobble = true
                                        Task { await features.save() }
                                    } else {

                                        showLastfmWizard = true
                                    }
                                } else {
                                    features.lastfmMirrorScrobble = false
                                    Task { await features.save() }
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    lastfmProfileStatusLine
                }
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, 12)

            if (backfill.pending?.eligible ?? 0) > 0 {
                CardDivider()
                pendingListensRow
            } else if let result = backfillRunResultText() {

                CardDivider()
                backfillResultRow(result)
            }
        }
        .onAppear {
            backfill.refreshPending()

            backfill.dismissLastRun()
        }

        .onChange(of: lastfmConnected) { _, _ in backfill.refreshPending() }

        .onChange(of: features.lastfmMirrorScrobble) { _, _ in backfill.refreshPending() }

        .task {
            var seen = ScrobbleBackfillService.listenLogModifiedAt()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                let now = ScrobbleBackfillService.listenLogModifiedAt()
                guard now != seen, !backfill.busy else { continue }
                seen = now
                backfill.refreshPending()
            }
        }
        .sheet(isPresented: $showLastfmWizard) { lastfmWizardSheet }
        .alert(L10n.t("断开 Last.fm？"), isPresented: $showLastfmDisconnectConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("断开"), role: .destructive) { performLastfmDisconnect() }
        } message: {
            Text(L10n.t("重新连接需要再走一次浏览器授权"))
        }
    }

    @ViewBuilder
    private var lastfmProfileStatusLine: some View {
        HStack(spacing: 8) {
            if lastfmConnected, mirrorStatus.info != nil {
                Label(L10n.t("授权已失效，Scrobble 已暂停"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(L10n.t("Last.fm 拒绝了写入，Scrobble 已暂停——授权可能已在网站上被撤销"))
                Button(L10n.t("重新连接")) { showLastfmWizard = true }
                    .buttonStyle(.link)
            } else if lastfmConnected {
                Label(L10n.t("已连接"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button(L10n.t("断开")) { showLastfmDisconnectConfirm = true }
                    .buttonStyle(.link)
            } else {
                Text(L10n.t("未连接"))
                    .foregroundStyle(.secondary)
                Button(L10n.t("连接账号…")) { showLastfmWizard = true }
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }

    private var lastfmStatsPlaceholderCard: some View {
        SettingsCard {
            Text(L10n.t("连接后这里会展示你的听歌档案"))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
    }

    private var lastfmConnected: Bool { !config.lastfmScrobbleSessionKey.isEmpty }

    private func performLastfmDisconnect() {
        config.lastfmScrobbleSessionKey = ""
        config.lastfmScrobbleUsername = ""
        config.lastfmUser = ""
        LastfmMirrorStatus.clear()
        LastfmStatsService.shared.resetAll()
        features.lastfmMirrorScrobble = false
        Task {
            await config.save()
            await features.save()
        }
    }

    private var lastfmDisplayName: String {
        config.lastfmScrobbleUsername.isEmpty ? config.lastfmUser : config.lastfmScrobbleUsername
    }

    private var lastfmConnectSucceeded: Bool {
        if case .success = lastfmConnect.state { return true }
        return false
    }

    private func trimmedLastfmKeys() -> (key: String, secret: String) {
        let k = config.lastfmScrobbleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = config.lastfmScrobbleSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if k != config.lastfmScrobbleAPIKey { config.lastfmScrobbleAPIKey = k }
        if s != config.lastfmScrobbleSecret { config.lastfmScrobbleSecret = s }
        return (k, s)
    }

    private var lastfmWizardSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("连接 Last.fm")).font(.title3.bold())
                Spacer()
                Button(L10n.t("取消")) {
                    lastfmConnect.reset()
                    showLastfmWizard = false
                }
            }
            HStack {
                Text(L10n.t("下面的「连接」要用这对密钥完成授权：先在 Last.fm 创建一个应用，拿到 API Key 和 Secret"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {

                    Button(L10n.t("前往申请")) {
                        NSWorkspace.shared.open(URL(string: "https://www.last.fm/api/account/create")!)
                        withAnimation { showLastfmApplyHint = true }
                    }
                    .buttonStyle(.link)

                    Button(L10n.t("查看已有应用")) {
                        NSWorkspace.shared.open(URL(string: "https://www.last.fm/api/accounts")!)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(L10n.t("这里能看到已创建应用的 API Key，但看不到 Secret；丢了就用「前往申请」再建一个。"))
                }
            }
            if showLastfmApplyHint {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(L10n.t("申请页基本只需要填「应用名称」，其余留空即可；提交后页面会直接显示 API Key 和 Shared Secret"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L10n.t("拷贝名称")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("Lyrimuse", forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(L10n.t("把「Lyrimuse」拷到剪贴板，粘进申请页的应用名称"))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
            SecretFieldRow("API Key", value: $config.lastfmScrobbleAPIKey)
            SecretFieldRow("Secret", value: $config.lastfmScrobbleSecret)
            Divider()
            lastfmConnectArea
        }
        .padding(20)
        .frame(width: 460)

        .onDisappear { lastfmConnect.reset() }
        .onChange(of: lastfmConnectSucceeded) { _, ok in
            guard ok else { return }

            features.lastfmMirrorScrobble = true
            Task { await features.save() }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                showLastfmWizard = false
                lastfmConnect.reset()
            }
        }
    }

    private var lastfmProfileURL: URL? {
        let trimmed = config.lastfmUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://www.last.fm/user/\(encoded)")
    }

    @ViewBuilder
    private var lastfmProfileLinkButton: some View {
        if let profileURL = lastfmProfileURL {
            Link(destination: profileURL) {
                Image(systemName: "arrow.up.forward.square")
            }
            .help(L10n.t("在 Last.fm 网站查看主页"))
        }
    }

    @ViewBuilder
    private var lastfmConnectArea: some View {
        switch lastfmConnect.state {
        case .idle:
            if config.lastfmScrobbleSessionKey.isEmpty {
                stepDots(current: 0)
                Button(L10n.t("连接 Last.fm 账号")) {
                    let keys = trimmedLastfmKeys()
                    lastfmConnect.start(apiKey: keys.key, secret: keys.secret)
                }
                    .buttonStyle(.borderedProminent)
            } else {
                HStack {
                    Label(
                        config.lastfmScrobbleUsername.isEmpty ? L10n.t("已连接 Last.fm 账号") : String(format: L10n.t("已连接：%@"), config.lastfmScrobbleUsername),
                        systemImage: "checkmark.seal.fill"
                    ).foregroundStyle(.green)
                    Spacer()
                    lastfmProfileLinkButton
                    Button(L10n.t("断开")) {

                        performLastfmDisconnect()
                    }
                    .buttonStyle(.link)
                }
            }
        case .requestingToken:
            stepDots(current: 1)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("正在获取授权令牌…")).font(.caption)
            }
        case .waitingForBrowserAuth:
            stepDots(current: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("已在浏览器打开 Last.fm 授权页面。请在浏览器里点击「Yes, allow access」完成授权，授权完会自动跳回 Lyrimuse 继续；如果浏览器没有自动跳转，也可以回来手动点下面的按钮"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.t("我已完成授权，继续")) { lastfmConnect.confirmBrowserAuth() }
                .buttonStyle(.borderedProminent)
                HStack(spacing: 12) {
                    Button(L10n.t("重新打开授权页面")) { lastfmConnect.reopenBrowserAuth() }
                        .buttonStyle(.link)
                    Button(L10n.t("取消")) { lastfmConnect.reset() }
                        .buttonStyle(.link).foregroundStyle(.secondary)
                }
            }
        case .exchanging:
            stepDots(current: 3)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("正在确认授权，即将完成…")).font(.caption)
            }
        case .success(let username):
            HStack {
                Label(String(format: L10n.t("已连接：%@"), username), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Spacer()
                lastfmProfileLinkButton
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                Button(L10n.t("重试")) { lastfmConnect.reset() }
                    .buttonStyle(.link)
            }
        }
    }

    private func stepDots(current: Int) -> some View {
        HStack(spacing: 4) {
            stepDot(filled: current >= 1, label: L10n.t("① 填写密钥"))
            stepLine(active: current >= 2)
            stepDot(filled: current >= 2, label: L10n.t("② 浏览器授权"))
            stepLine(active: current >= 3)
            stepDot(filled: current >= 3, label: L10n.t("③ 完成连接"))
        }
    }

    private func stepDot(filled: Bool, label: String) -> some View {
        Circle()
            .fill(filled ? Color.accentColor : Color.clear)
            .overlay(Circle().strokeBorder(filled ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1))
            .frame(width: 6, height: 6)
            .accessibilityLabel(label)
    }

    private func stepLine(active: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.accentColor : Color.secondary.opacity(0.3))
            .frame(width: 16, height: 1)
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
                HStack(spacing: 8) {

                    if features.weeklyDigest {
                        Picker("", selection: Binding(
                            get: { resolvedDigestSource(preference: features.weeklyDigestSource) },
                            set: { picked in
                                digestSourcePicked(picked, current: features.weeklyDigestSource) {
                                    features.weeklyDigestSource = $0
                                    Task { await features.save() }
                                }
                            }
                        )) {
                            Text("Last.fm").tag("lastfm")
                            Text("ListenBrainz").tag("listenbrainz")
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    Toggle("", isOn: Binding(
                        get: { features.weeklyDigest },
                        set: { newValue in
                            let source = resolvedDigestSource(preference: features.weeklyDigestSource)
                            toggleGuarded(newValue,
                                sameCardHint: config.pushMissingHint(),
                                crossCard: digestCrossCard(source: source)
                            ) { v in features.weeklyDigest = v; Task { await features.save() } }
                        }
                    ))
                }
            }
            CardDivider()
            SettingsRow(
                icon: "sun.max",
                title: L10n.t("每日听歌报告")
            ) {
                HStack(spacing: 8) {
                    if features.dailyDigest {
                        Picker("", selection: Binding(
                            get: { resolvedDigestSource(preference: features.dailyDigestSource) },
                            set: { picked in
                                digestSourcePicked(picked, current: features.dailyDigestSource) {
                                    features.dailyDigestSource = $0
                                    Task { await features.save() }
                                }
                            }
                        )) {
                            Text("Last.fm").tag("lastfm")
                            Text("ListenBrainz").tag("listenbrainz")
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    Toggle("", isOn: Binding(
                        get: { features.dailyDigest },
                        set: { newValue in
                            let source = resolvedDigestSource(preference: features.dailyDigestSource)
                            toggleGuarded(newValue,
                                sameCardHint: config.pushMissingHint(),
                                crossCard: digestCrossCard(source: source)
                            ) { v in features.dailyDigest = v; Task { await features.save() } }
                        }
                    ))
                }
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

private struct PendingListenRow: View {
    let item: ScrobbleBackfillService.Item
    let busy: Bool
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {

            Text(item.title)
                .font(.caption)
                .lineLimit(1)
                .layoutPriority(2)
            Text(item.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)

            if let album = item.album, !album.isEmpty {
                Text(album)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(AccountLinkingTab.listenTimeText(item.uts))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .opacity(isHovered ? 1 : 0)

            .allowsHitTesting(isHovered && !busy)
            .help(L10n.t("从待补提交清单里移除这条（不可恢复）"))
        }
        .contentShape(Rectangle())
        .onHover { inside in isHovered = inside }
    }
}
