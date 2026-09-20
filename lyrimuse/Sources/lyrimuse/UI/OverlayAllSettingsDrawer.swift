import LyrimuseCore
import SwiftUI

@MainActor
struct OverlayAllSettingsDrawer: View {
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.settingsSearchPendingDrawer) private var pendingSearchDrawer

    @State private var isExpanded = false

    var body: some View {
        SettingsCard {
            disclosureHeader
            if isExpanded {
                CardDivider()

                themeGroup
                CardDivider()
                textGroup
                CardDivider()
                backgroundGroup
                CardDivider()
                layoutGroup
                CardDivider()
                widthRow
                CardDivider()
                behaviorGroup
                placementGroup
                CardDivider()
                resetRow
            }
        }

        .onAppear { expandForSearchIfNeeded() }
        .onChange(of: pendingSearchDrawer) { _, _ in expandForSearchIfNeeded() }

    }

    private func expandForSearchIfNeeded() {
        guard pendingSearchDrawer == .overlay else { return }
        if !isExpanded {
            withAnimation(.settingsCardReveal) { isExpanded = true }
        }
        SettingsSearchRouter.shared.consumeDrawer(.overlay)
    }

    private var disclosureHeader: some View {
        Button {
            withAnimation(.settingsCardReveal) { isExpanded.toggle() }
        } label: {

            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(L10n.t("全部设置"))
                    .font(.system(size: 13))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("全部设置"))

        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityValue(isExpanded ? L10n.t("已展开") : L10n.t("已折叠"))
    }

    private var themeGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("主题"))
            CardDivider()
            OverlayThemeSettingsRows()
        }
    }

    private var backgroundGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("背景"))
            CardDivider()
            OverlayBackgroundSettingsRows()
        }
    }

    private var textGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("文字"))
            CardDivider()
            OverlayTextSettingsRows()
        }
    }

    private var layoutGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("排版"))
            CardDivider()
            OverlayLayoutSettingsRows()
        }
    }

    private var behaviorGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("行为"))
            CardDivider()
            OverlayBehaviorSettingsRows()
        }
    }

    private var placementGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("位置"))
            CardDivider()
            OverlayPlacementSettingsRows()
        }
    }

    private var widthRow: some View {
        SettingsRow(icon: "arrow.left.and.right", title: L10n.t("宽度")) {
            HStack(spacing: 8) {

                SteppedSlider(value: Binding(
                    get: { settings.overlayWidth },
                    set: { newValue in

                        guard newValue != settings.overlayWidth else { return }
                        settings.overlayWidth = newValue

                        if settings.classicOverlayEnabled {
                            LyricsOverlayWindowController.shared.setWidth(newValue)
                        }
                    }
                ), in: OverlayEditorStage.widthRange, step: 10)
                .frame(width: 150)
                Text(String(format: L10n.t("%@pt"), "\(Int(settings.overlayWidth))"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    private var resetRow: some View {
        SettingsRow(
            icon: "arrow.uturn.backward",
            title: L10n.t("恢复默认")
        ) {
            Button(L10n.t("恢复")) { OverlayStyleDefaults.restoreTextAndColors() }
        }
    }
}
