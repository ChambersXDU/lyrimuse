import LyrimuseCore
import SwiftUI

enum AutoHideSurface {
    case desktopOverlay
    case notch
}

enum AutoHideItem: String, CaseIterable, Identifiable {
    case duringScreenCapture
    case whenNotPlaying

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .duringScreenCapture: return "camera.viewfinder"
        case .whenNotPlaying: return "pause.circle"
        }
    }

    var title: String {
        switch self {
        case .duringScreenCapture: return L10n.t("截屏/录屏时隐藏")
        case .whenNotPlaying: return L10n.t("暂停/无播放时隐藏")
        }
    }

    var subtitle: String? {
        switch self {
        case .duringScreenCapture: return L10n.t("别人看不到，你仍看得见")
        case .whenNotPlaying: return nil
        }
    }

    var help: String? {
        switch self {
        case .duringScreenCapture: return L10n.t("截图、录屏、视频会议共享屏幕都拍不到它")
        case .whenNotPlaying: return nil
        }
    }

    @MainActor
    func binding(for surface: AutoHideSurface) -> Binding<Bool> {
        let settings = AppSettings.shared
        switch (surface, self) {
        case (.desktopOverlay, .duringScreenCapture):
            return Binding(
                get: { settings.hideDuringScreenCapture },
                set: { newValue in
                    settings.hideDuringScreenCapture = newValue
                    if settings.classicOverlayEnabled {
                        LyricsOverlayWindowController.shared.setHiddenFromCapture(newValue)
                    }
                })
        case (.desktopOverlay, .whenNotPlaying):
            return Binding(
                get: { settings.hideWhenNotPlaying },
                set: { newValue in
                    settings.hideWhenNotPlaying = newValue
                    if settings.classicOverlayEnabled {
                        LyricsOverlayWindowController.shared.setHideWhenNotPlaying(newValue)
                    }
                })
        case (.notch, .duringScreenCapture):
            return Binding(
                get: { settings.notchHideDuringScreenCapture },
                set: { newValue in
                    settings.notchHideDuringScreenCapture = newValue
                    if settings.notchOverlayEnabled {
                        NotchLyricsWindowController.shared.setHiddenFromCapture(newValue)
                    }
                })

        case (.notch, .whenNotPlaying):
            return Binding(
                get: { settings.notchHideWhenNotPlaying },
                set: { newValue in
                    settings.notchHideWhenNotPlaying = newValue
                    if settings.notchOverlayEnabled {
                        NotchLyricsWindowController.shared.setHideWhenNotPlaying(newValue)
                    }
                })
        }
    }
}

@MainActor
struct AutoHideSettingsRows: View {
    let surface: AutoHideSurface
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(AutoHideItem.allCases.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardDivider() }
                SettingsRow(
                    icon: item.icon,
                    title: item.title,
                    subtitle: item.subtitle,
                    help: item.help
                ) {
                    Toggle("", isOn: item.binding(for: surface))
                }
            }
        }
    }
}
