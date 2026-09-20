import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

enum ShortcutConflict {
    enum Kind {

        case otherHotkey(String)

        case mainMenu(String)

        case system

        var message: String {
            switch self {
            case .otherHotkey(let title):
                return String(format: L10n.t("这个组合已经分配给「%@」了。"), title)
            case .mainMenu(let title):
                return String(format: L10n.t("这个组合是本 App 菜单里「%@」的快捷键。"), title)
            case .system:
                return L10n.t("这个组合已被 macOS 系统占用。")
            }
        }

        var hint: String {
            switch self {
            case .otherHotkey:
                return L10n.t("换一个组合，或者先清除那一项。")
            case .mainMenu:
                return L10n.t("换一个组合——否则 Lyrimuse 在前台时，按下它会同时触发菜单里的那一项。")
            case .system:
                return L10n.t("换一个组合。系统占用的组合注册不上，录进去也不会生效；要用它得先到「系统设置 → 键盘 → 键盘快捷键」里把系统那一项关掉。")
            }
        }
    }

    @MainActor
    static func check(
        _ shortcut: KeyboardShortcuts.Shortcut,
        event: NSEvent,
        recording name: KeyboardShortcuts.Name
    ) -> Kind? {

        for other in KeyboardShortcuts.Name.allLyrimuseNames where other != name {
            if KeyboardShortcuts.getShortcut(for: other) == shortcut {
                return .otherHotkey(KeyboardShortcuts.Name.title(for: other))
            }
        }
        if let item = mainMenuItem(matching: event) {
            return .mainMenu(item)
        }
        if isTakenBySystem(shortcut) {
            return .system
        }
        return nil
    }

    @MainActor
    private static func mainMenuItem(matching event: NSEvent) -> String? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
        return search(mainMenu, chars: chars, modifiers: modifiers)
    }

    @MainActor
    private static func search(_ menu: NSMenu, chars: String, modifiers: NSEvent.ModifierFlags) -> String? {
        for item in menu.items {
            var equivalent = item.keyEquivalent
            var mask = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])

            if equivalent.lowercased() != equivalent {
                equivalent = equivalent.lowercased()
                mask.insert(.shift)
            }
            if equivalent == chars, mask == modifiers {
                return item.title
            }
            if let submenu = item.submenu, let hit = search(submenu, chars: chars, modifiers: modifiers) {
                return hit
            }
        }
        return nil
    }

    private static func isTakenBySystem(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {

        if shortcut.carbonKeyCode == kVK_F12, shortcut.carbonModifiers == 0 { return false }

        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr,
              let entries = raw?.takeRetainedValue() as? [[String: Any]]
        else {

            return false
        }
        for e in entries {
            guard (e[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = e[kHISymbolicHotKeyCode] as? Int,
                  let mods = e[kHISymbolicHotKeyModifiers] as? Int
            else { continue }
            if code == shortcut.carbonKeyCode, mods == shortcut.carbonModifiers { return true }
        }
        return false
    }

    @MainActor
    static func present(_ kind: Kind, over window: NSWindow?) {
        NSSound.beep()
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = kind.message
            alert.informativeText = kind.hint
            alert.addButton(withTitle: L10n.t("好"))
            if let window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }
}
