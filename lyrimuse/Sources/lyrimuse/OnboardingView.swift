import AppKit
import Combine
import LyrimuseCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var step = 0
    @State private var automationStatus: MusicAutomationPermissionStatus = .notDetermined

    @State private var isRequestingAutomation = false

    @State private var automationRequestTimedOut = false

    @State private var collectorRunning = false
    @State private var isTogglingCollectorService = false

    @State private var isPlayingNow = false

    @State private var furthestStep = 0

    @State private var collectorFailure: String?

    @State private var browserPickerError: String?

    @State private var confettiBurst = 0

    private enum Step: Equatable {
        case welcome, playerChoice, automation, browserPairing, background,
             displayMode, lyricsExtras, lastfm, done
    }

    @State private var wantsBrowserYouTubeMusic = false

    private static let youTubeMusicPlatformID = "youtubeMusic"

    private var needsAppleMusicAutomation: Bool {
        features.players.contains(.appleMusic) || features.players.contains(.auto)
    }

    private var steps: [Step] {
        var s: [Step] = [.welcome, .playerChoice]
        if needsAppleMusicAutomation {
            s.append(.automation)
        }

        if wantsBrowserYouTubeMusic {
            s.append(.browserPairing)
        }

        s.append(contentsOf: [.background, .displayMode, .lyricsExtras, .lastfm, .done])
        return s
    }

    private var currentStep: Step {
        let list = steps
        return list[min(max(step, 0), list.count - 1)]
    }

    private var isLastStep: Bool { step >= steps.count - 1 }

    private var nextIsLocked: Bool { currentStep == .background && !collectorRunning }

    var body: some View {
        VStack(spacing: 0) {

            ScrollView(.vertical) {
                Group {
                    switch currentStep {
                    case .welcome: welcomeStep
                    case .playerChoice: playerChoiceStep
                    case .automation: automationStep
                    case .browserPairing: browserPairingStep
                    case .background: backgroundStep
                    case .displayMode: displayModeStep
                    case .lyricsExtras: lyricsExtrasStep
                    case .lastfm: lastfmStep
                    case .done: doneStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(28)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                stepDots
                Spacer()

                if nextIsLocked {
                    Button(L10n.t("暂时跳过")) { goTo(step + 1) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                if step > 0 {
                    Button(L10n.t("上一步")) { goTo(step - 1) }
                }
                Button(isLastStep ? L10n.t("开始使用") : L10n.t("下一步")) {
                    if isLastStep {
                        finish()
                    } else {
                        goTo(step + 1)
                    }
                }
                .keyboardShortcut(.defaultAction)

                .disabled(nextIsLocked)
            }
            .padding(16)
        }
        .frame(width: 480, height: 420)

        .overlay { ConfettiOverlay(burst: confettiBurst) }

        .navigationTitle(L10n.t("欢迎使用 Lyrimuse"))

        .onChange(of: steps.count) { _, newCount in
            if step > newCount - 1 { step = newCount - 1 }
            if furthestStep > newCount - 1 { furthestStep = newCount - 1 }
        }

        .onChange(of: step) { _, _ in
            guard currentStep == .done || currentStep == .background else { return }
            automationStatus = MusicAutomationPermission.check(askIfNeeded: false)
            collectorRunning = CollectorServiceManager.isRunning
        }

        .onChange(of: currentStep) { _, new in
            if new == .done { confettiBurst += 1 }
        }
        .onAppear {
            automationStatus = MusicAutomationPermission.check(askIfNeeded: false)
            collectorRunning = CollectorServiceManager.isRunning

            wantsBrowserYouTubeMusic = BrowserPairing
                .hasAnyPair(platformID: Self.youTubeMusicPlatformID)
        }

        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let latest = MusicAutomationPermission.check(askIfNeeded: false)
            automationStatus = latest
            if latest != .notDetermined {
                isRequestingAutomation = false
                automationRequestTimedOut = false
            }
        }
        .onReceive(PlaybackCoordinator.shared.$isPlayingNow.removeDuplicates()) { playing in
            isPlayingNow = playing
        }

        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }
        .onDisappear { AuxiliaryWindowActivation.windowDidDisappear() }
    }

    private var stepDots: some View {
        HStack(spacing: 8) {

            HStack(spacing: 0) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                        .onTapGesture { if i <= furthestStep { goTo(i) } }
                }
            }
            Text("\(step + 1) / \(steps.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: L10n.t("第 %1$d 步，共 %2$d 步"), step + 1, steps.count))
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text(L10n.t("欢迎使用 Lyrimuse"))
                .font(.title.bold())
            Text(L10n.t("一个贴心的桌面悬浮歌词小工具。接下来用几步简单设置，帮你把它调整成合适的样子——这些选项以后随时可以在设置里再调整"))
                .foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                Text(L10n.t("界面语言"))
                Spacer(minLength: 12)
                Picker(L10n.t("界面语言"), selection: $settings.appLanguage) {
                    Text(L10n.t("跟随系统")).tag("system")
                    Text(L10n.t("简体中文")).tag("zh-hans")
                    Text(L10n.t("繁體中文")).tag("zh-hant")
                    Text("English").tag("en")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            HStack(spacing: 4) {
                Text(L10n.t("继续即表示你已了解"))
                    .foregroundStyle(.secondary)
                Button(L10n.t("版权说明")) { LegalNotices.openUsageNotice() }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    private var playerChoiceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("选择播放器"))
                .font(.title2.bold())

            Text(L10n.t("Lyrimuse 支持 Apple Music、QQ 音乐、网易云音乐、酷狗音乐、Spotify，浏览器里的 YouTube Music 也可以，还可以交给「自动识别」——平时用哪些就都勾上，随时可以在设置里改"))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {

                ForEach(PlaybackPlayer.displayOrder.filter { $0 != .auto }) { player in

                    PlayerChoiceCard(player: player,
                                     isSelected: features.players.contains(player),
                                     isCoveredByAuto: features.players.contains(.auto)
                                         && !features.players.contains(player)) {
                        features.togglePlayer(player)
                    }
                }

                WebPlatformChoiceCard(
                    icon: WebPlatformIcon.image(Self.youTubeMusicPlatformID),
                    title: "YouTube Music",
                    isSelected: wantsBrowserYouTubeMusic
                ) {
                    toggleYouTubeMusic()
                }

                ForEach(PlaybackPlayer.displayOrder.filter { $0 == .auto }) { player in
                    PlayerChoiceCard(player: player, isSelected: features.players.contains(player)) {
                        features.togglePlayer(player)
                    }
                }
                MorePlayersComingCard()
            }
        }
    }

    private func toggleYouTubeMusic() {
        wantsBrowserYouTubeMusic.toggle()

    }

    private var browserPairingStep: some View {
        let platformID = Self.youTubeMusicPlatformID

        let candidates = BrowserPairing.candidateBrowsers(platformID: platformID)
        return VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("YouTube Music 用哪个浏览器？"))
                .font(.title2.bold())
            Text(L10n.t("YouTube Music 是在浏览器里播的，Lyrimuse 需要知道是哪一个才能读到播放进度。选你平时用来听歌的（可以多选）——之后系统会问你要不要授权，同意就行；随时可以在设置的「网页播放器」里再改"))
                .foregroundStyle(.secondary)
            if candidates.isEmpty {

                Text(L10n.t("这台电脑上没有找到默认列出的浏览器（Safari、Chrome、Edge）。别的浏览器可以用下面的「从应用程序中选择…」自己挑一个"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(candidates, id: \.self) { bundleID in
                        browserCard(bundleID: bundleID, platformID: platformID)
                    }
                }

            }

            Button(L10n.t("从应用程序中选择…")) {
                browserPickerError = BrowserPairing.chooseFromApplications(platformID: platformID)
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .alert(
            L10n.t("这个应用用不了"),
            isPresented: Binding(
                get: { browserPickerError != nil },
                set: { if !$0 { browserPickerError = nil } })
        ) {
            Button(L10n.t("知道了"), role: .cancel) { browserPickerError = nil }
        } message: {
            Text(browserPickerError ?? "")
        }
    }

    private func browserCard(bundleID: String, platformID: String) -> some View {

        let isPaired = BrowserPairing.isPaired(bundleID, platformID: platformID)
        return WebPlatformChoiceCard(
            icon: AppIconResolver.icon(forBundleID: bundleID),
            title: FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID,
            isSelected: isPaired
        ) {
            if isPaired {

                BrowserPairing.unpair(bundleID, platformID: platformID)
            } else {
                BrowserPairing.trustAndPair(bundleID, platformID: platformID)
            }
        }
    }

    private var automationStep: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text(L10n.t("Apple Music 自动化权限（推荐）"))
                .font(.title2.bold())
            Text(L10n.t("这个权限用来把 Apple Music 的播放进度校得更准，以及让你直接在歌词上控制播放（播放/暂停、切歌、拖进度、喜欢、加资料库）。没有它歌词照样能显示——基本的播放信息由后台服务读取——只是进度会有偏差、那些按钮按不动。点下面的按钮会弹出系统授权对话框，选择「允许」即可；随时可以在设置里重新打开这一步"))
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: automationStatusIconName)
                    .foregroundStyle(automationStatusIconColor)
                Text(automationStatusCaption)
                Spacer()
                if isRequestingAutomation {
                    ProgressView().controlSize(.small)
                } else {
                    Button(automationActionTitle) { handleAutomationAction() }
                }
            }
            if isRequestingAutomation {
                if automationRequestTimedOut {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("这次请求耗时有点久。如果你已经看到系统弹窗，请去处理它；找不到弹窗的话，可以直接去系统设置里手动开启"))
                        Button(L10n.t("打开系统设置")) {
                            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(L10n.t("请查看屏幕上弹出的系统授权对话框，选择「允许」"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var backgroundStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("让它一直待命"))
                .font(.title2.bold())
            Text(L10n.t("Lyrimuse 需要一个后台程序常驻运行，负责读取播放状态、解析歌词/封面并写入本地缓存——没有它，悬浮歌词/灵动岛无法显示任何内容"))
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: collectorRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(collectorRunning ? .green : .red)
                Text(collectorRunning
                     ? L10n.t("后台采集服务：运行中")
                     : L10n.t("后台采集服务：未运行（必需）"))
                Spacer()
                if isTogglingCollectorService {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.t("启用")) { enableCollectorService() }
                        .disabled(collectorRunning)
                }
            }

            if let collectorFailure {
                Text(collectorFailure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            toggleRow(
                icon: "power",
                title: L10n.t("开机时自动启动 Lyrimuse"),
                subtitle: L10n.t("菜单栏图标开机就在，不用每次自己打开"),
                isOn: $settings.launchAtLoginEnabled)
        }
    }

    private var lyricsExtrasStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("译文与罗马音"))
                .font(.title2.bold())
            Text(L10n.t("听不懂的语言可以并排显示中文译文；日文、韩文、粤语还能标上罗马音跟着唱"))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(
                    icon: "text.bubble",
                    title: L10n.t("显示译文"),
                    subtitle: L10n.t("歌词下面并排显示一行译文"),
                    isOn: $settings.showTranslation)
                toggleRow(
                    icon: "textformat.alt",
                    title: L10n.t("显示罗马音"),
                    subtitle: L10n.t("日文、韩文、中文拼音、粤拼默认都会注音，可以在设置里单独关掉"),
                    isOn: $settings.showRomanization)
            }
            Text(L10n.t("这两项只在「桌面悬浮歌词」和「歌词窗口」里显示——灵动岛受限于胶囊空间放不下，菜单栏歌词只能显示一行纯文字"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayModeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("歌词显示在哪里"))
                .font(.title2.bold())
            Text(L10n.t("这几种可以同时开着，先挑你现在想用的——之后随时能在设置里单独开关"))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                displayModeRow(
                    kind: .classic,
                    title: L10n.t("桌面悬浮歌词"),
                    subtitle: L10n.t("贴在桌面上"),
                    isOn: Binding(
                        get: { settings.classicOverlayEnabled },
                        set: { LyricsOverlayWindowController.shared.setVisible($0) }))
                displayModeRow(
                    kind: .notch,
                    title: L10n.t("灵动岛歌词"),
                    subtitle: hasNotchedScreen
                        ? L10n.t("紧凑地贴着屏幕顶部的刘海")
                        : L10n.t("这台 Mac 没有刘海，会显示在屏幕顶部正中"),
                    isOn: Binding(
                        get: { settings.notchOverlayEnabled },
                        set: { NotchLyricsWindowController.shared.setVisible($0) }))
                displayModeRow(
                    kind: .menuBar,
                    title: L10n.t("菜单栏歌词"),
                    subtitle: L10n.t("菜单栏里的一行字"),
                    isOn: $settings.showLyricsInMenuBar)
            }

            if noDisplayModeEnabled {
                displayModeNote(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: L10n.t("三种方式都关掉了，播放时屏幕上不会出现歌词——菜单栏图标一直都在，随时可以从那里重新打开"))
            } else if !isPlayingNow {
                displayModeNote(
                    icon: "info.circle.fill",
                    tint: .secondary,
                    text: L10n.t("现在没有在播放——桌面悬浮歌词会立刻出现，灵动岛和菜单栏歌词要等开始播放才看得到"))
            }
        }
    }

    private func displayModeRow(
        kind: DisplayModeThumbnail.Kind,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            DisplayModeThumbnail(kind: kind)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func toggleRow(
        icon: String, title: String, subtitle: String, isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)

                .environment(\.locale, Locale(identifier: "en"))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func displayModeNote(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)

                .environment(\.locale, Locale(identifier: "en"))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var hasNotchedScreen: Bool { ScreenIdentity.notched != nil }

    private var noDisplayModeEnabled: Bool {
        !settings.classicOverlayEnabled
            && !settings.notchOverlayEnabled
            && !settings.showLyricsInMenuBar
    }

    private var lastfmStep: some View {
        VStack(alignment: .leading, spacing: 16) {

            lastfmBadge(size: 44)
            Text(L10n.t("同步收听到 Last.fm（可选）"))
                .font(.title.bold())
            Text(L10n.t("连上之后，你播放的每一首歌都会自动 scrobble 到 Last.fm，还能在这里看到你专属的听歌档案"))
                .foregroundStyle(.secondary)
            Button(L10n.t("现在去设置里连接")) {
                AppActions.shared.requestSettings(.account(.lastfm))
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
    }

    private struct ReadinessItem: Identifiable {
        let id: String
        let ok: Bool
        let title: String
        let target: Step
    }

    private var readinessItems: [ReadinessItem] {
        var items: [ReadinessItem] = [
            ReadinessItem(id: "collector", ok: collectorRunning,
                          title: L10n.t("常驻后台服务"), target: .background)
        ]
        if needsAppleMusicAutomation {
            items.append(ReadinessItem(
                id: "automation", ok: automationStatus == .authorized,
                title: L10n.t("Apple Music 自动化权限"), target: .automation))
        }
        if wantsBrowserYouTubeMusic {
            items.append(ReadinessItem(
                id: "browser",
                ok: BrowserPairing.hasAnyPair(platformID: Self.youTubeMusicPlatformID),
                title: L10n.t("YouTube Music 的浏览器"), target: .browserPairing))
        }
        items.append(ReadinessItem(
            id: "display", ok: !noDisplayModeEnabled,
            title: L10n.t("歌词显示方式"), target: .displayMode))
        return items
    }

    private var doneStep: some View {
        let items = readinessItems
        let allOK = items.allSatisfy(\.ok)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: allOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(allOK ? Color.green : Color.orange)
                Text(allOK ? L10n.t("一切就绪") : L10n.t("还差一点"))
                    .font(.title.bold())
            }

            Text(allOK ? L10n.t("缪斯已经就位——接下来交给音乐。按下「开始使用」，让每一句歌词都跟着旋律亮起来")
                       : L10n.t("缪斯还在候场——把上面标橙的那几项补齐，她随时可以开嗓"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            chosenPlayersStrip

            if !allOK {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items.filter { !$0.ok }) { item in
                        readinessRow(item)
                    }
                }
            }
            Text(L10n.t("Lyrimuse 住在屏幕右上角的菜单栏里，点它就能打开设置、歌词管理和歌词窗口；按住 ⌘ 拖动可以把图标挪个位置。常用操作还能在设置的「快捷键」里配上全局热键"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !collectorRunning {
                Text(L10n.t("后台采集服务还没启用，所以这次不算走完引导——下次启动会再问一次"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private enum ChosenEntry: Identifiable {
        case player(PlaybackPlayer)
        case webPlatform(id: String, title: String)

        var id: String {
            switch self {
            case .player(let p): return "player.\(p)"
            case .webPlatform(let id, _): return "web.\(id)"
            }
        }

        var displayName: String {
            switch self {
            case .player(let p): return p.displayName
            case .webPlatform(_, let title): return title
            }
        }
    }

    private var chosenEntries: [ChosenEntry] {
        var entries = PlaybackPlayer.displayOrder
            .filter { $0 != .auto && features.players.contains($0) }
            .map(ChosenEntry.player)
        if wantsBrowserYouTubeMusic {
            entries.append(.webPlatform(id: Self.youTubeMusicPlatformID, title: "YouTube Music"))
        }

        entries += PlaybackPlayer.displayOrder
            .filter { $0 == .auto && features.players.contains($0) }
            .map(ChosenEntry.player)
        return entries
    }

    private var chosenPlayersStrip: some View {
        let entries = chosenEntries
        let names = entries.map(\.displayName)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(entries) { entry in
                    switch entry {
                    case .player(let player):
                        PlayerIconView(player: player, size: 24)
                    case .webPlatform(let id, _):
                        if let icon = WebPlatformIcon.image(id) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                        } else {

                            Image(systemName: "globe")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.secondary,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }

            Text(String(format: L10n.t("歌词会跟着这些走：%@"), names.joined(separator: " · ")))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("你选的播放器") + "：" + names.joined(separator: "、"))
    }

    private func readinessRow(_ item: ReadinessItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(item.ok ? Color.green : Color.orange)
                .environment(\.locale, Locale(identifier: "en"))

                .accessibilityLabel(item.ok ? L10n.t("已就绪") : L10n.t("未完成"))
            Text(item.title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            if !item.ok {
                Button(L10n.t("去处理")) { jump(to: item.target) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    private var automationStatusCaption: String {
        switch automationStatus {
        case .authorized: return L10n.t("已授权")
        case .denied: return L10n.t("已拒绝")
        case .notDetermined: return L10n.t("未授权")
        }
    }

    private var automationStatusIconName: String {
        switch automationStatus {
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        }
    }

    private var automationStatusIconColor: Color {
        switch automationStatus {
        case .authorized: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        }
    }

    private var automationActionTitle: String {
        automationStatus == .notDetermined ? L10n.t("请求权限") : L10n.t("打开系统设置")
    }

    private func handleAutomationAction() {
        if automationStatus == .notDetermined {
            requestAutomationPermission()
        } else {
            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
        }
    }

    private func requestAutomationPermission() {
        isRequestingAutomation = true
        automationRequestTimedOut = false
        Task {
            if let status = await MusicAutomationPermission.requestWithTimeout() {
                automationStatus = status
                isRequestingAutomation = false
                automationRequestTimedOut = false
            } else {
                automationRequestTimedOut = true
            }
        }
    }

    private func enableCollectorService() {
        isTogglingCollectorService = true
        collectorFailure = nil
        Task {

            let state = await CollectorServiceManager.setEnabledAndWait(true)
            settings.collectorServiceEnabled = true
            collectorRunning = state.isRunning
            isTogglingCollectorService = false

            collectorFailure = state.isRunning ? nil : String(
                format: L10n.t("没能启动（%@）。可以先「暂时跳过」，之后到设置的「通用 → 后台采集服务」里重试，那一页会给出更细的状态。"),
                state.description)
        }
    }

    private func goTo(_ index: Int) {
        let list = steps
        step = min(max(index, 0), list.count - 1)
        furthestStep = max(furthestStep, step)
    }

    private func jump(to target: Step) {
        guard let index = steps.firstIndex(of: target) else { return }
        goTo(index)
    }

    private func finish() {

        if collectorRunning {
            settings.hasCompletedOnboarding = true
        }
        dismissWindow(id: "onboarding")
    }
}

private struct DisplayModeThumbnail: View {
    enum Kind { case classic, notch, menuBar }

    let kind: Kind

    private static let width: CGFloat = 56
    private static let height: CGFloat = 36
    private static let menuBarHeight: CGFloat = 6
    private static let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)

    var body: some View {
        ZStack(alignment: .top) {
            Self.shape.fill(Color.primary.opacity(0.08))

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(height: Self.menuBarHeight)
            sketch
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))

        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var sketch: some View {
        switch kind {
        case .classic:

            VStack(spacing: 4) {
                Capsule().fill(Color.accentColor).frame(width: 32, height: 4)
                Capsule().fill(Color.primary.opacity(0.3)).frame(width: 22, height: 3)
            }
            .frame(width: Self.width, height: Self.height, alignment: .center)
            .offset(y: 5)
        case .notch:

            HStack(spacing: 3) {
                UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 18, height: Self.menuBarHeight + 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 15, height: 4)
                    .padding(.top, 1)
            }
            .frame(width: Self.width, alignment: .center)
        case .menuBar:

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 20, height: 3)
                    .padding(.trailing, 3)
            }
            .frame(width: Self.width, height: Self.menuBarHeight, alignment: .trailing)
        }
    }
}
