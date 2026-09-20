import AppKit
import LyrimuseCore
import SwiftUI

@MainActor
enum SectionPreviewMetrics {
    static let bottomPadding: CGFloat = 10
    static let captionSpacing: CGFloat = 6

    static let captionHeight: CGFloat = 15

}

extension MenuBarPreviewBar where Lane == EmptyView {

    init(reservesWidthLane: Bool = false) {
        self.reservesWidthLane = reservesWidthLane
        self.lane = { EmptyView() }
    }
}

@MainActor
struct MenuBarPreviewBar<Lane: View>: View {

    var reservesWidthLane = false

    @ViewBuilder var lane: () -> Lane

    static var widthLaneHeight: CGFloat { 28 }

    @ObservedObject private var settings = AppSettings.shared

    @ObservedObject private var menuBarAppearance = MenuBarAppearanceStore.shared
    @State private var line: SyncedLyricLine?

    @State private var anchor: ProgressAnchor?
    @State private var pausedPositionMs: Int?
    @State private var lyricsOffsetMs = 0
    @State private var isPlayingNow = false

    private var fullText: String {
        if let text = line?.plainText, !text.isEmpty { return text }
        return L10n.t("这里是一句歌词示例")
    }

    private var secondaryKind: LyricSecondaryLine { settings.menuBarSecondaryLine }
    private var twoRows: Bool { secondaryKind.showsSecondaryRow }

    private var mainFont: NSFont { MenuBarMarqueeRenderer.mainFont(for: fullText, twoRows: twoRows) }

    private var secondaryText: String? {
        guard twoRows else { return nil }
        if let line, let text = line.plainText, !text.isEmpty {
            return secondaryKind.secondaryText(currentLine: line,
                                               nextLineText: PlaybackCoordinator.shared.nextLineText)
        }
        return secondaryKind.displayName
    }

    private func adaptiveWindowWidth(for visible: String) -> CGFloat {
        let mainW = MenuBarMarqueeRenderer.width(of: visible, font: mainFont)
        guard twoRows else { return mainW }
        let secondaryW = secondaryText.map {
            MenuBarMarqueeRenderer.width(of: $0, font: MenuBarMarqueeRenderer.doubleRowSecondaryFont)
        } ?? 0
        return min(settings.menuBarLyricsWidth, max(mainW, secondaryW))
    }

    private var rowsHeight: CGFloat {
        twoRows ? MenuBarLyricRows.buttonHeight : MenuBarMarqueeRenderer.lineHeight
    }

    private var karaokeFillPath: [MenuBarMarquee.KaraokeFillPoint]? {
        guard settings.menuBarLyricsKaraoke,
              let line, let words = line.words, !words.isEmpty,
              line.plainText == fullText else { return nil }
        let path = MenuBarMarquee.karaokeFillPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words, font: mainFont))
        return path.isEmpty ? nil : path
    }

    private var followReadingPath: [MenuBarMarquee.KaraokeFillPoint]? {
        guard let line, let words = line.words, !words.isEmpty,
              line.plainText == fullText else { return nil }
        let path = MenuBarMarquee.followReadingPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words, font: mainFont))
        return path.isEmpty ? nil : path
    }

    private var karaokePositionMs: Int? {
        let raw = anchor?.extrapolatedPositionMs(now: Date()) ?? pausedPositionMs
        return raw.map { $0 + lyricsOffsetMs }
    }

    private var previewIconBadge: MenuBarScrollingLabel.IconBadge? {
        let position = settings.menuBarLyricsIconPosition
        guard position != .off else { return nil }
        return MenuBarScrollingLabel.IconBadge(style: settings.menuBarIconStyle,
                                               position: position)
    }

    private var reservedIconWidth: CGFloat {
        MenuBarProgressIcon.reservedWidth(for: previewIconBadge?.style)
    }

    private var progressPositionMs: Int? {
        anchor?.extrapolatedPositionMs(now: Date()) ?? pausedPositionMs
    }

    private var progressDurationMs: Int? {
        [anchor?.durationMs, PlaybackCoordinator.shared.currentDurationMs]
            .compactMap { $0 }.first { $0 > 0 }
    }

    private func lyricsSlotWidth(_ p: MenuBarMarqueeRenderer.Presentation) -> CGFloat {
        switch p {
        case .text(let visible): return adaptiveWindowWidth(for: visible)
        case .fixed(_, let windowWidth, _): return windowWidth
        }
    }

    private var presentation: MenuBarMarqueeRenderer.Presentation {
        MenuBarMarqueeRenderer.presentation(
            for: fullText, windowWidth: settings.menuBarLyricsWidth,

            dwellSeconds: line == nil ? nil : PlaybackCoordinator.shared.currentLineDwellSeconds,

            leadInSeconds: 0,
            widthMode: settings.menuBarLyricsWidthMode,
            font: mainFont)
    }

    private static func willScroll(_ p: MenuBarMarqueeRenderer.Presentation) -> Bool {
        if case .fixed(_, _, let pacing) = p { return pacing != nil }
        return false
    }

    private func previewCaption(_ p: MenuBarMarqueeRenderer.Presentation) -> String {
        Self.willScroll(p) ? L10n.t("预览 · 本句会横向滚动") : L10n.t("预览")
    }

    static var cardHeight: CGFloat { 24 }

    private var stageHeight: CGFloat {
        Self.cardHeight + SectionPreviewMetrics.bottomPadding
            + (reservesWidthLane ? Self.widthLaneHeight : 0)
    }

    var body: some View {

        let p = presentation
        return VStack(spacing: SectionPreviewMetrics.captionSpacing) {
            stage(p)

            Text(previewCaption(p))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                .frame(height: SectionPreviewMetrics.captionHeight)
        }
        .frame(maxWidth: .infinity)
        .onReceive(PlaybackCoordinator.shared.$currentLine.removeDuplicates()) { line = $0 }

        .onReceive(PlaybackCoordinator.shared.$anchor) { anchor = $0 }
        .onReceive(PlaybackCoordinator.shared.$pausedPositionMs) { pausedPositionMs = $0 }
        .onReceive(PlaybackCoordinator.shared.$currentLyricsOffsetMs) { lyricsOffsetMs = $0 }
        .onReceive(PlaybackCoordinator.shared.$isPlayingNow) { isPlayingNow = $0 }
        .accessibilityHidden(true)
    }

    private func stage(_ p: MenuBarMarqueeRenderer.Presentation) -> some View {
        menuBarStrip(p)

            .frame(height: stageHeight, alignment: .top)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) { desktopSurface }
            .overlay(alignment: .bottom) { lane() }

            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            .environment(\.colorScheme, menuBarAppearance.colorScheme)
    }

    private var desktopSurface: some View {
        ZStack(alignment: .top) {
            if let wallpaper = DesktopWallpaperSample.image {
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
                    .frame(height: stageHeight, alignment: .top)
                    .clipped()
            } else {

                Color(nsColor: .textColor).opacity(0.14)
            }

            Color(nsColor: .windowBackgroundColor).opacity(0.16)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func menuBarStrip(_ p: MenuBarMarqueeRenderer.Presentation) -> some View {
        HStack(spacing: 0) {

            Image(systemName: "apple.logo")
                .font(.system(size: 16))
                .foregroundStyle(Color(nsColor: .labelColor).opacity(0.55))
                .padding(.leading, 12)

            Spacer(minLength: 12)
            lyricsSlot(p)

                .padding(.horizontal, 3)

                .overlay(alignment: previewIconBadge?.position == .leading ? .trailing : .leading) {
                    slotEdgeOutline.frame(width: lyricsSlotWidth(p) + 6)
                }

            HStack(spacing: 11) {
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
                Text(Date(), style: .time)
            }
            .font(Font(MenuBarMarqueeRenderer.font))
            .foregroundStyle(Color(nsColor: .labelColor).opacity(0.55))
            .padding(.leading, 14)
            .padding(.trailing, 12)
        }
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity)

        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var slotEdgeOutline: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .shadow(color: .black.opacity(0.55), radius: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func lyricsSlot(_ presentation: MenuBarMarqueeRenderer.Presentation) -> some View {
        switch presentation {
        case .text(let visible):

            if visible == fullText, karaokeFillPath != nil || previewIconBadge != nil || twoRows {
                let w = adaptiveWindowWidth(for: visible)
                MenuBarScrollingLabel.Representable(
                    text: visible, windowWidth: w, pacing: nil, fillPath: karaokeFillPath,
                    followPath: followReadingPath, karaokePositionMs: karaokePositionMs,
                    karaokeRate: anchor?.rate ?? 0, karaokePlaying: isPlayingNow,
                    icon: previewIconBadge, progressPositionMs: progressPositionMs,
                    progressDurationMs: progressDurationMs,
                    secondaryText: secondaryText, secondaryKind: secondaryKind)
                    .frame(width: w + reservedIconWidth, height: rowsHeight)
            } else {
                Text(visible)
                    .font(Font(MenuBarMarqueeRenderer.font))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: MenuBarMarqueeRenderer.lineHeight)
            }
        case .fixed(let text, let windowWidth, let pacing):
            MenuBarScrollingLabel.Representable(
                text: text, windowWidth: windowWidth, pacing: pacing,
                fillPath: karaokeFillPath, followPath: followReadingPath,
                karaokePositionMs: karaokePositionMs,
                karaokeRate: anchor?.rate ?? 0, karaokePlaying: isPlayingNow,
                icon: previewIconBadge, progressPositionMs: progressPositionMs,
                progressDurationMs: progressDurationMs,
                secondaryText: secondaryText, secondaryKind: secondaryKind)
                .frame(width: windowWidth + reservedIconWidth, height: rowsHeight)
        }
    }
}
