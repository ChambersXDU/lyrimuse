import AppKit
import SwiftUI

@MainActor
enum MenuBarSceneActions {
    private static var anchorWindow: NSWindow?

    private static func mainMenuSettingsItem() -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            if let hit = submenu.items.first(where: {
                $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
            }) {
                return hit
            }
        }
        return nil
    }

    static func presentSettings(fallback: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let item = mainMenuSettingsItem(), let action = item.action,
           NSApp.sendAction(action, to: item.target, from: item) {
            return
        }

        fallback()
    }

    static func install() {
        guard anchorWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SceneActionRegistrar())

        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.ignoresCycle, .stationary]
        window.isReleasedWhenClosed = false

        anchorWindow = window
    }
}

private struct SceneActionRegistrar: View {
    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.openWindow) private var openWindowAction

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {

                AppActions.shared.openSettings = {
                    MenuBarSceneActions.presentSettings { openSettingsAction() }
                }
                AppActions.shared.openLyricsManager = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindowAction(id: "lyrics-manager")
                }
                AppActions.shared.openLyricsQuickSearch = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindowAction(id: "lyrics-quick-search")

                    AppActions.shared.quickSearchRefreshRequests.send()
                }
            }
    }
}
