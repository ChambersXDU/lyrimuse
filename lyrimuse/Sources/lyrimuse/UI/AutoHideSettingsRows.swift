import LyrimuseCore
import SwiftUI

enum AutoHideSurface {
    case desktopOverlay
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
                    title: item.title
                ) {
                    Toggle("", isOn: item.binding(for: surface))
                }
            }
        }
    }
}
