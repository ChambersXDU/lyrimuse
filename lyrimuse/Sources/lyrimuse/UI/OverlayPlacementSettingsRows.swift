import LyrimuseCore
import SwiftUI

@MainActor
struct OverlayPlacementSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "dock.rectangle",
            title: L10n.t("位置")
        ) {
            OverlayPlacementSegmentedControl(selection: $settings.overlayPlacementMode)
        }
    }
}

@MainActor
struct OverlayPlacementSegmentedControl: View {
    @Binding var selection: OverlayPlacementMode

    static func label(for mode: OverlayPlacementMode) -> String {
        switch mode {
        case .free: return L10n.t("自由")
        case .topCenter: return L10n.t("顶部居中")
        case .bottomCenter: return L10n.t("底部居中")
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OverlayPlacementMode.allCases, id: \.self) { mode in
                let isSelected = selection == mode
                Button {
                    selection = mode
                } label: {
                    Text(Self.label(for: mode))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(minWidth: 56)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .fixedSize()
    }
}

@MainActor
struct OverlayPlacementPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("位置"), width: 420) {
            OverlayPlacementSettingsRows()
        }
    }
}
