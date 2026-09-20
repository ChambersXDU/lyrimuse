import SwiftUI

@MainActor
struct MenuBarIconPicker: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let chipSize = CGSize(width: 44, height: 28)
    private static let chipsPerRow = 6

    var body: some View {
        let styles = MenuBarIconStyle.allCases
        Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(stride(from: 0, to: styles.count, by: Self.chipsPerRow)), id: \.self) { start in
                GridRow {
                    ForEach(styles[start ..< min(start + Self.chipsPerRow, styles.count)]) { style in
                        chip(style)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("菜单栏图标"))
    }

    private func chip(_ style: MenuBarIconStyle) -> some View {
        let selected = settings.menuBarIconStyle == style
        return Button {
            settings.menuBarIconStyle = style
        } label: {
            Image(nsImage: MenuBarIconStyle.cachedImage(for: style))
                .renderingMode(.template)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: Self.chipSize.width, height: Self.chipSize.height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(style.displayName)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
