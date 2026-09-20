import SwiftUI
import Combine
import LyrimuseCore

@MainActor
private final class OverlayPlayback: ObservableObject {

    static let cardHorizontalPadding: CGFloat = 20

    @Published private(set) var currentLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?
    @Published private(set) var nextLineSide: LyricDuet.Side?
    @Published private(set) var isPlayingNow = false

    @Published private(set) var hasTrack = false
    @Published private(set) var isFavorited: Bool?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false

    @Published private(set) var isRadioTalkBreak = false
    @Published private(set) var currentLineFillSettled = true

    @Published private(set) var displayForegroundColor: Color = .white

    @Published private(set) var lockPosition = false
    @Published private(set) var fadeOnHover = false
    @Published private(set) var placementMode: OverlayPlacementMode = .free
    @Published private(set) var showRomanization = true
    @Published private(set) var showTranslation = false
    @Published private(set) var showNextLinePreview = true
    @Published private(set) var duetAlignmentOverride: OverlayDuetAlignmentOverride = .automatic
    @Published private(set) var mainFont: Font = .system(size: 20, weight: .bold)
    @Published private(set) var romanizationFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var translationFont: Font = .system(size: 14, weight: .regular)
    @Published private(set) var previewFont: Font = .system(size: 14, weight: .medium)
    @Published private(set) var textStrokeEnabled = false
    @Published private(set) var textStrokeColor: Color = .black.opacity(0.65)
    @Published private(set) var backgroundIsVisible = false
    @Published private(set) var backgroundColor: Color = .clear
    @Published private(set) var backgroundGlass = false

    @Published private(set) var duetInsetUnit: CGFloat = 0

    @Published private(set) var duetStageInset: CGFloat = 0
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [

            Publishers.CombineLatest(p.$currentLine, s.$overlayLyricsKaraoke)
                .map { line, karaoke in karaoke ? line : line?.lineLevel }
                .removeDuplicates()
                .sink { [weak self] in self?.currentLine = $0 },
            p.$nextLineText.removeDuplicates().sink { [weak self] in self?.nextLineText = $0 },
            p.$nextLineSide.removeDuplicates().sink { [weak self] in self?.nextLineSide = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },

            Publishers.CombineLatest3(p.$title, p.$artist, p.$isCurrentTrackAdBreak)
                .map { title, artist, isAd in !title.isEmpty || !artist.isEmpty || isAd }
                .removeDuplicates()
                .sink { [weak self] in self?.hasTrack = $0 },
            p.$isFavorited.removeDuplicates().sink { [weak self] in self?.isFavorited = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$isRadioTalkBreak.removeDuplicates().sink { [weak self] in self?.isRadioTalkBreak = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            Publishers.CombineLatest3(p.$artworkAccentColor, s.$followsCoverArt, s.$foregroundColor)
                .map { accent, follows, fg in (follows ? accent : nil) ?? fg }
                .removeDuplicates()
                .sink { [weak self] in self?.displayForegroundColor = $0 },
            s.$lockPosition.removeDuplicates().sink { [weak self] in self?.lockPosition = $0 },
            s.$overlayFadeOnHover.removeDuplicates().sink { [weak self] in self?.fadeOnHover = $0 },
            s.$overlayPlacementMode.removeDuplicates().sink { [weak self] in self?.placementMode = $0 },
            s.$showRomanization.removeDuplicates().sink { [weak self] in self?.showRomanization = $0 },
            s.$showTranslation.removeDuplicates().sink { [weak self] in self?.showTranslation = $0 },
            s.$showNextLinePreview.removeDuplicates().sink { [weak self] in self?.showNextLinePreview = $0 },
            s.$overlayDuetAlignmentOverride.removeDuplicates().sink { [weak self] in self?.duetAlignmentOverride = $0 },
            s.$mainFont.removeDuplicates().sink { [weak self] in self?.mainFont = $0 },
            s.$romanizationFont.removeDuplicates().sink { [weak self] in self?.romanizationFont = $0 },
            s.$translationFont.removeDuplicates().sink { [weak self] in self?.translationFont = $0 },
            s.$previewFont.removeDuplicates().sink { [weak self] in self?.previewFont = $0 },
            s.$textStrokeEnabled.removeDuplicates().sink { [weak self] in self?.textStrokeEnabled = $0 },
            s.$textStrokeColor.removeDuplicates().sink { [weak self] in self?.textStrokeColor = $0 },
            s.$backgroundIsVisible.removeDuplicates().sink { [weak self] in self?.backgroundIsVisible = $0 },
            s.$backgroundColor.removeDuplicates().sink { [weak self] in self?.backgroundColor = $0 },
            s.$overlayBackgroundGlass.removeDuplicates().sink { [weak self] in self?.backgroundGlass = $0 },

            s.$overlayWidth.combineLatest(s.$fontSize)
                .map { width, font in
                    LyricDuetLayout.insets(
                        for: .leading,
                        availableWidth: CGFloat(width) - Self.cardHorizontalPadding * 2,
                        fontSize: CGFloat(font)
                    ).trailing
                }
                .removeDuplicates()
                .sink { [weak self] in self?.duetInsetUnit = $0 },

            s.$overlayWidth.combineLatest(s.$fontSize)
                .map { width, font in
                    OverlayCardGeometry.duetStageInset(
                        availableWidth: CGFloat(width) - Self.cardHorizontalPadding * 2,
                        fontSize: CGFloat(font))
                }
                .removeDuplicates()
                .sink { [weak self] in self?.duetStageInset = $0 },
        ]
    }
}

@MainActor
protocol OverlayChromeSource: ObservableObject {

    var isHoveringForControls: Bool { get }

    var isHoveringLyrics: Bool { get }

    var isHoveringControlPill: Bool { get }

    var hoveredControl: OverlayControlID? { get }

    var isDragArmed: Bool { get }

    var showDragHint: Bool { get }

    var transientHint: String? { get }

    var placementLockNotice: String? { get }

    var placementLockShakeTick: Int { get }

    func controlsDidBecomeVisible()
}

struct OverlayPreviewLine {
    var line: SyncedLyricLine
    var nextLineText: String?
}

private enum OverlaySpeakerIndicator {
    static let barHeight: CGFloat = 12
    static let width: CGFloat = 6 + 7 + 2 + 7
}

private enum OverlayControlsSidePin: Equatable {
    case free
    case pinned(LyricDuet.Side?)
}

struct LyricsOverlayView<Chrome: OverlayChromeSource>: View {

    @StateObject private var playback = OverlayPlayback()

    @State private var wrapContentSink = WrapContentRectSink()

    @ObservedObject var overlayController: Chrome

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    var onControlsFrameChange: (CGRect) -> Void = { _ in }

    var onControlRectsChange: ([OverlayControlID: CGRect]) -> Void = { _ in }

    var onLyricsTextRectChange: (CGRect) -> Void = { _ in }

    var showsDebugHUD: Bool = true

    var previewLine: OverlayPreviewLine? = nil

    private let overlayBackgroundCornerRadius: CGFloat = 16
    private let overlayCoordSpaceName = "overlayContent"

    @State private var frameProbe = FrameRateProbe()
    @State private var debugFPS: Double?

    @State private var controlsSidePin: OverlayControlsSidePin = .free

    private var controlsVisible: Bool {
        overlayController.isHoveringForControls && !playback.lockPosition
    }

    private var hoverFadeOpacity: Double {
        playback.fadeOnHover && overlayController.isHoveringLyrics ? 0.15 : 1
    }

    private var line: SyncedLyricLine? { playback.currentLine ?? previewLine?.line }

    private var showingPreviewLine: Bool { playback.currentLine == nil && previewLine != nil }

    private var nextLineText: String? {
        showingPreviewLine ? previewLine?.nextLineText : playback.nextLineText
    }

    var body: some View {

        VStack(spacing: 0) {
            if !controlsSlotBelow { controlsSlot }
            lyricsCard
            if controlsSlotBelow { controlsSlot }
        }
        .coordinateSpace(name: overlayCoordSpaceName)

        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightPreferenceKey.self) { onContentHeightChange($0) }
        .onPreferenceChange(ControlsFramePreferenceKey.self) { onControlsFrameChange($0) }
        .onPreferenceChange(ControlRectsPreferenceKey.self) { onControlRectsChange($0) }
        .onPreferenceChange(LyricsTextRectPreferenceKey.self) { onLyricsTextRectChange($0) }
        .animation(.easeOut(duration: 0.16), value: controlsVisible)
        .animation(.easeOut(duration: 0.3), value: overlayController.showDragHint)
        .animation(.easeOut(duration: 0.2), value: overlayController.transientHint)
        .animation(.easeOut(duration: 0.2), value: overlayController.placementLockNotice)

        .opacity(hoverFadeOpacity)
        .animation(.easeOut(duration: hoverFadeOpacity < 1 ? 0.12 : 0.18), value: hoverFadeOpacity)

        .overlay(alignment: .topTrailing) {
            if showsDebugHUD, AppSettings.shared.debugHUDEnabled {
                Text(debugFPS.map { String(format: "%.0f fps", $0) } ?? "-- fps")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }

        .onChange(of: controlsVisible) { _, visible in
            if visible { overlayController.controlsDidBecomeVisible() }
        }

        .onChange(of: overlayController.isHoveringControlPill) { _, onPill in
            controlsSidePin = onPill ? .pinned(line?.side) : .free
        }

        .onChange(of: overlayController.isHoveringForControls) { _, hovering in
            if !hovering { controlsSidePin = .free }
        }

        .frame(maxHeight: .infinity, alignment: playback.placementMode.anchorsBottom ? .bottom : .top)
    }

    private var controlsSlotBelow: Bool { playback.placementMode == .topCenter }

    private var controlsSlot: some View {
        Group {

            if let notice = overlayController.placementLockNotice {
                placementLockPill(notice)
            } else if playback.lockPosition {
                unlockPill
                    .opacity(unlockPillVisible ? 1 : 0)
                    .allowsHitTesting(unlockPillVisible)
                    .animation(.easeOut(duration: 0.16), value: unlockPillVisible)
            } else {
                playbackControls
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)

                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ControlsFramePreferenceKey.self,
                                value: proxy.frame(in: .named(overlayCoordSpaceName))
                            )
                        }
                    )
            }
        }

        .padding(controlsSlotBelow ? .bottom : .top, 4)
        .padding(controlsSlotBelow ? .top : .bottom, 4)

        .padding(.leading, controlsInsets.leading)
        .padding(.trailing, controlsInsets.trailing)
        .frame(maxWidth: .infinity, alignment: controlsFrameAlignment)
    }

    private var duetSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveAlignmentSide(realSide: line?.side)
    }

    private var nextLineDuetSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveAlignmentSide(realSide: playback.nextLineSide)
    }

    private var duetDecorationSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveDecorationSide(realSide: line?.side) ?? .center
    }
    private var nextLineDecorationSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveDecorationSide(realSide: playback.nextLineSide) ?? .center
    }

    private var controlsRealSide: LyricDuet.Side? {
        if case .pinned(let side) = controlsSidePin { return side }
        return line?.side
    }

    private var controlsFrameAlignment: Alignment {
        frameAlignment(for: playback.duetAlignmentOverride.effectiveAlignmentSide(realSide: controlsRealSide))
    }

    private var controlsInsets: (leading: CGFloat, trailing: CGFloat) {
        OverlayCardGeometry.controlsInsets(
            for: playback.duetAlignmentOverride.effectiveDecorationSide(realSide: controlsRealSide),
            unit: playback.duetInsetUnit,
            stageInset: playback.duetStageInset,
            cardHorizontalPadding: OverlayPlayback.cardHorizontalPadding)
    }

    private var nextLinePreviewFont: Font {
        guard playback.duetAlignmentOverride == .automatic,
              let nextSide = playback.nextLineSide, nextSide != line?.side
        else {
            return playback.previewFont
        }
        return playback.mainFont
    }

    private func horizontalAlignment(for side: LyricDuet.Side) -> HorizontalAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private func textAlignment(for side: LyricDuet.Side) -> TextAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private func frameAlignment(for side: LyricDuet.Side) -> Alignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var duetAlignment: HorizontalAlignment { horizontalAlignment(for: duetSide) }

    private var duetTextAlignment: TextAlignment { textAlignment(for: duetSide) }

    private func speakerIndicatorInset(side: LyricDuet.Side) -> (leading: CGFloat, trailing: CGFloat) {
        switch side {
        case .leading: return (OverlaySpeakerIndicator.width, 0)
        case .trailing: return (0, OverlaySpeakerIndicator.width)
        case .center: return (0, 0)
        }
    }

    @ViewBuilder
    private func withSpeakerIndicator<V: View>(side: LyricDuet.Side, color: Color, @ViewBuilder content: () -> V) -> some View {
        if side != .center {
            let dot = Circle().fill(color).frame(width: 6, height: 6)
            let bar = Capsule().fill(color.opacity(0.55)).frame(width: 2, height: OverlaySpeakerIndicator.barHeight)
            HStack(spacing: 7) {
                if side == .leading {
                    dot
                    bar
                    content()
                } else {
                    content()
                    bar
                    dot
                }
            }
        } else {
            content()
        }
    }

    private var duetFrameAlignment: Alignment { frameAlignment(for: duetSide) }

    private func reportingTextRect<V: View>(_ v: V) -> some View {
        v.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LyricsTextRectPreferenceKey.self,
                    value: proxy.frame(in: .named(overlayCoordSpaceName)))
            })
    }

    private func reportingMainLineRect<V: View>(_ v: V) -> some View {
        v.background(
            GeometryReader { proxy in
                let f = proxy.frame(in: .named(overlayCoordSpaceName))
                let local = wrapContentSink.rect
                let rect = local == .zero
                    ? f
                    : CGRect(x: f.minX + local.minX, y: f.minY + local.minY,
                             width: local.width, height: local.height)
                return Color.clear.preference(key: LyricsTextRectPreferenceKey.self, value: rect)
            })
    }

    private func duetInsets(for side: LyricDuet.Side?) -> (leading: CGFloat, trailing: CGFloat) {
        OverlayCardGeometry.cardInsets(for: side, unit: playback.duetInsetUnit,
                                       stageInset: playback.duetStageInset)
    }

    private var duetInsets: (leading: CGFloat, trailing: CGFloat) {
        duetInsets(for: playback.duetAlignmentOverride.effectiveDecorationSide(realSide: line?.side))
    }

    private var nextLineInsetsDelta: (leading: CGFloat, trailing: CGFloat) {
        let override = playback.duetAlignmentOverride
        let current = duetInsets(for: override.effectiveDecorationSide(realSide: line?.side))
        let next = duetInsets(for: override.effectiveDecorationSide(realSide: playback.nextLineSide))
        return (next.leading - current.leading, next.trailing - current.trailing)
    }

    private var duetRowAlignment: WrapLayout.RowAlignment {
        switch duetSide {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var lyricsCard: some View {
        VStack(alignment: duetAlignment, spacing: 4) {
            withSpeakerIndicator(side: duetDecorationSide, color: playback.displayForegroundColor) {
                reportingMainLineRect(mainLine)
            }

            if playback.showRomanization, !usesPerWordRomanization,
                let roma = line?.romanization
            {
                reportingTextRect(
                    Text(roma)
                        .font(playback.romanizationFont)
                        .foregroundStyle(playback.displayForegroundColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                        .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor))

                    .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                    .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
            }
            if playback.showTranslation, let tr = line?.translation {
                reportingTextRect(
                    Text(tr)
                        .font(playback.translationFont)
                        .foregroundStyle(playback.displayForegroundColor.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor))

                    .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                    .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
            }
            if playback.showNextLinePreview, let next = nextLineText {

                withSpeakerIndicator(side: nextLineDecorationSide, color: playback.displayForegroundColor.opacity(0.4)) {
                    reportingTextRect(
                        Text(next)
                            .font(nextLinePreviewFont)
                            .foregroundStyle(playback.displayForegroundColor.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                            .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    )
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment(for: nextLineDuetSide))
                .multilineTextAlignment(textAlignment(for: nextLineDuetSide))

                .padding(.leading, nextLineInsetsDelta.leading)
                .padding(.trailing, nextLineInsetsDelta.trailing)
            }

            if let hint = overlayController.transientHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.8))
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    .transition(.opacity)
            } else if overlayController.showDragHint {
                Text(AppSettings.shared.overlayDragNeedsLongPress
                        ? L10n.t("长按即可拖动位置")
                        : L10n.t("按住歌词即可拖动位置"))
                    .font(.caption)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.8))
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    .transition(.opacity)
            }
        }

        .padding(.leading, duetInsets.leading)
        .padding(.trailing, duetInsets.trailing)
        .padding(.horizontal, OverlayPlayback.cardHorizontalPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: duetFrameAlignment)
        .background(overlayBackground)

        .overlay(
            RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                .stroke(playback.displayForegroundColor.opacity(overlayController.isDragArmed ? 0.6 : 0), lineWidth: 2)
        )

        .modifier(OverlayRejectShake(
            travel: reduceMotion ? 0 : CGFloat(overlayController.placementLockShakeTick)))
        .animation(reduceMotion ? nil : .linear(duration: 0.45), value: overlayController.placementLockShakeTick)

        .multilineTextAlignment(duetTextAlignment)
    }

    private var unlockPillVisible: Bool {
        overlayController.isHoveringForControls && playback.lockPosition
    }

    private var unlockPill: some View {
        iconButton(.unlockPill, "lock.fill", primary: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)

            .overlayCapsuleBackground(visible: unlockPillVisible)
            .transition(.opacity)
    }

    private var playbackControls: some View {
        HStack(spacing: 5) {
            iconButton(.previous, "backward.fill")
            iconButton(.playPause, playback.isPlayingNow ? "pause.fill" : "play.fill", primary: true)
            iconButton(.next, "forward.fill")

            if let favorited = playback.isFavorited {
                iconButton(.favorite, favorited ? "heart.fill" : "heart")
                    .foregroundStyle(favorited ? Color.red : Color.white)
            }

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 12)
            iconButton(.expandToLyricsWindow, "arrow.up.left.and.arrow.down.right")
            iconButton(.settingsMenu, "gearshape.fill")
            iconButton(.lock, "lock.open.fill")
            iconButton(.closeOverlay, "xmark")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .overlayCapsuleBackground(visible: controlsVisible)
    }

    private func placementLockPill(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlayCapsuleBackground(visible: true)
        .transition(.opacity)
        .accessibilityLabel(text)
    }

    private func iconButton(_ id: OverlayControlID, _ systemName: String,
                            primary: Bool = false) -> some View {
        let hovered = overlayController.hoveredControl == id
        return Image(systemName: systemName)
            .font(.system(size: primary ? 12 : 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .scaleEffect(hovered ? 1.16 : 1)
            .frame(width: primary ? 22 : 19, height: primary ? 22 : 19)
            .background {
                Circle()
                    .fill(Color.white.opacity(hovered ? 0.18 : 0))
                    .scaleEffect(hovered ? 1 : 0.55)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72),
                       value: hovered)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ControlRectsPreferenceKey.self,
                        value: [id: proxy.frame(in: .named(overlayCoordSpaceName))])
                }
            )
    }

    @ViewBuilder
    private var overlayBackground: some View {
        if playback.backgroundGlass {

            ZStack {
                RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                    .fill(playback.backgroundColor)
            }
        } else if playback.backgroundIsVisible {
            RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                .fill(playback.backgroundColor)
        } else {

            Color.black.opacity(0.001)
        }
    }

    @ViewBuilder
    private var mainLine: some View {
        if let words = line?.words {

            TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                    paused: !playback.isPlayingNow || playback.currentLineFillSettled)) { context in
                let currentMs = (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: context.date)
                    ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
                    + PlaybackCoordinator.shared.currentLyricsOffsetMs
                karaokeLineContent(words: words, atMs: currentMs)
                    .onChange(of: context.date) { _, date in
                        guard showsDebugHUD, AppSettings.shared.debugHUDEnabled else { return }
                        frameProbe.tick(at: date)
                        debugFPS = frameProbe.fps
                    }
            }
            .font(playback.mainFont)

            .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor) {
                karaokeLineContent(words: words, atMs: nil)
                    .font(playback.mainFont)
            }
        } else if let text = line?.mainText {
            Text(text)
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor)
                .fixedSize(horizontal: false, vertical: true)
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if !playback.hasTrack {

            (Text(Image(systemName: "music.note")) + Text(verbatim: " Lyrimuse"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.7))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isCurrentTrackAdBreak {

            Text(L10n.t("广告中"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isRadioTalkBreak {

            Text(L10n.t("口白"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isCurrentTrackInstrumental {

            Text(L10n.t("纯音乐"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.currentTrackHasNoLyrics {

            Text(L10n.t("暂无歌词"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.collectorNetworkDown && !playback.hasLyricsContent {

            Text(L10n.t("网络连接失败"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isPlayingNow && !playback.hasLyricsContent {

            Text(L10n.t("搜索歌词中…"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else {
            Text("♪")
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.3))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        }
    }

    private var usesPerWordRomanization: Bool {
        playback.showRomanization && line?.wordGroups?.isEmpty == false
    }

    @ViewBuilder
    private func karaokeLineContent(words: [SyncedLyricWord], atMs currentMs: Int?) -> some View {

        let palette = currentMs != nil
            ? WordKaraokeGradient.palette(fg: playback.displayForegroundColor) : nil
        let romaPalette = (currentMs != nil && usesPerWordRomanization)
            ? WordKaraokeGradient.palette(fg: playback.displayForegroundColor.opacity(0.75)) : nil

        WrapLayout(rowAlignment: duetRowAlignment,
                   contentKey: overlayLineLayoutKey,
                   contentRectSink: wrapContentSink) {
            if let groups = line?.wordGroups, usesPerWordRomanization {

                ForEach(groups) { g in

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {

                            ForEach(g.words.indices, id: \.self) { i in
                                wordText(g.words[i], atMs: currentMs, palette: palette)
                            }
                        }
                        if let roma = g.romanization {
                            romaText(roma, group: g, atMs: currentMs, palette: romaPalette)
                        }
                    }
                }
            } else {
                ForEach(words.indices, id: \.self) { i in
                    wordText(words[i], atMs: currentMs, palette: palette)
                }
            }
        }
    }

    private var overlayLineLayoutKey: AnyHashable {
        AnyHashable(OverlayLineKey(
            text: line?.plainText,
            roma: usesPerWordRomanization,
            mainFont: playback.mainFont,
            romaFont: playback.romanizationFont))
    }

    private struct OverlayLineKey: Hashable {
        let text: String?
        let roma: Bool
        let mainFont: Font
        let romaFont: Font
    }

    private func romaText(
        _ roma: String, group: SyncedLyricWordGroup, atMs currentMs: Int?,
        palette: WordKaraokeGradient.Palette?
    ) -> some View {
        let style: AnyShapeStyle
        if let currentMs, let palette {

            let fraction = KaraokeFill.fillFraction(
                startMs: group.startMs, durationMs: max(1, group.endMs - group.startMs),
                atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand
            style = palette.style(left: fraction - band, right: fraction + band)
        } else {

            style = AnyShapeStyle(Color.black)
        }
        return Text(roma)
            .font(playback.romanizationFont)
            .foregroundStyle(style)
            .lineLimit(1)
            .fixedSize()

            .padding(.horizontal, 2)
    }

    private func wordText(
        _ w: SyncedLyricWord, atMs currentMs: Int?, palette: WordKaraokeGradient.Palette?
    ) -> some View {
        let style: AnyShapeStyle
        if let currentMs, let palette {
            let fraction = WordKaraokeGradient.fillFraction(for: w, atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand
            style = palette.style(left: fraction - band, right: fraction + band)
        } else {

            style = AnyShapeStyle(Color.black)
        }
        return Text(w.text)
            .foregroundStyle(style)

    }
}

private struct OptionalTextStroke<MaskSource: View>: ViewModifier {
    let enabled: Bool
    let color: Color
    let maskSource: MaskSource?

    private let width: CGFloat = 1.2
    private let symbolID = "np-lyrics-stroke"

    init(enabled: Bool, color: Color, maskSource: MaskSource?) {
        self.enabled = enabled
        self.color = color
        self.maskSource = maskSource
    }

    func body(content: Content) -> some View {
        if enabled {
            content

                .padding(width * 2)
                .background(
                    Rectangle()
                        .foregroundStyle(color)
                        .mask {
                            Canvas { context, size in
                                context.addFilter(.alphaThreshold(min: 0.01))
                                context.drawLayer { ctx in
                                    if let resolved = context.resolveSymbol(id: symbolID) {
                                        ctx.draw(resolved, at: CGPoint(x: size.width / 2, y: size.height / 2))
                                    }
                                }
                            } symbols: {

                                symbolSource(content: content)
                                    .padding(width * 2)
                                    .tag(symbolID)
                                    .blur(radius: width)
                            }
                        }
                )
        } else {
            content
        }
    }

    @ViewBuilder
    private func symbolSource(content: Content) -> some View {
        if let maskSource {
            maskSource
        } else {
            content
        }
    }
}

extension View {
    func lyricsTextStroke(_ enabled: Bool, color: Color) -> some View {
        modifier(OptionalTextStroke<EmptyView>(enabled: enabled, color: color, maskSource: nil))
    }

    func lyricsTextStroke<M: View>(
        _ enabled: Bool, color: Color, @ViewBuilder maskSource: () -> M
    ) -> some View {
        modifier(OptionalTextStroke(enabled: enabled, color: color, maskSource: maskSource()))
    }

    @ViewBuilder
    func overlayCapsuleBackground(visible: Bool = true) -> some View {
        let shape = Capsule()
        if #available(macOS 26.0, *) {
            if visible {
                glassEffect(.regular.tint(.black.opacity(0.32)), in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            } else {

                self
            }
        } else {
            background(.black.opacity(0.55), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
    }
}

private struct LyricsTextRectPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard next != .zero, next.width > 0, next.height > 0 else { return }
        value = value == .zero ? next : value.union(next)
    }
}

private struct ContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ControlRectsPreferenceKey: PreferenceKey {
    static let defaultValue: [OverlayControlID: CGRect] = [:]
    static func reduce(value: inout [OverlayControlID: CGRect],
                       nextValue: () -> [OverlayControlID: CGRect]) {
        for (id, rect) in nextValue() where rect != .zero { value[id] = rect }
    }
}

private struct ControlsFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

final class WrapContentRectSink: @unchecked Sendable {

    var rect: CGRect = .zero
}

struct AnySendableHashable: Hashable, @unchecked Sendable {
    let base: AnyHashable
    init(_ base: AnyHashable) {
        self.base = base
    }
}

struct WrapLayout: Layout {
    typealias RowAlignment = WrapLayoutMath.RowAlignment

    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 2
    var rowAlignment: RowAlignment = .center

    var contentKey: AnySendableHashable? = nil

    var contentRectSink: WrapContentRectSink? = nil

    init(
        horizontalSpacing: CGFloat = 0,
        verticalSpacing: CGFloat = 2,
        rowAlignment: RowAlignment = .center,
        contentKey: AnyHashable? = nil,
        contentRectSink: WrapContentRectSink? = nil
    ) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.rowAlignment = rowAlignment
        self.contentKey = contentKey.map(AnySendableHashable.init)
        self.contentRectSink = contentRectSink
    }

    struct Cache {
        var sizes: [CGSize]
        var contentKey: AnySendableHashable?
        var subviewCount: Int

        var rows: [WrapLayoutMath.Row]?
        var rowsWidth: CGFloat = .nan
        var rowsSpacing: CGFloat = .nan
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) },
              contentKey: contentKey, subviewCount: subviews.count)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        if let key = contentKey, key == cache.contentKey, subviews.count == cache.subviewCount {
            return
        }
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.contentKey = contentKey
        cache.subviewCount = subviews.count
        cache.rows = nil
        cache.rowsWidth = .nan
        cache.rowsSpacing = .nan
    }

    private func cachedRows(_ cache: inout Cache, maxWidth: CGFloat) -> [WrapLayoutMath.Row] {
        if let rows = cache.rows, cache.rowsWidth == maxWidth, cache.rowsSpacing == horizontalSpacing {
            return rows
        }
        let rows = WrapLayoutMath.rows(
            sizes: cache.sizes, maxWidth: maxWidth, horizontalSpacing: horizontalSpacing)
        cache.rows = rows
        cache.rowsWidth = maxWidth
        cache.rowsSpacing = horizontalSpacing
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let maxWidth = proposal.width, maxWidth.isFinite else {

            return WrapLayoutMath.unconstrainedSize(
                sizes: cache.sizes, horizontalSpacing: horizontalSpacing)
        }
        return WrapLayoutMath.totalSize(
            rows: cachedRows(&cache, maxWidth: maxWidth),
            maxWidth: maxWidth, verticalSpacing: verticalSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rows = cachedRows(&cache, maxWidth: bounds.width)
        if let sink = contentRectSink {

            let local = WrapLayoutMath.contentBounds(
                rows: rows, bounds: CGRect(origin: .zero, size: bounds.size),
                verticalSpacing: verticalSpacing, rowAlignment: rowAlignment)
            sink.rect = local
        }
        for p in WrapLayoutMath.placements(
            rows: rows,
            sizes: cache.sizes, bounds: bounds,
            horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing,
            rowAlignment: rowAlignment)
        {
            subviews[p.index].place(
                at: p.origin, anchor: .topLeading, proposal: ProposedViewSize(p.size))
        }
    }
}

private struct OverlayRejectShake: GeometryEffect {
    var travel: CGFloat
    var amplitude: CGFloat = 7
    var cycles: CGFloat = 3

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = amplitude * sin(travel * .pi * 2 * cycles)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}
