import SwiftUI

@main
struct LyrimuseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @ObservedObject private var languageSettings = AppSettings.shared

    var body: some Scene {

        Settings {
            SettingsView()
        }
        Window(L10n.t("歌词管理"), id: "lyrics-manager") {
            LyricsManagerView()
        }

        Window(L10n.t("搜索歌词…"), id: "lyrics-quick-search") {
            LyricsQuickSearchWindow()
        }

    }
}
