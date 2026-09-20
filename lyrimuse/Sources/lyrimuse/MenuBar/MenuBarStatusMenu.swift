import AppKit
import LyrimuseCore

@MainActor
final class MenuBarStatusMenu: NSObject, NSMenuDelegate {
    private var onHighlightChange: ((Bool) -> Void)?

    func makeMenu(onHighlightChange: @escaping (Bool) -> Void) -> NSMenu {
        self.onHighlightChange = onHighlightChange
        let menu = NSMenu()
        menu.delegate = self

        menu.autoenablesItems = false

        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {

        rebuild(menu)
    }

    func menuWillOpen(_ menu: NSMenu) { onHighlightChange?(true) }
    func menuDidClose(_ menu: NSMenu) { onHighlightChange?(false) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared

        let quick = NSMenu()
        quick.autoenablesItems = false
        quick.addItem(toggle(L10n.t("显示桌面悬浮歌词"), symbol: "captions.bubble",
                             on: settings.classicOverlayEnabled,
                             action: #selector(toggleClassicOverlay)))
        quick.addItem(toggle(L10n.t("显示灵动岛歌词"), symbol: "rectangle.topthird.inset.filled",
                             on: settings.notchOverlayEnabled,
                             action: #selector(toggleNotchOverlay)))

        quick.addItem(toggle(L10n.t("显示菜单栏歌词"), symbol: "menubar.rectangle",
                             on: settings.showLyricsInMenuBar,
                             action: #selector(toggleMenuBarLyrics)))

        if settings.classicOverlayEnabled {
            let locked = LyricsOverlayWindowController.shared.isPositionLocked

            quick.addItem(toggle(L10n.t("锁定位置"),
                                 symbol: locked ? "lock.fill" : "lock.open.fill",
                                 on: locked, action: #selector(toggleLockPosition)))
        }
        quick.addItem(.separator())
        quick.addItem(toggle(L10n.t("开机启动"), symbol: "power",
                             on: settings.launchAtLoginEnabled,
                             action: #selector(toggleLaunchAtLogin)))
        menu.addItem(submenu(L10n.t("快速开关"), symbol: "switch.2", menu: quick))

        if !coordinator.title.isEmpty {
            let offset = NSMenu()
            offset.autoenablesItems = false
            offset.addItem(action(nudgeTitle(L10n.t("提前")), symbol: "gobackward",
                                  selector: #selector(nudgeEarlier)))
            offset.addItem(action(nudgeTitle(L10n.t("延后")), symbol: "goforward",
                                  selector: #selector(nudgeLater)))

            if coordinator.trackLyricsOffsetMs != 0 {
                offset.addItem(.separator())
                offset.addItem(action(L10n.t("重置"), symbol: "arrow.counterclockwise",
                                      selector: #selector(resetOffset)))
            }
            menu.addItem(submenu(offsetMenuTitle, symbol: "timer", menu: offset))
        }

        menu.addItem(.separator())
        menu.addItem(action(L10n.t("设置…"), symbol: "gearshape",
                            selector: #selector(openSettings)))
        menu.addItem(action(L10n.t("歌词管理…"), symbol: "music.note.list",
                            selector: #selector(openLyricsManager)))

        menu.addItem(.separator())
        menu.addItem(action(L10n.t("歌词窗口…"), symbol: "text.quote",
                            selector: #selector(openLyricsWindow)))

        menu.addItem(.separator())
        menu.addItem(action(L10n.t("检查更新…"), symbol: "arrow.triangle.2.circlepath",
                            selector: #selector(checkForUpdates)))

        menu.addItem(action(L10n.t("重新运行引导…"), symbol: "sparkles",
                            selector: #selector(rerunOnboarding)))
        menu.addItem(action(L10n.t("关于 Lyrimuse"), symbol: "info.circle",
                            selector: #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(action(L10n.t("退出 Lyrimuse"),
                            symbol: "rectangle.portrait.and.arrow.right",
                            selector: #selector(quit)))
    }

    private func makeItem(_ title: String, symbol: String, selector: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {

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

    private func nudgeTitle(_ verb: String) -> String {
        let step = AppSettings.shared.lyricsOffsetStepMs
        return "\(verb) \(AppSettings.formattedSeconds(ms: step))\(L10n.t("秒"))"
    }

    private var offsetMenuTitle: String {

        let ms = PlaybackCoordinator.shared.trackLyricsOffsetMs
        guard ms != 0 else { return L10n.t("歌词时间轴") }

        let sign = ms > 0 ? "+" : ""
        return "\(L10n.t("歌词时间轴"))(\(sign)\(AppSettings.formattedSeconds(ms: ms))s)"
    }

    @objc private func toggleClassicOverlay() {

        LyricsOverlayWindowController.shared.setVisible(!AppSettings.shared.classicOverlayEnabled)
    }

    @objc private func toggleNotchOverlay() {
        NotchLyricsWindowController.shared.setVisible(!AppSettings.shared.notchOverlayEnabled)
    }

    @objc private func toggleMenuBarLyrics() {
        AppSettings.shared.showLyricsInMenuBar.toggle()
    }

    @objc private func toggleLockPosition() {
        guard AppSettings.shared.classicOverlayEnabled else { return }
        let overlay = LyricsOverlayWindowController.shared
        let newValue = !overlay.isPositionLocked

        AppSettings.shared.lockPosition = newValue
        overlay.setLocked(newValue)
    }

    @objc private func toggleLaunchAtLogin() {
        AppSettings.shared.launchAtLoginEnabled.toggle()
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

    @objc private func openSettings() { AppActions.shared.openSettings?() }
    @objc private func openLyricsManager() { AppActions.shared.openLyricsManager?() }
    @objc private func openLyricsWindow() { AppActions.shared.openLyricsWindow?() }
    @objc private func rerunOnboarding() { AppActions.shared.openOnboarding?() }

    @objc private func openAbout() {

        AppActions.shared.requestSettings(.tab(.about))
        AppActions.shared.openSettings?()
    }

    @objc private func checkForUpdates() {

        NSApp.activate(ignoringOtherApps: true)
        SparkleUpdaterManager.shared.checkForUpdates()
    }

    @objc private func quit() {

        AppExit.request(.menuQuit)
    }
}
