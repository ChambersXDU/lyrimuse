import SwiftUI
import AppKit
import Combine
import LyrimuseCore
import KeyboardShortcuts

enum SettingsTab: String, Hashable, CaseIterable, Identifiable {

    case lyrics, player, appearance, shortcuts, general, about

    var id: Self { self }

    static let lastTabStorageKey = "settings:lastTab"

    static func restoredLastTab(defaults: UserDefaults = .standard) -> SettingsTab {
        defaults.string(forKey: lastTabStorageKey).flatMap(SettingsTab.init(rawValue:)) ?? .lyrics
    }

    var title: String {
        switch self {
        case .lyrics: return L10n.t("歌词")
        case .player: return L10n.t("播放器")

        case .appearance: return L10n.t("歌词显示")
        case .shortcuts: return L10n.t("快捷键")
        case .general: return L10n.t("通用")
        case .about: return L10n.t("关于")
        }
    }

    var icon: String {
        switch self {
        case .lyrics: return "text.quote"
        case .player: return "play.circle"

        case .appearance: return "rectangle.3.group"
        case .shortcuts: return "keyboard"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .lyrics: return .indigo
        case .player: return .mint
        case .appearance: return .yellow
        case .shortcuts: return .teal
        case .general: return .gray

        case .about: return .blue
        }
    }
}

func iconBadge(_ systemName: String, tint: Color, size: CGFloat = 20, cornerRadius: CGFloat = 5) -> some View {
    IconBadge(systemName: systemName, tint: tint, size: size, cornerRadius: cornerRadius)
}

private struct IconBadge: View {
    let systemName: String
    let tint: Color
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private static let glyphRatio: CGFloat = 0.62

    var body: some View {

        let base = colorScheme == .dark ? SettingsIconTint.dimmedForDarkMode(tint) : tint
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: size * Self.glyphRatio, height: size * Self.glyphRatio)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                shape.fill(base)

                    .overlay(shape.fill(LinearGradient(
                        colors: [.white.opacity(0.20), .white.opacity(0.02), .black.opacity(0.07)],
                        startPoint: .top, endPoint: .bottom)))

                    .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            }
    }
}

enum SettingsIconTint {

    static let luminanceCap = 0.30

    static func dimmedForDarkMode(_ tint: Color) -> Color {

        var resolved: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(tint).usingColorSpace(.sRGB)
        }
        guard let base = resolved else { return tint }
        let r = linearized(base.redComponent)
        let g = linearized(base.greenComponent)
        let b = linearized(base.blueComponent)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard luminance > luminanceCap else { return tint }
        let k = luminanceCap / luminance
        return Color(nsColor: NSColor(srgbRed: encoded(r * k), green: encoded(g * k),
                                      blue: encoded(b * k), alpha: base.alphaComponent))
    }

    private static func linearized(_ c: CGFloat) -> Double {
        let v = Double(c)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ c: Double) -> CGFloat {
        let v = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return CGFloat(min(max(v, 0), 1))
    }
}

enum SettingsSidebarItem: Hashable {
    case tab(SettingsTab)
    case account(AccountDestination)

    case softwareUpdate
}

struct SettingsView: View {

    @ObservedObject private var languageSettings = AppSettings.shared

    @State private var selection: SettingsSidebarItem? = .tab(SettingsTab.restoredLastTab())
    @AppStorage(SettingsTab.lastTabStorageKey) private var lastTabRaw = SettingsTab.lyrics.rawValue

    @StateObject private var playerHealth = PlayerHealthMonitor()

    @ObservedObject private var updater = SparkleUpdaterManager.shared

    @State private var isAdditionalFeaturesExpanded = false

    @State private var settingsSearchText = ""

    @FocusState private var settingsSearchFocused: Bool

    @ObservedObject private var searchRouter = SettingsSearchRouter.shared

    private var isSearchingSettings: Bool {
        !settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var settingsSearchHits: [SettingsSearchHit] {
        SettingsSearchIndex.shared.search(settingsSearchText)
    }

    @ViewBuilder private var settingsSearchResultsSection: some View {
        let hits = settingsSearchHits
        if hits.isEmpty {
            Text(L10n.t("没有找到匹配的设置"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            Section {
                ForEach(hits) { hit in
                    SettingsSearchResultRow(hit: hit) { openSettingsSearchHit(hit) }
                }
            }
        }
    }

    private func openFirstSettingsSearchResult() {
        if let first = settingsSearchHits.first { openSettingsSearchHit(first) }
    }

    private func openSettingsSearchHit(_ hit: SettingsSearchHit) {
        let entry = hit.entry
        switch entry.destination {
        case .tab(let raw):
            if let tab = SettingsTab(rawValue: raw) { selection = .tab(tab) }
        case .softwareUpdate:
            selection = .softwareUpdate
        case .account(let name):
            if let destination = AccountDestination.allCases.first(where: { String(describing: $0) == name }) {

                if destination != .lastfm {
                    withAnimation { isAdditionalFeaturesExpanded = true }
                }
                selection = .account(destination)
            }
        }
        if let key = entry.sectionKey, let value = entry.sectionValue {
            UserDefaults.standard.set(value, forKey: key)
        }
        searchRouter.reveal(hit)
        settingsSearchText = ""
        settingsSearchFocused = false
    }

    @ViewBuilder private var sidebarSections: some View {
        Section {
            LastfmIdentityRow()
                .tag(SettingsSidebarItem.account(.lastfm))
            if updater.shownItem != nil {

                SoftwareUpdateSidebarRow()
                    .tag(SettingsSidebarItem.softwareUpdate)
            }
        }

        Section {
            sidebarLabel(.lyrics)
            sidebarLabel(.player)
            sidebarLabel(.appearance)
            sidebarLabel(.shortcuts)
            sidebarLabel(.general)
            sidebarLabel(.about)
        }

        Section(isExpanded: $isAdditionalFeaturesExpanded) {
            ForEach(AccountDestination.allCases.filter { $0 != .lastfm }) { destination in
                AccountSidebarRow(destination: destination)
                    .tag(SettingsSidebarItem.account(destination))
            }
        } header: {

            HStack(spacing: 4) {
                Text(L10n.t("实验室功能"))
                Image(systemName: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help(L10n.t("实验性 Beta 功能"))
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {

                if isSearchingSettings {
                    settingsSearchResultsSection
                } else {
                    sidebarSections
                }
            }
            .listStyle(.sidebar)

            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsSearchField(text: $settingsSearchText, focused: $settingsSearchFocused,
                                    onSubmit: openFirstSettingsSearchResult)
            }

            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)

            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection {
                case .tab(.lyrics): LyricsSettingsTab()
                case .tab(.player): PlayerSettingsTab()
                case .tab(.appearance): AppearanceSettingsTab()
                case .tab(.shortcuts): ShortcutsSettingsTab()
                case .tab(.general): GeneralSettingsTab()
                case .tab(.about): AboutSettingsTab()
                case .softwareUpdate: SoftwareUpdatePage()
                case .account(let destination):
                    AccountLinkingTab(destination: destination, onJumpToAccount: { target in

                        if target != .lastfm {
                            withAnimation { isAdditionalFeaturesExpanded = true }
                        }
                        selection = .account(target)
                    })
                case nil: ContentUnavailableView(L10n.t("选择左侧的设置分类"), systemImage: "gearshape")
                }
            }

            .safeAreaInset(edge: .top, spacing: 0) { ConfigFileDamageBanner() }

            .overlay(alignment: .bottom) { CollectorApplyStatusBar() }

            .navigationTitle(L10n.t("设置"))
            .navigationSubtitle(selectedCategoryTitle)
        }

        .frame(minWidth: 760, idealWidth: 860, minHeight: 690, idealHeight: 720)

        .environment(\.settingsSearchHighlightedTitles, searchRouter.highlightedTitles)
        .environment(\.settingsSearchPendingDrawer, searchRouter.pendingDrawer)
        .background(SettingsWindowConfigurator())

        .onAppear {
            if let pending = AppActions.shared.pendingSettingsSelection {
                selection = pending
                AppActions.shared.pendingSettingsSelection = nil
            }
        }

        .onReceive(AppActions.shared.selectionRequests) { item in
            selection = item

            AppActions.shared.pendingSettingsSelection = nil
        }

        .onChange(of: selection) { previous, item in
            if case .tab(let tab)? = item { lastTabRaw = tab.rawValue }

            if item == nil, previous == .softwareUpdate {
                selection = .softwareUpdate
                return
            }

            settingsSearchFocused = false
        }

        .onAppear {
            AuxiliaryWindowActivation.windowDidAppear()
            playerHealth.start()

            LastfmAvatarStore.shared.refreshFromConfig()
        }
        .onDisappear {
            AuxiliaryWindowActivation.windowDidDisappear()
            playerHealth.stop()

            SparkleUpdaterManager.shared.settingsWindowClosed()
        }
    }

    private func sidebarLabel(_ tab: SettingsTab) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(tab.title)
                if tab == .player, let warning = playerHealth.warningText {
                    Spacer(minLength: 4)
                    SidebarCountBadge(count: max(1, playerHealth.warnings.count))
                        .help(warning)
                        .accessibilityLabel(warning)
                }
            }
        } icon: {
            iconBadge(tab.icon, tint: tab.tint)
        }
        .tag(SettingsSidebarItem.tab(tab))
    }

    private var selectedCategoryTitle: String {
        switch selection {
        case .tab(let tab): return tab.title
        case .account(let destination): return destination.title
        case .softwareUpdate: return L10n.t("软件更新")
        case nil: return L10n.t("设置")
        }
    }
}

private struct LyricsSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    private let local = LocalPlaybackSource.shared

    @ObservedObject private var offsets = LyricsOffsetStore.shared

    @State private var sourceDrag: SourceDragState?

    @State private var priorityRowFrames: [LyricsSource: CGRect] = [:]

    private func romanizationToggle(
        _ title: String, _ option: RomanizationScripts, help: String
    ) -> some View {
        HStack(spacing: 4) {
            Toggle("", isOn: Binding(
                get: { settings.romanizationScripts.contains(option) },
                set: { on in
                    var next = settings.romanizationScripts
                    if on { next.insert(option) } else { next.remove(option) }
                    settings.romanizationScripts = next
                    local.romanizationScripts = next
                }
            ))
            .toggleStyle(.checkbox)
            Text(title).font(.system(size: 12))
        }
        .help(help)
    }
    @ObservedObject private var features = FeatureSettingsStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Section: String, CaseIterable, Identifiable {
        case fetch, translation, display, manage
        var id: Self { self }
        var title: String {
            switch self {
            case .fetch: return L10n.t("获取")
            case .translation: return L10n.t("译文")

            case .display: return L10n.t("效果")
            case .manage: return L10n.t("管理")
            }
        }
    }

    @State private var manualPickLockNotice: String?

    @State private var manualPickLockNoticeToken = 0

    @State private var manualPickLockBusy = false

    @State private var pendingManualUnlockCount = 0
    @State private var showManualPickUnlockConfirm = false

    @State private var hoveredSource: String?

    @State private var hoveredRow: LyricsSource?

    private enum LyricSourceTestState: Equatable {
        case testing
        case result(status: LyricSourceTestService.Status, detail: String)
    }
    @State private var sourceTestStates: [LyricsSource: LyricSourceTestState] = [:]

    @State private var isTestingLyricSources = false
    @State private var lyricSourceTestGeneration = 0

    @State private var offsetScope = ""

    @State private var nowPlayingBundleID: String?

    private func refreshNowPlayingPlayer() {
        let coordinator = PlaybackCoordinator.shared
        nowPlayingBundleID = coordinator.isPlayingSmoothed ? coordinator.resolvedPlayerBundleID : nil
    }

    private var offsetScopeOptions: [String] {

        LyricsOffsetScope.options(
            builtInOrder: PlaybackPlayer.displayOrder,
            trusted: features.trustedPlayers,
            configured: Set(offsets.playerOffsets.keys),
            nowPlaying: nowPlayingBundleID
        )
    }

    private func playerDisplayName(_ bundleID: String) -> String {
        if let builtin = PlaybackPlayer.allCases.first(where: { $0 != .auto && $0.bundleIdentifier == bundleID }) {
            return builtin.displayName
        }
        if let trusted = features.trustedPlayers[bundleID], !trusted.isEmpty { return trusted }
        return FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID
    }

    private func offsetScopeLabel(_ bundleID: String) -> String {
        let name = playerDisplayName(bundleID)
        if bundleID == nowPlayingBundleID { return name + L10n.t("（正在播放）") }
        if offsets.playerOffset(forBundleID: bundleID) != 0 { return name + L10n.t("（已调）") }
        return name
    }

    private var scopedOffsetMs: Int {
        offsetScope.isEmpty ? offsets.globalOffsetMs : offsets.playerOffset(forBundleID: offsetScope)
    }

    private func setScopedOffset(_ ms: Int) {
        if offsetScope.isEmpty {
            PlaybackCoordinator.shared.setGlobalLyricsOffset(ms)
        } else {
            PlaybackCoordinator.shared.setPlayerLyricsOffset(ms, forBundleID: offsetScope)
        }
    }

    @AppStorage("settings:lyricsSection") private var sectionRaw = Section.fetch.rawValue
    private var section: Section { Section(rawValue: sectionRaw) ?? .fetch }

    var body: some View {

        SettingsPage(
            title: L10n.t("歌词")
        ) {
            sectionPicker

            currentSection
                .id(section)
                .transition(.opacity)
        }
        .id(L10n.current)
    }

    private var sectionPicker: some View {
        Picker(
            "",
            selection: Binding(
                get: { section },
                set: { next in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        sectionRaw = next.rawValue
                    }
                })
        ) {
            ForEach(Section.allCases) { s in
                Text(s.title).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        .fixedSize()
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var currentSection: some View {
        switch section {
        case .fetch:

            sourcesCard
            matchingCard
        case .translation:
            translationCard
        case .display:
            displayCard
        case .manage:
            managementCard
        }
    }

    private var sourcesCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("歌词来源")) { testAllSourcesButton }
            CardDivider()

            SettingsRawRow(insetToText: true) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                    alignment: .leading, spacing: 4
                ) {
                    ForEach(LyricsSource.allCases) { source in

                        HStack(spacing: 4) {
                            sourceCheckbox(source)
                            Spacer(minLength: 0)
                            sourceTestAccessory(source)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoveredRow = hovering ? source : (hoveredRow == source ? nil : hoveredRow)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var matchingModeSubtitle: String {
        switch features.lyricsSourceMode {
        case .smart: return L10n.t("给每个来源打分，取分最高的")
        case .priority: return L10n.t("不打分，按下面的顺序取第一个有结果的来源")
        }
    }

    private func matchingModeLabel(_ mode: LyricsSourceMode) -> String {
        mode == .smart
            ? String(format: L10n.t("%@（推荐）"), mode.displayName)
            : mode.displayName
    }

    private var matchingCard: some View {
        SettingsCard {

            SettingsRow(
                icon: "slider.horizontal.3",
                title: L10n.t("匹配算法"),
                subtitle: matchingModeSubtitle
            ) {
                Picker("", selection: Binding(
                    get: { features.lyricsSourceMode },
                    set: { features.lyricsSourceMode = $0; Task { await features.save() } }
                )) {
                    ForEach(LyricsSourceMode.allCases) { mode in
                        Text(matchingModeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            if features.lyricsSourceMode == .priority {

                let visible = orderedEnabledSources
                ForEach(Array(visible.enumerated()), id: \.element) { index, source in
                    CardDivider()
                    priorityRow(index: index, source: source, visible: visible)
                }
            }
            CardDivider()

            SettingsRow(
                icon: "arrow.triangle.2.circlepath",
                title: L10n.t("跟进算法升级"),
                help: L10n.t("开（默认）：匹配算法或打分规则更新后，后台会重新评估已有歌词，可能换成更合适的一份\n关：一旦定下来就不再自动更换；首次解析、手动重搜和手动编辑不受影响")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.lyricsAutoUpgrade },
                    set: { features.lyricsAutoUpgrade = $0; Task { await features.save() } }
                ))
            }
            CardDivider()

            SettingsRow(
                icon: "square.stack",

                title: L10n.t("提前解析同专辑其它曲目")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.albumPrefetch },
                    set: { features.albumPrefetch = $0; Task { await features.save() } }
                ))
            }
            CardDivider()

            SettingsRow(
                icon: "lock.circle",
                title: L10n.t("锁定手选歌词"),

                help: L10n.t("关（默认）：只换这一次，以后自动重搜或打分变化仍可能换掉\n开：锁住这首歌的歌词，自动匹配不再碰它\n打开时，之前手动选过的歌一并锁定（已被自动换掉的除外）")
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.manualPickLocksLyrics },
                    set: { on in

                        settings.manualPickLocksLyrics = on
                        runManualPickLockSweep(locking: on)
                    }
                ))
            }

            if manualPickLockBusy || manualPickLockNotice != nil {
                CardDivider()
                SettingsNote {
                    HStack(spacing: 6) {
                        if manualPickLockBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(manualPickLockNotice ?? L10n.t("正在检查已经手动选定过的歌…"))
                    }
                }
            }
        }

        .animation(.easeInOut(duration: 0.18), value: manualPickLockBusy)
        .animation(.easeInOut(duration: 0.18), value: manualPickLockNotice)
        .alert(L10n.t("要把之前锁定的歌一并解锁吗？"), isPresented: $showManualPickUnlockConfirm) {

            Button(L10n.t("保持锁定"), role: .cancel) {
                showManualPickLockNotice(String(
                    format: L10n.t("%@ 首保持锁定；从现在起手动选定的歌不再自动锁定"),
                    "\(pendingManualUnlockCount)"))
            }
            Button(L10n.t("一并解锁")) {
                Task {
                    manualPickLockBusy = true
                    let n = await EnrichCacheStore.shared.applyManualPickLock(false)
                    manualPickLockBusy = false
                    showManualPickLockNotice(String(format: L10n.t("已解锁 %@ 首"), "\(n)"))
                }
            }
        } message: {
            Text(String(
                format: L10n.t("有 %@ 首歌是因为这个开关被锁定的。解锁后它们会重新接受自动重搜和打分改进；你手动编辑过正文的歌不受影响，始终保持锁定"),
                "\(pendingManualUnlockCount)"))
        }

        .coordinateSpace(name: Self.priorityListSpace)
        .onPreferenceChange(PrioritySourceFramesKey.self) { priorityRowFrames = $0 }
        .onChange(of: orderedEnabledSources.count) { _, _ in sourceDrag = nil }
        .onChange(of: features.lyricsSourceMode) { _, _ in sourceDrag = nil }
    }

    private func runManualPickLockSweep(locking: Bool) {
        manualPickLockNotice = nil
        manualPickLockBusy = true
        Task {

            let store = EnrichCacheStore.shared
            await store.reload(onlyIfChanged: true)
            let stats = store.manualPickLockStats(locking: locking)

            guard locking else {
                manualPickLockBusy = false

                guard stats.targets > 0 else {
                    showManualPickLockNotice(L10n.t("从现在起，手动选定的歌不再自动锁定"))
                    return
                }
                pendingManualUnlockCount = stats.targets
                showManualPickUnlockConfirm = true
                return
            }

            let changed = await store.applyManualPickLock(true)
            manualPickLockBusy = false
            if changed > 0 {
                showManualPickLockNotice(String(
                    format: L10n.t("已锁定 %@ 首之前手动选定的歌；从现在起选定的会直接锁定"),
                    "\(changed)"))
            } else if stats.picked == 0 {

                showManualPickLockNotice(L10n.t("还没有手动选定过歌词；从现在起你选定的都会直接锁定"))
            } else if stats.stillOriginal == 0 {
                showManualPickLockNotice(String(
                    format: L10n.t("之前手动选定的 %@ 首，歌词后来都被自动更新过，已经不是你当初选的那一份，所以没有锁定"),
                    "\(stats.picked)"))
            } else {
                showManualPickLockNotice(String(
                    format: L10n.t("之前手动选定的 %@ 首已经都是锁定状态"), "\(stats.stillOriginal)"))
            }
        }
    }

    private func showManualPickLockNotice(_ text: String) {
        manualPickLockNoticeToken += 1
        let token = manualPickLockNoticeToken
        manualPickLockNotice = text
        Task {
            try? await Task.sleep(for: .seconds(8))
            guard manualPickLockNoticeToken == token else { return }
            manualPickLockNotice = nil
        }
    }

    private func sourceCheckbox(_ source: LyricsSource) -> some View {
        sourceCheckbox(
            id: source.rawValue, name: source.displayName, color: source.color,
            on: features.lyricsSources.contains(source),
            toggle: { setSource(source, enabled: $0) })
    }

    private func sourceCheckbox(
        id: String, name: String, color: Color, on: Bool, toggle: @escaping (Bool) -> Void
    ) -> some View {
        let hovered = hoveredSource == id
        return Button {
            toggle(!on)
        } label: {
            HStack(spacing: 6) {

                ZStack {
                    Circle()
                        .fill(on ? color : .clear)
                        .overlay(
                            Circle().strokeBorder(
                                on ? .clear : Color.secondary.opacity(0.4), lineWidth: 1.5))
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 15, height: 15)

                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.secondary.opacity(0.12) : .clear))

            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(sourceHelpText(id))
        .onHover { hoveredSource = $0 ? id : (hoveredSource == id ? nil : hoveredSource) }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func setSource(_ source: LyricsSource, enabled: Bool) {

        let before = features.lyricsSources
        if enabled {
            features.lyricsSources.insert(source)
        } else if features.lyricsSources.count > 1 {
            features.lyricsSources.remove(source)
        }
        guard features.lyricsSources != before else { return }
        Task { await features.save() }
    }

    private var testAllSourcesButton: some View {
        Button {
            testAllSources()
        } label: {
            HStack(spacing: 4) {
                if isTestingLyricSources {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                Text(isTestingLyricSources ? L10n.t("测试中…") : L10n.t("测试"))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .controlSize(.small)
        .settingsGlassButtons()
    }

    @ViewBuilder
    private func sourceTestAccessory(_ source: LyricsSource) -> some View {
        let state = sourceTestStates[source]

        let isRowHovered = hoveredRow == source
        let isAccessoryHovered = accessoryHoverSource == source
        let tooltip = sourceAccessoryTooltip(state)
        Group {
            switch state {
            case .testing:
                ProgressView().controlSize(.mini)
            case .result(let status, _):
                Button { testSource(source) } label: {
                    Image(systemName: statusSymbol(status))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor(status))
                }
                .buttonStyle(.plain)
            case nil:
                if isRowHovered || isAccessoryHovered {
                    Button { testSource(source) } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                            .foregroundStyle(isAccessoryHovered ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        .frame(width: 16, height: 16)

        .background(Circle().fill(isAccessoryHovered ? Color.secondary.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .disabled(isTestingLyricSources)
        .onHover { hovering in
            accessoryHoverSource = hovering ? source : (accessoryHoverSource == source ? nil : accessoryHoverSource)
        }
        .popover(isPresented: Binding(
            get: { isAccessoryHovered && tooltip != nil },
            set: { shown in if !shown { accessoryHoverSource = nil } }
        ), arrowEdge: .bottom) {
            if let tooltip {

                Text(tooltip)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.leading)
                    .frame(width: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
        }
    }

    @State private var accessoryHoverSource: LyricsSource?

    private func sourceAccessoryTooltip(_ state: LyricSourceTestState?) -> String? {
        switch state {

        case .result(let status, let detail): return status == .ok ? nil : detail

        case .testing, nil: return nil
        }
    }

    private func statusSymbol(_ status: LyricSourceTestService.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.circle.fill"
        case .fail: return "wifi.slash"
        }
    }

    private func statusColor(_ status: LyricSourceTestService.Status) -> Color {
        switch status {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .secondary
        }
    }

    private func testSource(_ source: LyricsSource) {
        lyricSourceTestGeneration += 1
        let generation = lyricSourceTestGeneration
        isTestingLyricSources = true
        sourceTestStates[source] = .testing
        Task {
            do {
                try await LyricSourceTestService.shared.test(source: source) { result in
                    guard let matched = LyricsSource(rawValue: result.source) else { return }
                    sourceTestStates[matched] = .result(
                        status: result.status,
                        detail: LyricSourceFailureReason.text(forCode: result.reasonCode))
                }
            } catch {
                if generation == lyricSourceTestGeneration {
                    sourceTestStates[source] = .result(
                        status: .fail, detail: error.localizedDescription)
                }
            }
            if generation == lyricSourceTestGeneration {
                isTestingLyricSources = false
            }
        }
    }

    private func testAllSources() {
        lyricSourceTestGeneration += 1
        let generation = lyricSourceTestGeneration
        isTestingLyricSources = true
        for source in LyricsSource.allCases where features.lyricsSources.contains(source) {
            sourceTestStates[source] = .testing
        }
        Task {
            do {
                try await LyricSourceTestService.shared.test(source: nil) { result in
                    guard let matched = LyricsSource(rawValue: result.source) else { return }
                    sourceTestStates[matched] = .result(
                        status: result.status,
                        detail: LyricSourceFailureReason.text(forCode: result.reasonCode))
                }
            } catch {

                if generation == lyricSourceTestGeneration {
                    for source in LyricsSource.allCases where sourceTestStates[source] == .testing {
                        sourceTestStates[source] = .result(
                            status: .fail, detail: error.localizedDescription)
                    }
                }
            }
            if generation == lyricSourceTestGeneration {
                isTestingLyricSources = false
            }
        }
    }

    private var translationCard: some View {
        SettingsCard {

            SettingsRow(
                icon: "text.bubble",
                title: L10n.t("显示译文"),
                help: L10n.t("只影响桌面悬浮歌词和歌词窗口；灵动岛受空间所限不支持，菜单栏只能显示一行。")
            ) {
                Toggle("", isOn: $settings.showTranslation)
            }
            CardDivider()
            SettingsRow(
                icon: "globe",
                title: L10n.t("译文语言")
            ) {
                Picker("", selection: Binding(
                    get: { features.lyricsTranslationLanguage },
                    set: { features.lyricsTranslationLanguage = $0; Task { await features.save() } }
                )) {
                    ForEach(MusixmatchTranslationLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            CardDivider()
            SettingsRow(
                icon: "character.book.closed",
                title: L10n.t("系统兜底翻译"),
                help: L10n.t("歌词源没带译文时补充")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.lyricsMachineTranslation },
                    set: { features.lyricsMachineTranslation = $0; Task { await features.save() } }
                ))
            }

            if #available(macOS 26.0, *), features.lyricsMachineTranslation {
                CardDivider()
                LanguagePackRow()
            }
        }
    }

    private var displayCard: some View {
        SettingsCard {

            if AppSettings.userReadsChinese || settings.hasSeenChineseLyrics
                || settings.lyricsChineseVariant != .off
            {
            SettingsRow(
                icon: "character.bubble",
                title: L10n.t("繁简转换"),
                help: L10n.t("把中文歌词统一显示成简体或繁体")
            ) {
                Picker("", selection: Binding(
                    get: { settings.lyricsChineseVariant },
                    set: { newValue in
                        settings.lyricsChineseVariant = newValue
                        local.chineseVariant = newValue
                    }
                )) {
                    Text(L10n.t("不转换")).tag(ChineseVariant.off)
                    Text(L10n.t("简体")).tag(ChineseVariant.simplified)
                    Text(L10n.t("繁体")).tag(ChineseVariant.traditional)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            CardDivider()
            }
            SettingsRow(
                icon: "textformat.alt",
                title: L10n.t("显示罗马音"),
                help: L10n.t("只影响桌面悬浮歌词和歌词窗口；灵动岛受空间所限不支持，菜单栏只能显示一行。")
            ) {
                Toggle("", isOn: $settings.showRomanization)
            }

            if settings.showRomanization {
                CardDivider()

                SettingsSubRow(
                    title: L10n.t("标注哪些语言")
                ) {
                    HStack(spacing: 12) {
                        romanizationToggle(
                            L10n.t("日语"), .japanese,
                            help: L10n.t("只对判定为日语的歌词生效，例如 こんにちは → konnichiwa"))
                        romanizationToggle(
                            L10n.t("韩语"), .korean,
                            help: L10n.t("只对判定为韩语的歌词生效，例如 안녕하세요 → annyeonghaseyo"))
                        romanizationToggle(
                            L10n.t("拼音"), .chinese,
                            help: L10n.t("只对判定为普通话的歌词生效，例如 你好 → nǐ hǎo"))
                        romanizationToggle(
                            L10n.t("粤拼"), .cantonese,
                            help: L10n.t("只对判定为粤语的歌词生效，用的是粤拼(Jyutping)方案，例如 你好 → nei5 hou2"))
                    }
                }

                .help(L10n.t("日语、韩语标成罗马字，普通话标成拼音，粤语标成粤拼"))
            }
            CardDivider()

            SettingsRow(
                icon: "timer",
                title: L10n.t("全局时间轴偏移"),
                help: L10n.t("正数＝歌词提前，负数＝歌词延后；常用来抵消蓝牙耳机的声音延迟")
            ) {
                HStack(spacing: 8) {
                    Picker("", selection: $offsetScope) {

                        Text(L10n.t("全部播放器")).tag("")
                        ForEach(offsetScopeOptions, id: \.self) { bundleID in
                            Text(offsetScopeLabel(bundleID)).tag(bundleID)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

                    Text("\(AppSettings.signedSeconds(ms: scopedOffsetMs))\(L10n.t("秒"))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Stepper("", value: Binding(
                        get: { Double(scopedOffsetMs) / 1000 },
                        set: { setScopedOffset(Int(($0 * 1000).rounded())) }
                    ), in: -5.0...5.0, step: 0.05)

                    if scopedOffsetMs != 0 {
                        Button(L10n.t("重置")) { setScopedOffset(0) }
                    }
                }
            }

            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                refreshNowPlayingPlayer()
            }
            .onAppear { refreshNowPlayingPlayer() }
        }
    }

    @ViewBuilder
    private var managementCard: some View {
        SettingsCard {

            SettingsCardHeader(title: L10n.t("歌词库")) {

                Button(L10n.t("打开歌词管理")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "lyrics-manager")
                }
                .font(.system(size: 11, weight: .medium))
                .controlSize(.small)
                .settingsGlassButtons()
                .help(L10n.t("查看、编辑、重搜已缓存的歌词"))
            }
            CardDivider()

            LyricsLibraryStatsPanel()
        }
        SettingsCard {
            lyricsFolderRow

            if !features.lyricsDir.isEmpty {
                CardDivider()
                SettingsSubRow(title: L10n.t("已改用自定义位置")) {
                    Button(L10n.t("恢复默认位置")) {
                        features.lyricsDir = ""
                        Task { await features.save() }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var lyricsFolderRow: some View {
        let url = features.effectiveLyricsDir
        return SettingsRow(
            icon: "folder",
            title: L10n.t("歌词文件夹"),
            help: L10n.t("换文件夹后，旧文件不会自动搬过去")
        ) {
            HStack(spacing: 8) {
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                    .help(url.path)

                    .accessibilityLabel(L10n.t("歌词文件夹"))
                    .accessibilityValue(url.path)
                Button(L10n.t("在访达中显示")) {

                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
                .fixedSize()
                Button(L10n.t("更改…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = L10n.t("选择")
                    panel.directoryURL = url
                    if panel.runModal() == .OK, let picked = panel.url {
                        features.lyricsDir = picked.path
                        Task { await features.save() }
                    }
                }
                .fixedSize()
            }
        }
    }

    private var orderedEnabledSources: [LyricsSource] {
        features.lyricsSourceOrder.filter { features.lyricsSources.contains($0) }
    }

    private static let priorityListSpace = "lyrics-priority-list"

    struct SourceDragState {

        var source: Int

        var target: Int

        var translation: CGFloat

        var rowMidYs: [CGFloat]
    }

    private func priorityRow(index: Int, source: LyricsSource, visible: [LyricsSource]) -> some View {
        let isDragged = sourceDrag?.source == index
        let offset: CGFloat = {
            guard let drag = sourceDrag else { return 0 }
            if isDragged { return drag.translation }
            return ReorderDrag.displacement(row: index, source: drag.source, target: drag.target, rowMidYs: drag.rowMidYs)
        }()
        return SettingsRawRow(insetToText: true) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)

                    .environment(\.locale, Locale(identifier: "en"))
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
                    .help(L10n.t("拖动调整顺序"))
                    .accessibilityLabel(L10n.t("拖动调整顺序"))
                    .gesture(priorityDragGesture(index: index, visible: visible))
                Text("\(index + 1)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .trailing)
                Circle().fill(source.color).frame(width: 8, height: 8)
                Text(source.displayName)
                    .font(.system(size: 13))
                Spacer()

                Button {
                    moveEnabledSource(source, direction: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .accessibilityLabel(L10n.t("上移"))
                Button {
                    moveEnabledSource(source, direction: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(index == visible.count - 1)
                .accessibilityLabel(L10n.t("下移"))
            }
        }
        .offset(y: offset)
        .scaleEffect(isDragged ? 1.015 : 1)
        .zIndex(isDragged ? 1 : 0)
        .animation(isDragged || reduceMotion ? nil : .easeOut(duration: 0.15), value: sourceDrag?.target)
        .background(GeometryReader { geo in
            Color.clear.preference(
                key: PrioritySourceFramesKey.self,
                value: [source: geo.frame(in: .named(Self.priorityListSpace))]
            )
        })
    }

    private func priorityDragGesture(index: Int, visible: [LyricsSource]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.priorityListSpace))
            .onChanged { value in
                if sourceDrag == nil {
                    let mids = visible.compactMap { priorityRowFrames[$0]?.midY }
                    guard mids.count == visible.count, visible.indices.contains(index) else { return }
                    sourceDrag = SourceDragState(source: index, target: index, translation: 0, rowMidYs: mids)
                }
                guard var drag = sourceDrag, drag.source == index else { return }
                let raw = value.location.y - value.startLocation.y
                drag.translation = ReorderDrag.clampedTranslation(raw, source: drag.source, rowMidYs: drag.rowMidYs)
                drag.target = ReorderDrag.targetIndex(
                    rowMidYs: drag.rowMidYs, source: drag.source, current: drag.target,
                    draggedMidY: drag.rowMidYs[drag.source] + drag.translation
                )
                sourceDrag = drag
            }
            .onEnded { _ in
                guard let drag = sourceDrag, drag.source == index else { return }
                let changed = drag.target != drag.source
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    sourceDrag = nil
                    if changed {
                        features.lyricsSourceOrder = ReorderDrag.moved(
                            features.lyricsSourceOrder,
                            isVisible: { features.lyricsSources.contains($0) },
                            from: drag.source, to: drag.target
                        )
                    }
                }
                if changed { Task { await features.save() } }
            }
    }

    private func moveEnabledSource(_ source: LyricsSource, direction: Int) {
        let visible = orderedEnabledSources
        guard let visibleIndex = visible.firstIndex(of: source) else { return }
        let targetIndex = visibleIndex + direction
        guard visible.indices.contains(targetIndex) else { return }
        let other = visible[targetIndex]
        guard let i = features.lyricsSourceOrder.firstIndex(of: source),
              let j = features.lyricsSourceOrder.firstIndex(of: other) else { return }
        features.lyricsSourceOrder.swapAt(i, j)
        Task { await features.save() }
    }
}

private struct PrioritySourceFramesKey: PreferenceKey {
    static let defaultValue: [LyricsSource: CGRect] = [:]
    static func reduce(value: inout [LyricsSource: CGRect], nextValue: () -> [LyricsSource: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {

        SettingsPageWithStickyHeader {

            Group {
                switch section {

                case .overlay: EmptyView()
                case .notch: EmptyView()

                case .menuBar: EmptyView()
                }
            }
            .animation(.easeOut(duration: 0.18), value: sectionRaw)
        } page: {
            SettingsPage(
                title: L10n.t("歌词显示"),

                subtitle: L10n.t("三种展示方式可以同时开启")

            ) {
                sectionPicker
                currentSection
                    .id(section)
                    .transition(.opacity)
            }
        }
        .id(L10n.current)
    }

    private enum Section: String, CaseIterable, Identifiable {
        case overlay, notch, menuBar
        var id: Self { self }
        var title: String {
            switch self {
            case .overlay: return L10n.t("悬浮歌词")
            case .notch: return L10n.t("灵动岛")
            case .menuBar: return L10n.t("菜单栏")
            }
        }
    }

    @AppStorage(LyricsSurface.appearanceSectionStorageKey) private var sectionRaw = Section.overlay.rawValue
    private var section: Section { Section(rawValue: sectionRaw) ?? .overlay }

    private var sectionPicker: some View {
        Picker(
            "",
            selection: Binding(
                get: { section },
                set: { next in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        sectionRaw = next.rawValue
                    }
                })
        ) {
            ForEach(Section.allCases) { s in
                Text(s.title).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var currentSection: some View {
        switch section {
        case .overlay:

            OverlayEditorStage()
            modeToggleCard(
                icon: "captions.bubble",
                title: L10n.t("桌面悬浮歌词"),
                isOn: Binding(
                    get: { settings.classicOverlayEnabled },
                    set: { LyricsOverlayWindowController.shared.setVisible($0) }))

            OverlayAllSettingsDrawer()
        case .notch:

            NotchEditorStage()

            modeToggleCard(
                icon: "rectangle.topthird.inset.filled",
                title: L10n.t("灵动岛歌词"),
                subtitle: L10n.t("紧凑地贴着屏幕顶部的刘海显示"),
                isOn: Binding(
                    get: { settings.notchOverlayEnabled },
                    set: { NotchLyricsWindowController.shared.setVisible($0) }))

            NotchAllSettingsDrawer()
        case .menuBar:

            MenuBarEditorStage()
            modeToggleCard(
                icon: "menubar.rectangle",
                title: L10n.t("菜单栏歌词"),
                isOn: $settings.showLyricsInMenuBar)
            MenuBarAllSettingsDrawer()
        }
    }

    private func modeToggleCard(
        icon: String, title: String, subtitle: String? = nil, isOn: Binding<Bool>
    ) -> some View {
        SettingsCard {
            SettingsRow(icon: icon, title: title, subtitle: subtitle) {
                Toggle("", isOn: Binding(
                    get: { isOn.wrappedValue },
                    set: { newValue in

                        withAnimation(.settingsCardReveal) { isOn.wrappedValue = newValue }
                    }
                ))
            }
        }
    }

}

enum NotchBehaviorItem: String, CaseIterable, Identifiable {
    case showLyrics

    case karaoke
    case collapseWhenPaused
    case lyricRowArtwork
    case expandedNextLine
    case expandedShowsControls
    case expandedShowsLyricsOffset

    case expandedShowsQuickActions
    case expandedShowsArtwork
    case expandedShowsTrackTitle
    case expandedShowsArtist
    case expandedShowsAlbum

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .showLyrics: return "text.alignleft"
        case .karaoke: return "sparkles"
        case .collapseWhenPaused: return "arrow.down.right.and.arrow.up.left"
        case .lyricRowArtwork: return "photo"
        case .expandedNextLine: return "text.bubble"
        case .expandedShowsControls: return "playpause.fill"
        case .expandedShowsLyricsOffset: return "timer"
        case .expandedShowsQuickActions: return "ellipsis.circle"
        case .expandedShowsArtwork: return "photo"
        case .expandedShowsTrackTitle: return "textformat"
        case .expandedShowsArtist: return "music.mic"
        case .expandedShowsAlbum: return "opticaldisc"
        }
    }

    var title: String {
        switch self {
        case .showLyrics: return L10n.t("显示歌词")
        case .karaoke: return L10n.t("卡拉OK效果")
        case .collapseWhenPaused: return L10n.t("暂停缩回")
        case .lyricRowArtwork: return L10n.t("显示封面")

        case .expandedNextLine: return L10n.t("展开时预览下一句")
        case .expandedShowsControls: return L10n.t("显示播放控制")
        case .expandedShowsLyricsOffset: return L10n.t("显示歌词校准")
        case .expandedShowsQuickActions: return L10n.t("快捷操作")

        case .expandedShowsArtwork: return NotchEarModule.artwork.displayName
        case .expandedShowsTrackTitle: return NotchEarModule.title.displayName
        case .expandedShowsArtist: return NotchEarModule.artist.displayName
        case .expandedShowsAlbum: return NotchEarModule.album.displayName
        }
    }

    var help: String? {
        switch self {
        case .expandedNextLine: return L10n.t("展开时在进度条上方显示下一句要唱的歌词。")
        case .karaoke: return L10n.t("逐字歌词，唱到哪个字亮到哪个字；没有逐字数据的歌整行高亮")
        case .expandedShowsQuickActions:
            return L10n.t("展开时在曲目信息右侧显示四颗按钮：搜索歌词、显示歌词、设置、关闭灵动岛歌词。")
        default: return nil
        }
    }

    @MainActor
    var binding: Binding<Bool> {
        let settings = AppSettings.shared
        switch self {
        case .showLyrics:
            return Binding(get: { settings.notchShowLyrics }, set: { settings.notchShowLyrics = $0 })
        case .karaoke:
            return Binding(get: { settings.notchLyricsKaraoke }, set: { settings.notchLyricsKaraoke = $0 })
        case .collapseWhenPaused:
            return Binding(get: { settings.notchCollapsesWhenPaused },
                            set: { settings.notchCollapsesWhenPaused = $0 })
        case .lyricRowArtwork:
            return Binding(get: { settings.notchLyricRowShowsArtwork },
                            set: { settings.notchLyricRowShowsArtwork = $0 })
        case .expandedNextLine:
            return Binding(get: { settings.notchExpandedShowsNextLine },
                            set: { settings.notchExpandedShowsNextLine = $0 })
        case .expandedShowsControls:
            return Binding(get: { settings.notchExpandedShowsControls },
                            set: { settings.notchExpandedShowsControls = $0 })
        case .expandedShowsLyricsOffset:
            return Binding(get: { settings.notchExpandedShowsLyricsOffset },
                            set: { settings.notchExpandedShowsLyricsOffset = $0 })
        case .expandedShowsQuickActions:
            return Binding(get: { settings.notchExpandedShowsQuickActions },
                            set: { settings.notchExpandedShowsQuickActions = $0 })
        case .expandedShowsArtwork:
            return Binding(get: { settings.notchExpandedShowsArtwork },
                            set: { settings.notchExpandedShowsArtwork = $0 })
        case .expandedShowsTrackTitle:
            return Binding(get: { settings.notchExpandedShowsTrackTitle },
                            set: { settings.notchExpandedShowsTrackTitle = $0 })
        case .expandedShowsArtist:
            return Binding(get: { settings.notchExpandedShowsArtist },
                            set: { settings.notchExpandedShowsArtist = $0 })
        case .expandedShowsAlbum:
            return Binding(get: { settings.notchExpandedShowsAlbum },
                            set: { settings.notchExpandedShowsAlbum = $0 })
        }
    }
}

@MainActor
private struct NotchBehaviorToggleRow: View {
    let item: NotchBehaviorItem

    var body: some View {
        SettingsRow(icon: item.icon, title: item.title, help: item.help) {
            Toggle("", isOn: item.binding)
        }
    }
}

@MainActor
private struct NotchBehaviorToggleSubRow: View {
    let item: NotchBehaviorItem

    var body: some View {
        SettingsSubRow(title: item.title, help: item.help) {
            Toggle("", isOn: item.binding)
        }
    }
}

@MainActor
private struct NotchLyricRowArtworkPositionRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsSubRow(title: L10n.t("封面位置")) {
            Picker("", selection: $settings.notchLyricRowArtworkPosition) {
                ForEach(NotchLyricRowArtworkPosition.allCases, id: \.self) { position in
                    Text(position.displayName).tag(position)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

@MainActor
private struct NotchLyricsAlignmentRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.alignleft",
            title: L10n.t("对齐方式"),

            help: L10n.t("只影响装得下的短句：它在歌词行里靠哪边。「自动」按对唱声部走：谁唱靠谁那边、合唱居中，没有对唱信息就靠左。放不下的句子会横向滚动，没有多余空间，对齐不起作用")
        ) {
            LyricsAlignmentSegmentedControl(selection: $settings.notchLyricsAlignment,
                                            options: LyricsRestingAlignment.notchOptions)
        }
    }
}

@MainActor
private struct LyricSecondaryLineRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.append",
            title: L10n.t("副行"),
            help: L10n.t("主歌词下方多显示一行，行高不变。译文和罗马音显示的是当前句，下一句显示接下来那句；选「下一句」时展开区不再重复显示下一句预览")
        ) {
            Picker("", selection: $settings.notchSecondaryLine) {
                ForEach(LyricSecondaryLine.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

@MainActor
struct NotchLyricRowSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            NotchBehaviorToggleRow(item: .showLyrics)
            if settings.notchShowLyrics {
                CardDivider()
                NotchLyricsAlignmentRow()
                CardDivider()
                LyricSecondaryLineRow()
                if !settings.notchSecondaryLine.hidesExpandedNextLinePreview {
                    CardDivider()
                    NotchBehaviorToggleSubRow(item: .expandedNextLine)
                }
                CardDivider()
                NotchBehaviorToggleRow(item: .karaoke)
                CardDivider()
                NotchBehaviorToggleRow(item: .lyricRowArtwork)
                if settings.notchLyricRowShowsArtwork {
                    CardDivider()
                    NotchLyricRowArtworkPositionRow()
                }
            } else if !settings.notchSecondaryLine.hidesExpandedNextLinePreview {
                CardDivider()
                NotchBehaviorToggleRow(item: .expandedNextLine)
            }
        }
    }
}

@MainActor
struct NotchFontSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    private var sizeRange: ClosedRange<Double> {
        Double(NotchLyricRowMetrics.mainFontSizeRange.lowerBound)...Double(NotchLyricRowMetrics.mainFontSizeRange.upperBound)
    }

    private var sizeHelp: String {
        String(format: L10n.t("只调主行，%@～%@pt，歌词行高度不变；副行和展开时的下一句预览固定 %@pt，只跟随字体与粗细"),
               "\(Int(NotchLyricRowMetrics.mainFontSizeRange.lowerBound))",
               "\(Int(NotchLyricRowMetrics.mainFontSizeRange.upperBound))",
               "\(Int(NotchLyricRowMetrics.secondaryFontSize))")
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "character", title: L10n.t("字体")) {
                FontFamilyPicker(selection: $settings.notchFontFamilyName)
            }
            CardDivider()
            SettingsRow(
                icon: "bold",
                title: L10n.t("粗细"),
                help: L10n.t("主行的笔画粗细；副行和展开时的下一句预览比它细一档")
            ) {
                Picker("", selection: $settings.notchFontWeight) {
                    ForEach(OverlayFontWeight.allCases, id: \.self) { weight in
                        Text(weight.displayName).tag(weight)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            CardDivider()
            SettingsRow(icon: "textformat.size", title: L10n.t("字号"), help: sizeHelp) {
                HStack(spacing: 8) {
                    SteppedSlider(value: Binding(
                        get: { settings.notchFontSize },
                        set: { newValue in

                            guard newValue != settings.notchFontSize else { return }
                            settings.notchFontSize = newValue
                        }
                    ), in: sizeRange, step: 1)
                        .frame(width: 150)
                    Text(String(format: L10n.t("%@pt"), "\(Int(settings.notchFontSize))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }
}

@MainActor
struct NotchExpandedSettingsRows: View {
    var body: some View {
        VStack(spacing: 0) {
            NotchBehaviorToggleRow(item: .expandedShowsControls)
            CardDivider()
            NotchBehaviorToggleRow(item: .expandedShowsLyricsOffset)
            CardDivider()
            NotchBehaviorToggleRow(item: .expandedShowsQuickActions)
            CardDivider()
            SettingsRow(
                icon: "person.text.rectangle",
                title: L10n.t("曲目信息"),
                help: L10n.t("展开时在歌词行上方多一块曲目信息，四项各自独立；全关则这一块不占位置。")
            )
            CardDivider()
            NotchBehaviorToggleSubRow(item: .expandedShowsArtwork)
            CardDivider()
            NotchBehaviorToggleSubRow(item: .expandedShowsTrackTitle)
            CardDivider()
            NotchBehaviorToggleSubRow(item: .expandedShowsArtist)
            CardDivider()
            NotchBehaviorToggleSubRow(item: .expandedShowsAlbum)
        }
    }
}

@MainActor
struct NotchBehaviorSettingsRows: View {
    var body: some View {
        VStack(spacing: 0) {
            NotchBehaviorToggleRow(item: .collapseWhenPaused)

            CardDivider()
            AutoHideSettingsRows(surface: .notch)
        }
    }
}

struct NotchLyricRowPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("歌词行"), width: 470) {
            NotchLyricRowSettingsRows()
        }
    }
}

struct NotchFontPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("字体")) {
            NotchFontSettingsRows()
        }
    }
}

struct NotchExpandedPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("展开态"), width: 340) {
            NotchExpandedSettingsRows()
        }
    }
}

struct NotchBehaviorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("行为"), width: 420) {
            NotchBehaviorSettingsRows()
        }
    }
}

private struct NotchAllSettingsDrawer: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var isExpanded = false

    @Environment(\.settingsSearchPendingDrawer) private var pendingSearchDrawer

    var body: some View {
        SettingsCard {
            disclosureHeader
            if isExpanded {
                CardDivider()
                group(L10n.t("风格")) { NotchStyleSettingsRows() }
                CardDivider()
                group(L10n.t("屏幕")) { NotchScreenSettingsRows(onScreenChange: {}) }
                CardDivider()
                group(L10n.t("左耳")) { NotchEarSettingsRows(side: .left) }
                CardDivider()
                group(L10n.t("右耳")) { NotchEarSettingsRows(side: .right) }
                CardDivider()
                widthRow
                CardDivider()
                expandedWidthRow
                CardDivider()
                group(L10n.t("歌词行")) { NotchLyricRowSettingsRows() }
                CardDivider()
                group(L10n.t("字体")) { NotchFontSettingsRows() }
                CardDivider()
                group(L10n.t("展开态")) { NotchExpandedSettingsRows() }
                CardDivider()
                group(L10n.t("行为")) { NotchBehaviorSettingsRows() }
                CardDivider()
                resetRow
            }
        }
        .onAppear { expandForSearchIfNeeded() }
        .onChange(of: pendingSearchDrawer) { _, _ in expandForSearchIfNeeded() }

    }

    private func expandForSearchIfNeeded() {
        guard pendingSearchDrawer == .notch else { return }
        if !isExpanded {
            withAnimation(.settingsCardReveal) { isExpanded = true }
        }
        SettingsSearchRouter.shared.consumeDrawer(.notch)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Group {
            SettingsCardHeader(title: title)
            CardDivider()
            content()
        }
    }

    private var resetRow: some View {
        SettingsRow(
            icon: "arrow.uturn.backward",
            title: L10n.t("恢复默认"),
            subtitle: L10n.t("不含宽度和总开关")
        ) {
            Button(L10n.t("恢复")) { NotchStyleDefaults.restoreDefaults() }
        }
    }

    private var widthRow: some View {
        SettingsRow(icon: "arrow.left.and.right", title: L10n.t("宽度")) {
            HStack(spacing: 8) {

                SteppedSlider(value: Binding(
                    get: { NotchEditorStage.effectiveWidth(baseWidth: settings.notchContentWidth) },
                    set: { NotchEditorStage.commitWidths(steady: $0) }
                ), in: NotchEditorStage.usableWidthRangeOnCurrentScreen, step: 10)
                .frame(width: 150)
                Text(String(format: L10n.t("%@pt"),
                            "\(Int(NotchEditorStage.effectiveWidth(baseWidth: settings.notchContentWidth)))"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    private var expandedWidthRow: some View {
        SettingsRow(icon: "arrow.left.and.right.square", title: L10n.t("展开宽度")) {
            HStack(spacing: 8) {
                SteppedSlider(value: Binding(
                    get: {
                        NotchEditorStage.effectiveExpandedWidth(
                            steadyBase: settings.notchContentWidth,
                            expandedBase: settings.notchExpandedContentWidth)
                    },
                    set: { NotchEditorStage.commitWidths(expanded: $0) }
                ), in: NotchEditorStage.usableExpandedWidthRangeOnCurrentScreen, step: 10)
                .frame(width: 150)
                Text(String(format: L10n.t("%@pt"),
                            "\(Int(NotchEditorStage.effectiveExpandedWidth(steadyBase: settings.notchContentWidth, expandedBase: settings.notchExpandedContentWidth)))"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    private var disclosureHeader: some View {
        Button {
            withAnimation(.settingsCardReveal) { isExpanded.toggle() }
        } label: {
            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(L10n.t("全部设置"))
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("全部设置"))
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityValue(isExpanded ? L10n.t("已展开") : L10n.t("已折叠"))
    }
}

@MainActor
private final class PlayerTabStores: ObservableObject {

    @Published private(set) var browserJSVerifiedAt: [String: Date] = [:]
    @Published private(set) var browserPlatformPairs: [String: Set<String>] = [:]
    @Published private(set) var manualBrowserFamilies: [String: String] = [:]
    @Published private(set) var launchPlayersOnLyrimuseOpen: Set<PlaybackPlayer> = []
    @Published private(set) var quitWithPlayers: Set<PlaybackPlayer> = []

    @Published private(set) var players: Set<PlaybackPlayer> = [.auto]
    @Published private(set) var trustedPlayers: [String: String] = [:]
    @Published private(set) var launchLyrimuseOnPlayers: Set<PlaybackPlayer> = []

    @Published private(set) var mediaControlState: MediaControlHealth.State = .unknown
    private var subs: [AnyCancellable] = []

    init() {
        let s = AppSettings.shared
        let f = FeatureSettingsStore.shared
        let h = MediaControlHealth.shared
        browserJSVerifiedAt = s.browserJSVerifiedAt
        browserPlatformPairs = s.browserPlatformPairs
        manualBrowserFamilies = s.manualBrowserFamilies
        launchPlayersOnLyrimuseOpen = s.launchPlayersOnLyrimuseOpen
        quitWithPlayers = s.quitWithPlayers
        players = f.players
        trustedPlayers = f.trustedPlayers
        launchLyrimuseOnPlayers = f.launchLyrimuseOnPlayers
        mediaControlState = h.state
        subs = [
            s.$browserJSVerifiedAt.removeDuplicates().sink { [weak self] in self?.browserJSVerifiedAt = $0 },
            s.$browserPlatformPairs.removeDuplicates().sink { [weak self] in self?.browserPlatformPairs = $0 },
            s.$manualBrowserFamilies.removeDuplicates().sink { [weak self] in self?.manualBrowserFamilies = $0 },
            s.$launchPlayersOnLyrimuseOpen.removeDuplicates().sink { [weak self] in self?.launchPlayersOnLyrimuseOpen = $0 },
            s.$quitWithPlayers.removeDuplicates().sink { [weak self] in self?.quitWithPlayers = $0 },
            f.$players.removeDuplicates().sink { [weak self] in self?.players = $0 },
            f.$trustedPlayers.removeDuplicates().sink { [weak self] in self?.trustedPlayers = $0 },
            f.$launchLyrimuseOnPlayers.removeDuplicates().sink { [weak self] in self?.launchLyrimuseOnPlayers = $0 },
            h.$state.removeDuplicates().sink { [weak self] in self?.mediaControlState = $0 },
        ]
    }

}

private struct PlayerSettingsTab: View {
    @StateObject private var stores = PlayerTabStores()

    @State private var automationStatus: MusicAutomationPermissionStatus = .notDetermined

    @State private var isRequestingAutomation = false
    @State private var automationRequestTimedOut = false

    @State private var collectorState: LaunchdJobState = .notRegistered
    @State private var isTogglingCollectorService = false

    @State private var collectorEnableFailed = false

    @State private var collectorVersionMismatch: (appVersion: String, collectorVersion: String)?

    @State private var ungatedNowPlaying: MediaControlClient.UngatedNowPlaying?

    @State private var notificationsDenied = false

    var body: some View {
        SettingsPage(
            title: L10n.t("播放器")
        ) {
            playerCard
            browserAutomationCard
            unknownPlayerCard
            notificationDeniedCard
            trustedPlayersCard
            companionCard
            permissionCard
            collectorCard
        }
        .id(L10n.current)
        .onAppear { refreshUngatedNowPlaying(); refreshNotificationStatus(); refreshBrowserLiveStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotificationStatus()

            refreshBrowserLiveStatus()
        }

        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshUngatedNowPlaying()
            refreshBrowserLiveStatus()
        }
        .onChange(of: automationRefreshTick) { _, _ in refreshBrowserLiveStatus() }
        .onChange(of: stores.browserPlatformPairs) { _, _ in refreshBrowserLiveStatus() }
    }

    private func refreshUngatedNowPlaying() {
        guard let seen = MediaControlClient.lastUngatedNowPlaying,
              Date().timeIntervalSince(seen.at) < 15 else {
            if ungatedNowPlaying != nil { ungatedNowPlaying = nil }
            return
        }
        if ungatedNowPlaying != seen { ungatedNowPlaying = seen }
    }

    private func refreshNotificationStatus() {
        Task {
            let denied = await UnknownPlayerNotifier.authorizationStatus() == .denied
            if notificationsDenied != denied { notificationsDenied = denied }
        }
    }

    private var playerCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("播放器"))
            SettingsRawRow {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(PlaybackPlayer.displayOrder) { player in
                        PlayerChoiceCard(player: player,
                                         isSelected: stores.players.contains(player),
                                         isCoveredByAuto: isCoveredByAuto(player)) {
                            toggleSelectedPlayer(player)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if stores.players.contains(.auto) {
                SettingsNote {
                    Text(L10n.t("「自动识别」开着时会认出所有已知和你信任过的播放器，上面的勾选暂不生效。想只认其中几个，取消勾选它。"))
                }
            }
        }
    }

    private func isCoveredByAuto(_ player: PlaybackPlayer) -> Bool {
        player != .auto && stores.players.contains(.auto) && !stores.players.contains(player)
    }

    private func toggleSelectedPlayer(_ player: PlaybackPlayer) {
        FeatureSettingsStore.shared.togglePlayer(player)
    }

    @ViewBuilder
    private var unknownPlayerCard: some View {

        if let seen = ungatedNowPlaying,
           UnknownPlayerAlert.shouldOffer(
               bundleID: seen.bundleID, artist: seen.artist, album: seen.album,
               observedAt: seen.at, isAutoDetect: stores.players.contains(.auto), now: Date(),
               isAccepted: { TrustedPlayers.isAccepted($0) }) {
            SettingsCard {
                SettingsRow(

                    icon: "questionmark.app.dashed",
                    iconImage: AppIconResolver.icon(forBundleID: seen.bundleID),
                    title: FeatureSettingsStore.appDisplayName(forBundleID: seen.bundleID) ?? seen.bundleID,
                    subtitle: unknownPlayerSubtitle(seen),
                    help: L10n.t("信任之后它跟内置播放器完全同权:显示歌词，也会记进收听历史")
                ) {
                    Button(L10n.t("加入信任列表")) {
                        Task { await FeatureSettingsStore.shared.trust(bundleID: seen.bundleID) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notificationDeniedCard: some View {
        if stores.players.contains(.auto), notificationsDenied {
            SettingsCard {
                SettingsRow(
                    icon: "bell.slash",
                    title: L10n.t("新播放器提醒"),
                    subtitle: L10n.t("系统通知已关闭")
                ) {
                    Button(L10n.t("打开系统设置")) {
                        if let url = URL(string:
                            "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    private func unknownPlayerSubtitle(_ seen: MediaControlClient.UngatedNowPlaying) -> String {
        let what = [seen.artist, seen.title].filter { !$0.isEmpty }.joined(separator: " - ")
        if what.isEmpty { return seen.bundleID }
        return seen.bundleID + " · " + String(format: L10n.t("正在放：%@"), what)
    }

    @ViewBuilder
    private var trustedPlayersCard: some View {
        if !stores.trustedPlayers.isEmpty {
            SettingsCard {

                SettingsCardHeader(title: L10n.t("已信任的播放器"))

                ForEach(stores.trustedPlayers.keys.sorted(), id: \.self) { bundleID in
                    if bundleID != stores.trustedPlayers.keys.sorted().first { CardDivider() }

                    SettingsRow(
                        icon: "checkmark.seal",
                        iconImage: AppIconResolver.icon(forBundleID: bundleID),
                        title: displayNameForTrusted(bundleID),
                        subtitle: bundleID
                    ) {
                        Button(L10n.t("移除")) {
                            Task {
                                await FeatureSettingsStore.shared.untrust(bundleID: bundleID)

                                unpairBrowserEverywhere(bundleID)
                            }
                        }
                    }
                }
            }
        }
    }

    private func displayNameForTrusted(_ bundleID: String) -> String {
        if let stored = stores.trustedPlayers[bundleID], !stored.isEmpty { return stored }
        return FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID
    }

    private func addablePlatformBrowsers(platformID: String) -> [String] {
        BrowserPairing.addableBrowsers(platformID: platformID)
    }

    @State private var browserPickerError: String?

    private func chooseBrowserFromApplications(platformID: String) {
        browserPickerError = BrowserPairing.chooseFromApplications(
            platformID: platformID,
            revealPairing: { bundleID in
                expandedBrowserBundleID = bundleID
                expandedBrowserPlatformID = platformID
            },
            automationDidResolve: { automationRefreshTick &+= 1 })
    }

    private func rememberManualBrowser(_ bundleID: String, family: BrowserAutomationPermission.Family) {
        BrowserPairing.rememberManualBrowser(bundleID, family: family)
    }

    private func trustAndPairBrowser(_ bundleID: String, platformID: String) {
        BrowserPairing.trustAndPair(
            bundleID, platformID: platformID,
            revealPairing: {
                expandedBrowserBundleID = bundleID
                expandedBrowserPlatformID = platformID
            },
            automationDidResolve: { automationRefreshTick &+= 1 })
    }

    @State private var automationRefreshTick = 0

    struct BrowserLiveStatus: Equatable {

        var jsSwitch: BrowserAutomationPermission.Status
        var running: Bool

        var automation: MusicAutomationPermissionStatus?
    }
    @State private var browserLiveStatus: [String: BrowserLiveStatus] = [:]
    @State private var browserLiveStatusInFlight = false

    private func refreshBrowserLiveStatus() {
        guard !browserLiveStatusInFlight else { return }
        let ids = Set(stores.browserPlatformPairs.values.flatMap { $0 })
        guard !ids.isEmpty else {
            if !browserLiveStatus.isEmpty { browserLiveStatus = [:] }
            return
        }
        let running = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, MusicAutomationPermission.isRunning(bundleID: $0))
        })
        browserLiveStatusInFlight = true
        Task {
            let fresh = await Task.detached(priority: .utility) { () -> [String: BrowserLiveStatus] in
                var out: [String: BrowserLiveStatus] = [:]
                for id in ids {
                    let isRunning = running[id] ?? false
                    out[id] = BrowserLiveStatus(
                        jsSwitch: BrowserAutomationPermission.status(forBundleID: id),
                        running: isRunning,

                        automation: isRunning
                            ? MusicAutomationPermission.check(bundleID: id, askIfNeeded: false) : nil)
                }
                return out
            }.value
            browserLiveStatusInFlight = false
            if fresh != browserLiveStatus { browserLiveStatus = fresh }
        }
    }

    private func requestBrowserAutomation(bundleID: String) {
        Task {
            _ = await MusicAutomationPermission.requestWithTimeout(
                bundleID: bundleID, launchIfNeeded: true)
            automationRefreshTick &+= 1
        }
    }

    private func addBrowserMenuLabel(_ bundleID: String) -> String {
        let name = FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID
        guard stores.trustedPlayers[bundleID] == nil else { return name }
        return name + L10n.t("（未信任，选择后自动信任）")
    }

    private func pairBrowser(_ bundleID: String, platformID: String) {
        BrowserPairing.pair(bundleID, platformID: platformID)
    }

    private func unpairBrowserEverywhere(_ bundleID: String) {
        var pairs = stores.browserPlatformPairs
        var changed = false
        for (platformID, ids) in pairs where ids.contains(bundleID) {
            var next = ids
            next.remove(bundleID)
            if next.isEmpty { pairs.removeValue(forKey: platformID) } else { pairs[platformID] = next }
            changed = true
        }

        guard changed else { return }
        AppSettings.shared.browserPlatformPairs = pairs
        BrowserPositionProbe.shared.platformBrowserPairs = pairs
        forgetManualBrowserIfUnpaired(bundleID)
    }

    private func forgetManualBrowserIfUnpaired(_ bundleID: String) {
        BrowserPairing.forgetManualBrowserIfUnpaired(bundleID)
    }

    private func unpairBrowser(_ bundleID: String, platformID: String) {
        BrowserPairing.unpair(bundleID, platformID: platformID)
    }

    @State private var expandedBrowserBundleID: String?
    @State private var expandedBrowserPlatformID: String?

    @ViewBuilder
    private var browserAutomationCard: some View {

        let anySupportedInstalled = (BrowserAutomationPermission.knownBrowserBundleIDs
            + Array(stores.manualBrowserFamilies.keys))
            .contains { BrowserAutomationPermission.isInstalled(bundleID: $0)
                        && BrowserAutomationPermission.family(forBundleID: $0) != nil }
        if anySupportedInstalled {
            SettingsCard {
                SettingsCardHeader(
                    title: L10n.t("网页播放器"),
                    help: L10n.t("网页播放器不会主动汇报精确进度，切歌后需要这个开关才能立刻校准。")
                )
                SettingsRawRow {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(BrowserPositionProbe.supportedPlatforms) { platform in
                            browserPlatformCard(platform: platform)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
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

            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                automationRefreshTick &+= 1

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    automationRefreshTick &+= 1
                }
            }
        }
    }

    private func browserPlatformCard(platform: BrowserPositionProbe.BrowserMusicPlatform) -> some View {

        let pairedBundleIDs = (stores.browserPlatformPairs[platform.id] ?? [])
            .filter { BrowserAutomationPermission.isInstalled(bundleID: $0) }
            .sorted()
        let addable = addablePlatformBrowsers(platformID: platform.id)
        return VStack(spacing: 6) {
            if let icon = WebPlatformIcon.image(platform.id) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
            }
            Text(platform.displayName)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                ForEach(pairedBundleIDs, id: \.self) { bundleID in
                    browserAvatarButton(bundleID: bundleID, platformID: platform.id)
                }

                do {
                    Menu {
                        ForEach(addable, id: \.self) { bundleID in
                            Button(addBrowserMenuLabel(bundleID)) { trustAndPairBrowser(bundleID, platformID: platform.id) }
                        }
                        Divider()
                        Button(L10n.t("从应用程序中选择…")) { chooseBrowserFromApplications(platformID: platform.id) }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 15))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(pairedBundleIDs.isEmpty ? Color.primary.opacity(0.05) : Color.accentColor.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(pairedBundleIDs.isEmpty ? Color.clear : Color.accentColor, lineWidth: 1.5)
        )
    }

    private func browserAvatarButton(bundleID: String, platformID: String) -> some View {
        Button {
            expandedBrowserBundleID = bundleID
            expandedBrowserPlatformID = platformID
        } label: {
            Self.browserIconView(bundleID: bundleID, size: 22)

                .overlay(alignment: .topTrailing) {
                    if browserSetupIncomplete(bundleID: bundleID) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white, Color.orange)
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(browserSetupIncomplete(bundleID: bundleID)
              ? L10n.t("还没配置完，点开看看还差什么")
              : L10n.t("已配置好，点开可查看或移除"))
        .popover(isPresented: Binding(
            get: { expandedBrowserBundleID == bundleID && expandedBrowserPlatformID == platformID },
            set: { if !$0 { expandedBrowserBundleID = nil; expandedBrowserPlatformID = nil } }
        )) {
            browserPermissionPopover(bundleID: bundleID, platformID: platformID)
        }
    }

    private func browserPermissionPopover(bundleID: String, platformID: String) -> some View {

        let live = browserLiveStatus[bundleID]
        let status = live?.jsSwitch ?? .unknown

        let running = live?.running ?? false

        let liveAutomation: MusicAutomationPermissionStatus? = running ? live?.automation : nil
        let verifiedBefore = stores.browserJSVerifiedAt[bundleID] != nil
        let automation: MusicAutomationPermissionStatus? =
            liveAutomation ?? (verifiedBefore ? .authorized : nil)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Self.browserIconView(bundleID: bundleID, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayNameForTrusted(bundleID)).font(.system(size: 13))

                    Text(browserJSSwitchCaption(bundleID: bundleID, status: status))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(browserAutomationCaption(automation, live: liveAutomation != nil))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !browserJSLikelyWorking(bundleID: bundleID) {
                Text(browserManualEnableHint(bundleID: bundleID))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.t("勾完要退出并重新打开这个浏览器才生效——这个开关只在浏览器启动时读一次。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let r = browserSelfTestResults[bundleID] {

                    Text(browserSelfTestCaption(r, switchDisabled: status == .disabled))
                        .font(.system(size: 11))
                        .foregroundStyle(r == .ok ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L10n.t("检测是否已生效")) { runBrowserSelfTest(bundleID: bundleID) }
                        .disabled(browserSelfTestRunning.contains(bundleID))
                    Spacer()

                    Button(L10n.t("打开该浏览器")) {
                        guard let appURL = NSWorkspace.shared
                            .urlForApplication(withBundleIdentifier: bundleID) else { return }
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = true
                        NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                    }
                }
            }

            if browserJSLikelyWorking(bundleID: bundleID) {
                if let r = browserSelfTestResults[bundleID] {

                    Text(browserSelfTestCaption(r, switchDisabled: status == .disabled))
                        .font(.system(size: 11))
                        .foregroundStyle(r == .ok ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L10n.t("重新检测")) { runBrowserSelfTest(bundleID: bundleID) }
                        .disabled(browserSelfTestRunning.contains(bundleID))
                    Spacer()
                }
            }
            if automation != .authorized {
                HStack {
                    Spacer()
                    if automation == .denied {

                        Button(L10n.t("打开系统设置")) {
                            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
                        }
                    } else {
                        Button(L10n.t("请求系统授权")) { requestBrowserAutomation(bundleID: bundleID) }
                    }
                }
            }
            Divider()
            HStack {
                Button(L10n.t("移除配对")) {
                    unpairBrowser(bundleID, platformID: platformID)
                    expandedBrowserBundleID = nil
                    expandedBrowserPlatformID = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    @State private var browserSelfTestResults: [String: BrowserPositionProbe.SelfTestResult] = [:]
    @State private var browserSelfTestRunning: Set<String> = []

    private func runBrowserSelfTest(bundleID: String) {
        guard let family = BrowserAutomationPermission.family(forBundleID: bundleID) else { return }
        browserSelfTestRunning.insert(bundleID)
        browserSelfTestResults[bundleID] = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = BrowserPositionProbe.selfTest(bundleID: bundleID, family: family)
            DispatchQueue.main.async {
                browserSelfTestRunning.remove(bundleID)
                browserSelfTestResults[bundleID] = r

                var map = stores.browserJSVerifiedAt
                switch r {
                case .ok:
                    map[bundleID] = Date()
                    AppSettings.shared.browserJSVerifiedAt = map
                case .blocked, .noReply:
                    if map.removeValue(forKey: bundleID) != nil { AppSettings.shared.browserJSVerifiedAt = map }
                case .noTab, .failed:
                    break
                }

                automationRefreshTick &+= 1
            }
        }
    }

    private func browserSelfTestCaption(_ r: BrowserPositionProbe.SelfTestResult,
                                        switchDisabled: Bool = false) -> String {
        switch r {
        case .ok:
            if switchDisabled {
                return L10n.t("✓ 此刻驱动得动——但这是重启前的暂时状态：上面那个开关已经被关掉，重启后就会失效")
            }
            return L10n.t("✓ 已生效——这个浏览器现在可以被驱动了")
        case .noTab: return L10n.t("这个浏览器没在运行，或者一个标签页都没开——打开它并随便开一个网页，再检测一次")
        case .blocked: return L10n.t("还没生效：浏览器回绝了执行 JavaScript 的请求，按上面那条路径再确认一下开关勾上了没有")
        case .noReply: return L10n.t("还没生效：浏览器收下了请求却一直没回应，多半是那个开关还没勾上（有的浏览器不报错、直接不回）。按上面那条路径再确认一下")
        case .failed(let msg): return String(format: L10n.t("检测没通过：%@"), msg)
        }
    }

    private func browserJSSwitchCaption(bundleID: String, status: BrowserAutomationPermission.Status) -> String {
        switch status {
        case .enabled: return L10n.t("已开启")
        case .disabled:

            if browserJSProvenWorking(bundleID: bundleID) {
                return L10n.t("这个开关已经被关掉了——现在还能用，只是因为该浏览器还没重启；重启后就会失效")
            }
            return L10n.t("未开启")
        case .unknown:

            if let at = stores.browserJSVerifiedAt[bundleID] {
                return String(format: L10n.t("上次检测通过（%@）"), Self.verifiedAtFormatter.localizedString(for: at, relativeTo: Date()))
            }
            return L10n.t("无法确认状态（读不到该浏览器的配置文件）")
        case .unsupported: return ""
        }
    }

    private static let verifiedAtFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private func browserJSProvenWorking(bundleID: String) -> Bool {
        if browserSelfTestResults[bundleID] == .ok { return true }
        return stores.browserJSVerifiedAt[bundleID] != nil
    }

    private func browserJSLikelyWorking(bundleID: String) -> Bool {

        let status = browserLiveStatus[bundleID]?.jsSwitch ?? .unknown

        if status == .disabled { return false }

        if let r = browserSelfTestResults[bundleID] {
            switch r {
            case .ok: return true
            case .blocked, .noReply, .failed: return false
            case .noTab: break
            }
        }
        if status == .enabled { return true }
        return stores.browserJSVerifiedAt[bundleID] != nil
    }

    private func browserManualEnableHint(bundleID: String) -> String {
        switch bundleID {
        case "com.google.Chrome":

            return L10n.t("在 Chrome 菜单栏依次打开「显示 → 开发者 → 允许 Apple 事件中的 JavaScript」。")
        case "com.microsoft.edgemac":
            return L10n.t("在 Edge 菜单栏依次打开「查看 → 开发人员 → 允许 Apple 事件中的 JavaScript」。")
        case "company.thebrowser.Browser":
            return L10n.t("在 Arc 菜单栏依次打开「View → Developer → Allow JavaScript from Apple Events」。Arc 的这几个菜单项在中文系统下也是英文。")
        case "com.apple.Safari":
            return L10n.t("Safari 在设置里，不在菜单栏：先到「Safari 浏览器 → 设置 → 高级」勾上「显示网页开发者功能」，设置里就会多出「开发」一栏，在那里勾上「允许Apple事件中的JavaScript」。")
        default:
            return L10n.t("到该浏览器的开发者菜单里打开「允许 Apple 事件中的 JavaScript」。")
        }
    }

    private func browserSetupIncomplete(bundleID: String) -> Bool {

        guard let live = browserLiveStatus[bundleID] else { return false }

        if !browserJSLikelyWorking(bundleID: bundleID) { return true }
        guard live.running else { return false }
        return live.automation != .authorized
    }

    private func browserAutomationCaption(_ status: MusicAutomationPermissionStatus?,
                                          live: Bool = true) -> String {
        switch status {
        case .authorized:

            return live ? L10n.t("系统自动化授权：已授权")
                        : L10n.t("系统自动化授权：上次检测时已授权")
        case .denied: return L10n.t("系统自动化授权：已拒绝，需要在系统设置里打开")
        case .notDetermined: return L10n.t("系统自动化授权：尚未授权")
        case nil: return L10n.t("系统自动化授权：这个浏览器没在运行，查不到当前状态")
        }
    }

    private static func browserIconView(bundleID: String, size: CGFloat) -> some View {
        Group {
            if let icon = AppIconResolver.icon(forBundleID: bundleID) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed")
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }

    @ViewBuilder
    private var permissionCard: some View {

        if stores.players.contains(.appleMusic) {
            SettingsCard {
                SettingsRow(
                    icon: automationStatusIconName,
                    iconTint: automationStatusIconColor,
                    title: L10n.t("Apple Music 自动化"),

                    subtitle: automationStatusCaption,
                    help: L10n.t("没有它读不到播放状态")
                ) {
                    if isRequestingAutomation {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(automationActionTitle) { handleAutomationAction() }
                    }
                }
                if isRequestingAutomation {
                    CardDivider()
                    SettingsNote {
                        if automationRequestTimedOut {
                            Text(L10n.t("这次请求耗时有点久。如果你已经看到系统弹窗，请去处理它；找不到弹窗的话，可以直接去系统设置里手动开启"))
                            Button(L10n.t("打开系统设置")) {
                                NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
                            }
                        } else {
                            Text(L10n.t("请查看屏幕上弹出的系统授权对话框，选择「允许」"))
                        }
                    }
                }
            }
            .onAppear { refreshAutomationStatus() }

            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshAutomationStatus(clearRequestUI: true)
            }
        }
    }

    private var collectorCard: some View {
        SettingsCard {
            SettingsRow(
                icon: collectorStatusIconName,
                iconTint: collectorStatusIconColor,
                title: L10n.t("后台采集服务"),

                subtitle: collectorStatusCaption,
                help: L10n.t("读取播放状态、抓歌词和封面")
            ) {

                if isTogglingCollectorService {
                    ProgressView().controlSize(.small)
                } else if !collectorState.isRunning {
                    Button(L10n.t("启用")) { enableCollectorService() }
                }
            }

            if collectorEnableFailed {
                CardDivider()
                SettingsNote {
                    Text(L10n.t("启用失败，可能是权限或系统限制导致后台服务没能正常启动，导出诊断信息能看到具体原因，也方便反馈问题"))
                    Button(L10n.t("导出诊断…")) { exportDiagnostics() }
                }
            }

            if case .unavailable(let message) = stores.mediaControlState {
                CardDivider()
                SettingsNote {
                    Text(L10n.t("系统的媒体信息通道在这台机器上不可用，QQ 音乐 / 网易云音乐的播放检测会受影响（Apple Music、Spotify 不受影响）"))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            if let mismatch = collectorVersionMismatch {
                CardDivider()
                SettingsNote {
                    Text(L10n.t("这个版本打包时漏了同步后台采集服务的版本号。不影响功能，采集服务的实际代码跟 App 是同一个版本，不需要你做任何处理"))
                    Text("App \(mismatch.appVersion) · \(L10n.t("采集服务")) \(mismatch.collectorVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }

        .onAppear {
            refreshCollectorState()
            refreshCollectorVersionCheck()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshCollectorState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCollectorState()
        }
    }

    private var linkageCandidates: [PlaybackPlayer] {
        let set = PlayerLinkage.candidates(selectedPlayers: stores.players)
        return PlaybackPlayer.displayOrder.filter { set.contains($0) }
    }

    private var companionCard: some View {
        SettingsCard {
            SettingsCardHeader(
                title: L10n.t("播放器联动"),
                help: L10n.t("每一项都按播放器单独勾选；选了「自动识别」时五个播放器都可勾"))
            CardDivider()
            PlayerLinkageRow(
                icon: "arrow.up.forward.app",
                title: L10n.t("打开 Lyrimuse 时启动"),
                help: L10n.t("Lyrimuse 启动时把勾选的播放器一起打开，已经在跑的不动，也不抢焦点"),
                candidates: linkageCandidates,
                chosen: stores.launchPlayersOnLyrimuseOpen
            ) { AppSettings.shared.launchPlayersOnLyrimuseOpen = $0 }
            CardDivider()
            PlayerLinkageRow(
                icon: "arrow.down.app",
                title: L10n.t("跟随播放器启动"),
                help: L10n.t("检测到播放器打开时自动拉起 Lyrimuse"),
                candidates: linkageCandidates,
                chosen: stores.launchLyrimuseOnPlayers
            ) { chosen in
                FeatureSettingsStore.shared.launchLyrimuseOnPlayers = chosen
                Task { await FeatureSettingsStore.shared.save() }
            }
            CardDivider()
            PlayerLinkageRow(
                icon: "power",
                title: L10n.t("跟随播放器退出"),
                help: L10n.t("勾选的播放器全部退出后，等 5 秒再退出 Lyrimuse；期间任一个重新打开就取消。设置、歌词管理或歌词窗口开着时不退"),
                candidates: linkageCandidates,
                chosen: stores.quitWithPlayers
            ) { AppSettings.shared.quitWithPlayers = $0 }
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

    private var collectorStatusCaption: String {
        switch collectorState {
        case .running:
            return L10n.t("运行中")
        case .registeredNotRunning(let code):

            if let code {
                return String(format: L10n.t("已安装但未运行（上次退出码 %d）"), code)
            }
            return L10n.t("已安装但未运行")
        case .unknown:
            return L10n.t("状态未知")
        case .notRegistered:
            return L10n.t("未运行")
        }
    }

    private var collectorStatusIconName: String {
        switch collectorState {
        case .running: return "checkmark.circle.fill"
        case .registeredNotRunning, .unknown: return "exclamationmark.triangle.fill"
        case .notRegistered: return "xmark.circle.fill"
        }
    }

    private var collectorStatusIconColor: Color {
        switch collectorState {
        case .running: return .green
        case .registeredNotRunning, .unknown: return .orange
        case .notRegistered: return .red
        }
    }

    private func refreshAutomationStatus(clearRequestUI: Bool = false) {
        Task {
            let latest = await Task.detached(priority: .utility) {
                MusicAutomationPermission.check(askIfNeeded: false)
            }.value
            if latest != automationStatus { automationStatus = latest }
            if clearRequestUI, latest != .notDetermined {
                isRequestingAutomation = false
                automationRequestTimedOut = false
            }
        }
    }

    @State private var collectorStateInFlight = false

    private func refreshCollectorState() {
        guard !collectorStateInFlight else { return }
        collectorStateInFlight = true
        Task {
            let latest = await Task.detached(priority: .utility) { CollectorServiceManager.state }.value
            collectorStateInFlight = false
            if latest != collectorState { collectorState = latest }
        }
    }

    private func refreshCollectorVersionCheck() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        Task.detached(priority: .utility) {
            guard let collectorVersion = CollectorServiceManager.bundledCollectorVersion(),
                  collectorVersion != appVersion else {

                await MainActor.run { collectorVersionMismatch = nil }
                return
            }
            await MainActor.run {
                collectorVersionMismatch = (appVersion: appVersion, collectorVersion: collectorVersion)
            }
        }
    }

    private func enableCollectorService() {
        isTogglingCollectorService = true
        collectorEnableFailed = false
        Task {
            let state = await CollectorServiceManager.setEnabledAndWait(true)
            AppSettings.shared.collectorServiceEnabled = true
            collectorState = state
            isTogglingCollectorService = false

            collectorEnableFailed = !state.isRunning
        }
    }

    private func exportDiagnostics() {
        DiagnosticsExporter.exportInteractively()
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var showExportConfigWarning = false
    @State private var showImportConfigConfirm = false
    @State private var showICloudExportWarning = false

    @State private var iCloudSnapshot: ICloudConfigStore.Snapshot?
    @State private var iCloudBusy = false
    @State private var iCloudMessage: String?

    @State private var configMessage: String?

    @State private var iCloudJustSaved = false

    @State private var iCloudJustSavedToken = 0
    @State private var pendingImportData: Data?

    @State private var pendingImportLyrics: Data?

    @State private var pendingImportLyricsCount = 0

    @State private var pendingImportFolder: URL?
    @State private var showClearConfigWarning = false

    var body: some View {
        SettingsPage(
            title: L10n.t("通用"),

            subtitle: L10n.t("菜单栏图标、语言与启动，以及备份搬家")
        ) {

            SettingsCard {
                SettingsCardHeader(title: L10n.t("菜单栏与 Dock"))
                CardDivider()

                SettingsRow(
                    icon: "menubar.rectangle",
                    title: L10n.t("菜单栏图标")
                ) {
                    Text(settings.menuBarIconStyle.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                SettingsRawRow {

                    MenuBarIconPicker()
                }
                CardDivider()

                SettingsRow(
                    icon: "figure.dance",
                    title: L10n.t("随播放律动"),
                    help: L10n.t("播放时图标动起来，暂停即静止")
                ) {
                    Toggle("", isOn: $settings.menuBarIconAnimates)
                }
                CardDivider()
                SettingsRow(
                    icon: "macwindow",
                    title: L10n.t("在 Dock 中显示"),
                    help: L10n.t("关闭后只保留菜单栏图标，不占 Dock 位置")
                ) {
                    Toggle("", isOn: $settings.showInDock)
                }
            }

            SettingsCard {
                SettingsCardHeader(title: L10n.t("语言与启动"))
                CardDivider()

                SettingsRow(icon: "globe", title: L10n.t("语言")) {
                    Picker("", selection: $settings.appLanguage) {
                        Text(L10n.t("跟随系统")).tag("system")
                        Text(L10n.t("简体中文")).tag("zh-hans")

                        Text(L10n.t("繁體中文")).tag("zh-hant")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                CardDivider()
                SettingsRow(icon: "power", title: L10n.t("开机启动")) {
                    Toggle("", isOn: $settings.launchAtLoginEnabled)
                }
            }

            SettingsCard {

                SettingsCardHeader(title: L10n.t("备份与迁移")) {

                    Menu {
                        Button(L10n.t("更换备份文件夹…")) { chooseBackupFolder() }
                        if ICloudConfigStore.usingCustomFolder {
                            Button(L10n.t("改回 iCloud")) {
                                ICloudConfigStore.setCustomFolder(nil)
                                iCloudSnapshot = ICloudConfigStore.latestSnapshot()
                            }
                        }

                        Divider()

                        Button(L10n.t("打开备份文件夹")) {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [ICloudConfigStore.preparedFolderURL()])
                        }
                    } label: {
                        Text(L10n.t("备份文件夹…"))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                CardDivider()

                SettingsRow(
                    icon: ICloudConfigStore.usingCustomFolder ? "folder" : "icloud",
                    title: ICloudConfigStore.usingCustomFolder
                        ? L10n.t("备份文件夹") : L10n.t("iCloud 备份"),
                    subtitle: iCloudSubtitle
                ) {
                    HStack(spacing: 8) {
                        if iCloudBusy { ProgressView().controlSize(.small) }
                        Button {
                            showICloudExportWarning = true
                        } label: {
                            if iCloudJustSaved {
                                Label(L10n.t("已保存"), systemImage: "checkmark")
                            } else {
                                Text(iCloudSnapshot == nil
                                    ? (ICloudConfigStore.usingCustomFolder
                                        ? L10n.t("存一份") : L10n.t("存到 iCloud"))
                                    : L10n.t("更新备份"))
                            }
                        }

                        .frame(minWidth: 88)
                        .disabled(!ICloudConfigStore.isAvailable)
                        if iCloudSnapshot != nil {

                            Button(L10n.t("恢复这份")) { importFromICloud() }
                                .disabled(!ICloudConfigStore.isAvailable)
                        }
                    }
                }
                if let iCloudMessage {
                    CardDivider()
                    SettingsNote { Text(iCloudMessage) }
                }
                CardDivider()

                SettingsRow(
                    icon: "doc.badge.gearshape",
                    title: L10n.t("设置文件"),

                    subtitle: L10n.t("含明文凭证；导入会覆盖全部设置并重启"),
                    help: L10n.t("歌词库是同名的第二个文件，搬家时两个都要拷。\n凭证别发给别人；导入连已连接的账号、播放数据发往的地址一起覆盖")
                ) {
                    HStack(spacing: 8) {
                        Button(L10n.t("导出…")) { showExportConfigWarning = true }
                        Button(L10n.t("从文件导入…")) { pickConfigFileToImport() }
                    }
                }
                if let configMessage {
                    CardDivider()
                    SettingsNote { Text(configMessage) }
                }
            }
            .onAppear {
                iCloudSnapshot = ICloudConfigStore.latestSnapshot()
            }

            .alert(L10n.t("确定要存到 iCloud 吗？"), isPresented: $showICloudExportWarning) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("存到 iCloud")) {

                    Task { @MainActor in
                        guard let data = ConfigPortability.buildExportData() else { return }
                        let name = ConfigPortability.suggestedFilename()
                        guard ICloudConfigStore.write(data, filename: name) != nil else {
                            iCloudMessage = L10n.t("写入 iCloud 失败，可以改用下面的「导出…」存成文件")
                            return
                        }

                        var note: String?
                        if let archive = await LyricsBackupStore.buildArchive() {
                            let lyricsName = LyricsBackupArchive.sidecarName(forConfigName: name)
                            if ICloudConfigStore.write(archive, filename: lyricsName) == nil {
                                note = L10n.t("设置已存好，但歌词库那一份没写成功")
                            }
                        }

                        iCloudSnapshot = ICloudConfigStore.latestSnapshot()
                        iCloudMessage = note

                        if note == nil {
                            iCloudJustSavedToken += 1
                            let token = iCloudJustSavedToken
                            withAnimation { iCloudJustSaved = true }
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1))
                                guard iCloudJustSavedToken == token else { return }
                                withAnimation { iCloudJustSaved = false }
                            }
                        }
                    }
                }
            }
            .alert(L10n.t("确定要导出设置吗？"), isPresented: $showExportConfigWarning) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("继续导出")) {
                    guard let data = ConfigPortability.buildExportData() else { return }
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = ConfigPortability.suggestedFilename()

                    panel.directoryURL = ICloudConfigStore.isAvailable
                        ? ICloudConfigStore.preparedFolderURL()
                        : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                    if panel.runModal() == .OK, let url = panel.url {

                        do {
                            try data.writeSecurely(to: url)
                        } catch {
                            configMessage = String(format: L10n.t("导出失败：%@"), error.localizedDescription)
                            return
                        }

                        Task { @MainActor in
                            guard let archive = await LyricsBackupStore.buildArchive() else {
                                configMessage = L10n.t("设置已导出；歌词库这次没打包成功，只有设置那一个文件")
                                return
                            }
                            let sidecarName = LyricsBackupArchive.sidecarName(forConfigName: url.lastPathComponent)
                            let sidecar = url.deletingLastPathComponent().appendingPathComponent(sidecarName)
                            do {
                                try archive.writeSecurely(to: sidecar)

                                configMessage = String(format: L10n.t("已导出两个文件：设置和歌词库（%@）。搬到新电脑时两个都要拷"), sidecarName)
                            } catch {
                                configMessage = L10n.t("设置已导出；歌词库那份写盘失败，只有设置那一个文件")
                            }
                        }
                    }
                }
            } message: {
                Text(L10n.t("导出的文件包含账号登录凭证和密钥，妥善保管，不要发给别人。歌词库会另外存成同名的第二个文件，搬家时两个都要拷"))
            }
            .alert(L10n.t("确定要导入这份设置吗？"), isPresented: $showImportConfigConfirm) {
                Button(L10n.t("取消"), role: .cancel) {}

                Button(L10n.t("导入并重启"), role: .destructive) {
                    if let data = pendingImportData {
                        Task { @MainActor in

                            guard await ConfigPortability.importData(data) else {
                                configMessage = L10n.t("导入失败：这个文件不是 Lyrimuse 的设置备份，或者已经损坏。当前设置没有被改动")
                                return
                            }

                            if let lyrics = pendingImportLyrics {
                                await LyricsBackupStore.restore(from: lyrics)
                            }

                            if let folder = pendingImportFolder {
                                ICloudConfigStore.adoptFolder(folder)
                            }
                            ConfigPortability.restartApp()
                        }
                    }
                }
            } message: {

                if let source = pendingImportSourceDescription {
                    Text(String(format: L10n.t("即将导入：%@"), source))
                }

                if pendingImportLyrics != nil {
                    Text(String(format: L10n.t("这会覆盖当前所有设置，包括已连接的账号和播放数据发往的地址；同一份备份里的 %@ 个歌词文件也会一并恢复（同名的会被覆盖）。完成后立即重启 Lyrimuse 使其生效"),
                                "\(pendingImportLyricsCount)"))
                } else {
                    Text(L10n.t("这会覆盖当前所有设置，包括已连接的账号和播放数据发往的地址，并立即重启 Lyrimuse 使其生效"))
                }
            }

            SettingsCard {
                SettingsCardHeader(title: L10n.t("封面"))
                CardDivider()
                SettingsRow(
                    icon: "photo.badge.arrow.down",
                    title: L10n.t("动态封面"),
                    help: L10n.t("歌词窗口的封面卡：部分专辑在 Apple Music 上有会动的封面，没有的照旧静态显示。低电量或开了「减弱动态效果」时自动暂停")
                ) {
                    Toggle("", isOn: $settings.motionCoverEnabled)
                }
            }

            SettingsCard {
                SettingsRow(
                    icon: "trash",
                    title: L10n.t("清除所有设置"),
                    subtitle: L10n.t("本机设置，无法撤销")
                ) {
                    DestructiveButton(title: L10n.t("清除…")) { showClearConfigWarning = true }
                }
            }

            .alert(L10n.t("确定要清除所有设置吗？"), isPresented: $showClearConfigWarning) {
                Button(L10n.t("取消"), role: .cancel) {}

                Button(L10n.t("清除并重启"), role: .destructive) {
                    Task { @MainActor in
                        await ConfigPortability.clearAllConfig()
                        ConfigPortability.restartApp()
                    }
                }
            } message: {
                Text(L10n.t("这会清除本机所有账号 token、密钥和个人设置，恢复到刚装完时的样子（下次启动会重新走一遍引导向导），且无法撤销。iCloud 里那份备份和已经导出的文件都不受影响；两样都没有的话，建议先备份一份"))
            }
        }
        .id(L10n.current)
    }

    private var pendingImportSourceDescription: String? {
        guard let data = pendingImportData else { return nil }
        let meta = ICloudConfigStore.metadata(in: data)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        switch (meta.exportedAt, meta.deviceName) {
        case let (when?, device?) where !device.isEmpty:
            return String(format: L10n.t("%1$@ 从「%2$@」导出的备份"), formatter.string(from: when), device)
        case let (when?, _):
            return String(format: L10n.t("%@ 导出的备份"), formatter.string(from: when))
        case let (nil, device?) where !device.isEmpty:
            return String(format: L10n.t("从「%@」导出的备份"), device)
        default:

            return nil
        }
    }

    private var iCloudSubtitle: String {
        guard let snap = iCloudSnapshot else {

            guard ICloudConfigStore.usingCustomFolder else {
                return L10n.t("存一份到 iCloud，换 Mac 时直接读回来")
            }
            return String(format: L10n.t("备份到「%@」，还没存过"), ICloudConfigStore.folderURL.lastPathComponent)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let when = formatter.string(from: snap.exportedAt ?? snap.modifiedAt)
        let base: String
        if let device = snap.deviceName, !device.isEmpty {
            base = String(format: L10n.t("%1$@ · 来自 %2$@"), when, device)
        } else {
            base = when
        }

        guard ICloudConfigStore.usingCustomFolder else { return base }
        return base + " · " + ICloudConfigStore.folderURL.lastPathComponent
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("选择")
        panel.message = L10n.t("选一个会自动同步的文件夹（Dropbox、坚果云、OneDrive 等），换 Mac 时在那台机器上指向同一个文件夹即可")
        panel.directoryURL = ICloudConfigStore.preparedFolderURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ICloudConfigStore.setCustomFolder(url)

        iCloudSnapshot = ICloudConfigStore.latestSnapshot()
        iCloudMessage = nil
    }

    private func pickConfigFileToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = L10n.t("导入")
        if ICloudConfigStore.isAvailable {
            panel.directoryURL = ICloudConfigStore.folderURL
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        let looksLikeExport: Bool = {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return obj["appSettings"] != nil || obj["config"] != nil || obj["version"] != nil
        }()
        guard looksLikeExport else {
            configMessage = L10n.t("这个文件不是 Lyrimuse 的设置备份，没有导入")
            return
        }
        configMessage = nil
        pendingImportData = data
        pendingImportFolder = nil

        let sidecar = url.deletingLastPathComponent().appendingPathComponent(
            LyricsBackupArchive.sidecarName(forConfigName: url.lastPathComponent))
        pendingImportLyrics = try? Data(contentsOf: sidecar)
        pendingImportLyricsCount = 0
        showImportConfigConfirm = true
        if let lyrics = pendingImportLyrics {
            Task { @MainActor in
                pendingImportLyricsCount = await LyricsBackupStore.peek(lyrics)?.files ?? 0
            }
        }
    }

    private func importFromICloud() {
        guard let snap = iCloudSnapshot else { return }
        iCloudBusy = true
        iCloudMessage = nil
        Task {

            let outcome = await ICloudConfigStore.readOutcome(snap.url)
            iCloudBusy = false
            let data: Data
            switch outcome {
            case .data(let d):
                data = d
            case .downloading:
                iCloudMessage = L10n.t("正在从 iCloud 下载这份备份，下载完再点一次「导入」")
                return
            case .unavailable:
                iCloudMessage = L10n.t("读不到这份备份：可能没开 iCloud Drive，或者这个文件夹不在同步")
                return
            }
            pendingImportData = data
            pendingImportFolder = snap.folderURL

            let sidecarURL = snap.url.deletingLastPathComponent().appendingPathComponent(
                LyricsBackupArchive.sidecarName(forConfigName: snap.url.lastPathComponent))
            pendingImportLyrics = await ICloudConfigStore.read(sidecarURL)
            pendingImportLyricsCount = 0
            if let lyrics = pendingImportLyrics {
                pendingImportLyricsCount = await LyricsBackupStore.peek(lyrics)?.files ?? 0
            }
            showImportConfigConfirm = true
        }
    }
}

private struct ShortcutsSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {

        SettingsPage(
            title: L10n.t("快捷键"),
            subtitle: L10n.t("在任何 App 里都能触发，需搭配 ⌘ ⌥ ⌃ 之一")
        ) {

            SettingsCard {
                SettingsRow(icon: "eye", title: L10n.t("显示/隐藏悬浮歌词")) {
                    ShortcutRecorderControl(name: .toggleOverlay)
                }
                CardDivider()
                SettingsRow(icon: "inset.filled.topthird.square", title: L10n.t("显示/隐藏灵动岛歌词")) {
                    ShortcutRecorderControl(name: .toggleNotchOverlayHotkey)
                }
                CardDivider()
                SettingsRow(icon: "menubar.rectangle", title: L10n.t("显示/隐藏菜单栏歌词")) {
                    ShortcutRecorderControl(name: .toggleMenuBarLyricsHotkey)
                }
                CardDivider()
                SettingsRow(icon: "lock", title: L10n.t("锁定/解锁位置")) {
                    ShortcutRecorderControl(name: .toggleLockPosition)
                }
                CardDivider()
                SettingsRow(
                    icon: "character.book.closed",
                    title: L10n.t("显示/隐藏译文")
                ) {
                    ShortcutRecorderControl(name: .toggleTranslationHotkey)
                }
                CardDivider()

                SettingsRow(icon: "textformat.abc", title: L10n.t("显示/隐藏发音")) {
                    ShortcutRecorderControl(name: .toggleRomanizationHotkey)
                }
            }

            SettingsCard {
                SettingsRow(icon: "list.bullet.rectangle", title: L10n.t("打开歌词管理")) {
                    ShortcutRecorderControl(name: .openLyricsManagerHotkey)
                }
                CardDivider()
                SettingsRow(icon: "text.quote", title: L10n.t("打开歌词窗口")) {
                    ShortcutRecorderControl(name: .openLyricsWindowHotkey)
                }
                CardDivider()
                SettingsRow(
                    icon: "magnifyingglass",
                    title: L10n.t("搜索歌词")
                ) {
                    ShortcutRecorderControl(name: .lyricsQuickSearchHotkey)
                }
                CardDivider()
                SettingsRow(icon: "gearshape", title: L10n.t("打开设置")) {
                    ShortcutRecorderControl(name: .openSettingsHotkey)
                }
            }

            SettingsCard {
                SettingsRow(
                    icon: "backward.end",
                    title: L10n.t("歌词提前")
                ) {
                    ShortcutRecorderControl(name: .lyricsAdvanceHotkey)
                }
                CardDivider()
                SettingsRow(icon: "forward.end", title: L10n.t("歌词延后")) {
                    ShortcutRecorderControl(name: .lyricsDelayHotkey)
                }
                CardDivider()
                SettingsRow(
                    icon: "arrow.counterclockwise",
                    title: L10n.t("歌词偏移归零")
                ) {
                    ShortcutRecorderControl(name: .lyricsOffsetResetHotkey)
                }
                CardDivider()

                SettingsRow(
                    icon: "timer",
                    title: L10n.t("步长"),
                    subtitle: L10n.t("每按一次调整的幅度")
                ) {
                    HStack(spacing: 8) {
                        Text("\(AppSettings.formattedSeconds(ms: settings.lyricsOffsetStepMs))\(L10n.t("秒"))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("", value: Binding(
                            get: { Double(settings.lyricsOffsetStepMs) / 1000 },
                            set: { settings.lyricsOffsetStepMs = Int(($0 * 1000).rounded()) }
                        ), in: 0.05...2.0, step: 0.05)
                    }
                }
            }

            SettingsCard {
                SettingsRow(icon: "playpause", title: L10n.t("播放/暂停")) {
                    ShortcutRecorderControl(name: .playPauseHotkey)
                }
                CardDivider()
                SettingsRow(icon: "forward.fill", title: L10n.t("下一首")) {
                    ShortcutRecorderControl(name: .nextTrackHotkey)
                }
                CardDivider()
                SettingsRow(icon: "backward.fill", title: L10n.t("上一首")) {
                    ShortcutRecorderControl(name: .previousTrackHotkey)
                }
            }
        }
        .id(L10n.current)
    }
}

private struct GitHubStarsBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 10))
            Text(String(count))
                .font(.system(size: 12, weight: .medium))

                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(L10n.t("GitHub Star 数"))

        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("GitHub Star 数"))
        .accessibilityValue(String(count))
    }
}

private struct AboutSettingsTab: View {

    @ObservedObject private var updater = SparkleUpdaterManager.shared
    @ObservedObject private var githubStars = GitHubStarsService.shared

    @ObservedObject private var settings = AppSettings.shared

    @State private var versionCopied = false

    private var appIcon: NSImage { NSApplication.shared.applicationIconImage }
    private var versionString: String { SparkleUpdaterManager.appVersionString }

    var body: some View {

        SettingsPageCustomHeader {
            hero
        } content: {
            updateCard
            communityCard
            legalCard
            diagnosticsCard
            Text("© 2026 Yudaotor · GPL-3.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }

        .id(L10n.current)

        .task { await githubStars.refreshIfStale() }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)

                .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                .padding(.bottom, 6)

            Text(LyrimuseIdentity.displayName)
                .font(.system(size: 24, weight: .bold))
            versionChip
            Text(L10n.t("Lyric × Muse——把你的歌词交给音乐女神吧"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            HStack(spacing: 10) {

                Button {
                    NSWorkspace.shared.open(URL(string: "https://yudaotor.github.io/donate/")!)
                } label: {
                    Label(L10n.t("请作者喝杯咖啡"), systemImage: "cup.and.saucer.fill")
                }
                .settingsProminentGlassButton(tint: .orange)
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse")!)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("GitHub")

                        if let stars = githubStars.starCount {
                            GitHubStarsBadge(count: stars)
                        }
                    }
                }
                .settingsGlassButtons()
            }
            .padding(.top, 8)

            Text(L10n.t("开源免费，你的 ⭐ 是最大的鼓励，谢谢支持"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }

        .frame(maxWidth: .infinity)

        .background { AboutHeroBackdrop() }
    }

    private var versionChip: some View {
        Button {
            copyVersionInfo()
        } label: {
            HStack(spacing: 6) {
                if versionCopied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L10n.t("已复制版本信息"))
                } else {
                    Text(String(format: L10n.t("版本 %@"), versionString))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(Self.architectureName)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(L10n.t("点击复制版本信息，反馈问题时贴上"))
        .animation(.easeInOut(duration: 0.15), value: versionCopied)
    }

    private static var architectureName: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }

    private func copyVersionInfo() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let text = "Lyrimuse \(versionString) (\(Self.architectureName)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        versionCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            versionCopied = false
        }
    }

    private var updateCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("更新"))
            CardDivider()
            SettingsRow(icon: "arrow.triangle.2.circlepath", title: L10n.t("软件更新"), subtitle: updateSubtitle) {
                Button(L10n.t("打开")) {
                    AppActions.shared.requestSettings(.softwareUpdate)
                }
            }
        }
    }

    private var updateSubtitle: String {
        if let update = updater.shownItem {

            return String(format: update.downloaded ? L10n.t("%@ 已下载，点击安装") : L10n.t("有新版本 %@"),
                          update.version)
        }
        guard let date = updater.lastUpdateCheckDate else { return L10n.t("还没有检查过更新") }
        let formatter = DateFormatter()

        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return String(format: L10n.t("上次检查：%@"), formatter.string(from: date))
    }

    private var communityCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("反馈与社区"))
            CardDivider()
            SettingsRow(
                icon: "exclamationmark.bubble",
                title: L10n.t("反馈问题"),
                subtitle: L10n.t("GitHub Issues")
            ) {
                Button(L10n.t("前往")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse/issues")!)
                }
            }
            CardDivider()

            SettingsRow(
                icon: "lightbulb",
                title: L10n.t("想法与建议"),
                subtitle: L10n.t("GitHub Discussions")
            ) {
                Button(L10n.t("前往")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse/discussions/categories/ideas")!)
                }
            }
        }
    }

    private var legalCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("许可与版权"))
            CardDivider()

            SettingsRow(
                icon: "doc.text",
                title: L10n.t("版权说明")
            ) {
                Button(L10n.t("打开")) { LegalNotices.openUsageNotice() }
            }
            CardDivider()

            SettingsRow(
                icon: "checkmark.seal",
                title: L10n.t("第三方许可"),
                subtitle: L10n.t("开源组件与词典")
            ) {
                Button(L10n.t("打开")) { LegalNotices.openThirdPartyLicenses() }
            }
            CardDivider()
            SettingsRow(
                icon: "scroll",
                title: L10n.t("开源许可证"),
                subtitle: L10n.t("GPL-3.0")
            ) {
                Button(L10n.t("打开")) { LegalNotices.openLicense() }
            }
        }
    }

    private var diagnosticsCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("诊断与数据"))
            CardDivider()

            SettingsRow(
                icon: "doc.text.magnifyingglass",
                title: L10n.t("导出诊断"),
                subtitle: L10n.t("不含账号与密钥")
            ) {
                Button(L10n.t("导出…")) {
                    DiagnosticsExporter.exportInteractively()
                }
            }
            CardDivider()

            SettingsRow(
                icon: "folder",
                title: L10n.t("配置文件夹"),

                subtitle: String(format: L10n.t("%@，纯文本可直接编辑；外观与快捷键不在里面（它们在 UserDefaults）"),
                                 "~/.config/" + LyrimuseIdentity.configDirName),
                help: L10n.t("含账号凭据，不要发给别人；要连外观、快捷键一起搬走，用「备份与迁移」")
            ) {
                Button(L10n.t("打开配置文件夹")) {
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigPortability.configFolderURL])
                }
            }
        }
    }
}

struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            view.window?.styleMask.insert([.resizable, .miniaturizable])
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
