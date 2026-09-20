import AppKit
import KeyboardShortcuts
import LyrimuseCore

extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self("toggleOverlay")
    static let toggleLockPosition = Self("toggleLockPosition")
    static let openLyricsManagerHotkey = Self("openLyricsManagerHotkey")
    static let openLyricsWindowHotkey = Self("openLyricsWindowHotkey")
    static let openSettingsHotkey = Self("openSettingsHotkey")
    static let playPauseHotkey = Self("playPauseHotkey")
    static let nextTrackHotkey = Self("nextTrackHotkey")
    static let previousTrackHotkey = Self("previousTrackHotkey")
    static let lyricsAdvanceHotkey = Self("lyricsAdvanceHotkey")
    static let lyricsDelayHotkey = Self("lyricsDelayHotkey")

    static let lyricsQuickSearchHotkey = Self("lyricsQuickSearchHotkey")
    static let toggleTranslationHotkey = Self("toggleTranslationHotkey")
    static let toggleRomanizationHotkey = Self("toggleRomanizationHotkey")
    static let toggleNotchOverlayHotkey = Self("toggleNotchOverlayHotkey")
    static let toggleMenuBarLyricsHotkey = Self("toggleMenuBarLyricsHotkey")
    static let lyricsOffsetResetHotkey = Self("lyricsOffsetResetHotkey")

    static let allLyrimuseNames: [Self] = [
        .toggleOverlay, .toggleLockPosition, .openLyricsManagerHotkey,
        .openLyricsWindowHotkey, .openSettingsHotkey, .playPauseHotkey,
        .nextTrackHotkey, .previousTrackHotkey, .lyricsAdvanceHotkey, .lyricsDelayHotkey,
        .lyricsQuickSearchHotkey, .toggleTranslationHotkey, .toggleRomanizationHotkey,
        .toggleNotchOverlayHotkey, .toggleMenuBarLyricsHotkey, .lyricsOffsetResetHotkey,
    ]

    static func title(for name: Self) -> String {
        switch name {
        case .toggleOverlay: return L10n.t("显示/隐藏悬浮歌词")
        case .toggleLockPosition: return L10n.t("锁定/解锁位置")
        case .openLyricsManagerHotkey: return L10n.t("打开歌词管理")
        case .openLyricsWindowHotkey: return L10n.t("打开歌词窗口")
        case .openSettingsHotkey: return L10n.t("打开设置")
        case .playPauseHotkey: return L10n.t("播放/暂停")
        case .nextTrackHotkey: return L10n.t("下一首")
        case .previousTrackHotkey: return L10n.t("上一首")
        case .lyricsAdvanceHotkey: return L10n.t("歌词提前")
        case .lyricsDelayHotkey: return L10n.t("歌词延后")
        case .lyricsQuickSearchHotkey: return L10n.t("搜索歌词")
        case .toggleTranslationHotkey: return L10n.t("显示/隐藏译文")
        case .toggleRomanizationHotkey: return L10n.t("显示/隐藏发音")
        case .toggleNotchOverlayHotkey: return L10n.t("显示/隐藏灵动岛歌词")
        case .toggleMenuBarLyricsHotkey: return L10n.t("显示/隐藏菜单栏歌词")
        case .lyricsOffsetResetHotkey: return L10n.t("歌词偏移归零")
        default: return name.rawValue
        }
    }
}

@MainActor
enum GlobalHotkeys {
    static func registerAll() {

        KeyboardShortcuts.onKeyUp(for: .toggleOverlay) {
            LyricsOverlayWindowController.shared.setVisible(!AppSettings.shared.classicOverlayEnabled)
        }
        KeyboardShortcuts.onKeyUp(for: .toggleLockPosition) {

            guard AppSettings.shared.classicOverlayEnabled else {
                flashHint(icon: "lock.slash", text: L10n.t("锁定位置只对桌面悬浮歌词有效"))
                return
            }
            let overlay = LyricsOverlayWindowController.shared
            let newValue = !overlay.isPositionLocked

            AppSettings.shared.lockPosition = newValue
            overlay.setLocked(newValue)

            flashHint(icon: newValue ? "lock" : "lock.open",
                      text: newValue ? L10n.t("已锁定位置") : L10n.t("已解锁位置"))
        }
        KeyboardShortcuts.onKeyUp(for: .openLyricsManagerHotkey) {
            AppActions.shared.openLyricsManager?()
        }
        KeyboardShortcuts.onKeyUp(for: .openLyricsWindowHotkey) {
            AppActions.shared.openLyricsWindow?()
        }
        KeyboardShortcuts.onKeyUp(for: .openSettingsHotkey) {
            AppActions.shared.openSettings?()
        }

        KeyboardShortcuts.onKeyUp(for: .playPauseHotkey) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }

                PlaybackCoordinator.shared.userTogglePlayPause()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .nextTrackHotkey) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                MusicPlaybackController.nextTrack()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .previousTrackHotkey) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                MusicPlaybackController.previousTrack()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .lyricsAdvanceHotkey) {
            showOffsetBanner(PlaybackCoordinator.shared.nudgeLyricsOffset(by: AppSettings.shared.lyricsOffsetStepMs))
        }
        KeyboardShortcuts.onKeyUp(for: .lyricsDelayHotkey) {
            showOffsetBanner(PlaybackCoordinator.shared.nudgeLyricsOffset(by: -AppSettings.shared.lyricsOffsetStepMs))
        }

        KeyboardShortcuts.onKeyUp(for: .lyricsOffsetResetHotkey) {
            PlaybackCoordinator.shared.resetLyricsOffset()
            showOffsetBanner(0)
        }

        KeyboardShortcuts.onKeyUp(for: .lyricsQuickSearchHotkey) {
            AppActions.shared.openLyricsQuickSearch?()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleTranslationHotkey) {
            let on = !AppSettings.shared.showTranslation
            AppSettings.shared.showTranslation = on
            flashHint(icon: on ? "character.book.closed" : "character.book.closed.fill",
                      text: on ? L10n.t("已显示译文") : L10n.t("已隐藏译文"))
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRomanizationHotkey) {
            let on = !AppSettings.shared.showRomanization
            AppSettings.shared.showRomanization = on
            flashHint(icon: "textformat.abc",
                      text: on ? L10n.t("已显示发音") : L10n.t("已隐藏发音"))
        }

        KeyboardShortcuts.onKeyUp(for: .toggleNotchOverlayHotkey) {
            let on = !AppSettings.shared.notchOverlayEnabled
            NotchLyricsWindowController.shared.setVisible(on)
            flashHint(icon: on ? "inset.filled.topthird.square" : "square.slash",
                      text: on ? L10n.t("已显示灵动岛歌词") : L10n.t("已隐藏灵动岛歌词"))
        }

        KeyboardShortcuts.onKeyUp(for: .toggleMenuBarLyricsHotkey) {
            let on = !AppSettings.shared.showLyricsInMenuBar
            AppSettings.shared.showLyricsInMenuBar = on
            flashHint(icon: "menubar.rectangle",
                      text: on ? L10n.t("已显示菜单栏歌词") : L10n.t("已隐藏菜单栏歌词"))
        }

        #if DEBUG
        for name in KeyboardShortcuts.Name.allLyrimuseNames {
            assert(KeyboardShortcuts.Name.title(for: name) != name.rawValue,
                   "快捷键 \(name.rawValue) 没有在 KeyboardShortcuts.Name.title(for:) 里登记显示名")
        }
        #endif
    }

    private static func showOffsetBanner(_ offsetMs: Int) {
        let seconds = Double(offsetMs) / 1000
        flashHint(icon: "timer", text: String(format: "%@ %+.2fs", L10n.t("歌词偏移"), seconds))
    }

    static func flashHint(icon: String, text: String) {
        NotchTransientCenter.shared.show(.init(icon: icon, text: text, progress: nil))
        if AppSettings.shared.classicOverlayEnabled {
            LyricsOverlayWindowController.shared.flashTransientHint(text)
        }
    }
}
