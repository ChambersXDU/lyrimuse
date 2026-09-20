import AppKit
import LyrimuseCore

@MainActor
final class OverlayQuickSettingsMenu: NSObject, NSMenuDelegate {
    private let menu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }()

    override init() {
        super.init()
        menu.delegate = self
    }

    func popUp() {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = AppSettings.shared

        if LocalPlaybackSource.shared.currentLyricsSupportsChineseVariant {
            menu.addItem(submenu(L10n.t("简繁转换"), symbol: "character.bubble", menu: chineseVariantMenu(settings)))
        }
        menu.addItem(toggle(L10n.t("双行歌词"), symbol: "text.aligncenter",
                            on: settings.showNextLinePreview,
                            action: #selector(toggleNextLinePreview)))
        menu.addItem(submenu(L10n.t("更改配色"), symbol: "paintpalette", menu: colorThemeMenu(settings)))
        menu.addItem(submenu(offsetMenuTitle, symbol: "timer", menu: lyricsOffsetMenu()))

        menu.addItem(submenu(L10n.t("位置"), symbol: "dock.rectangle", menu: placementMenu(settings)))

        if !PlaybackCoordinator.shared.title.isEmpty {
            menu.addItem(action(L10n.t("搜索歌词…"), symbol: "magnifyingglass",
                               selector: #selector(searchLyrics)))
        }
        menu.addItem(.separator())
        menu.addItem(action(L10n.t("更多设置…"), symbol: "gearshape",
                           selector: #selector(openMoreSettings)))
    }

    private func chineseVariantMenu(_ settings: AppSettings) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let current = settings.lyricsChineseVariant
        m.addItem(toggle(L10n.t("不转换"), symbol: "", on: current == .off,
                         action: #selector(setChineseVariantOff)))
        m.addItem(toggle(L10n.t("简体"), symbol: "", on: current == .simplified,
                         action: #selector(setChineseVariantSimplified)))
        m.addItem(toggle(L10n.t("繁体"), symbol: "", on: current == .traditional,
                         action: #selector(setChineseVariantTraditional)))
        return m
    }

    private func placementMenu(_ settings: AppSettings) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let current = settings.overlayPlacementMode
        m.addItem(toggle(OverlayPlacementSegmentedControl.label(for: .free), symbol: "", on: current == .free,
                         action: #selector(setPlacementFree)))
        m.addItem(toggle(OverlayPlacementSegmentedControl.label(for: .topCenter), symbol: "", on: current == .topCenter,
                         action: #selector(setPlacementTopCenter)))
        m.addItem(toggle(OverlayPlacementSegmentedControl.label(for: .bottomCenter), symbol: "",
                         on: current == .bottomCenter, action: #selector(setPlacementBottomCenter)))
        return m
    }

    private func colorThemeMenu(_ settings: AppSettings) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(toggle(L10n.t("跟随封面"), symbol: "photo",
                         on: settings.followsCoverArt,
                         action: #selector(toggleFollowsCoverArt)))
        m.addItem(.separator())
        let current = ColorTheme(
            name: "", foregroundColorHex: settings.foregroundColorHex,
            backgroundColorHex: settings.backgroundColorHex,
            textStrokeEnabled: settings.textStrokeEnabled, textStrokeColorHex: settings.textStrokeColorHex)

        let showsCheckmarks = !settings.followsCoverArt
        for theme in ColorTheme.builtInPresets {
            m.addItem(colorThemeItem(theme, checked: showsCheckmarks && theme.hasSameColors(as: current)))
        }
        if !settings.customColorThemes.isEmpty {
            m.addItem(.separator())
            for theme in settings.customColorThemes {

                m.addItem(colorThemeItem(theme, checked: showsCheckmarks && theme.hasSameColors(as: current)))
            }
        }
        return m
    }

    private func colorThemeItem(_ theme: ColorTheme, checked: Bool) -> NSMenuItem {
        let item = makeItem(theme.name, symbol: "", selector: #selector(applyColorTheme(_:)))
        item.representedObject = theme

        item.state = checked ? .on : .off
        return item
    }

    private func lyricsOffsetMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(action(nudgeTitle(L10n.t("提前")), symbol: "gobackward",
                        selector: #selector(nudgeEarlier)))
        m.addItem(action(nudgeTitle(L10n.t("延后")), symbol: "goforward",
                        selector: #selector(nudgeLater)))
        if PlaybackCoordinator.shared.trackLyricsOffsetMs != 0 {
            m.addItem(.separator())
            m.addItem(action(L10n.t("重置"), symbol: "arrow.counterclockwise",
                            selector: #selector(resetOffset)))
        }
        return m
    }

    private func nudgeTitle(_ verb: String) -> String {
        let step = AppSettings.shared.lyricsOffsetStepMs
        return "\(verb) \(AppSettings.formattedSeconds(ms: step))\(L10n.t("秒"))"
    }

    private var offsetMenuTitle: String {
        let ms = PlaybackCoordinator.shared.trackLyricsOffsetMs
        guard ms != 0 else { return L10n.t("歌词进度") }
        let sign = ms > 0 ? "+" : ""
        return "\(L10n.t("歌词进度"))(\(sign)\(AppSettings.formattedSeconds(ms: ms))s)"
    }

    private func makeItem(_ title: String, symbol: String, selector: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        if !symbol.isEmpty, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            item.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)) ?? image
        }
        return item
    }

    private func action(_ title: String, symbol: String, selector: Selector) -> NSMenuItem {
        makeItem(title, symbol: symbol, selector: selector)
    }

    private func toggle(_ title: String, symbol: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = makeItem(title, symbol: symbol, selector: action)
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String, symbol: String, menu: NSMenu) -> NSMenuItem {
        let item = makeItem(title, symbol: symbol, selector: nil)
        item.submenu = menu
        return item
    }

    @objc private func toggleNextLinePreview() {
        AppSettings.shared.showNextLinePreview.toggle()
    }

    private func setChineseVariant(_ variant: ChineseVariant) {
        AppSettings.shared.lyricsChineseVariant = variant
        LocalPlaybackSource.shared.chineseVariant = variant
    }
    @objc private func setChineseVariantOff() { setChineseVariant(.off) }
    @objc private func setChineseVariantSimplified() { setChineseVariant(.simplified) }
    @objc private func setChineseVariantTraditional() { setChineseVariant(.traditional) }

    @objc private func setPlacementFree() { AppSettings.shared.overlayPlacementMode = .free }
    @objc private func setPlacementTopCenter() { AppSettings.shared.overlayPlacementMode = .topCenter }
    @objc private func setPlacementBottomCenter() { AppSettings.shared.overlayPlacementMode = .bottomCenter }

    @objc private func toggleFollowsCoverArt() {
        AppSettings.shared.followsCoverArt.toggle()
    }

    @objc private func applyColorTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? ColorTheme else { return }
        theme.apply(to: AppSettings.shared)
    }

    @objc private func nudgeEarlier() {
        PlaybackCoordinator.shared.nudgeLyricsOffset(by: AppSettings.shared.lyricsOffsetStepMs)
    }

    @objc private func nudgeLater() {
        PlaybackCoordinator.shared.nudgeLyricsOffset(by: -AppSettings.shared.lyricsOffsetStepMs)
    }

    @objc private func resetOffset() {
        PlaybackCoordinator.shared.resetLyricsOffset()
    }

    @objc private func searchLyrics() {
        AppActions.shared.openLyricsQuickSearch?()
    }

    @objc private func openMoreSettings() {
        UserDefaults.standard.set(LyricsSurface.overlay.appearanceSectionRawValue,
                                  forKey: LyricsSurface.appearanceSectionStorageKey)
        AppActions.shared.requestSettings(.tab(.appearance))
        AppActions.shared.openSettings?()
    }
}
