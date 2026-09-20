import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

@MainActor
private final class NotchPlayback: ObservableObject {

    @Published private(set) var title = ""
    @Published private(set) var artist = ""

    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var currentLine: SyncedLyricLine?

    @Published private(set) var displayLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?

    @Published private(set) var secondaryText: String?

    @Published private(set) var secondaryLine: LyricSecondaryLine = AppSettings.defaultNotchSecondaryLine
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false

    @Published private(set) var isRadioTalkBreak = false
    @Published private(set) var radioStationName: String?
    @Published private(set) var radioStationImage: NSImage?

    @Published private(set) var currentAdSlot: YouTubeMusicAdProbe.AdSlot? = nil
    @Published private(set) var currentLineFillSettled = true
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var highResArtworkImage: NSImage?

    @Published private(set) var blurredArtworkImage: NSImage?
    @Published private(set) var anchor: ProgressAnchor?
    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?

    @Published private(set) var accent: Color = .white

    @Published private(set) var notchCardStyle: NotchCardStyle = .coverArt

    @Published private(set) var leftEar: NotchEarModule = .title
    @Published private(set) var rightEar: NotchEarModule = .artist

    @Published private(set) var lyricRowShowsArtwork: Bool = true
    @Published private(set) var lyricRowArtworkPosition: NotchLyricRowArtworkPosition = .right

    @Published private(set) var lyricsAlignment: LyricsRestingAlignment =
        AppSettings.defaultNotchLyricsAlignment

    @Published private(set) var mainFont: Font = AppSettings.shared.notchMainFont
    @Published private(set) var mainDetailFont: Font = AppSettings.shared.notchMainDetailFont
    @Published private(set) var secondaryFont: Font = AppSettings.shared.notchSecondaryFont

    @Published private(set) var mainLineHeight: CGFloat =
        NotchLyricRowMetrics.mainLineHeight(fontSize: CGFloat(AppSettings.shared.notchFontSize))

    @Published private(set) var nextLineSide: LyricDuet.Side?

    var mainLyricAlignment: Alignment {
        lyricsAlignment.resolved(duetSide: displayLine?.side).swiftUIAlignment
    }
    var nextLineAlignment: Alignment {
        lyricsAlignment.resolved(duetSide: nextLineSide).swiftUIAlignment
    }
    var secondaryLyricAlignment: Alignment {
        secondaryLine == .nextLine ? nextLineAlignment : mainLyricAlignment
    }

    var canSkipAd: Bool {
        isCurrentTrackAdBreak && YouTubeMusicAdSkipper.isYouTubeMusicAd(artist: artist, title: title)
            && adSkipAvailable
    }

    @Published private(set) var adSkipAvailable = false

    private var adSkipGateTask: Task<Void, Never>?

    static let skipGateLogger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "ytmusic-skip")

    func syncAdSkipGate(adBreak: Bool) {
        NotchPlayback.skipGateLogger.info("gate: adBreak \(adBreak, privacy: .public) → \(adBreak ? "start" : "stop", privacy: .public)")
        adSkipGateTask?.cancel()
        adSkipGateTask = nil
        guard adBreak else {
            if adSkipAvailable { adSkipAvailable = false }
            return
        }
        adSkipAvailable = false
        let bundleID = LocalPlaybackSource.shared.lastResolvedBundleID
        adSkipGateTask = Task.detached(priority: .utility) { [weak self] in
            for round in 0 ..< YouTubeMusicAdSkipper.gateMaxRounds {
                if Task.isCancelled { return }
                let state = YouTubeMusicAdSkipper.probeSkippability(reportedBundleID: bundleID)
                let shows = YouTubeMusicAdSkipper.showsSkipButton(state)
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    if self.adSkipAvailable != shows {
                        self.adSkipAvailable = shows
                        NotchPlayback.skipGateLogger.info(
                            "gate: adSkipAvailable -> \(shows, privacy: .public) (state \(String(describing: state), privacy: .public))")
                    }
                }

                guard let state, state != .notInAd else { return }
                try? await Task.sleep(for: .seconds(YouTubeMusicAdSkipper.gateRetryDelay(after: state, round: round)))
            }
        }
    }

    @Published private(set) var skipAdInFlight = false

    func skipAd() {
        guard !skipAdInFlight else { return }
        skipAdInFlight = true
        let bundleID = LocalPlaybackSource.shared.lastResolvedBundleID
        Task.detached(priority: .userInitiated) {
            let outcome = YouTubeMusicAdSkipper.skip(reportedBundleID: bundleID)
            await MainActor.run { [weak self] in
                self?.skipAdInFlight = false
                NotchPlayback.reportSkipOutcome(outcome)
            }
        }
    }

    private static func reportSkipOutcome(_ outcome: YouTubeMusicAdSkipper.Outcome?) {
        switch outcome {
        case .skipped?:
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        case .notYetSkippable(let seconds)?:
            let text = seconds.map { String(format: L10n.t("%@ 秒后可跳过"), String($0)) } ?? L10n.t("这条广告还不能跳过")
            NotchTransientCenter.shared.show(.init(icon: "forward.end", text: text, progress: nil))
        case .needsAccessibility?:

            AccessibilitySkipPress.promptForTrust()
            NotchTransientCenter.shared.show(.init(icon: "hand.raised", text: L10n.t("跳过广告需要「辅助功能」权限"), progress: nil),
                                             for: 2.4)
        case .tabNotFrontmost?:
            NotchTransientCenter.shared.show(.init(icon: "macwindow", text: L10n.t("把 YouTube Music 标签页切到前面再试"), progress: nil),
                                             for: 2.4)
        case .clickedNoEffect?, .notFound?, nil:
            NotchTransientCenter.shared.show(.init(icon: "megaphone", text: L10n.t("没能跳过这条广告"), progress: nil))
        }
    }

    @Published private(set) var showsLyricsOffsetControls: Bool = false

    @Published private(set) var trackLyricsOffsetMs: Int = 0
    @Published private(set) var lyricsOffsetStepMs: Int = 200
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$currentLine.removeDuplicates().sink { [weak self] in self?.currentLine = $0 },

            Publishers.CombineLatest4(p.$compactLine, p.$currentLine, s.$notchLyricsKaraoke, s.$notchSecondaryLine)
                .map { compact, current, karaoke, secondary -> SyncedLyricLine? in
                    let line = secondary.showsSecondaryRow ? current : compact
                    return karaoke ? line : line?.lineLevel
                }
                .removeDuplicates()
                .sink { [weak self] in self?.displayLine = $0 },

            Publishers.CombineLatest3(p.$currentLine, p.$nextLineText, s.$notchSecondaryLine)
                .map { current, next, secondary -> String? in

                    secondary.secondaryText(currentLine: current, nextLineText: next)
                }
                .removeDuplicates()
                .sink { [weak self] in self?.secondaryText = $0 },
            s.$notchSecondaryLine.removeDuplicates().sink { [weak self] in self?.secondaryLine = $0 },
            p.$nextLineText.removeDuplicates().sink { [weak self] in self?.nextLineText = $0 },
            p.$nextLineSide.removeDuplicates().sink { [weak self] in self?.nextLineSide = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$isRadioTalkBreak.removeDuplicates().sink { [weak self] in self?.isRadioTalkBreak = $0 },
            p.$radioStationName.removeDuplicates().sink { [weak self] in self?.radioStationName = $0 },
            p.$radioStationImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.radioStationImage = $0 },
            p.$currentAdSlot.removeDuplicates().sink { [weak self] in self?.currentAdSlot = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
            p.$blurredArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.blurredArtworkImage = $0 },

            p.$anchor.sink { [weak self] in self?.anchor = $0 },
            p.$pausedPositionMs.removeDuplicates().sink { [weak self] in self?.pausedPositionMs = $0 },
            p.$currentDurationMs.removeDuplicates().sink { [weak self] in self?.currentDurationMs = $0 },

            Publishers.CombineLatest(p.$notchAccentColor, s.$notchCardStyle)
                .map { accent, style in style == .coverArt ? (accent ?? .white) : .white }
                .removeDuplicates()
                .sink { [weak self] in self?.accent = $0 },
            s.$notchCardStyle.removeDuplicates().sink { [weak self] in self?.notchCardStyle = $0 },
            s.$notchLeftEar.removeDuplicates().sink { [weak self] in self?.leftEar = $0 },
            s.$notchRightEar.removeDuplicates().sink { [weak self] in self?.rightEar = $0 },
            s.$notchLyricRowShowsArtwork.removeDuplicates().sink { [weak self] in self?.lyricRowShowsArtwork = $0 },
            s.$notchLyricRowArtworkPosition.removeDuplicates().sink { [weak self] in self?.lyricRowArtworkPosition = $0 },
            s.$notchLyricsAlignment.removeDuplicates().sink { [weak self] in self?.lyricsAlignment = $0 },

            s.$notchMainFont.sink { [weak self] in self?.mainFont = $0 },
            s.$notchMainDetailFont.sink { [weak self] in self?.mainDetailFont = $0 },
            s.$notchSecondaryFont.sink { [weak self] in self?.secondaryFont = $0 },
            s.$notchFontSize.removeDuplicates()
                .map { NotchLyricRowMetrics.mainLineHeight(fontSize: CGFloat($0)) }
                .removeDuplicates()
                .sink { [weak self] in self?.mainLineHeight = $0 },
            s.$notchExpandedShowsLyricsOffset.removeDuplicates().sink { [weak self] in self?.showsLyricsOffsetControls = $0 },
            p.$trackLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.trackLyricsOffsetMs = $0 },
            s.$lyricsOffsetStepMs.removeDuplicates().sink { [weak self] in self?.lyricsOffsetStepMs = $0 },
        ]
    }
}

extension NotchEarModule {

    var displayName: String {
        switch self {
        case .title: return L10n.t("歌名")
        case .artist: return L10n.t("歌手")
        case .album: return L10n.t("专辑")
        case .artwork: return L10n.t("封面")
        case .controls: return L10n.t("播放控制")
        case .elapsed: return L10n.t("已播时长")
        case .remaining: return L10n.t("剩余时长")
        case .none: return L10n.t("不显示")
        }
    }

    var isClock: Bool { self == .elapsed || self == .remaining }

    func minEarContentWidth(contentTopInset: CGFloat) -> CGFloat {
        switch self {
        case .none, .title, .artist, .album: return 0
        case .controls: return 48
        case .artwork: return NotchMetrics.earArtworkSide(contentTopInset: contentTopInset)

        case .elapsed, .remaining: return 39
        }
    }

    var isPrimary: Bool { self == .title }
}

extension NotchLyricRowArtworkPosition {
    var displayName: String {
        switch self {
        case .left: return L10n.t("左")
        case .right: return L10n.t("右")
        }
    }
}

extension LyricSecondaryLine {

    var displayName: String {
        switch self {
        case .off: return L10n.t("不显示")
        case .nextLine: return L10n.t("下一句")
        case .translation: return L10n.t("译文")
        case .romanization: return L10n.t("罗马音")
        }
    }
}

extension NotchCardStyle {
    var displayName: String {
        switch self {
        case .solidBlack: return L10n.t("纯黑")
        case .frostedGlass: return L10n.t("磨砂玻璃")
        case .darkGradient: return L10n.t("深色渐变")
        case .coverArt: return L10n.t("跟随封面")
        }
    }

    var fill: AnyShapeStyle {
        switch self {
        case .solidBlack:
            return AnyShapeStyle(Color.black)
        case .frostedGlass:
            return AnyShapeStyle(.thickMaterial)
        case .darkGradient, .coverArt:

            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(hexWithAlpha: "#1C1A24FF", fallback: .black),
                        Color(hexWithAlpha: "#14212AFF", fallback: .black),
                        Color(hexWithAlpha: "#10161CFF", fallback: .black),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

enum NotchMetrics {

    static var compactRowHeight: CGFloat { NotchLyricRowMetrics.rowHeight }

    static var secondaryLyricLineHeight: CGFloat { NotchLyricRowMetrics.secondaryLineHeight }
    static var secondaryLineSpacing: CGFloat { NotchLyricRowMetrics.lineSpacing }

    static func expandedExtraHeightMax(
        hasLyricPreviewPossible: Bool = true, hasControlsPossible: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        NotchExpandedMetrics.maxHeight(
            hasLyricPreviewPossible: hasLyricPreviewPossible, hasControlsPossible: hasControlsPossible,
            trackInfoHeight: trackInfoHeight)
    }

    static func expandedExtraHeight(
        hasLyricPreview: Bool, hasScrubber: Bool, hasControls: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        NotchExpandedMetrics.height(
            hasLyricPreview: hasLyricPreview, hasScrubber: hasScrubber, hasControls: hasControls,
            trackInfoHeight: trackInfoHeight)
    }

    static func expandedTrackInfoHeight(
        showsArtwork: Bool, showsTitle: Bool, showsArtist: Bool, showsAlbum: Bool, showsActions: Bool = false
    ) -> CGFloat {
        NotchExpandedMetrics.trackInfoHeight(
            showsArtwork: showsArtwork, showsTitle: showsTitle, showsArtist: showsArtist, showsAlbum: showsAlbum,
            showsActions: showsActions)
    }

    static var trackInfoSpacing: CGFloat { NotchExpandedMetrics.trackInfoSpacing }
    static var trackInfoTopSpacing: CGFloat { NotchExpandedMetrics.trackInfoTopSpacing }
    static var trackInfoArtworkSide: CGFloat { NotchExpandedMetrics.trackInfoArtworkSide }
    static var trackInfoLineSpacing: CGFloat { NotchExpandedMetrics.trackInfoLineSpacing }
    static var trackInfoActionsHeight: CGFloat { NotchExpandedMetrics.trackInfoActionsHeight }

    static var idleExpandedPanelHeight: CGFloat { NotchExpandedMetrics.idlePanelHeight }

    static let collapsedEarWidth: CGFloat = 34
    static let artworkLyricSpacing: CGFloat = 10

    static let lyricEdgeFadeWidth: CGFloat = 10
    static let artworkCornerRadius: CGFloat = 5

    static let earNotchInset: CGFloat = 6

    static let cardHorizontalPadding: CGFloat = 10

    static let earWaveSpacing: CGFloat = 5

    static func earArtworkSide(contentTopInset: CGFloat) -> CGFloat { max(16, contentTopInset - 10) }

    static func earAppIconSide(contentTopInset: CGFloat) -> CGFloat {
        min(contentTopInset - 4, earArtworkSide(contentTopInset: contentTopInset) + 4)
    }

    static func earAdIconSize(contentTopInset: CGFloat) -> CGFloat {
        max(11, earArtworkSide(contentTopInset: contentTopInset) * 0.56)
    }
}

@MainActor
protocol NotchChromeSource: ObservableObject {

    var isCollapsed: Bool { get }
    var isExpanded: Bool { get }

    var notchWidth: CGFloat { get }
    var contentTopInset: CGFloat { get }

    var steadyCardWidth: CGFloat { get }
    var expandedCardWidth: CGFloat { get }

    var expandedShowsLyricPreview: Bool { get }

    var expandedShowsScrubber: Bool { get }

    var hasTrack: Bool { get }

    var isAdBreakNow: Bool { get }

    var showsLyrics: Bool { get }

    var showsEqualizer: Bool { get }

    var equalizerEar: NotchEqualizerEar { get }

    var expandedShowsNextLine: Bool { get }

    var expandedShowsControls: Bool { get }

    var expandedTrackInfoShowsArtwork: Bool { get }
    var expandedTrackInfoShowsTitle: Bool { get }
    var expandedTrackInfoShowsArtist: Bool { get }
    var expandedTrackInfoShowsAlbum: Bool { get }

    var expandedShowsQuickActions: Bool { get }
    func setExpanded(_ expanded: Bool)

    func closeFromQuickAction()
}

extension NotchChromeSource {

    var showsLyricRow: Bool { hasTrack && (showsLyrics || isExpanded) }

    var showsExpandedLyricPreview: Bool { expandedShowsLyricPreview && expandedShowsNextLine }

    var showsExpandedTrackInfo: Bool {
        hasTrack && !isAdBreakNow
            && (expandedTrackInfoShowsArtwork || expandedTrackInfoShowsTitle
                || expandedTrackInfoShowsArtist || expandedTrackInfoShowsAlbum
                || expandedShowsQuickActions)
    }

    var expandedTrackInfoHeight: CGFloat {
        guard showsExpandedTrackInfo else { return 0 }
        return NotchMetrics.expandedTrackInfoHeight(
            showsArtwork: expandedTrackInfoShowsArtwork,
            showsTitle: expandedTrackInfoShowsTitle,
            showsArtist: expandedTrackInfoShowsArtist,
            showsAlbum: expandedTrackInfoShowsAlbum,
            showsActions: expandedShowsQuickActions)
    }

    var expandedTrackInfoHeaderHeight: CGFloat {
        let height = expandedTrackInfoHeight
        return height > 0 ? height + NotchMetrics.trackInfoTopSpacing + NotchMetrics.trackInfoSpacing : 0
    }

    var cardHeight: CGFloat {
        if isCollapsed { return contentTopInset }

        if !hasTrack {
            return contentTopInset + (isExpanded ? NotchMetrics.idleExpandedPanelHeight : 0)
        }
        return contentTopInset

            + (showsLyricRow ? NotchMetrics.compactRowHeight : 0)
            + (isExpanded
               ? NotchMetrics.expandedExtraHeight(
                   hasLyricPreview: showsExpandedLyricPreview,
                   hasScrubber: expandedShowsScrubber,
                   hasControls: expandedShowsControls,
                   trackInfoHeight: expandedTrackInfoHeight)
               : 0)
    }
}

struct NotchLyricsView<Chrome: NotchChromeSource>: View {
    @ObservedObject var controller: Chrome

    var prompt: NotchUnknownPlayerPrompt = .inert

    @StateObject private var playback = NotchPlayback()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.notchRevealContentOpacity) private var revealContentOpacity

    @Environment(\.notchHostClipsCard) private var hostClipsCard

    @Environment(\.notchCardLayerActive) private var cardLayerActive

    @Environment(\.displayScale) private var displayScale

    @State private var hoveredQuickAction: QuickActionHint?

    @State private var shownQuickActionTooltip: QuickActionHint?

    var body: some View {
        GeometryReader { proxy in

            let earWidth = max(0, (proxy.size.width - controller.notchWidth
                                   - NotchMetrics.cardHorizontalPadding * 2) / 2)
            ZStack(alignment: .top) {
                backgroundLayer(size: proxy.size)

                Color.black
                    .opacity(controller.isCollapsed || isIdleNoTrack || controller.isAdBreakNow ? 1 : 0)

                notchSeam
                    .frame(height: controller.contentTopInset)
                    .opacity(revealContentOpacity)

                VStack(spacing: 0) {

                    topRow(earWidth: earWidth)
                        .frame(height: controller.contentTopInset)

                }

                .opacity(revealContentOpacity)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }

            .overlay(alignment: .top) {
                if !controller.isCollapsed, controller.hasTrack {
                    cardBodyLayer

                        .opacity(revealContentOpacity)
                } else if !controller.isCollapsed {

                    NotchIdlePanelHost(prompt: prompt, tint: accentOrWhite) { idleExpandedPanel }
                        .frame(width: controller.expandedCardWidth,
                               height: NotchMetrics.idleExpandedPanelHeight, alignment: .top)
                        .padding(.top, controller.contentTopInset)
                        .modifier(NotchCardLayerActive(active: controller.isExpanded))
                        .opacity(revealContentOpacity)
                }
            }

            .modifier(NotchCardClip(enabled: !hostClipsCard))
        }

        .onAppear { playback.syncAdSkipGate(adBreak: controller.isAdBreakNow) }
        .onChange(of: controller.isAdBreakNow) { _, on in playback.syncAdSkipGate(adBreak: on) }

        .onChange(of: playback.canSkipAd) { _, value in
            NotchPlayback.skipGateLogger.info("""
                view: canSkipAd=\(value, privacy: .public) expanded=\(controller.isExpanded, privacy: .public)                 showsLyrics=\(controller.showsLyrics, privacy: .public) hint=\(showsAdSkipHint, privacy: .public)
                """)
        }
        .onChange(of: showsAdSkipHint) { _, value in
            NotchPlayback.skipGateLogger.info("view: adSkipHint=\(value, privacy: .public)")
        }

    }

    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {

        if playback.notchCardStyle == .coverArt,
           let image = playback.blurredArtworkImage {
            ZStack {

                Color(hexWithAlpha: "#14212AFF", fallback: .black)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)

                    .overlay(Color.black.opacity(LocalPlaybackSource.notchCoverArtOverlayOpacity))
                    .animation(.easeInOut(duration: 0.5), value: playback.blurredArtworkImage)
            }
        } else {
            NotchHangingShape(bottomCornerRadius: 20)
                .fill(playback.notchCardStyle.fill)
        }
    }

    private var isIdleNoTrack: Bool { !controller.hasTrack }

    private var notchGap: some View {
        Spacer(minLength: 0).frame(width: controller.notchWidth)
    }

    private var notchSeam: some View {
        ZStack {
            if controller.notchWidth > 0, controller.hasTrack {
                Text(verbatim: "Lyrimuse")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(seamTextColor)
                    .padding(.horizontal, 9)
                    .frame(height: min(22, max(14, controller.contentTopInset - 8)))
                    .background {

                        Capsule().fill(accentOrWhite)
                            .overlay {
                                Capsule().fill(LinearGradient(
                                    colors: [.white.opacity(0.42), .white.opacity(0.10), .clear],
                                    startPoint: .top, endPoint: .center))
                            }
                            .overlay { Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5) }
                    }
                    .accessibilityHidden(true)
            }
        }
        .frame(width: controller.notchWidth)
    }

    private var seamTextColor: Color {
        guard let ns = NSColor(accentOrWhite).usingColorSpace(.sRGB) else { return .black }
        let lum = LocalPlaybackSource.relativeLuminance(
            r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
        return lum > 0.179 ? .black : .white
    }

    private func showsEqualizer(on side: NotchEqualizerEar, module: NotchEarModule) -> Bool {
        controller.showsEqualizer && controller.equalizerEar == side && module != .controls
    }

    private var equalizerBars: some View {
        EqualizerBars(color: accentOrWhite, isPlaying: playback.isPlayingNow,
                      amplitude: Self.vocalAmplitude(at:))
    }

    private func topRow(earWidth: CGFloat) -> some View {
        let collapsed = controller.isCollapsed
        let leftModule: NotchEarModule = collapsed ? .artwork : playback.leftEar
        let rightModule: NotchEarModule = collapsed ? .none : playback.rightEar
        let equalizerOnLeft = !collapsed && showsEqualizer(on: .left, module: playback.leftEar)
        let equalizerOnRight = collapsed || showsEqualizer(on: .right, module: playback.rightEar)
        return HStack(spacing: 0) {

            HStack(spacing: NotchMetrics.earWaveSpacing) {
                if equalizerOnLeft {
                    equalizerBars
                }

                if isIdleNoTrack {
                    idleEarIcon(alignment: .leading)
                } else if controller.isAdBreakNow {

                    adBreakEarIcon(alignment: .leading)
                } else if leftModule != .none {
                    earContent(leftModule, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            .padding(.trailing, NotchMetrics.earNotchInset)
            .frame(width: earWidth)

            notchGap

            HStack(spacing: NotchMetrics.earWaveSpacing) {
                if rightModule != .none {
                    earContent(rightModule, alignment: .trailing)
                }
                if equalizerOnRight {
                    equalizerBars
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, NotchMetrics.earNotchInset)
            .frame(width: earWidth)
        }
        .padding(.horizontal, NotchMetrics.cardHorizontalPadding)
    }

    @ViewBuilder
    private func earContent(_ module: NotchEarModule, alignment: Alignment) -> some View {
        switch module {
        case .artwork:
            earArtwork(alignment: alignment)
        case .controls:
            earControls(alignment: alignment)
        case .elapsed, .remaining:
            if let anchor = playback.anchor {
                TimelineView(NotchTimeFormat.clockSchedule(for: anchor)) { _ in
                    earText(clockText(module), module: module, alignment: alignment)
                }
            } else {
                earText(clockText(module), module: module, alignment: alignment)
            }
        case .title, .artist, .album, .none:
            earText(metadataText(module), module: module, alignment: alignment)
        }
    }

    @ViewBuilder
    private func earArtwork(alignment: Alignment) -> some View {
        if let image = radioTalkStation?.image ?? playback.highResArtworkImage ?? playback.artworkImage {
            artworkThumbnail(
                image,
                side: NotchMetrics.earArtworkSide(contentTopInset: controller.contentTopInset))
                .frame(maxWidth: .infinity, alignment: alignment)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
        }
    }

    @ViewBuilder
    private func adBreakEarIcon(alignment: Alignment) -> some View {
        let side = NotchMetrics.earAdIconSize(contentTopInset: controller.contentTopInset)
        let hint = showsAdSkipHint
        HStack(spacing: side * 0.22) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: side, weight: .semibold))
            if hint {

                Image(systemName: "forward.end.fill")
                    .font(.system(size: side * 0.78, weight: .semibold))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(accentOrWhite.opacity(0.7))
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        .frame(maxWidth: .infinity, alignment: alignment)

        .accessibilityHidden(!hint)
        .accessibilityLabel(hint ? L10n.t("这条广告可以跳过") : "")
    }

    private var showsAdSkipHint: Bool {
        playback.canSkipAd && !controller.isExpanded && !controller.showsLyrics
    }

    @ViewBuilder
    private func idleAppIcon(alignment: Alignment) -> some View {
        let side = NotchMetrics.earAppIconSide(contentTopInset: controller.contentTopInset)
        let scale = max(1, displayScale)
        Group {
            if let bitmap = NotchIdleAppIcon.bitmap(pixelSide: Int((side * scale).rounded())) {
                Image(decorative: bitmap, scale: scale)
            } else {

                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityHidden(true)
    }

    private func earControls(alignment: Alignment) -> some View {
        HStack(spacing: 0) {
            controlButton("backward.fill") { MusicPlaybackController.previousTrack() }
            controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill", primary: true) {

                PlaybackCoordinator.shared.userTogglePlayPause()
            }
            controlButton("forward.fill") { MusicPlaybackController.nextTrack() }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func metadataText(_ module: NotchEarModule) -> String {
        if isIdleNoTrack { return "" }
        let isAd = playback.isCurrentTrackAdBreak

        let station = radioTalkStation
        switch module {
        case .title:
            if isAd { return L10n.t("广告中") }
            if let station { return station.name }
            return playback.title.isEmpty ? "♪" : playback.title
        case .artist: return (isAd || station != nil) ? "" : playback.artist
        case .album: return (isAd || station != nil) ? "" : playback.album

        case .artwork, .controls, .elapsed, .remaining, .none: return ""
        }
    }

    private var radioTalkStation: (name: String, image: NSImage?)? {
        guard playback.isRadioTalkBreak, let name = playback.radioStationName, !name.isEmpty else { return nil }
        return (name, playback.radioStationImage)
    }

    private func clockText(_ module: NotchEarModule) -> String {
        guard !isIdleNoTrack else { return "" }
        guard let position = playback.anchor?.extrapolatedPositionMs(now: Date())
                ?? playback.pausedPositionMs else { return "" }
        switch module {
        case .elapsed:
            return NotchTimeFormat.mmss(ms: position)
        case .remaining:
            guard let total = playback.currentDurationMs, total > 0 else { return "" }
            return "-" + NotchTimeFormat.mmss(ms: max(0, total - position))
        default:
            return ""
        }
    }

    private func earText(_ text: String, module: NotchEarModule, alignment: Alignment) -> some View {
        let base = Font.system(size: 11.5, weight: module.isPrimary ? .semibold : .medium)
        return MarqueeText(id: text, restingAlignment: alignment) {
            Text(text)
                .font(module.isClock ? base.monospacedDigit() : base)
                .foregroundStyle(accentOrWhite.opacity(module.isPrimary ? 0.85 : 0.6))
                .lineLimit(1)
        }
    }

    private static func artworkSide(rowHeight: CGFloat) -> CGFloat {
        max(16, min(32, rowHeight - 12))
    }

    private func artworkThumbnail(_ image: NSImage, side: CGFloat? = nil) -> some View {
        let side = side ?? Self.artworkSide(rowHeight: NotchMetrics.compactRowHeight)
        return HoverReveal { hovering in
            artworkButton(image, side: side, hovering: hovering)
        }
    }

    private func artworkButton(_ image: NSImage, side: CGFloat, hovering: Bool) -> some View {
        let scale = max(1, displayScale)

        return Button {
            AppActions.shared.openLyricsWindow?()
        } label: {
            Group {
                if let bitmap = ArtworkThumbnailCache.bitmap(for: image, pixelSide: Int((side * scale).rounded())) {
                    Image(decorative: bitmap, scale: scale)
                } else {

                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
                .frame(width: side, height: side)

                .clipShape(RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous))

                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        }
        .buttonStyle(NotchArtworkButtonStyle(cornerRadius: NotchMetrics.artworkCornerRadius,
                                             hovering: hovering))
        .help(L10n.t("打开歌词窗口"))
    }

    private var cardBodyLayer: some View {
        let expanded = controller.isExpanded
        let top = controller.contentTopInset
        let headerHeight = controller.expandedTrackInfoHeaderHeight

        return ZStack(alignment: .top) {

            if controller.showsExpandedTrackInfo {
                trackInfoHeader
                    .frame(width: controller.expandedCardWidth, height: headerHeight, alignment: .top)
                    .padding(.top, top)
                    .modifier(NotchCardLayerActive(active: expanded))
            }

            if controller.showsLyrics {
                lyricRow
                    .frame(width: controller.steadyCardWidth, height: NotchMetrics.compactRowHeight)
                    .padding(.top, top)
                    .modifier(NotchCardLayerActive(active: !expanded))
            }
            lyricRow
                .frame(width: controller.expandedCardWidth, height: NotchMetrics.compactRowHeight)
                .padding(.top, top + headerHeight)
                .modifier(NotchCardLayerActive(active: expanded))

            expandedContent
                .frame(width: controller.expandedCardWidth)
                .padding(.top, top + headerHeight + NotchMetrics.compactRowHeight)
                .modifier(NotchCardLayerActive(active: expanded))
        }
    }

    private var lyricRow: some View {

        NotchTransientHost(tint: accentOrWhite) {
            lyricRowContent
        }
    }

    private var lyricRowContent: some View {
        HStack(spacing: NotchMetrics.artworkLyricSpacing) {

            if playback.lyricRowArtworkPosition == .left { lyricRowArtwork }

            Group {
                if playback.isCurrentTrackAdBreak {
                    adStatusColumn
                } else {
                    lyricTextColumn
                }
            }

            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if playback.lyricRowArtworkPosition == .right { lyricRowArtwork }
        }
        .padding(.horizontal, 16)

        .animation(nil, value: !lyricRowArtworkPresent)
    }

    private var adStatusColumn: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 11, weight: .semibold))

                Text(L10n.t("广告中"))
                    .font(playback.mainFont)
                adSlotText
                    .font(playback.mainDetailFont)
                adCountdown
                    .font(playback.mainDetailFont)
            }
            .foregroundStyle(accentOrWhite.opacity(0.7))
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .lineLimit(1)
            Spacer(minLength: 0)
            if playback.canSkipAd {
                NotchPillButton(systemName: "forward.end.fill", title: L10n.t("跳过广告"), tint: accentOrWhite) {
                    playback.skipAd()
                }

                .opacity(playback.skipAdInFlight ? 0.45 : 1)
                .disabled(playback.skipAdInFlight)
            }
        }
    }

    @ViewBuilder
    private var adCountdown: some View {
        if let total = playback.currentDurationMs, total > 0 {
            if let anchor = playback.anchor, cardLayerActive {
                TimelineView(NotchTimeFormat.clockSchedule(for: anchor)) { _ in
                    Text(adRemainingText(total: total, position: anchor.extrapolatedPositionMs(now: Date())))
                }
            } else if let position = playback.anchor?.extrapolatedPositionMs(now: Date()) ?? playback.pausedPositionMs {
                Text(adRemainingText(total: total, position: position))
            }
        }
    }

    private func adRemainingText(total: Int, position: Int) -> String {
        "· " + String(format: L10n.t("还剩 %@"), NotchTimeFormat.mmss(ms: max(0, total - position)))
    }

    @ViewBuilder
    private var adSlotText: some View {
        if let slot = playback.currentAdSlot {
            Text(verbatim: "· \(slot.index)/\(slot.total)")
        }
    }

    @ViewBuilder
    private var lyricTextColumn: some View {
        if playback.secondaryLine.showsSecondaryRow {
            VStack(alignment: .leading, spacing: NotchMetrics.secondaryLineSpacing) {
                mainLyricLine
                    .frame(height: playback.mainLineHeight)
                secondaryLyricLine
                    .frame(height: NotchMetrics.secondaryLyricLineHeight)
            }
        } else {
            mainLyricLine
        }
    }

    private var mainLyricLine: some View {
        MarqueeText(id: playback.displayLine?.plainText ?? "",
                    restingAlignment: playback.mainLyricAlignment,
                    edgeFadeWidth: NotchMetrics.lyricEdgeFadeWidth) {
            lyricContent
        }

        .font(playback.mainFont)
    }

    private var secondaryLyricLine: some View {
        Text(playback.secondaryText ?? "")

            .font(playback.secondaryFont)
            .foregroundStyle(accentOrWhite.opacity(secondaryLineOpacity))
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: playback.secondaryLyricAlignment)
    }

    private var secondaryLineOpacity: Double {
        switch playback.secondaryLine {
        case .off, .nextLine: return 0.45
        case .translation: return 0.75
        case .romanization: return 0.6
        }
    }

    @ViewBuilder
    private var lyricRowArtwork: some View {
        if playback.lyricRowShowsArtwork {
            if controller.isAdBreakNow {

                adBreakArtworkTile(side: Self.artworkSide(rowHeight: NotchMetrics.compactRowHeight))
            } else if let image = radioTalkStation?.image ?? playback.highResArtworkImage ?? playback.artworkImage {
                artworkThumbnail(image)
            }
        }
    }

    private func adBreakArtworkTile(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous)
            .fill(.white.opacity(0.10))
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: "megaphone.fill")
                    .font(.system(size: side * 0.44, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .accessibilityHidden(true)
    }

    private var lyricRowArtworkPresent: Bool {

        playback.lyricRowShowsArtwork
            && (controller.isAdBreakNow || (playback.highResArtworkImage ?? playback.artworkImage) != nil)
    }

    private var lyricContent: some View {
        Group {
            if let words = playback.displayLine?.words, !words.isEmpty {

                TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                        paused: !playback.isPlayingNow || playback.currentLineFillSettled
                                            || !cardLayerActive)) { context in

                    let currentMs = (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: context.date)
                        ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
                        + PlaybackCoordinator.shared.currentLyricsOffsetMs

                    let palette = WordKaraokeGradient.palette(fg: accentOrWhite)
                    HStack(spacing: 0) {

                        ForEach(words.indices, id: \.self) { i in
                            wordText(words[i], atMs: currentMs, palette: palette)
                        }
                    }
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                }
            } else if playback.isCurrentTrackAdBreak {

                Text(L10n.t("广告中"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.isRadioTalkBreak {

                Text(L10n.t("口白"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.isCurrentTrackInstrumental {

                Text(L10n.t("纯音乐"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.currentTrackHasNoLyrics {

                Text(L10n.t("暂无歌词"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.collectorNetworkDown && !playback.hasLyricsContent {

                Text(L10n.t("网络连接失败"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.isPlayingNow && !playback.hasLyricsContent {

                Text(L10n.t("搜索歌词中…"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else {

                Text(playback.displayLine?.plainText ?? (isIdleNoTrack ? "" : "♪"))
                    .foregroundStyle(accentOrWhite)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            }
        }
        .lineLimit(1)
    }

    private func wordText(
        _ w: SyncedLyricWord, atMs currentMs: Int, palette: WordKaraokeGradient.Palette
    ) -> some View {
        let fraction = WordKaraokeGradient.fillFraction(for: w, atMs: currentMs)
        let band = WordKaraokeGradient.wordEdgeSoftenBand
        return Text(w.text)
            .foregroundStyle(palette.style(left: fraction - band, right: fraction + band))
    }

    private static func vocalAmplitude(at date: Date) -> Double {
        let coordinator = PlaybackCoordinator.shared
        guard let words = coordinator.currentLine?.words, !words.isEmpty else {
            return VocalEnvelope.idleAmplitude
        }

        let posMs = (coordinator.anchor?.extrapolatedPositionMs(now: date)
            ?? coordinator.pausedPositionMs ?? 0)
            + coordinator.currentLyricsOffsetMs
        return VocalEnvelope.amplitude(atMs: posMs, words: words)
    }

    private var accentOrWhite: Color {

        playback.accent
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {

            if controller.showsExpandedLyricPreview, !nextLineDisplayText.isEmpty {
                Text(nextLineDisplayText)

                    .font(playback.secondaryFont)
                    .foregroundStyle(accentOrWhite.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)

                    .frame(maxWidth: .infinity,
                           alignment: playback.nextLineAlignment)
            }

            NotchScrubber(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                isPlayingNow: playback.isPlayingNow,
                tint: accentOrWhite,

                showsLyricsOffsetControls: playback.showsLyricsOffsetControls && !playback.isCurrentTrackAdBreak,
                trackLyricsOffsetMs: playback.trackLyricsOffsetMs,
                lyricsOffsetStepMs: playback.lyricsOffsetStepMs)

            if controller.expandedShowsControls {
                HStack(spacing: 34) {
                    controlButton("backward.fill", glyphSize: 11.5, hitSize: 22) {
                        MusicPlaybackController.previousTrack()
                    }
                    controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill",
                                  glyphSize: 14, hitSize: 22) {

                        PlaybackCoordinator.shared.userTogglePlayPause()
                    }
                    controlButton("forward.fill", glyphSize: 11.5, hitSize: 22) {
                        MusicPlaybackController.nextTrack()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)

        .padding(.bottom, controller.expandedShowsControls ? 10 : 0)

        .frame(maxWidth: .infinity, alignment: .leading)

        .frame(height: NotchMetrics.expandedExtraHeight(
            hasLyricPreview: controller.showsExpandedLyricPreview,
            hasScrubber: controller.expandedShowsScrubber,
            hasControls: controller.expandedShowsControls,
            trackInfoHeight: 0), alignment: .top)
    }

    @ViewBuilder
    private var trackInfoHeader: some View {
        if controller.showsExpandedTrackInfo {
            HStack(spacing: 8) {
                trackInfoArtwork
                trackInfoTextStack
                trackInfoQuickActions
            }

                .modifier(QuickActionTooltipOverlay(hovered: hoveredQuickAction,
                                                    shown: $shownQuickActionTooltip,
                                                    tint: accentOrWhite, edge: .bottom))

                .padding(.horizontal, 16)

                .padding(.top, NotchMetrics.trackInfoTopSpacing)
        }
    }

    @ViewBuilder
    private var trackInfoArtwork: some View {
        if controller.expandedTrackInfoShowsArtwork,
           let image = playback.highResArtworkImage ?? playback.artworkImage {
            artworkThumbnail(image, side: NotchMetrics.trackInfoArtworkSide)
        }
    }

    private var trackInfoTextStack: some View {
        VStack(alignment: .leading, spacing: NotchMetrics.trackInfoLineSpacing) {
            if controller.expandedTrackInfoShowsTitle {
                Text(metadataText(.title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.9))
            }
            if controller.expandedTrackInfoShowsArtist {
                Text(metadataText(.artist))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accentOrWhite.opacity(0.6))
            }
            if controller.expandedTrackInfoShowsAlbum {
                Text(metadataText(.album))
                    .font(.system(size: 9))
                    .foregroundStyle(accentOrWhite.opacity(0.4))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var trackInfoQuickActions: some View {
        if controller.expandedShowsQuickActions {
            HStack(spacing: 2) {
                quickActionButton("magnifyingglass", label: L10n.t("搜索歌词…")) {
                    AppActions.shared.openLyricsQuickSearch?()
                }
                quickActionButton("text.alignleft",
                                  label: controller.showsLyrics ? L10n.t("隐藏歌词") : L10n.t("显示歌词"),
                                  dimmed: !controller.showsLyrics) {
                    AppSettings.shared.notchShowLyrics.toggle()
                }

                Rectangle()
                    .fill(accentOrWhite.opacity(0.18))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 3)
                quickActionButton("gearshape.fill", label: L10n.t("设置…")) { openNotchSettingsPage() }
                quickActionButton("xmark", label: L10n.t("关闭灵动岛歌词")) {
                    controller.closeFromQuickAction()
                }
            }
            .frame(height: NotchMetrics.trackInfoActionsHeight)
        }
    }

    private func openNotchSettingsPage() {
        UserDefaults.standard.set(LyricsSurface.notch.appearanceSectionRawValue,
                                  forKey: LyricsSurface.appearanceSectionStorageKey)
        AppActions.shared.requestSettings(.tab(.appearance))
        AppActions.shared.openSettings?()
    }

    private func idleEarIcon(alignment: Alignment) -> some View {
        NotchIdleEarIconHost(prompt: prompt,
                             side: NotchMetrics.earAppIconSide(contentTopInset: controller.contentTopInset),
                             scale: max(1, displayScale), alignment: alignment) {
            idleAppIcon(alignment: alignment)
        }
    }

    private var idleExpandedPanel: some View {
        let player = IdlePlaybackActions.player
        let canResume = IdlePlaybackActions.canResume(player)
        let name = player.displayName
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: NotchMetrics.trackInfoLineSpacing) {
                Text(L10n.t("没有在播放"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.9))

                Text(L10n.t("在播放器里播放任意歌曲，歌词会自动出现"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accentOrWhite.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                quickActionButton(canResume ? "play.fill" : "arrow.up.forward.app",
                                  label: canResume ? L10n.t("继续播放") : String(format: L10n.t("打开 %@"), name)) {
                    if canResume {
                        IdlePlaybackActions.resume(player: player)
                    } else {
                        IdlePlaybackActions.openPlayerApp(player)
                    }
                }

                Rectangle()
                    .fill(accentOrWhite.opacity(0.18))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 3)
                quickActionButton("gearshape.fill", label: L10n.t("设置…")) { openNotchSettingsPage() }
                quickActionButton("xmark", label: L10n.t("关闭灵动岛歌词")) {
                    controller.closeFromQuickAction()
                }
            }
            .frame(height: NotchMetrics.trackInfoActionsHeight)
        }

        .modifier(QuickActionTooltipOverlay(hovered: hoveredQuickAction,
                                            shown: $shownQuickActionTooltip,
                                            tint: accentOrWhite, edge: .top))
        .padding(.horizontal, 16)
        .padding(.top, NotchMetrics.trackInfoTopSpacing)
    }

    private func quickActionButton(_ systemName: String, label: String, dimmed: Bool = false,
                                   action: @escaping () -> Void) -> some View {
        NotchIconButton(systemName: systemName, glyphSize: 11, hitSize: NotchMetrics.trackInfoActionsHeight,
                        tint: accentOrWhite, glyphOpacity: dimmed ? 0.4 : 0.75, action: action)

            .onHover { inside in
                if inside {
                    hoveredQuickAction = QuickActionHint(key: systemName, text: label)
                } else if hoveredQuickAction?.key == systemName {
                    hoveredQuickAction = nil
                }
            }

            .onChange(of: label) { _, newLabel in
                if hoveredQuickAction?.key == systemName {
                    hoveredQuickAction = QuickActionHint(key: systemName, text: newLabel)
                }
            }

            .anchorPreference(key: QuickActionAnchorKey.self, value: .bounds) { [systemName: $0] }
            .accessibilityLabel(label)
    }

    private var nextLineDisplayText: String {
        playback.nextLineText ?? ""
    }

    private func controlButton(_ systemName: String, primary: Bool = false,
                               glyphSize: CGFloat? = nil, hitSize: CGFloat? = nil,
                               action: @escaping () -> Void) -> some View {
        let glyph = glyphSize ?? (primary ? 11 : 9.5)
        let hit = hitSize ?? (primary ? 18 : 15)
        return NotchIconButton(systemName: systemName, glyphSize: glyph, hitSize: hit,
                               tint: accentOrWhite, glyphOpacity: 1) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                action()
            }
        }
    }
}

private struct QuickActionHint: Equatable {
    let key: String
    let text: String
}

private struct QuickActionTooltipOverlay: ViewModifier {
    let hovered: QuickActionHint?
    @Binding var shown: QuickActionHint?
    let tint: Color

    let edge: VerticalEdge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bubbleSize: CGSize = .zero

    private static let gap: CGFloat = 5

    private static let initialDelayMs = 150

    private static let fallbackHeight: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(QuickActionAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let shown, let anchor = anchors[shown.key] {
                        let key = proxy[anchor]
                        let half = bubbleSize.width / 2
                        let height = bubbleSize.height > 0 ? bubbleSize.height : Self.fallbackHeight
                        bubble(shown.text)

                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(key: QuickActionBubbleSizeKey.self,
                                                           value: g.size)
                                }
                            )
                            .position(

                                x: min(max(key.midX, half), max(half, proxy.size.width - half)),
                                y: edge == .bottom
                                    ? key.maxY + Self.gap + height / 2
                                    : key.minY - Self.gap - height / 2)
                    }
                }

                .onPreferenceChange(QuickActionBubbleSizeKey.self) { bubbleSize = $0 }
                .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: shown)
            .task(id: hovered) {
                guard let hovered else {
                    shown = nil
                    return
                }
                if shown == nil {
                    try? await Task.sleep(for: .milliseconds(Self.initialDelayMs))
                    if Task.isCancelled { return }
                }
                shown = hovered
            }

            .onDisappear { shown = nil }
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)

                    .fill(Color.black.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tint.opacity(0.14))
                    )
            )
            .fixedSize()
    }
}

private struct QuickActionBubbleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct QuickActionAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct NotchIconButton: View {
    let systemName: String
    let glyphSize: CGFloat
    let hitSize: CGFloat
    let tint: Color

    let glyphOpacity: Double
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering ? min(1, glyphOpacity + 0.25) : glyphOpacity))
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }

        .buttonStyle(NotchIconButtonStyle(tint: tint, cornerRadius: (hitSize * 0.27).rounded(),
                                          hovering: hovering))
        .onHover { hovering = $0 }
    }
}

private struct NotchIconButtonStyle: ButtonStyle {
    let tint: Color
    let cornerRadius: CGFloat
    let hovering: Bool

    var restingLevel: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let level: Double = pressed ? max(0.24, restingLevel + 0.12)
            : (hovering ? max(0.14, restingLevel + 0.08) : restingLevel)
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(level))
            )

            .scaleEffect(pressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.65), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

private struct HoverReveal<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

private struct NotchArtworkButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return configuration.label
            .overlay(shape.fill(.white.opacity(pressed ? 0.16 : (hovering ? 0.08 : 0))))
            .overlay(shape.strokeBorder(.white.opacity(pressed ? 0.5 : (hovering ? 0.38 : 0.18)),
                                        lineWidth: 0.5))
            .scaleEffect(pressed ? 0.96 : 1)

            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.65), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

private struct NotchPillButton: View {
    let systemName: String
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 9.5, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint.opacity(hovering ? 1 : 0.85))
            .padding(.horizontal, 9)
            .frame(height: NotchMetrics.trackInfoActionsHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(NotchIconButtonStyle(tint: tint, cornerRadius: NotchMetrics.trackInfoActionsHeight / 2,
                                          hovering: hovering, restingLevel: 0.12))
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct NotchTransientHost<Fallback: View>: View {
    @ObservedObject private var transients = NotchTransientCenter.shared
    let tint: Color
    @ViewBuilder let fallback: () -> Fallback

    init(tint: Color, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.tint = tint
        self.fallback = fallback
    }

    var body: some View {
        ZStack {
            if let banner = transients.banner {
                NotchTransientRow(banner: banner, tint: tint)
                    .transition(.opacity)
            } else {
                fallback()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: transients.banner)
    }
}

private struct NotchScrubber: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    let isPlayingNow: Bool
    let tint: Color

    let showsLyricsOffsetControls: Bool
    let trackLyricsOffsetMs: Int
    let lyricsOffsetStepMs: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.notchCardLayerActive) private var cardLayerActive

    @GestureState private var scrubbingFraction: Double?

    @State private var scrubWidth: CGFloat = 0

    @State private var hoveringScrubber = false

    var body: some View {
        if let anchor, anchor.durationMs > 0 {
            TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                    paused: !isPlayingNow || !cardLayerActive)) { context in

                let currentMs = scrubbingFraction.map { Int($0 * Double(anchor.durationMs)) }
                    ?? anchor.extrapolatedPositionMs(now: context.date)
                scrubberAndTimes(currentMs: currentMs, durationMs: anchor.durationMs)
            }
        } else if let paused = pausedPositionMs,
                  let duration = durationMs, duration > 0 {

            let currentMs = scrubbingFraction.map { Int($0 * Double(duration)) } ?? paused
            scrubberAndTimes(currentMs: currentMs, durationMs: duration)
        }
    }

    private func scrubberAndTimes(currentMs: Int, durationMs: Int) -> some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let fraction = min(1, max(0, Double(currentMs) / Double(durationMs)))
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.18))
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: proxy.size.width * fraction)
                }

                .frame(height: scrubberHeight)
                .frame(maxHeight: .infinity)

                .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7),
                           value: scrubberHeight)
            }

            .frame(height: 6)

            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .padding(.vertical, -8)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { scrubWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in scrubWidth = w }
                }
            )
            .onHover { hoveringScrubber = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($scrubbingFraction) { value, state, _ in
                        guard scrubWidth > 0 else { return }

                        if state == nil {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment, performanceTime: .now)
                        }
                        state = min(1, max(0, value.location.x / scrubWidth))
                    }
                    .onEnded { value in
                        guard scrubWidth > 0 else { return }
                        let f = min(1, max(0, value.location.x / scrubWidth))
                        PlaybackCoordinator.shared.seek(toMs: Int(f * Double(durationMs)))
                    }
            )
            HStack {
                Text(Self.timeString(ms: currentMs))
                Spacer()

                if showsLyricsOffsetControls {
                    lyricsOffsetControls
                    Spacer()
                }
                Text("-" + Self.timeString(ms: max(0, durationMs - currentMs)))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint.opacity(0.4))
            .monospacedDigit()
        }
    }

    private var lyricsOffsetControls: some View {
        HStack(spacing: 3) {
            lyricsOffsetButton("minus", help: nudgeHelp(L10n.t("延后"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: -lyricsOffsetStepMs)
            }
            offsetReadout
            lyricsOffsetButton("plus", help: nudgeHelp(L10n.t("提前"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: lyricsOffsetStepMs)
            }
        }
    }

    private var offsetText: String {
        "\(L10n.t("歌词")) \(AppSettings.signedSeconds(ms: trackLyricsOffsetMs))s"
    }

    private var offsetReadout: some View {
        let canReset = trackLyricsOffsetMs != 0
        return HoverReveal { hovering in

            Text(offsetWidthTemplate)
                .hidden()
                .overlay {
                    Text(offsetText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .monospacedDigit()

                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tint.opacity(canReset && hovering ? 0.14 : 0))
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canReset else { return }
                    PlaybackCoordinator.shared.resetLyricsOffset()
                }
                .modifier(OptionalHelp(text: canReset ? L10n.t("点击归零") : nil))
        }
    }

    private var offsetWidthTemplate: String {
        "\(L10n.t("歌词")) +2.2s"
    }

    private func nudgeHelp(_ verb: String) -> String {
        "\(verb) \(AppSettings.formattedSeconds(ms: lyricsOffsetStepMs))\(L10n.t("秒"))"
    }

    private func lyricsOffsetButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        HoverReveal { hovering in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .semibold))
                    .frame(width: 10, height: 11)
            }
            .buttonStyle(NotchIconButtonStyle(tint: tint, cornerRadius: 3, hovering: hovering))

            .padding(5)
            .contentShape(Rectangle())
        }
        .padding(-5)
        .modifier(OptionalHelp(text: help))
    }

    private var scrubberHeight: CGFloat {
        if scrubbingFraction != nil { return 6 }
        return hoveringScrubber ? 5 : 3
    }

    private static func timeString(ms: Int) -> String { NotchTimeFormat.mmss(ms: ms) }
}

enum NotchTimeFormat {

    static let clockEpoch = Date(timeIntervalSince1970: 0)

    static func clockSchedule(for anchor: ProgressAnchor) -> PeriodicTimelineSchedule {
        guard anchor.rate > 0 else { return .periodic(from: clockEpoch, by: 1) }
        let ref = anchor.fetchedAt
        let posAtRef = Double(anchor.extrapolatedPositionMs(now: ref))
        let msToBoundary = 1000 - posAtRef.truncatingRemainder(dividingBy: 1000)
        return .periodic(from: ref.addingTimeInterval(msToBoundary / 1000 / anchor.rate),
                         by: 1 / anchor.rate)
    }

    static func mmss(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct NotchCardLayerActive: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.notchCardLayerActive, active)
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}

struct NotchCardClip: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.clipShape(NotchHangingShape(bottomCornerRadius: 20))
        } else {
            content
        }
    }
}

struct NotchHangingShape: Shape {
    var bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(bottomCornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct NotchIdleEarIconHost<Fallback: View>: View {
    @ObservedObject private var prompt: NotchUnknownPlayerPrompt
    let side: CGFloat
    let scale: CGFloat
    let alignment: Alignment
    @ViewBuilder let fallback: () -> Fallback

    init(prompt: NotchUnknownPlayerPrompt, side: CGFloat, scale: CGFloat, alignment: Alignment,
         @ViewBuilder fallback: @escaping () -> Fallback) {
        self.prompt = prompt
        self.side = side
        self.scale = scale
        self.alignment = alignment
        self.fallback = fallback
    }

    private static var badgeSide: CGFloat { 7 }

    var body: some View {
        if let offer = prompt.offer,
           let icon = AppIconResolver.icon(forBundleID: offer.bundleID),
           let bitmap = NotchIdleAppIcon.bitmap(of: icon, cacheKey: offer.bundleID,
                                                pixelSide: Int((side * scale).rounded())) {
            Image(decorative: bitmap, scale: scale)
                .frame(width: side, height: side)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.red)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                        .frame(width: Self.badgeSide, height: Self.badgeSide)

                        .offset(x: 2, y: -2)
                }
                .frame(maxWidth: .infinity, alignment: alignment)
                .accessibilityLabel(L10n.t("检测到新的播放器") + " " + offer.displayName)
                .transition(.opacity)
        } else {
            fallback()
        }
    }
}

private struct NotchIdlePanelHost<Fallback: View>: View {
    @ObservedObject private var prompt: NotchUnknownPlayerPrompt
    let tint: Color
    @ViewBuilder let fallback: () -> Fallback

    @State private var hoveredAction: QuickActionHint?
    @State private var shownTooltip: QuickActionHint?

    init(prompt: NotchUnknownPlayerPrompt, tint: Color, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.prompt = prompt
        self.tint = tint
        self.fallback = fallback
    }

    var body: some View {
        if let offer = prompt.offer {
            unknownPlayerPanel(offer)
                .transition(.opacity)
        } else {
            fallback()
        }
    }

    private static var dismissKey: String { "xmark" }

    private func unknownPlayerPanel(_ offer: NotchUnknownPlayerPrompt.Offer) -> some View {
        let dismissLabel = L10n.t("关闭")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: NotchMetrics.trackInfoLineSpacing) {
                Text(L10n.t("检测到新的播放器"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.9))
                Text(offer.displayName + " · " + String(format: L10n.t("正在放：%@"), offer.nowPlayingText))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                NotchPillButton(systemName: "checkmark.shield.fill", title: L10n.t("加入信任列表"), tint: tint) {
                    prompt.trust()
                }
                NotchIconButton(systemName: Self.dismissKey, glyphSize: 11, hitSize: NotchMetrics.trackInfoActionsHeight,
                                tint: tint, glyphOpacity: 0.75) {
                    prompt.dismiss()
                }

                .onHover { inside in
                    if inside {
                        hoveredAction = QuickActionHint(key: Self.dismissKey, text: dismissLabel)
                    } else if hoveredAction?.key == Self.dismissKey {
                        hoveredAction = nil
                    }
                }
                .anchorPreference(key: QuickActionAnchorKey.self, value: .bounds) { [Self.dismissKey: $0] }
                .accessibilityLabel(dismissLabel)
            }
            .frame(height: NotchMetrics.trackInfoActionsHeight)
        }

        .modifier(QuickActionTooltipOverlay(hovered: hoveredAction, shown: $shownTooltip, tint: tint, edge: .top))
        .padding(.horizontal, 16)
        .padding(.top, NotchMetrics.trackInfoTopSpacing)
    }
}
