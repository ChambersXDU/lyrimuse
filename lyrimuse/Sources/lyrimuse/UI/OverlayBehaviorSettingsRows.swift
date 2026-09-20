import LyrimuseCore
import SwiftUI

enum OverlayBehaviorItem: String, CaseIterable, Identifiable {
    case lockPosition
    case dragNeedsLongPress
    case fadeOnHover

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .lockPosition: return "lock"
        case .dragNeedsLongPress: return "hand.tap"
        case .fadeOnHover: return "cursorarrow.motionlines"
        }
    }

    var title: String {
        switch self {
        case .lockPosition: return L10n.t("锁定位置")
        case .dragNeedsLongPress: return L10n.t("长按拖动")
        case .fadeOnHover: return L10n.t("悬浮淡化")
        }
    }

    @MainActor
    var binding: Binding<Bool> {
        let settings = AppSettings.shared
        switch self {
        case .lockPosition:
            return Binding(
                get: { settings.lockPosition },
                set: { newValue in
                    settings.lockPosition = newValue

                    if settings.classicOverlayEnabled {
                        LyricsOverlayWindowController.shared.setLocked(newValue)
                    }
                })
        case .dragNeedsLongPress:
            return Binding(
                get: { settings.overlayDragNeedsLongPress },
                set: { settings.overlayDragNeedsLongPress = $0 })
        case .fadeOnHover:
            return Binding(
                get: { settings.overlayFadeOnHover },
                set: { newValue in
                    settings.overlayFadeOnHover = newValue

                    if settings.classicOverlayEnabled {
                        LyricsOverlayWindowController.shared.setFadeOnHover(newValue)
                    }
                })
        }
    }
}

@MainActor
struct OverlayBehaviorSettingsRows: View {
    var body: some View {
        VStack(spacing: 0) {

            ForEach(Array(OverlayBehaviorItem.allCases.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardDivider() }
                SettingsRow(icon: item.icon, title: item.title) {
                    Toggle("", isOn: item.binding)
                }
            }
            CardDivider()
            AutoHideSettingsRows(surface: .desktopOverlay)
        }
    }
}

@MainActor
struct OverlayBehaviorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("行为"), width: 420) {
            OverlayBehaviorSettingsRows()
        }
    }
}
