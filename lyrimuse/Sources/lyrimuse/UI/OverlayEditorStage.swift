import AppKit
import LyrimuseCore
import SwiftUI

@MainActor
final class OverlayPreviewChrome: ObservableObject, OverlayChromeSource {
    let isHoveringForControls = false
    let isHoveringLyrics = false

    let isHoveringControlPill = false

    let hoveredControl: OverlayControlID? = nil
    let isDragArmed = false
    let showDragHint = false

    let transientHint: String? = nil

    let placementLockNotice: String? = nil
    let placementLockShakeTick = 0

    func controlsDidBecomeVisible() {}
}

@MainActor
struct OverlayEditorStage: View {

    init() {}

    @ObservedObject private var settings = AppSettings.shared

    @StateObject private var chrome = OverlayPreviewChrome()

    @State private var overlayContentHeight: CGFloat = 0

    @State private var popover: StagePopover?

    @State private var adjustingWidth = false

    private static let widthBarLaneHeight: CGFloat = 44

    private static let maxCardHeight: CGFloat = 266

    private static var cardAreaHeight: CGFloat { maxCardHeight }

    static var stageHeight: CGFloat { cardAreaHeight + widthBarLaneHeight }

    private var cardHeight: CGFloat {
        min(max(Self.overlayWindowDefaultHeight, ceil(overlayContentHeight)), Self.maxCardHeight)
    }

    private static let overlayWindowDefaultHeight: CGFloat = 120

    private static var previewLine: OverlayPreviewLine {
        OverlayPreviewLine(
            line: SyncedLyricLine(
                romanization: L10n.t("这里是罗马音示例"),
                translation: L10n.t("这里是译文示例"),
                mainText: L10n.t("这里是一句歌词示例"),
                words: nil, wordGroups: nil, side: nil),
            nextLineText: L10n.t("这里是下一句歌词示例"))
    }

    private static let widthBarSliderWidth: CGFloat = 168
    private static let widthBarBottomInset: CGFloat = 12

    private static let overflowFadeWidth: CGFloat = 20

    private static let toolbarHeight: CGFloat = 26

    private static let toolbarSpacing: CGFloat = 10

    static var totalHeight: CGFloat {
        (toolbarHeight + toolbarSpacing) * 2 + stageHeight
    }

    static let widthRange: ClosedRange<Double> = 300 ... 1400

    static let widthStep: Double = 2

    @State private var draggingWidth: Double?

    private var windowWidth: CGFloat { CGFloat(draggingWidth ?? settings.overlayWidth) }

    private static func isOverflowing(cardWidth: CGFloat, stageWidth: CGFloat) -> Bool {

        cardWidth > stageWidth + 0.5
    }

    private static func visibleCardWidth(cardWidth: CGFloat, stageWidth: CGFloat) -> CGFloat {
        min(cardWidth, stageWidth)
    }

    var body: some View {
        GeometryReader { geo in

            let stageWidth = geo.size.width
            VStack(spacing: Self.toolbarSpacing) {
                toolbar
                    .frame(height: Self.toolbarHeight)
                toolbarRow2
                    .frame(height: Self.toolbarHeight)

                stage(stageWidth: stageWidth)
            }
            .frame(maxWidth: .infinity)
        }

        .frame(height: Self.totalHeight)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {

            toolbarButton(
                icon: "circle.lefthalf.filled",
                title: L10n.t("主题"),
                summary: OverlayStyleSummary.theme,
                target: .theme
            )
            toolbarButton(
                icon: "textformat",
                title: L10n.t("文字"),
                summary: OverlayStyleSummary.text,
                target: .text
            )
            toolbarButton(
                icon: "rectangle.fill",
                title: L10n.t("背景"),
                summary: OverlayStyleSummary.background,
                target: .background
            )
            Spacer(minLength: 8)
            Menu {
                Button(L10n.t("恢复默认")) { OverlayStyleDefaults.restoreTextAndColors() }

                Text(L10n.t("不含排版、行为、位置和宽度"))
            } label: {
                Label(L10n.t("重置"), systemImage: "arrow.uturn.backward")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    private var toolbarRow2: some View {
        HStack(spacing: 8) {

            toolbarButton(
                icon: "text.justify",
                title: L10n.t("排版"),
                summary: OverlayStyleSummary.layout,
                target: .layout
            )
            toolbarButton(
                icon: "switch.2",
                title: L10n.t("行为"),
                summary: behaviorSummary,
                target: .behavior
            )

            toolbarButton(
                icon: "dock.rectangle",
                title: L10n.t("位置"),
                summary: OverlayPlacementSegmentedControl.label(for: settings.overlayPlacementMode),
                target: .placement
            )
            Spacer(minLength: 8)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    private var behaviorSummary: String {
        SettingsToggleSummary.text(
            OverlayBehaviorItem.allCases.map { (title: $0.title, isOn: $0.binding.wrappedValue) }
                + AutoHideItem.allCases.map {
                    (title: $0.title, isOn: $0.binding(for: .desktopOverlay).wrappedValue)
                })
    }

    private func toolbarButton(
        icon: String, title: String, summary: String, target: StagePopover
    ) -> some View {
        Button {
            popover = target
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))

                    .environment(\.locale, Locale(identifier: "en"))
                Text(title)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.tertiary)

                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)

                    .layoutPriority(-1)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: popoverBinding(target), arrowEdge: .bottom) {
            popoverContent(for: target)
        }
    }

    private enum StagePopover: Equatable {

        case theme
        case text
        case background
        case layout

        case behavior

        case placement
    }

    private func popoverBinding(_ target: StagePopover) -> Binding<Bool> {
        Binding(
            get: { popover == target },

            set: { shown in
                if shown { popover = target } else if popover == target { popover = nil }
            })
    }

    @ViewBuilder
    private func popoverContent(for target: StagePopover) -> some View {
        switch target {
        case .theme: OverlayThemePopover()
        case .text: OverlayTextPopover()
        case .background: OverlayBackgroundPopover()
        case .layout: OverlayLayoutPopover()
        case .behavior: OverlayBehaviorPopover()
        case .placement: OverlayPlacementPopover()
        }
    }

    private func stage(stageWidth: CGFloat) -> some View {
        let cardWidth = windowWidth
        let visibleWidth = Self.visibleCardWidth(cardWidth: cardWidth, stageWidth: stageWidth)
        return ZStack {
            stageBackground
            desktopSurround(stageWidth: stageWidth)
            inCardSlot { canvas(visibleWidth: visibleWidth) }
            inCardSlot { windowEdgeOutline(cardWidth: cardWidth) }

            if Self.isOverflowing(cardWidth: cardWidth, stageWidth: stageWidth) {
                inCardSlot { overflowFade }
            }

            widthBar
                .padding(.bottom, Self.widthBarBottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            if Self.isOverflowing(cardWidth: cardWidth, stageWidth: stageWidth) {
                overflowHint
                    .padding(.leading, Self.widthBarBottomInset)
                    .padding(.bottom, Self.widthBarBottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }

        .frame(width: stageWidth, height: Self.stageHeight)

        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func inCardSlot<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(height: Self.cardAreaHeight)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var stageBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.05))
    }

    private func desktopSurround(stageWidth: CGFloat) -> some View {
        OverlayDesktopSurface()
            .frame(width: stageWidth, height: Self.stageHeight)
            .clipped()
            .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.16))

            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func canvas(visibleWidth: CGFloat) -> some View {
        let cardWidth = windowWidth
        return LyricsOverlayView(
            overlayController: chrome,
            onContentHeightChange: { overlayContentHeight = $0 },

            showsDebugHUD: false,
            previewLine: Self.previewLine)
            .frame(width: cardWidth, height: cardHeight, alignment: .top)

            .clipped()

            .overlay(alignment: .bottomLeading) {
                lockBadge(clippedInset: (cardWidth - visibleWidth) / 2)
            }

            .animation(.easeOut(duration: 0.15), value: settings.lockPosition)
    }

    @ViewBuilder
    private func lockBadge(clippedInset: CGFloat) -> some View {
        if settings.lockPosition {
            HStack(spacing: 3) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                Text(L10n.t("位置已锁定"))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .foregroundStyle(.white)
            .padding(6)

            .padding(.leading, clippedInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    private var overflowFade: some View {
        HStack(spacing: 0) {
            fadeEdge(leading: true)
            Spacer(minLength: 0)
            fadeEdge(leading: false)
        }
        .frame(height: cardHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func fadeEdge(leading: Bool) -> some View {
        let page = Color(nsColor: .windowBackgroundColor)
        let colors = leading ? [page, page.opacity(0)] : [page.opacity(0), page]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            .frame(width: Self.overflowFadeWidth)
    }

    private func windowEdgeOutline(cardWidth: CGFloat) -> some View {
        let strong = adjustingWidth
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                Color.white.opacity(strong ? 0.95 : 0.5),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .shadow(color: .black.opacity(0.55), radius: 1)
            .frame(width: cardWidth, height: cardHeight)

            .opacity(settings.backgroundIsVisible ? 0 : 1)

            .animation(.easeOut(duration: 0.12), value: strong)
            .animation(.easeOut(duration: 0.15), value: settings.backgroundIsVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var widthBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))

            Slider(
                value: widthBinding,
                in: Self.widthRange,

                onEditingChanged: { editing in
                    adjustingWidth = editing

                    if !editing, let pending = draggingWidth {
                        commitWidth(pending)
                        draggingWidth = nil
                    }
                }
            )
            .controlSize(.small)
            .tint(.white)
            .frame(width: Self.widthBarSliderWidth)

            .accessibilityLabel(L10n.t("悬浮歌词宽度"))
            .accessibilityValue(widthValueText)
            Text(widthValueText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

                .accessibilityHidden(true)
        }

        .overlayStagePillChrome()
    }

    private var widthValueText: String {
        String(format: L10n.t("%@pt"), "\(Int(draggingWidth ?? settings.overlayWidth))")
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { draggingWidth ?? settings.overlayWidth },

            set: { draggingWidth = Self.snap($0) })
    }

    private func commitWidth(_ raw: Double) {
        let next = Self.snap(raw)
        guard next != settings.overlayWidth else { return }
        settings.overlayWidth = next
        if settings.classicOverlayEnabled {
            LyricsOverlayWindowController.shared.setWidth(CGFloat(next))
        }
    }

    private static func snap(_ raw: Double) -> Double {
        let clamped = min(max(raw, widthRange.lowerBound), widthRange.upperBound)
        return (clamped / widthStep).rounded() * widthStep
    }

    private var overflowHint: some View {
        Text(L10n.t("两端已裁切"))
            .font(.system(size: 11, weight: .medium))
            .overlayStagePillChrome()
    }
}

private extension View {
    func overlayStagePillChrome() -> some View {
        foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
    }
}
