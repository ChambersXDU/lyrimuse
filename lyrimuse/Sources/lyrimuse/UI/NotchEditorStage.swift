import AppKit
import LyrimuseCore
import SwiftUI

@MainActor
final class NotchPreviewChrome: ObservableObject, NotchChromeSource {
    @Published private(set) var isExpanded = false
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var contentTopInset: CGFloat = 0

    @Published private(set) var steadyCardWidth: CGFloat = AppSettings.defaultNotchContentWidth
    @Published private(set) var expandedCardWidth: CGFloat = AppSettings.defaultNotchContentWidth

    func setCardWidths(steady: CGFloat, expanded: CGFloat) {
        if steadyCardWidth != steady { steadyCardWidth = steady }
        if expandedCardWidth != expanded { expandedCardWidth = expanded }
    }

    var isCollapsed: Bool { false }

    var expandedShowsLyricPreview: Bool { true }
    var expandedShowsScrubber: Bool { true }

    var hasTrack: Bool { true }

    var isAdBreakNow: Bool { false }

    var showsLyrics: Bool { AppSettings.shared.notchShowLyrics }

    var showsEqualizer: Bool { AppSettings.shared.notchShowsEqualizer }
    var equalizerEar: NotchEqualizerEar { AppSettings.shared.notchEqualizerEar }

    var expandedShowsNextLine: Bool {
        LyricSecondaryLine.expandedNextLinePreviewVisible(
            userToggle: AppSettings.shared.notchExpandedShowsNextLine, secondary: AppSettings.shared.notchSecondaryLine)
    }
    var expandedShowsControls: Bool { AppSettings.shared.notchExpandedShowsControls }
    var expandedTrackInfoShowsArtwork: Bool { AppSettings.shared.notchExpandedShowsArtwork }
    var expandedTrackInfoShowsTitle: Bool { AppSettings.shared.notchExpandedShowsTrackTitle }
    var expandedTrackInfoShowsArtist: Bool { AppSettings.shared.notchExpandedShowsArtist }
    var expandedTrackInfoShowsAlbum: Bool { AppSettings.shared.notchExpandedShowsAlbum }
    var expandedShowsQuickActions: Bool { AppSettings.shared.notchExpandedShowsQuickActions }

    init() { refreshGeometry() }

    func setExpanded(_ expanded: Bool) {}

    func closeFromQuickAction() {}

    func setExpandedFromPreview(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
    }

    func refreshGeometry() {
        guard let screen = NotchLyricsWindowController.targetScreen() else { return }
        let geo = NotchLyricsWindowController.geometry(for: screen)
        notchWidth = geo.notchWidth
        contentTopInset = geo.notchHeight
    }
}

@MainActor
struct NotchEditorStage: View {

    init() {}

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var chrome = NotchPreviewChrome()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var popover: StagePopover?

    @State private var popoverAnchor: PopoverAnchor = .toolbar

    private enum PopoverAnchor: Equatable {
        case toolbar

        case hotspot(CardHotspot.Kind, rectIndex: Int)
    }

    @State private var hoveredHotspot: CardHotspot.Kind?

    @State private var adjustingThumb: NotchWidthRangeDrag.Thumb?

    @State private var draggingSteady: Double?
    @State private var draggingExpanded: Double?

    private static let widthBarLaneHeight: CGFloat = 56

    private static let widthBarSliderWidth: CGFloat = 168
    private static let widthBarBottomInset: CGFloat = 12

    private static let toolbarHeight: CGFloat = 26
    private static let toolbarSpacing: CGFloat = 10

    static let widthRange: ClosedRange<Double> = 200 ... 800

    static func usableWidthRange(notchWidth: CGFloat,
                                 contentTopInset: CGFloat) -> ClosedRange<Double> {
        let earFloor = Double(NotchLyricsWindowController.contentWidth(
            baseWidth: CGFloat(widthRange.lowerBound), notchWidth: notchWidth,
            contentTopInset: contentTopInset))
        let ceiled = (earFloor / widthStep).rounded(.up) * widthStep
        let lower = min(ceiled, widthRange.upperBound - widthStep)
        return lower ... widthRange.upperBound
    }

    static var usableWidthRangeOnCurrentScreen: ClosedRange<Double> {
        let geo = NotchLyricsWindowController.targetScreen()
            .map { NotchLyricsWindowController.geometry(for: $0) }
        return usableWidthRange(notchWidth: geo?.notchWidth ?? 0,
                                contentTopInset: geo?.notchHeight ?? 0)
    }

    static func usableExpandedWidthRange(steadyWidth: Double) -> ClosedRange<Double> {
        let ceiled = (steadyWidth / widthStep).rounded(.up) * widthStep
        let lower = min(max(ceiled, widthRange.lowerBound), widthRange.upperBound - widthStep)
        return lower ... widthRange.upperBound
    }

    static var usableExpandedWidthRangeOnCurrentScreen: ClosedRange<Double> {
        usableExpandedWidthRange(steadyWidth: effectiveWidth(baseWidth: AppSettings.shared.notchContentWidth))
    }

    static func commitWidths(steady: Double? = nil, expanded: Double? = nil) {
        let settings = AppSettings.shared
        let next = NotchWidthBounds.normalized(
            steady: steady ?? settings.notchContentWidth,
            expanded: expanded ?? settings.notchExpandedContentWidth)
        var changed = false
        if next.expanded != settings.notchExpandedContentWidth {
            settings.notchExpandedContentWidth = next.expanded
            changed = true
        }
        if next.steady != settings.notchContentWidth {
            settings.notchContentWidth = next.steady
            changed = true
        }
        guard changed, settings.notchOverlayEnabled else { return }
        NotchLyricsWindowController.shared.applyContentWidthSetting()
    }

    static let widthStep: Double = 2

    private var cardAreaHeight: CGFloat {
        chrome.contentTopInset + NotchMetrics.compactRowHeight + NotchMetrics.expandedExtraHeightMax(
            hasLyricPreviewPossible: chrome.expandedShowsNextLine,
            hasControlsPossible: chrome.expandedShowsControls,
            trackInfoHeight: NotchMetrics.expandedTrackInfoHeight(
                showsArtwork: chrome.expandedTrackInfoShowsArtwork,
                showsTitle: chrome.expandedTrackInfoShowsTitle,
                showsArtist: chrome.expandedTrackInfoShowsArtist,
                showsAlbum: chrome.expandedTrackInfoShowsAlbum,
                showsActions: chrome.expandedShowsQuickActions))
    }

    private var stageHeight: CGFloat { cardAreaHeight + Self.widthBarLaneHeight }

    private var totalHeight: CGFloat {
        (Self.toolbarHeight + Self.toolbarSpacing) * 2
            + stageHeight + SectionPreviewMetrics.captionSpacing + SectionPreviewMetrics.captionHeight
    }

    private var baseWidth: Double { draggingSteady ?? settings.notchContentWidth }

    private var expandedBaseWidth: Double { draggingExpanded ?? settings.notchExpandedContentWidth }

    static func effectiveWidth(baseWidth: Double) -> Double {
        let geo = NotchLyricsWindowController.targetScreen()
            .map { NotchLyricsWindowController.geometry(for: $0) }
        return Double(NotchLyricsWindowController.contentWidth(
            baseWidth: CGFloat(baseWidth), notchWidth: geo?.notchWidth ?? 0,
            contentTopInset: geo?.notchHeight ?? 0))
    }

    static func effectiveExpandedWidth(steadyBase: Double, expandedBase: Double) -> Double {
        Double(NotchWidthBounds.expandedWidth(
            steady: CGFloat(effectiveWidth(baseWidth: steadyBase)),
            expandedSetting: CGFloat(expandedBase)))
    }

    private var steadyCardWidth: CGFloat {
        NotchLyricsWindowController.contentWidth(
            baseWidth: CGFloat(baseWidth), notchWidth: chrome.notchWidth,
            contentTopInset: chrome.contentTopInset)
    }

    private var expandedCardWidth: CGFloat {
        NotchWidthBounds.expandedWidth(steady: steadyCardWidth, expandedSetting: CGFloat(expandedBaseWidth))
    }

    private var cardWidth: CGFloat {
        chrome.isExpanded ? expandedCardWidth : steadyCardWidth
    }

    private var cardHeight: CGFloat { chrome.cardHeight }

    var body: some View {
        GeometryReader { geo in

            let stageWidth = geo.size.width
            VStack(spacing: Self.toolbarSpacing) {
                toolbar
                    .frame(height: Self.toolbarHeight)
                toolbarRow2
                    .frame(height: Self.toolbarHeight)
                VStack(spacing: SectionPreviewMetrics.captionSpacing) {
                    stage(stageWidth: stageWidth)
                    caption(stageWidth: stageWidth)
                }
            }
            .frame(maxWidth: .infinity)
        }

        .frame(height: totalHeight)

        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: chrome.contentTopInset)

        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            chrome.refreshGeometry()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolbarButton(
                icon: "paintbrush.pointed",
                title: L10n.t("风格"),
                summary: settings.notchCardStyle.displayName,
                target: .style
            )
            toolbarButton(
                icon: "display",
                title: L10n.t("屏幕"),
                summary: NotchScreenSummary.current,
                target: .screen
            )

            toolbarButton(
                icon: "arrow.left.to.line",
                title: L10n.t("左耳"),
                summary: earSummary(.left),
                target: .leftEar
            )
            toolbarButton(
                icon: "arrow.right.to.line",
                title: L10n.t("右耳"),
                summary: earSummary(.right),
                target: .rightEar
            )
            Spacer(minLength: 8)

            Menu {
                Button(L10n.t("恢复默认")) { NotchStyleDefaults.restoreDefaults() }
                Text(L10n.t("不含宽度和总开关"))
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
                icon: "text.alignleft",
                title: L10n.t("歌词行"),
                summary: lyricRowSummary,
                target: .lyricRow
            )

            toolbarButton(
                icon: "textformat",
                title: L10n.t("字体"),
                summary: fontSummary,
                target: .font
            )
            toolbarButton(
                icon: "rectangle.expand.vertical",
                title: L10n.t("展开态"),
                summary: expandedSummary,
                target: .expanded
            )
            toolbarButton(
                icon: "switch.2",
                title: L10n.t("行为"),
                summary: behaviorSummary,
                target: .behavior
            )
            Spacer(minLength: 8)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    private var fontSummary: String {
        OverlayStyleSummary.fontText(family: settings.notchFontFamilyName, weight: settings.notchFontWeight,
                                     size: Int(settings.notchFontSize))
    }

    private var lyricRowSummary: String {
        var parts: [String] = []
        if settings.notchShowLyrics { parts.append(NotchBehaviorItem.showLyrics.title) }

        if settings.notchLyricsAlignment != AppSettings.defaultNotchLyricsAlignment {
            parts.append(LyricsAlignmentSegmentedControl.label(for: settings.notchLyricsAlignment))
        }

        if settings.notchSecondaryLine != AppSettings.defaultNotchSecondaryLine {
            parts.append("\(L10n.t("副行")) · \(settings.notchSecondaryLine.displayName)")
        }

        if !settings.notchSecondaryLine.hidesExpandedNextLinePreview, settings.notchExpandedShowsNextLine {
            parts.append(NotchBehaviorItem.expandedNextLine.title)
        }
        if settings.notchLyricRowShowsArtwork {
            parts.append("\(NotchEarModule.artwork.displayName) · \(settings.notchLyricRowArtworkPosition.displayName)")
        }
        guard !parts.isEmpty else { return L10n.t("全部关闭") }
        return ListFormatter.localizedString(byJoining: parts)
    }

    @MainActor
    private func behaviorLikeSummary(_ items: [NotchBehaviorItem]) -> String {
        toggleSummary(items.map { (title: $0.title, isOn: $0.binding.wrappedValue) })
    }

    @MainActor
    private func toggleSummary(_ entries: [(title: String, isOn: Bool)]) -> String {
        SettingsToggleSummary.text(entries)
    }

    private var behaviorSummary: String {
        toggleSummary(
            [(title: NotchBehaviorItem.collapseWhenPaused.title,
              isOn: NotchBehaviorItem.collapseWhenPaused.binding.wrappedValue)]
                + AutoHideItem.allCases.map {
                    (title: $0.title, isOn: $0.binding(for: .notch).wrappedValue)
                })
    }

    private var expandedSummary: String {
        behaviorLikeSummary([
            .expandedShowsControls, .expandedShowsLyricsOffset, .expandedShowsQuickActions, .expandedShowsArtwork,
            .expandedShowsTrackTitle, .expandedShowsArtist, .expandedShowsAlbum,
        ])
    }

    private func earSummary(_ side: NotchEarPopover.Side) -> String {
        let module = side == .left ? settings.notchLeftEar : settings.notchRightEar
        let equalizerHere = settings.notchShowsEqualizer
            && settings.notchEqualizerEar == (side == .left ? NotchEqualizerEar.left : .right)
        guard equalizerHere else { return module.displayName }
        if module == NotchEarModule.none { return L10n.t("音浪") }
        return ListFormatter.localizedString(byJoining: [module.displayName, L10n.t("音浪")])
    }

    private func toolbarButton(
        icon: String, title: String, summary: String, target: StagePopover
    ) -> some View {
        Button {
            popoverAnchor = .toolbar
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
        case style
        case screen
        case leftEar
        case rightEar
        case lyricRow
        case font
        case behavior
        case expanded
    }

    private func popoverBinding(_ target: StagePopover) -> Binding<Bool> {
        Binding(
            get: { popover == target && popoverAnchor == .toolbar },

            set: { shown in
                if shown {
                    popoverAnchor = .toolbar
                    popover = target
                } else if popover == target, popoverAnchor == .toolbar {
                    popover = nil
                }
            })
    }

    private var hotspotPopoverBinding: Binding<Bool> {
        Binding(
            get: {
                if case .hotspot = popoverAnchor { return popover != nil }
                return false
            },
            set: { shown in
                if !shown, case .hotspot = popoverAnchor { popover = nil }
            })
    }

    @ViewBuilder
    private func popoverContent(for target: StagePopover) -> some View {
        switch target {
        case .style: NotchStylePopover()

        case .screen: NotchScreenPopover(onScreenChange: { chrome.refreshGeometry() })
        case .leftEar: NotchEarPopover(side: .left)
        case .rightEar: NotchEarPopover(side: .right)
        case .lyricRow: NotchLyricRowPopover()
        case .font: NotchFontPopover()
        case .behavior: NotchBehaviorPopover()
        case .expanded: NotchExpandedPopover()
        }
    }

    private func stage(stageWidth: CGFloat) -> some View {
        let scale = Self.previewScale(stageWidth: stageWidth, widestCardWidth: expandedCardWidth)

        let screenWidth = stageWidth / scale
        return ZStack {
            stageBackground
            desktopSurround(stageWidth: stageWidth)

            ZStack {
                atScreenTop { menuBarStrip(stageWidth: screenWidth) }
                card

                atScreenTop { notchCutout }
            }
            .frame(width: screenWidth, height: cardAreaHeight, alignment: .top)
            .scaleEffect(scale, anchor: .top)
            .frame(width: stageWidth, height: cardAreaHeight, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)

            hotspotPopoverAnchor(stageWidth: stageWidth, scale: scale)

            widthBar
                .padding(.bottom, Self.widthBarBottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }

        .frame(width: stageWidth, height: stageHeight)

        .clipShape(NotchHangingShape(bottomCornerRadius: 12))

        .overlay(
            NotchHangingShape(bottomCornerRadius: 12)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func atScreenTop<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var stageBackground: some View {
        NotchHangingShape(bottomCornerRadius: 12)
            .fill(Color.primary.opacity(0.05))
    }

    private func desktopSurround(stageWidth: CGFloat) -> some View {
        OverlayDesktopSurface()
            .frame(width: stageWidth, height: stageHeight)
            .clipped()
            .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.16))

            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func menuBarStrip(stageWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "apple.logo")
                .padding(.leading, 12)
            Spacer(minLength: 0)
            HStack(spacing: 11) {
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
                Text(Date(), style: .time)
            }
            .padding(.trailing, 12)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(nsColor: .labelColor).opacity(0.6))
        .frame(width: stageWidth, height: chrome.contentTopInset)
        .background(.ultraThinMaterial)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var notchCutout: some View {
        if chrome.notchWidth > 0 {
            NotchHangingShape(bottomCornerRadius: 8)
                .fill(Color.black)
                .frame(width: chrome.notchWidth, height: chrome.contentTopInset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var card: some View {
        NotchLyricsView(controller: chrome)

            .frame(width: cardWidth, height: cardHeight)

            .onAppear { chrome.setCardWidths(steady: steadyCardWidth, expanded: expandedCardWidth) }
            .onChange(of: steadyCardWidth) { _, w in chrome.setCardWidths(steady: w, expanded: expandedCardWidth) }
            .onChange(of: expandedCardWidth) { _, w in chrome.setCardWidths(steady: steadyCardWidth, expanded: w) }
            .allowsHitTesting(false)

            .overlay(alignment: .topLeading) { hotspotLayer }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: chrome.isExpanded)

            .frame(width: cardWidth, height: cardAreaHeight, alignment: .top)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    chrome.setExpandedFromPreview(point.y <= cardHeight || keepsExpandedForPopover)
                case .ended:
                    chrome.setExpandedFromPreview(keepsExpandedForPopover)
                }
            }
            .onChange(of: popover) { _, newValue in

                guard case .hotspot = popoverAnchor else { return }
                if newValue != nil {
                    chrome.setExpandedFromPreview(true)
                } else if adjustingThumb == nil {
                    chrome.setExpandedFromPreview(false)
                }
            }

            .overlay(alignment: .top) { windowEdgeOutline }
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var keepsExpandedForPopover: Bool {
        guard popover != nil, case .hotspot = popoverAnchor else { return false }
        return true
    }

    private struct CardHotspot: Identifiable {
        enum Kind: Hashable {
            case leftEar, rightEar, lyricRow, expanded
        }
        let kind: Kind
        let rects: [CGRect]
        let target: StagePopover

        let title: String

        let arrowEdge: Edge
        var id: Kind { kind }
    }

    private var cardHotspots: [CardHotspot] {
        let width = cardWidth
        let earWidth = max(0, (width - chrome.notchWidth - NotchMetrics.cardHorizontalPadding * 2) / 2)
        let top = chrome.contentTopInset
        var spots: [CardHotspot] = [
            CardHotspot(kind: .leftEar,
                        rects: [CGRect(x: NotchMetrics.cardHorizontalPadding, y: 0, width: earWidth, height: top)],
                        target: .leftEar, title: L10n.t("左耳"), arrowEdge: .leading),
            CardHotspot(kind: .rightEar,
                        rects: [CGRect(x: width - NotchMetrics.cardHorizontalPadding - earWidth, y: 0,
                                       width: earWidth, height: top)],
                        target: .rightEar, title: L10n.t("右耳"), arrowEdge: .trailing),
        ]
        var y = top
        var expandedRects: [CGRect] = []
        if chrome.isExpanded, chrome.showsExpandedTrackInfo {
            let height = chrome.expandedTrackInfoHeaderHeight
            expandedRects.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        if chrome.showsLyricRow {
            var lyricHeight = NotchMetrics.compactRowHeight

            if chrome.isExpanded, chrome.showsExpandedLyricPreview {
                lyricHeight += NotchExpandedMetrics.lyricPreviewBlock
            }
            spots.append(CardHotspot(kind: .lyricRow,
                                     rects: [CGRect(x: 0, y: y, width: width, height: lyricHeight)],
                                     target: .lyricRow, title: L10n.t("歌词行"), arrowEdge: .trailing))
            y += lyricHeight
        }
        if chrome.isExpanded, cardHeight > y {

            expandedRects.append(CGRect(x: 0, y: y, width: width, height: cardHeight - y))
        }
        if !expandedRects.isEmpty {
            spots.append(CardHotspot(kind: .expanded, rects: expandedRects,
                                     target: .expanded, title: L10n.t("展开态"), arrowEdge: .trailing))
        }
        return spots
    }

    private var hotspotLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(cardHotspots) { spot in
                ForEach(Array(spot.rects.enumerated()), id: \.offset) { index, rect in
                    hotspotView(spot, rectIndex: index)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
    }

    private func hotspotView(_ spot: CardHotspot, rectIndex: Int) -> some View {
        let hovering = hoveredHotspot == spot.kind
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(hovering ? 0.07 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(hovering ? 0.7 : 0),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .padding(2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredHotspot = spot.kind
                    NSCursor.pointingHand.push()
                } else {
                    if hoveredHotspot == spot.kind { hoveredHotspot = nil }
                    NSCursor.pop()
                }
            }
            .onTapGesture { openPopover(for: spot, rectIndex: rectIndex) }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityElement()
            .accessibilityLabel(String(format: L10n.t("打开「%@」设置"), spot.title))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openPopover(for: spot, rectIndex: rectIndex) }
    }

    private func openPopover(for spot: CardHotspot, rectIndex: Int) {
        popoverAnchor = .hotspot(spot.kind, rectIndex: rectIndex)
        popover = spot.target
    }

    private func hotspotPopoverAnchor(stageWidth: CGFloat, scale: CGFloat) -> some View {
        var rect = CGRect.zero
        var arrowEdge: Edge = .bottom
        var target: StagePopover?
        if case .hotspot(let kind, let index) = popoverAnchor,
           let spot = cardHotspots.first(where: { $0.kind == kind }),
           index < spot.rects.count {
            let local = spot.rects[index]
            rect = CGRect(x: stageWidth / 2 + (local.minX - cardWidth / 2) * scale,
                          y: local.minY * scale,
                          width: local.width * scale, height: local.height * scale)
            arrowEdge = spot.arrowEdge
            target = spot.target
        }

        return Color.clear
            .frame(width: rect.width, height: rect.height)
            .popover(isPresented: hotspotPopoverBinding, arrowEdge: arrowEdge) {
                if let target { popoverContent(for: target) }
            }
            .padding(.leading, rect.minX)
            .padding(.top, rect.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var windowEdgeOutline: some View {

        NotchHangingShape(bottomCornerRadius: 20)
            .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .shadow(color: .black.opacity(0.55), radius: 1)
            .frame(width: cardWidth, height: cardHeight)

            .opacity(adjustingThumb != nil ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: adjustingThumb != nil)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    static func previewScale(stageWidth: CGFloat, widestCardWidth: CGFloat) -> CGFloat {
        guard widestCardWidth > stageWidth + 0.5, widestCardWidth > 0 else { return 1 }
        return stageWidth / widestCardWidth
    }

    private var widthBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))

            RangeSlider(
                lower: baseWidth, upper: expandedBaseWidth,
                range: Self.usableWidthRange(notchWidth: chrome.notchWidth,
                                             contentTopInset: chrome.contentTopInset),
                step: Self.widthStep, tint: .white,
                lowerLabel: L10n.t("灵动岛宽度"), upperLabel: L10n.t("灵动岛展开宽度"),
                valueText: { String(format: L10n.t("%@pt"), "\(Int($0))") },
                onChange: { steady, expanded in

                    draggingSteady = steady
                    draggingExpanded = expanded
                },
                onEditingChanged: { thumb in
                    adjustingThumb = thumb
                    switch thumb {
                    case .expanded?:
                        chrome.setExpandedFromPreview(true)
                    case .steady?:
                        chrome.setExpandedFromPreview(false)
                    case nil:

                        chrome.setExpandedFromPreview(keepsExpandedForPopover)
                        if draggingSteady != nil || draggingExpanded != nil {
                            Self.commitWidths(steady: draggingSteady, expanded: draggingExpanded)
                            draggingSteady = nil
                            draggingExpanded = nil
                        }
                    }
                })
            .frame(width: Self.widthBarSliderWidth)
            Text(widthValueText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)

                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
    }

    private var widthValueText: String {
        let steady = Int(steadyCardWidth)
        let expanded = Int(expandedCardWidth)
        if expanded == steady {
            return String(format: L10n.t("%@pt"), "\(steady)")
        }
        return String(format: L10n.t("%@–%@pt"), "\(steady)", "\(expanded)")
    }

    private func caption(stageWidth: CGFloat) -> some View {
        Text(captionText(stageWidth: stageWidth))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func captionText(stageWidth: CGFloat) -> String {
        var parts: [String] = []

        let scale = Self.previewScale(stageWidth: stageWidth, widestCardWidth: expandedCardWidth)
        if scale < 1 {
            parts.append(String(format: L10n.t("预览已缩小至 %@"), "\(Int((scale * 100).rounded()))%"))
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
enum NotchScreenSummary {
    static var current: String {
        let settings = AppSettings.shared
        if settings.notchAllScreens { return L10n.t("所有屏幕") }
        if settings.notchScreenID.isEmpty { return L10n.t("自动") }
        if let screen = ScreenIdentity.screen(withID: settings.notchScreenID) {
            return screen.localizedName
        }

        return L10n.t("已断开的屏幕")
    }
}

@MainActor
struct NotchStylePopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("风格"), width: 270) {
            NotchStyleSettingsRows()
        }
    }
}

@MainActor
struct NotchShowLyricsRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.alignleft",
            title: L10n.t("显示歌词"),
            help: L10n.t("关掉后稳态只保留刘海那条高度，不显示歌词；指向展开时播放控制、进度条、下一句预览仍照常显示。")
        ) {
            Toggle("", isOn: $settings.notchShowLyrics)
        }
    }
}

@MainActor
struct NotchCollapsesWhenPausedRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "arrow.down.right.and.arrow.up.left",
            title: L10n.t("暂停缩回")
        ) {
            Toggle("", isOn: $settings.notchCollapsesWhenPaused)
        }
    }
}

@MainActor
struct NotchStyleSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {

            ForEach(Array(NotchCardStyle.allCases.enumerated()), id: \.element) { index, style in
                if index > 0 { CardDivider() }
                row(style)
            }
        }
    }

    private func row(_ style: NotchCardStyle) -> some View {
        let isSelected = settings.notchCardStyle == style
        return Button {

            guard settings.notchCardStyle != style else { return }
            settings.notchCardStyle = style
        } label: {
            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {

                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(style.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

@MainActor
enum NotchStyleDefaults {
    static func restoreDefaults() {
        let settings = AppSettings.shared
        settings.notchCardStyle = AppSettings.defaultNotchCardStyle
        settings.notchLeftEar = AppSettings.defaultNotchLeftEar
        settings.notchRightEar = AppSettings.defaultNotchRightEar
        settings.notchAllScreens = AppSettings.defaultNotchAllScreens
        settings.notchScreenID = AppSettings.defaultNotchScreenID
        settings.notchShowLyrics = AppSettings.defaultNotchShowLyrics
        settings.notchCollapsesWhenPaused = AppSettings.defaultNotchCollapsesWhenPaused
        settings.notchShowsEqualizer = AppSettings.defaultNotchShowsEqualizer
        settings.notchEqualizerEar = AppSettings.defaultNotchEqualizerEar
        settings.notchExpandedShowsNextLine = AppSettings.defaultNotchExpandedShowsNextLine
        settings.notchExpandedShowsControls = AppSettings.defaultNotchExpandedShowsControls
        settings.notchExpandedShowsLyricsOffset = AppSettings.defaultNotchExpandedShowsLyricsOffset
        settings.notchExpandedShowsArtwork = AppSettings.defaultNotchExpandedShowsArtwork
        settings.notchExpandedShowsTrackTitle = AppSettings.defaultNotchExpandedShowsTrackTitle
        settings.notchExpandedShowsArtist = AppSettings.defaultNotchExpandedShowsArtist
        settings.notchExpandedShowsAlbum = AppSettings.defaultNotchExpandedShowsAlbum
        settings.notchExpandedShowsQuickActions = AppSettings.defaultNotchExpandedShowsQuickActions
        settings.notchLyricRowShowsArtwork = AppSettings.defaultNotchLyricRowShowsArtwork
        settings.notchLyricRowArtworkPosition = AppSettings.defaultNotchLyricRowArtworkPosition
        settings.notchLyricsAlignment = AppSettings.defaultNotchLyricsAlignment
        settings.notchSecondaryLine = AppSettings.defaultNotchSecondaryLine

        settings.notchFontFamilyName = AppSettings.defaultNotchFontFamilyName
        settings.notchFontWeight = AppSettings.defaultNotchFontWeight
        settings.notchFontSize = AppSettings.defaultNotchFontSize

        settings.notchHideDuringScreenCapture = AppSettings.defaultNotchHideDuringScreenCapture
        settings.notchHideWhenNotPlaying = AppSettings.defaultNotchHideWhenNotPlaying
    }
}

@MainActor
struct NotchEarPopover: View {
    enum Side { case left, right }
    let side: Side

    var body: some View {

        SettingsPopoverShell(
            title: side == .left ? L10n.t("左耳") : L10n.t("右耳"),
            width: 240
        ) {
            NotchEarSettingsRows(side: side)
        }
    }
}

@MainActor
struct NotchEarSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared
    let side: NotchEarPopover.Side

    private var current: NotchEarModule {
        side == .left ? settings.notchLeftEar : settings.notchRightEar
    }

    private var equalizerEarValue: NotchEqualizerEar { side == .left ? .left : .right }

    private var showsEqualizerHere: Bool {
        settings.notchShowsEqualizer && settings.notchEqualizerEar == equalizerEarValue
    }

    private var equalizerRow: some View {
        SettingsRow(icon: "waveform", title: L10n.t("音浪")) {
            Toggle("", isOn: Binding(
                get: { showsEqualizerHere },
                set: { on in
                    if on {
                        settings.notchEqualizerEar = equalizerEarValue
                        settings.notchShowsEqualizer = true
                    } else {
                        settings.notchShowsEqualizer = false
                    }
                }))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            equalizerRow
            CardDivider()

            ForEach(Array(NotchEarModule.allCases.enumerated()), id: \.element) { index, module in
                if index > 0 { CardDivider() }
                row(module)
            }
        }
    }

    private func row(_ module: NotchEarModule) -> some View {
        let isSelected = current == module
        return Button {
            apply(module)
        } label: {
            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {

                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(module.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func apply(_ module: NotchEarModule) {
        let target: NotchEarModule = current == module ? NotchEarModule.none : module
        if side == .left {
            guard settings.notchLeftEar != target else { return }
            settings.notchLeftEar = target
        } else {
            guard settings.notchRightEar != target else { return }
            settings.notchRightEar = target
        }
    }
}

@MainActor
struct NotchScreenPopover: View {

    var onScreenChange: () -> Void

    var body: some View {
        SettingsPopoverShell(
            title: L10n.t("屏幕"),
            help: L10n.t("「自动」选带刘海的那块；「所有屏幕」每块屏各显示一个；指定的屏幕拔掉后自动回到「自动」"),
            width: 300
        ) {
            NotchScreenSettingsRows(onScreenChange: onScreenChange)
        }
    }
}

@MainActor
struct NotchScreenSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared
    var onScreenChange: () -> Void

    @State private var availableScreens: [NSScreen] = NSScreen.screens

    private static let allScreensTag = "__all_screens__"

    private var selection: String {
        settings.notchAllScreens ? Self.allScreensTag : settings.notchScreenID
    }

    var body: some View {
        VStack(spacing: 0) {
            row(tag: "", title: L10n.t("自动"))
            CardDivider()
            row(tag: Self.allScreensTag, title: L10n.t("所有屏幕"))
            ForEach(availableScreens, id: \.self) { screen in
                if let id = ScreenIdentity.id(of: screen) {
                    CardDivider()
                    row(tag: id, title: screen.localizedName)
                }
            }

            if !settings.notchAllScreens, !settings.notchScreenID.isEmpty,
               ScreenIdentity.screen(withID: settings.notchScreenID) == nil {
                CardDivider()
                row(tag: settings.notchScreenID, title: L10n.t("已断开的屏幕"))
            }
        }

        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            availableScreens = NSScreen.screens
        }
    }

    private func row(tag: String, title: String) -> some View {
        let isSelected = selection == tag
        return Button {
            apply(tag)
        } label: {
            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func apply(_ tag: String) {
        let allScreens = (tag == Self.allScreensTag)
        var changed = false
        if settings.notchAllScreens != allScreens {
            settings.notchAllScreens = allScreens
            changed = true
        }

        if !allScreens, settings.notchScreenID != tag {
            settings.notchScreenID = tag
            changed = true
        }
        guard changed else { return }
        if settings.notchOverlayEnabled {
            NotchLyricsWindowController.shared.applyScreenSetting()
        }
        onScreenChange()
    }
}
