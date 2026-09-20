import AppKit

@MainActor
final class DockMenuController: NSObject {
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(L10n.t("设置…"), symbol: "gearshape",
                          selector: #selector(openSettings)))
        menu.addItem(item(L10n.t("歌词管理…"), symbol: "music.note.list",
                          selector: #selector(openLyricsManager)))
        return menu
    }

    private func item(_ title: String, symbol: String, selector: Selector) -> NSMenuItem {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        return item(title, image: image, selector: selector)
    }

    private func item(_ title: String, image: NSImage?, selector: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.target = self
        menuItem.isEnabled = true
        menuItem.image = image
        return menuItem
    }

    @objc private func openSettings() { AppActions.shared.openSettings?() }
    @objc private func openLyricsManager() { AppActions.shared.openLyricsManager?() }
}
