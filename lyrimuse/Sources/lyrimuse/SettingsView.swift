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
}

struct SettingsView: View {

    @ObservedObject private var languageSettings = AppSettings.shared

    @State private var selection: SettingsSidebarItem? = .tab(SettingsTab.restoredLastTab())
    @AppStorage(SettingsTab.lastTabStorageKey) private var lastTabRaw = SettingsTab.lyrics.rawValue

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
            sidebarLabel(.lyrics)
            sidebarLabel(.player)
            sidebarLabel(.appearance)
            sidebarLabel(.shortcuts)
            sidebarLabel(.general)
            sidebarLabel(.about)
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
                case nil: ContentUnavailableView(L10n.t("选择左侧的设置分类"), systemImage: "gearshape")
                }
            }

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

            settingsSearchFocused = false
        }

        .onAppear {
            AuxiliaryWindowActivation.windowDidAppear()
        }
        .onDisappear {
            AuxiliaryWindowActivation.windowDidDisappear()
        }
    }

    private func sidebarLabel(_ tab: SettingsTab) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(tab.title)
            }
        } icon: {
            iconBadge(tab.icon, tint: tab.tint)
        }
        .tag(SettingsSidebarItem.tab(tab))
    }

    private var selectedCategoryTitle: String {
        switch selection {
        case .tab(let tab): return tab.title
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
        _ title: String, _ option: RomanizationScripts
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

    private var scopedOffsetMs: Int {
        offsets.globalOffsetMs
    }

    private func setScopedOffset(_ ms: Int) {
        PlaybackCoordinator.shared.setGlobalLyricsOffset(ms)
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

    private func matchingModeLabel(_ mode: LyricsSourceMode) -> String {
        mode == .smart
            ? String(format: L10n.t("%@（推荐）"), mode.displayName)
            : mode.displayName
    }

    private var matchingCard: some View {
        SettingsCard {

            SettingsRow(
                icon: "slider.horizontal.3",
                title: L10n.t("匹配算法")
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
                title: L10n.t("跟进算法升级")
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
                title: L10n.t("锁定手选歌词")
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
                title: L10n.t("显示译文")
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
        }
    }

    private var displayCard: some View {
        SettingsCard {

            if AppSettings.userReadsChinese || settings.hasSeenChineseLyrics
                || settings.lyricsChineseVariant != .off
            {
            SettingsRow(
                icon: "character.bubble",
                title: L10n.t("繁简转换")
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
                title: L10n.t("显示罗马音")
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
                            L10n.t("日语"), .japanese)
                        romanizationToggle(
                            L10n.t("韩语"), .korean)
                    }
                }
            }
            CardDivider()

            SettingsRow(
                icon: "timer",
                title: L10n.t("全局时间轴偏移")
            ) {
                HStack(spacing: 8) {
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
            title: L10n.t("歌词文件夹")
        ) {
            HStack(spacing: 8) {
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
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
                case .menuBar: EmptyView()
                }
            }
            .animation(.easeOut(duration: 0.18), value: sectionRaw)
        } page: {
            SettingsPage(
                title: L10n.t("歌词显示")
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
        case overlay, menuBar
        var id: Self { self }
        var title: String {
            switch self {
            case .overlay: return L10n.t("悬浮歌词")
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
        icon: String, title: String, isOn: Binding<Bool>
    ) -> some View {
        SettingsCard {
            SettingsRow(icon: icon, title: title) {
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

private struct PlayerSettingsTab: View {
    @State private var automationStatus: MusicAutomationPermissionStatus = .notDetermined
    @State private var requestingAutomation = false
    @State private var collectorState: LaunchdJobState = .notRegistered
    @State private var collectorBusy = false

    var body: some View {
        SettingsPage(title: L10n.t("播放器")) {
            SettingsCard {
                SettingsRow(
                    icon: "music.note",
                    title: L10n.t("Apple Music 自动化")
                ) {
                    if requestingAutomation {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(automationActionTitle) { handleAutomationAction() }
                    }
                }
                if automationStatus == .denied {
                    CardDivider()
                    SettingsNote {
                        Button(L10n.t("打开系统设置")) {
                            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
                        }
                    }
                }
            }
            .onAppear { refreshAutomationStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshAutomationStatus()
            }

            SettingsCard {
                SettingsRow(
                    icon: collectorState.isRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    iconTint: collectorState.isRunning ? .green : .orange,
                    title: L10n.t("后台歌词服务")
                ) {
                    if collectorBusy {
                        ProgressView().controlSize(.small)
                    } else if !collectorState.isRunning {
                        Button(L10n.t("启用")) { enableCollector() }
                    }
                }
            }
            .onAppear { refreshCollectorState() }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                refreshCollectorState()
            }
        }
        .id(L10n.current)
    }

    private var automationActionTitle: String {
        automationStatus == .notDetermined ? L10n.t("请求权限") : L10n.t("打开系统设置")
    }

    private func handleAutomationAction() {
        if automationStatus == .notDetermined {
            requestingAutomation = true
            Task {
                _ = await MusicAutomationPermission.requestWithTimeout()
                requestingAutomation = false
                refreshAutomationStatus()
            }
        } else {
            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
        }
    }

    private func refreshAutomationStatus() {
        Task {
            let status = await Task.detached(priority: .utility) {
                MusicAutomationPermission.check(askIfNeeded: false)
            }.value
            automationStatus = status
        }
    }

    private func refreshCollectorState() {
        guard !collectorBusy else { return }
        Task {
            let state = await Task.detached(priority: .utility) { CollectorServiceManager.state }.value
            collectorState = state
        }
    }

    private func enableCollector() {
        collectorBusy = true
        Task {
            collectorState = await CollectorServiceManager.setEnabledAndWait(true)
            AppSettings.shared.collectorServiceEnabled = collectorState.isRunning
            collectorBusy = false
        }
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var showExportConfigWarning = false
    @State private var showImportConfigConfirm = false
    @State private var configMessage: String?
    @State private var pendingImportData: Data?
    @State private var pendingImportLyrics: Data?
    @State private var pendingImportLyricsCount = 0
    @State private var showClearConfigWarning = false

    var body: some View {
        SettingsPage(title: L10n.t("通用")) {
            SettingsCard {
                SettingsCardHeader(title: L10n.t("菜单栏与 Dock"))
                CardDivider()
                SettingsRow(icon: "menubar.rectangle", title: L10n.t("菜单栏图标")) {
                    Text(settings.menuBarIconStyle.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                SettingsRawRow { MenuBarIconPicker() }
                CardDivider()
                SettingsRow(icon: "figure.dance", title: L10n.t("随播放律动")) {
                    Toggle("", isOn: $settings.menuBarIconAnimates)
                }
                CardDivider()
                SettingsRow(icon: "macwindow", title: L10n.t("在 Dock 中显示")) {
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
                SettingsCardHeader(title: L10n.t("备份与迁移"))
                CardDivider()
                SettingsRow(icon: "doc.badge.gearshape", title: L10n.t("设置文件")) {
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
            .alert(L10n.t("确定要导出设置吗？"), isPresented: $showExportConfigWarning) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("继续导出")) { exportConfig() }
            } message: {
                Text(L10n.t("导出的文件包含账号登录凭证和密钥，妥善保管，不要发给别人。歌词库会另外存成同名的第二个文件。"))
            }
            .alert(L10n.t("确定要导入这份设置吗？"), isPresented: $showImportConfigConfirm) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("导入并重启"), role: .destructive) {
                    guard let data = pendingImportData else { return }
                    Task { @MainActor in
                        guard await ConfigPortability.importData(data) else {
                            configMessage = L10n.t("导入失败：这个文件不是 Lyrimuse 的设置备份，或者已经损坏。当前设置没有被改动")
                            return
                        }
                        if let lyrics = pendingImportLyrics {
                _ = await LyricsBackupStore.restore(from: lyrics)
                        }
                        ConfigPortability.restartApp()
                    }
                }
            } message: {
                if pendingImportLyrics != nil {
                    Text(String(format: L10n.t("这会覆盖当前设置，并恢复 %@ 个歌词文件；完成后立即重启 Lyrimuse。"), "\(pendingImportLyricsCount)"))
                } else {
                    Text(L10n.t("这会覆盖当前设置并立即重启 Lyrimuse。"))
                }
            }

            SettingsCard {
                SettingsRow(icon: "trash", title: L10n.t("清除所有设置")) {
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
                Text(L10n.t("这会清除本机所有账号 token、密钥和个人设置，且无法撤销。"))
            }
        }
        .id(L10n.current)
    }

    private func exportConfig() {
        guard let data = ConfigPortability.buildExportData() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ConfigPortability.suggestedFilename()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.writeSecurely(to: url)
        } catch {
            configMessage = String(format: L10n.t("导出失败：%@"), error.localizedDescription)
            return
        }
        Task { @MainActor in
            guard let archive = await LyricsBackupStore.buildArchive() else {
                configMessage = L10n.t("设置已导出；歌词库这次没打包成功")
                return
            }
            let sidecarName = LyricsBackupArchive.sidecarName(forConfigName: url.lastPathComponent)
            let sidecar = url.deletingLastPathComponent().appendingPathComponent(sidecarName)
            do {
                try archive.writeSecurely(to: sidecar)
                configMessage = String(format: L10n.t("已导出设置和歌词库（%@）"), sidecarName)
            } catch {
                configMessage = L10n.t("设置已导出；歌词库写盘失败")
            }
        }
    }

    private func pickConfigFileToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = L10n.t("导入")
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
        pendingImportData = data
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
}

private struct ShortcutsSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {

        SettingsPage(
            title: L10n.t("快捷键")
        ) {

            SettingsCard {
                SettingsRow(icon: "eye", title: L10n.t("显示/隐藏悬浮歌词")) {
                    ShortcutRecorderControl(name: .toggleOverlay)
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
                    title: L10n.t("步长")
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

        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("GitHub Star 数"))
        .accessibilityValue(String(count))
    }
}

private struct AboutSettingsTab: View {

    @ObservedObject private var githubStars = GitHubStarsService.shared

    @State private var versionCopied = false

    private var appIcon: NSImage { NSApplication.shared.applicationIconImage }
    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var body: some View {

        SettingsPageCustomHeader {
            hero
        } content: {
            communityCard
            legalCard
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

    private var communityCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("反馈与社区"))
            CardDivider()
            SettingsRow(
                icon: "exclamationmark.bubble",
                title: L10n.t("反馈问题")
            ) {
                Button(L10n.t("前往")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse/issues")!)
                }
            }
            CardDivider()

            SettingsRow(
                icon: "lightbulb",
                title: L10n.t("想法与建议")
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
                title: L10n.t("第三方许可")
            ) {
                Button(L10n.t("打开")) { LegalNotices.openThirdPartyLicenses() }
            }
            CardDivider()
            SettingsRow(
                icon: "scroll",
                title: L10n.t("开源许可证")
            ) {
                Button(L10n.t("打开")) { LegalNotices.openLicense() }
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
