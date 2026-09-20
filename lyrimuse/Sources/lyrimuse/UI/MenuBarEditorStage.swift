import SwiftUI
import LyrimuseCore

@MainActor
struct MenuBarEditorStage: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var popover: StagePopover?

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            toolbarRow2

            MenuBarPreviewBar(reservesWidthLane: true) {
                stageWidthBar.padding(.bottom, 8)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {

            toolbarButton(
                icon: "arrow.left.and.right.circle",
                title: L10n.t("布局"),
                summary: layoutSummary,
                target: .layout
            )
            toolbarButton(

                icon: "circle.lefthalf.filled",
                title: L10n.t("配色"),
                summary: colorSummary,
                target: .color
            )

            toolbarButton(
                icon: "textformat",
                title: L10n.t("字体"),
                summary: fontSummary,
                target: .font
            )
            Spacer(minLength: 8)

            Menu {
                Button(L10n.t("恢复默认")) { MenuBarStyleDefaults.restoreDefaults() }
                Text(L10n.t("不含宽度和总开关"))
            } label: {
                Label(L10n.t("重置"), systemImage: "arrow.uturn.backward")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    private var toolbarRow2: some View {
        HStack(spacing: 8) {
            toolbarButton(
                icon: "switch.2",
                title: L10n.t("行为"),
                summary: behaviorSummary,
                target: .behavior
            )
            Spacer(minLength: 8)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    private var layoutSummary: String {
        var parts = [settings.menuBarLyricsWidthMode.displayName]
        if settings.menuBarSecondaryLine != AppSettings.defaultMenuBarSecondaryLine {
            parts.append("\(L10n.t("副行")) · \(settings.menuBarSecondaryLine.displayName)")
        }
        return parts.joined(separator: " · ")
    }

    private var colorSummary: String {
        settings.menuBarLyricsKaraoke ? L10n.t("卡拉OK效果") : L10n.t("跟随系统")
    }

    private var fontSummary: String {
        let weight = settings.menuBarLyricsFontWeight.displayName
        guard !settings.menuBarSecondaryLine.showsSecondaryRow, settings.menuBarLyricsFontSize > 0 else { return weight }
        let size = String(format: L10n.t("%@pt"), "\(Int(MenuBarMarqueeRenderer.font.pointSize))")
        return "\(weight) \(size)"
    }

    private var behaviorSummary: String {
        SettingsToggleSummary.text([
            (title: L10n.t("悬停显示播放控制"), isOn: settings.menuBarHoverShowsControls),
            (title: L10n.t("无歌词时显示歌名"), isOn: settings.menuBarShowsTitleWhenNoLyrics),
        ])
    }

    private func toolbarButton(
        icon: String, title: String, summary: String, target: StagePopover
    ) -> some View {
        Button {
            popover = target
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .environment(\.locale, Locale(identifier: "en"))
                Text(title)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
                    .layoutPriority(-1)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: popoverBinding(target), arrowEdge: .bottom) {
            popoverContent(for: target)
        }
    }

    private enum StagePopover: Equatable {
        case layout
        case color
        case font

        case behavior
    }

    private func popoverBinding(_ target: StagePopover) -> Binding<Bool> {
        Binding(
            get: { popover == target },
            set: { shown in
                if shown { popover = target } else if popover == target { popover = nil }
            })
    }

    @ViewBuilder
    private func popoverContent(for target: StagePopover) -> some View {
        switch target {
        case .layout: MenuBarLayoutPopover()
        case .color: MenuBarColorPopover()
        case .font: MenuBarFontPopover()
        case .behavior: MenuBarBehaviorPopover()
        }
    }

    private var stageWidthBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
            Slider(value: Binding(
                get: { Double(settings.menuBarLyricsWidth) },
                set: {
                    let quantized = CGFloat(($0 / 10).rounded() * 10)
                    guard quantized != settings.menuBarLyricsWidth else { return }
                    settings.menuBarLyricsWidth = quantized
                }
            ), in: 80...600)
            .controlSize(.small)
            .tint(.white)
            .frame(width: 150)

            .accessibilityLabel(L10n.t("最大宽度"))
            .accessibilityValue(widthValueText)
            Text(widthValueText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
    }

    private var widthValueText: String {
        String(format: L10n.t("%@pt"), "\(Int(settings.menuBarLyricsWidth))")
    }
}

struct MenuBarWidthRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(icon: "arrow.left.and.right", title: L10n.t("最大宽度")) {
            HStack(spacing: 8) {

                SteppedSlider(value: Binding(
                    get: { Double(settings.menuBarLyricsWidth) },
                    set: {

                        let quantized = CGFloat(($0 / 10).rounded() * 10)
                        guard quantized != settings.menuBarLyricsWidth else { return }
                        settings.menuBarLyricsWidth = quantized
                    }
                ), in: 80...600, step: 10)
                .frame(width: 150)
                Text(String(format: L10n.t("%@pt"), "\(Int(settings.menuBarLyricsWidth))"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}

extension MenuBarLyricsWidthMode {
    var displayName: String {
        switch self {
        case .fixed: return L10n.t("固定")
        case .adaptive: return L10n.t("自适应")
        }
    }
}

extension MenuBarLyricsIconPosition {

    var displayName: String {
        switch self {
        case .off: return L10n.t("不显示")
        case .leading: return L10n.t("左")
        case .trailing: return L10n.t("右")
        }
    }
}

struct MenuBarLyricsIconRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "chart.bar.fill",
            title: L10n.t("歌词旁的图标"),
            help: L10n.t("在歌词一格的最左或最右放一枚菜单栏图标，图标颜色从下往上涨表示播放进度：涨上来的用「已唱到」色，其余用「未唱到」色。只在显示歌词时出现。")
        ) {
            Picker("", selection: $settings.menuBarLyricsIconPosition) {
                ForEach(MenuBarLyricsIconPosition.allCases, id: \.self) { position in
                    Text(position.displayName).tag(position)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

struct MenuBarHoverControlsRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "playpause.circle",
            title: L10n.t("悬停显示播放控制"),
            help: L10n.t("鼠标移到菜单栏歌词上换成「上一曲 / 播放暂停 / 下一曲」三个键，移开变回。暂停、间奏、或那一格太窄时不接管。点键以外的地方仍是打开面板。")
        ) {
            Toggle("", isOn: $settings.menuBarHoverShowsControls)
        }
    }
}

struct MenuBarTitleFallbackRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "music.note.list",
            title: L10n.t("无歌词时显示歌名"),
            help: L10n.t("这首歌没有歌词或还在搜索时，用「♪ 歌名」占住歌词的位置，不缩回小图标；歌词一到就换成歌词。暂停时仍缩回图标，广告中不显示")
        ) {
            Toggle("", isOn: $settings.menuBarShowsTitleWhenNoLyrics)
        }
    }
}

@MainActor
enum MenuBarStyleDefaults {
    static func restoreDefaults() {
        let settings = AppSettings.shared

        settings.menuBarLyricsWidthMode = AppSettings.defaultMenuBarLyricsWidthMode
        settings.menuBarLyricsAlignment = AppSettings.defaultMenuBarLyricsAlignment
        settings.menuBarSecondaryLine = AppSettings.defaultMenuBarSecondaryLine
        settings.menuBarLyricsIconPosition = AppSettings.defaultMenuBarLyricsIconPosition

        settings.menuBarLyricsKaraoke = AppSettings.defaultMenuBarLyricsKaraoke
        settings.menuBarLyricsTextColorHex = AppSettings.defaultMenuBarLyricsTextColorHex
        settings.menuBarLyricsFillColorHex = AppSettings.defaultMenuBarLyricsFillColorHex

        settings.menuBarLyricsFontWeight = AppSettings.defaultMenuBarLyricsFontWeight
        settings.menuBarLyricsFontSize = AppSettings.defaultMenuBarLyricsFontSize

        settings.menuBarHoverShowsControls = AppSettings.defaultMenuBarHoverShowsControls
        settings.menuBarShowsTitleWhenNoLyrics = AppSettings.defaultMenuBarShowsTitleWhenNoLyrics
    }
}

struct MenuBarLayoutRows: View {
    var body: some View {
        VStack(spacing: 0) {
            MenuBarWidthModeRow()
            CardDivider()
            MenuBarSecondaryLineRow()
            CardDivider()
            MenuBarLyricsIconRow()
        }
    }
}

struct MenuBarLayoutPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("布局"), width: 470) {
            MenuBarLayoutRows()
        }
    }
}

struct MenuBarBehaviorRows: View {
    var body: some View {
        VStack(spacing: 0) {
            MenuBarHoverControlsRow()
            CardDivider()
            MenuBarTitleFallbackRow()
        }
    }
}

struct MenuBarBehaviorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("行为"), width: 420) {
            MenuBarBehaviorRows()
        }
    }
}

struct MenuBarWidthModeRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "arrow.left.and.right.circle",
            title: L10n.t("宽度模式"),

            help: L10n.t("固定：始终占满设定宽度。\n自适应：提前按整首歌的歌词预留宽度，不超过设定上限；同一首歌换句时保持稳定。")
        ) {
            Picker("", selection: $settings.menuBarLyricsWidthMode) {
                Text(L10n.t("固定")).tag(MenuBarLyricsWidthMode.fixed)
                Text(L10n.t("自适应")).tag(MenuBarLyricsWidthMode.adaptive)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }

        if settings.menuBarLyricsWidthMode == .fixed {
            CardDivider()
            MenuBarAlignmentRow()
        }
    }
}

struct MenuBarAlignmentRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.alignleft",

            title: L10n.t("对齐方式"),
            help: L10n.t("只影响装得下的短句：它在固定宽度那一格里靠哪边。放不下的句子会横向滚动，没有多余空间，对齐不起作用")
        ) {

            LyricsAlignmentSegmentedControl(selection: $settings.menuBarLyricsAlignment,
                                            options: LyricsRestingAlignment.menuBarOptions)
        }
    }
}

struct MenuBarColorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("配色"), width: 330) {
            MenuBarColorRows()
        }
    }
}

struct MenuBarFontRows: View {
    var body: some View {
        VStack(spacing: 0) {
            MenuBarFontWeightRow()
            CardDivider()
            MenuBarFontSizeRow()
        }
    }
}

struct MenuBarFontPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("字体")) {
            MenuBarFontRows()
        }
    }
}

struct MenuBarSecondaryLineRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.append",
            title: L10n.t("副行"),
            help: L10n.t("主歌词下方多一行，高度不变（两行 10pt / 9pt，「字号」不生效）。译文和罗马音显示当前句，「下一句」显示接下来那句、主行不再提前切。副行不滚动，装不下时尾部渐隐。")
        ) {
            Picker("", selection: $settings.menuBarSecondaryLine) {
                ForEach(LyricSecondaryLine.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

struct MenuBarFontSizeRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "textformat.size",
            title: L10n.t("字号"),
            help: L10n.t("默认跟随系统菜单栏，可在 10～16pt 间调，16pt 仍在菜单栏项高度内。拖回系统字号那一格即恢复跟随。")
        ) {

            if settings.menuBarSecondaryLine.showsSecondaryRow {
                Text(L10n.t("由副行决定"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    SteppedSlider(value: Binding(
                        get: { Double(MenuBarMarqueeRenderer.font.pointSize) },
                        set: { newValue in
                            let range = MenuBarMarqueeRenderer.fontSizeRange
                            let quantized = min(max(CGFloat(newValue.rounded()), range.lowerBound), range.upperBound)
                            let stored: CGFloat = quantized == MenuBarMarqueeRenderer.systemPointSize ? 0 : quantized
                            guard stored != settings.menuBarLyricsFontSize else { return }
                            settings.menuBarLyricsFontSize = stored
                        }
                    ), in: Double(MenuBarMarqueeRenderer.fontSizeRange.lowerBound)...Double(MenuBarMarqueeRenderer.fontSizeRange.upperBound), step: 1)
                        .frame(width: 150)
                    Text(String(format: L10n.t("%@pt"), "\(Int(MenuBarMarqueeRenderer.font.pointSize))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }
}

struct MenuBarFontWeightRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "bold",
            title: L10n.t("粗细"),
            help: L10n.t("菜单栏歌词的笔画粗细。字体族继续跟随系统菜单栏，「常规」就是系统菜单栏本来的粗细；中文只变粗不变宽，英文越粗越宽一点")
        ) {
            Picker("", selection: $settings.menuBarLyricsFontWeight) {
                ForEach(OverlayFontWeight.allCases, id: \.self) { weight in
                    Text(weight.displayName).tag(weight)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

struct MenuBarColorRows: View {
    @ObservedObject private var settings = AppSettings.shared

    @ObservedObject private var menuBarAppearance = MenuBarAppearanceStore.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(
                icon: "text.word.spacing",

                title: L10n.t("卡拉OK效果"),
                help: L10n.t("跟着演唱进度把已唱到的部分染成系统强调色。只在这首歌有逐字时间轴时生效；打开菜单反白期间暂不染色")
            ) {
                Toggle("", isOn: $settings.menuBarLyricsKaraoke)
            }
            CardDivider()
            SettingsRow(
                icon: "textformat",

                title: settings.menuBarLyricsKaraoke
                    ? L10n.t("未唱到的颜色") : L10n.t("文字颜色"),
                help: L10n.t("未唱到部分的文字颜色。默认跟随系统：浅色/深色菜单栏自动适配，打开菜单时自动反白")
            ) {
                HStack(spacing: 8) {
                    if !settings.menuBarLyricsTextColorHex.isEmpty {
                        Button(L10n.t("跟随系统")) { settings.menuBarLyricsTextColorHex = "" }
                    }

                    ColorPicker("", selection: Binding(
                        get: {
                            Color(nsColor: MenuBarScrollingLabel
                                .textColor(hex: settings.menuBarLyricsTextColorHex,
                                           highlighted: false)
                                .resolved(in: menuBarAppearance.appearance))
                        },
                        set: { settings.menuBarLyricsTextColorHex = $0.hexStringWithAlpha }
                    ), supportsOpacity: false)
                }
            }

            if settings.menuBarLyricsKaraoke || settings.menuBarLyricsIconPosition != .off {
                CardDivider()
                SettingsRow(
                    icon: "paintpalette.fill",

                    title: L10n.t("已唱到的颜色"),
                    help: L10n.t("已唱到部分的颜色，也是歌词旁那枚图标上进度涨上来那一截的颜色。默认跟随系统强调色（深色菜单栏自动提亮）；自定义后原样使用、不再自动提亮")
                ) {
                    HStack(spacing: 8) {
                        if !settings.menuBarLyricsFillColorHex.isEmpty {
                            Button(L10n.t("跟随系统")) { settings.menuBarLyricsFillColorHex = "" }
                        }

                        ColorPicker("", selection: Binding(
                            get: {
                                Color(nsColor: MenuBarScrollingLabel
                                    .fillColor(hex: settings.menuBarLyricsFillColorHex,
                                               darkMenuBar: menuBarAppearance.isDark)
                                    .resolved(in: menuBarAppearance.appearance))
                            },
                            set: { settings.menuBarLyricsFillColorHex = $0.hexStringWithAlpha }
                        ), supportsOpacity: false)
                    }
                }
            }
        }
    }
}

struct MenuBarAllSettingsDrawer: View {
    @State private var isExpanded = false

    @Environment(\.settingsSearchPendingDrawer) private var pendingSearchDrawer

    var body: some View {
        SettingsCard {
            disclosureHeader
            if isExpanded {
                CardDivider()
                group(L10n.t("布局")) { MenuBarLayoutRows() }
                CardDivider()
                group(L10n.t("配色")) { MenuBarColorRows() }
                CardDivider()
                group(L10n.t("字体")) { MenuBarFontRows() }
                CardDivider()
                MenuBarWidthRow()
                CardDivider()
                group(L10n.t("行为")) { MenuBarBehaviorRows() }
                CardDivider()
                resetRow
            }
        }
        .onAppear { expandForSearchIfNeeded() }
        .onChange(of: pendingSearchDrawer) { _, _ in expandForSearchIfNeeded() }
    }

    private func expandForSearchIfNeeded() {
        guard pendingSearchDrawer == .menuBar else { return }
        if !isExpanded {
            withAnimation(.settingsCardReveal) { isExpanded = true }
        }
        SettingsSearchRouter.shared.consumeDrawer(.menuBar)
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
            Button(L10n.t("恢复")) { MenuBarStyleDefaults.restoreDefaults() }
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
