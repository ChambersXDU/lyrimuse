import Combine
import Foundation

@MainActor
final class AppActions {
    static let shared = AppActions()

    var openSettings: (() -> Void)?
    var openLyricsManager: (() -> Void)?
    var openLyricsWindow: (() -> Void)?
    var openOnboarding: (() -> Void)?

    var openLyricsQuickSearch: (() -> Void)?

    let quickSearchRefreshRequests = PassthroughSubject<Void, Never>()

    var pendingSettingsSelection: SettingsSidebarItem?

    let selectionRequests = PassthroughSubject<SettingsSidebarItem, Never>()

    func requestSettings(_ item: SettingsSidebarItem) {
        pendingSettingsSelection = item
        selectionRequests.send(item)
    }

    var suppressLyricsOnReopenUntil: Date?

    private init() {}
}
