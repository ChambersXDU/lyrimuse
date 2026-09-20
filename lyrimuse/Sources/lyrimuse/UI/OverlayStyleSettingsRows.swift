import AppKit
import LyrimuseCore
import SwiftUI

@MainActor
struct OverlayTextSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {

        VStack(spacing: 0) {
            SettingsRow(icon: "character", title: L10n.t("字体")) {

                FontFamilyPicker(selection: $settings.fontFamilyName)
            }
            CardDivider()

            SettingsRow(icon: "bold", title: L10n.t("粗细")) {
                Picker("", selection: $settings.overlayFontWeight) {
                    ForEach(OverlayFontWeight.allCases, id: \.self) { weight in
                        Text(weight.displayName).tag(weight)
                    }
                }
                .labelsHidden()

                .pickerStyle(.menu)
                .fixedSize()
            }
            CardDivider()
            SettingsRow(icon: "textformat.size", title: L10n.t("字号")) {
                HStack(spacing: 8) {

                    SteppedSlider(value: Binding(
                        get: { settings.fontSize },
                        set: { newValue in

                            guard newValue != settings.fontSize else { return }
                            settings.fontSize = newValue
                        }
                    ), in: 14...36, step: 1)
                        .frame(width: 150)
                    Text(String(format: L10n.t("%@pt"), "\(Int(settings.fontSize))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
            CardDivider()

            SettingsRow(
                icon: "sparkles",
                title: L10n.t("卡拉OK效果"),
                help: L10n.t("逐字歌词，唱到哪个字亮到哪个字；没有逐字数据的歌整行高亮")
            ) {
                Toggle("", isOn: $settings.overlayLyricsKaraoke)
            }

            CardDivider()
            SettingsRow(icon: "paintbrush", title: L10n.t("文字颜色")) {
                if settings.followsCoverArt {
                    Text(L10n.t("跟随封面"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    ColorPicker("", selection: Binding(
                        get: { settings.foregroundColor },
                        set: { settings.foregroundColorHex = $0.hexStringWithAlpha }
                    ), supportsOpacity: false)

                }
            }
            CardDivider()
            SettingsRow(icon: "pencil.and.outline", title: L10n.t("文字描边")) {
                Toggle("", isOn: $settings.textStrokeEnabled)
            }
            if settings.textStrokeEnabled {
                CardDivider()
                SettingsSubRow(title: L10n.t("描边颜色")) {
                    ColorPicker("", selection: Binding(
                        get: { settings.textStrokeColor },
                        set: { settings.textStrokeColorHex = $0.hexStringWithAlpha }
                    ), supportsOpacity: true)

                }
            }
        }

        .animation(.default, value: settings.textStrokeEnabled)
    }
}

@MainActor
struct OverlayLayoutSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {

            SettingsRow(icon: "rectangle.grid.1x2", title: L10n.t("双行显示")) {
                Toggle("", isOn: $settings.showNextLinePreview)
            }
            CardDivider()

            SettingsRow(
                icon: "text.alignleft",
                title: L10n.t("对齐方式"),
                help: L10n.t("自动（默认）：按对唱声部在左 / 右 / 居中间切换。\n其余：忽略声部，固定在一个位置。")
            ) {

                OverlayAlignmentSegmentedControl(selection: $settings.overlayDuetAlignmentOverride)
            }
        }
    }
}

@MainActor
struct OverlayAlignmentSegmentedControl: View {
    @Binding var selection: OverlayDuetAlignmentOverride

    static func label(for option: OverlayDuetAlignmentOverride) -> String {
        switch option {
        case .automatic: return L10n.t("自动")
        case .center: return L10n.t("居中")
        case .leading: return L10n.t("左对齐")
        case .trailing: return L10n.t("右对齐")
        }
    }

    var body: some View {

        HStack(spacing: 2) {
            ForEach(OverlayDuetAlignmentOverride.allCases, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(Self.label(for: option))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(minWidth: 56)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )

        .fixedSize()
    }
}

@MainActor
struct OverlayBackgroundSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "rectangle.fill", title: L10n.t("背景颜色")) {
                ColorPicker("", selection: Binding(
                    get: { settings.backgroundColor },
                    set: { settings.backgroundColorHex = $0.hexStringWithAlpha }
                ), supportsOpacity: true)

            }

            CardDivider()

            SettingsSubRow(title: L10n.t("毛玻璃背景")) {
                Toggle("", isOn: $settings.overlayBackgroundGlass)
            }
        }
    }
}

@MainActor
struct OverlayThemeSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {

            SettingsRow(
                icon: "photo.on.rectangle.angled",
                title: L10n.t("跟随封面")
            ) {
                Toggle("", isOn: $settings.followsCoverArt)
            }
            CardDivider()

            SettingsRow(icon: "swatchpalette", title: L10n.t("配色主题")) {
                Menu(Self.currentThemeLabel) {
                    ForEach(ColorTheme.builtInPresets) { theme in
                        themeItem(theme)
                    }
                    if !settings.customColorThemes.isEmpty {
                        Divider()
                        ForEach(settings.customColorThemes) { theme in
                            themeItem(theme)
                        }
                    }
                }
                .fixedSize()
            }
            CardDivider()
            OverlayCustomThemeRows()
        }
    }

    private func themeItem(_ theme: ColorTheme) -> some View {
        Button(theme.name) { theme.apply(to: settings) }
    }

    static func currentColors(_ settings: AppSettings) -> ColorTheme {
        ColorTheme(
            name: "",
            foregroundColorHex: settings.foregroundColorHex,
            backgroundColorHex: settings.backgroundColorHex,
            textStrokeEnabled: settings.textStrokeEnabled,
            textStrokeColorHex: settings.textStrokeColorHex
        )
    }

    static let noThemeInEffectPlaceholder = "—"

    static var currentThemeLabel: String {
        let settings = AppSettings.shared
        guard !settings.followsCoverArt else { return noThemeInEffectPlaceholder }
        let current = currentColors(settings)
        let all = ColorTheme.builtInPresets + settings.customColorThemes
        return all.first { $0.hasSameColors(as: current) }?.name ?? L10n.t("自定义")
    }
}

private struct OverlayInlineConfirmRow<Content: View>: View {
    var title: String?
    var message: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 2)
                .padding(.vertical, 1)
            VStack(alignment: .leading, spacing: 6) {
                if let title, !title.isEmpty {
                    Text(title).font(.system(size: 13))
                }
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) { content() }
                    .settingsGlassButtons()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, SettingsRowMetrics.textLeadingInset - 12)
        .padding(.trailing, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}

@MainActor
struct OverlayCustomThemeRows: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var isNaming = false
    @State private var newThemeName = ""

    @State private var pendingDeletion: ColorTheme.ID?

    private var trimmedName: String {
        newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "square.stack", title: L10n.t("我的配色主题")) {
                Button(L10n.t("存为新主题…")) {
                    newThemeName = ""

                    pendingDeletion = nil
                    isNaming = true
                }
            }
            if isNaming {
                CardDivider()
                OverlayInlineConfirmRow(
                    message: L10n.t("会把当前的文字颜色、背景颜色、描边颜色存成一个可以随时再套用的主题")
                ) {
                    TextField(L10n.t("主题名称"), text: $newThemeName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)

                        .onSubmit { saveTheme() }
                    Button(L10n.t("保存")) { saveTheme() }
                        .disabled(trimmedName.isEmpty)
                    Button(L10n.t("取消")) { isNaming = false }
                }
            }
            ForEach(settings.customColorThemes) { theme in
                CardDivider()
                if pendingDeletion == theme.id {

                    OverlayInlineConfirmRow(
                        title: theme.name,
                        message: String(format: L10n.t("「%@」删除后无法恢复"), theme.name)
                    ) {

                        Button(L10n.t("删除"), role: .destructive) {
                            settings.customColorThemes.removeAll { $0.id == theme.id }
                            pendingDeletion = nil
                        }
                        .foregroundStyle(.red)
                        .tint(.red)
                        Button(L10n.t("取消")) { pendingDeletion = nil }
                    }
                } else {
                    SettingsSubRow(title: theme.name) {
                        HStack(spacing: 10) {

                            Image(nsImage: theme.swatchImage())
                            Button(L10n.t("套用")) { theme.apply(to: settings) }
                            Button {
                                isNaming = false
                                pendingDeletion = theme.id
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .animation(.default, value: isNaming)
        .animation(.default, value: pendingDeletion)
    }

    private func saveTheme() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        settings.customColorThemes.append(ColorTheme(
            name: name,
            foregroundColorHex: settings.foregroundColorHex,
            backgroundColorHex: settings.backgroundColorHex,
            textStrokeEnabled: settings.textStrokeEnabled,
            textStrokeColorHex: settings.textStrokeColorHex
        ))
        newThemeName = ""
        isNaming = false
    }
}

@MainActor
enum OverlayStyleDefaults {
    static func restoreTextAndColors() {
        let settings = AppSettings.shared

        settings.followsCoverArt = AppSettings.defaultFollowsCoverArt
        settings.fontFamilyName = AppSettings.defaultFontFamilyName
        settings.fontSize = AppSettings.defaultFontSize

        settings.overlayFontWeight = AppSettings.defaultOverlayFontWeight
        settings.foregroundColorHex = ColorTheme.defaultTheme.foregroundColorHex
        settings.backgroundColorHex = ColorTheme.defaultTheme.backgroundColorHex

        settings.overlayBackgroundGlass = false
        settings.textStrokeEnabled = ColorTheme.defaultTheme.textStrokeEnabled
        settings.textStrokeColorHex = ColorTheme.defaultTheme.textStrokeColorHex
    }
}

@MainActor
enum OverlayStyleSummary {

    static var text: String {
        let settings = AppSettings.shared
        return fontText(family: settings.fontFamilyName, weight: settings.overlayFontWeight, size: Int(settings.fontSize))
    }

    static func fontText(family: String, weight: OverlayFontWeight, size: Int) -> String {
        let sizeText = String(format: L10n.t("%@pt"), "\(size)")
        return "\(FontFamilyPicker.displayName(for: family)) \(weight.displayName) \(sizeText)"
    }

    static var theme: String {
        AppSettings.shared.followsCoverArt ? L10n.t("跟随封面") : OverlayThemeSettingsRows.currentThemeLabel
    }

    static var background: String {
        let settings = AppSettings.shared
        if settings.overlayBackgroundGlass { return L10n.t("毛玻璃") }
        return AppSettings.backgroundVisible(hex: settings.backgroundColorHex, glass: false)
            ? L10n.t("纯色") : L10n.t("透明")
    }

    static var layout: String {
        let settings = AppSettings.shared
        let lines = settings.showNextLinePreview ? L10n.t("双行") : L10n.t("单行")
        let alignment = OverlayAlignmentSegmentedControl.label(for: settings.overlayDuetAlignmentOverride)
        return "\(lines) · \(alignment)"
    }
}

@MainActor
struct OverlayTextPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("文字")) {
            OverlayTextSettingsRows()
        }
    }
}

@MainActor
struct OverlayThemePopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("主题")) {
            OverlayThemeSettingsRows()
        }
    }
}

@MainActor
struct OverlayBackgroundPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("背景"), width: 420) {
            OverlayBackgroundSettingsRows()
        }
    }
}

@MainActor
struct OverlayLayoutPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("排版"), width: 460) {
            OverlayLayoutSettingsRows()
        }
    }
}
