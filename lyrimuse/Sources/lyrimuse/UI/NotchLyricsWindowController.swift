import AppKit
import SwiftUI
import Combine
import LyrimuseCore

@MainActor

final class NotchLyricsWindowController: NSWindowController, ObservableObject, NotchChromeSource {
    static let shared = NotchLyricsWindowController(pinnedScreenID: nil)

    @Published private(set) var isVisible: Bool = AppSettings.shared.notchOverlayEnabled
    @Published private(set) var hideWhenNotPlaying: Bool = false

    @Published private(set) var contentTopInset: CGFloat = 32

    @Published private(set) var notchWidth: CGFloat = 0

    @Published private(set) var isExpanded: Bool = false

    private var hoverExpanded = false
    private var alertHold = false

    @Published private(set) var isPlayingNow: Bool = false

    var isCollapsed: Bool {
        collapsesWhenPaused && ((!isPlayingNow && !hideWhenNotPlaying) || isAdBreakNow) && !isExpanded
    }

    @Published private(set) var isVanished = false

    @Published private(set) var revealGeneration = 0

    @Published private(set) var isAdBreakNow: Bool = false

    @Published private(set) var collapsesWhenPaused: Bool = AppSettings.shared.notchCollapsesWhenPaused

    @Published private(set) var showsEqualizer: Bool = AppSettings.shared.notchShowsEqualizer

    @Published private(set) var equalizerEar: NotchEqualizerEar = AppSettings.shared.notchEqualizerEar

    @Published private(set) var expandedShowsLyricPreview: Bool = false

    @Published private(set) var showsLyrics: Bool = AppSettings.shared.notchShowLyrics

    @Published private(set) var expandedShowsScrubber: Bool = false

    @Published private(set) var expandedShowsNextLine: Bool = LyricSecondaryLine.expandedNextLinePreviewVisible(
        userToggle: AppSettings.shared.notchExpandedShowsNextLine, secondary: AppSettings.shared.notchSecondaryLine)

    @Published private(set) var expandedShowsControls: Bool = AppSettings.shared.notchExpandedShowsControls

    @Published private(set) var expandedTrackInfoShowsArtwork: Bool = AppSettings.shared.notchExpandedShowsArtwork
    @Published private(set) var expandedTrackInfoShowsTitle: Bool = AppSettings.shared.notchExpandedShowsTrackTitle
    @Published private(set) var expandedTrackInfoShowsArtist: Bool = AppSettings.shared.notchExpandedShowsArtist
    @Published private(set) var expandedTrackInfoShowsAlbum: Bool = AppSettings.shared.notchExpandedShowsAlbum

    @Published private(set) var expandedShowsQuickActions: Bool = AppSettings.shared.notchExpandedShowsQuickActions

    @Published private(set) var hasTrack: Bool = false

    @Published private(set) var steadyCardWidth: CGFloat = 360

    @Published private(set) var expandedCardWidth: CGFloat = 360

    @Published private(set) var collapsedCardWidth: CGFloat = collapsedFallbackWidth

    private static let fallbackNotchHeight: CGFloat = 24

    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        max(fallbackNotchHeight, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    private static let collapsedFallbackWidth: CGFloat = 120

    private static var contentHeight: CGFloat { NotchMetrics.compactRowHeight }

    static func minEarWidth(leftEar: NotchEarModule, rightEar: NotchEarModule,
                            showsEqualizer: Bool, equalizerEar: NotchEqualizerEar,
                            contentTopInset: CGFloat) -> CGFloat {

        func equalizerAllowance(forEar ear: NotchEqualizerEar, module: NotchEarModule) -> CGFloat {
            guard showsEqualizer, equalizerEar == ear, module != .controls else { return 0 }
            return EqualizerBars.width + NotchMetrics.earWaveSpacing
        }
        let left = leftEar.minEarContentWidth(contentTopInset: contentTopInset)
            + equalizerAllowance(forEar: .left, module: leftEar)
            + NotchMetrics.earNotchInset
        let right = rightEar.minEarContentWidth(contentTopInset: contentTopInset)
            + equalizerAllowance(forEar: .right, module: rightEar)
            + NotchMetrics.earNotchInset
        return max(left, right)
    }

    private func expandedExtraHeight(
        expandedShowsNextLine: Bool? = nil,
        expandedShowsControls: Bool? = nil,
        expandedTrackInfoShowsArtwork: Bool? = nil,
        expandedTrackInfoShowsTitle: Bool? = nil,
        expandedTrackInfoShowsArtist: Bool? = nil,
        expandedTrackInfoShowsAlbum: Bool? = nil,
        expandedShowsQuickActions: Bool? = nil
    ) -> CGFloat {
        let showsArtwork = expandedTrackInfoShowsArtwork ?? AppSettings.shared.notchExpandedShowsArtwork
        let showsTitle = expandedTrackInfoShowsTitle ?? AppSettings.shared.notchExpandedShowsTrackTitle
        let showsArtist = expandedTrackInfoShowsArtist ?? AppSettings.shared.notchExpandedShowsArtist
        let showsAlbum = expandedTrackInfoShowsAlbum ?? AppSettings.shared.notchExpandedShowsAlbum
        let showsActions = expandedShowsQuickActions ?? AppSettings.shared.notchExpandedShowsQuickActions
        let trackInfoHeight = NotchMetrics.expandedTrackInfoHeight(
            showsArtwork: showsArtwork, showsTitle: showsTitle, showsArtist: showsArtist, showsAlbum: showsAlbum,
            showsActions: showsActions)
        return NotchMetrics.expandedExtraHeightMax(
            hasLyricPreviewPossible: expandedShowsNextLine ?? LyricSecondaryLine.expandedNextLinePreviewVisible(
                userToggle: AppSettings.shared.notchExpandedShowsNextLine, secondary: AppSettings.shared.notchSecondaryLine),
            hasControlsPossible: expandedShowsControls ?? AppSettings.shared.notchExpandedShowsControls,
            trackInfoHeight: trackInfoHeight)
    }

    private var isPlayingObserver: AnyCancellable?
    private var adBreakObserver: AnyCancellable?
    private var lyricPresenceObserver: AnyCancellable?
    private var durationObserver: AnyCancellable?
    private var showLyricsObserver: AnyCancellable?
    private var collapsesWhenPausedObserver: AnyCancellable?
    private var showsEqualizerObserver: AnyCancellable?
    private var equalizerEarObserver: AnyCancellable?
    private var expandedShowsNextLineObserver: AnyCancellable?
    private var expandedShowsControlsObserver: AnyCancellable?
    private var expandedTrackInfoShowsArtworkObserver: AnyCancellable?
    private var expandedTrackInfoShowsTitleObserver: AnyCancellable?
    private var expandedTrackInfoShowsArtistObserver: AnyCancellable?
    private var expandedTrackInfoShowsAlbumObserver: AnyCancellable?
    private var expandedShowsQuickActionsObserver: AnyCancellable?
    private var leftEarObserver: AnyCancellable?
    private var rightEarObserver: AnyCancellable?
    private var trackPresenceObserver: AnyCancellable?
    private var unknownPlayerAlertObserver: AnyCancellable?
    private var screenParamsObserver: NSObjectProtocol?

    private var hostingView: NSHostingView<NotchWindowRoot>?

    private var pinnedScreenID: String?

    convenience init(pinnedScreenID: String?) {

        let placeholder = NSSize(width: AppSettings.shared.notchContentWidth, height: Self.fallbackNotchHeight + Self.contentHeight)
        let panel = NotchLyricsWindow(contentRect: NSRect(origin: .zero, size: placeholder))
        self.init(window: panel)
        self.pinnedScreenID = pinnedScreenID

        let hosting = NSHostingView(rootView: NotchWindowRoot(controller: self))
        hosting.frame = NSRect(origin: .zero, size: placeholder)
        hosting.autoresizingMask = [.width, .height]

        hosting.sizingOptions = []
        panel.contentView = hosting
        hostingView = hosting

        recomputeGeometry(animate: false)

        if pinnedScreenID == nil {
            screenParamsObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.recomputeGeometry(animate: false) }
            }
        }

        isPlayingObserver = PlaybackCoordinator.shared.$isPlayingSmoothed.sink { [weak self] isPlaying in

            self?.isPlayingNow = isPlaying
            self?.updateActualVisibility(isPlayingNow: isPlaying)
        }

        adBreakObserver = PlaybackCoordinator.shared.$isCurrentTrackAdBreak.sink { [weak self] isAd in
            self?.isAdBreakNow = isAd
        }

        trackPresenceObserver = Publishers.CombineLatest3(
            PlaybackCoordinator.shared.$title,
            PlaybackCoordinator.shared.$artist,
            PlaybackCoordinator.shared.$isCurrentTrackAdBreak
        ).sink { [weak self] title, artist, isAd in
            self?.hasTrack = !title.isEmpty || !artist.isEmpty || isAd
        }

        unknownPlayerAlertObserver = NotchUnknownPlayerPrompt.shared.$isAlerting.removeDuplicates().sink { [weak self] alerting in
            self?.setAlertHold(alerting)
        }

        lyricPresenceObserver = PlaybackCoordinator.shared.$hasLyricsContent.sink { [weak self] has in
            self?.expandedShowsLyricPreview = has
        }
        durationObserver = PlaybackCoordinator.shared.$currentDurationMs.sink { [weak self] ms in
            self?.expandedShowsScrubber = (ms ?? 0) > 0
        }

        showLyricsObserver = AppSettings.shared.$notchShowLyrics.removeDuplicates().sink { [weak self] show in
            self?.showsLyrics = show
        }

        collapsesWhenPausedObserver = AppSettings.shared.$notchCollapsesWhenPaused.removeDuplicates().sink { [weak self] collapses in
            self?.collapsesWhenPaused = collapses
        }

        leftEarObserver = AppSettings.shared.$notchLeftEar.removeDuplicates().sink { [weak self] module in
            self?.recomputeGeometry(animate: false, leftEar: module)
        }
        rightEarObserver = AppSettings.shared.$notchRightEar.removeDuplicates().sink { [weak self] module in
            self?.recomputeGeometry(animate: false, rightEar: module)
        }

        showsEqualizerObserver = AppSettings.shared.$notchShowsEqualizer.removeDuplicates().sink { [weak self] shows in
            self?.showsEqualizer = shows
            self?.recomputeGeometry(animate: false, showsEqualizer: shows)
        }
        equalizerEarObserver = AppSettings.shared.$notchEqualizerEar.removeDuplicates().sink { [weak self] ear in
            self?.equalizerEar = ear
            self?.recomputeGeometry(animate: false, equalizerEar: ear)
        }

        expandedShowsNextLineObserver = Publishers.CombineLatest(
            AppSettings.shared.$notchExpandedShowsNextLine, AppSettings.shared.$notchSecondaryLine
        )
        .map { LyricSecondaryLine.expandedNextLinePreviewVisible(userToggle: $0, secondary: $1) }
        .removeDuplicates()
        .sink { [weak self] shows in
            self?.expandedShowsNextLine = shows
            self?.recomputeGeometry(animate: false, expandedShowsNextLine: shows)
        }
        expandedShowsControlsObserver = AppSettings.shared.$notchExpandedShowsControls.removeDuplicates().sink { [weak self] shows in
            self?.expandedShowsControls = shows
            self?.recomputeGeometry(animate: false, expandedShowsControls: shows)
        }
        expandedTrackInfoShowsArtworkObserver = AppSettings.shared.$notchExpandedShowsArtwork.removeDuplicates().sink { [weak self] shows in
            self?.expandedTrackInfoShowsArtwork = shows
            self?.recomputeGeometry(animate: false, expandedTrackInfoShowsArtwork: shows)
        }
        expandedTrackInfoShowsTitleObserver = AppSettings.shared.$notchExpandedShowsTrackTitle.removeDuplicates().sink { [weak self] shows in
            self?.expandedTrackInfoShowsTitle = shows
            self?.recomputeGeometry(animate: false, expandedTrackInfoShowsTitle: shows)
        }
        expandedTrackInfoShowsArtistObserver = AppSettings.shared.$notchExpandedShowsArtist.removeDuplicates().sink { [weak self] shows in
            self?.expandedTrackInfoShowsArtist = shows
            self?.recomputeGeometry(animate: false, expandedTrackInfoShowsArtist: shows)
        }
        expandedTrackInfoShowsAlbumObserver = AppSettings.shared.$notchExpandedShowsAlbum.removeDuplicates().sink { [weak self] shows in
            self?.expandedTrackInfoShowsAlbum = shows
            self?.recomputeGeometry(animate: false, expandedTrackInfoShowsAlbum: shows)
        }
        expandedShowsQuickActionsObserver = AppSettings.shared.$notchExpandedShowsQuickActions.removeDuplicates().sink { [weak self] shows in
            self?.expandedShowsQuickActions = shows
            self?.recomputeGeometry(animate: false, expandedShowsQuickActions: shows)
        }

    }

    deinit {
        if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
    }

    func closeFromQuickAction() {
        setVisible(false)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        AppSettings.shared.notchOverlayEnabled = visible
        if visible {
            setHiddenFromCapture(AppSettings.shared.notchHideDuringScreenCapture)
            setHideWhenNotPlaying(AppSettings.shared.notchHideWhenNotPlaying)

            recomputeGeometry(animate: false)
        }
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    func setHideWhenNotPlaying(_ hide: Bool) {
        hideWhenNotPlaying = hide
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    func setHiddenFromCapture(_ hidden: Bool) {
        window?.sharingType = hidden ? .none : .readWrite
    }

    private static let hoverEnterDelay: TimeInterval = 0.12
    private static let hoverExitDelay: TimeInterval = 0.1
    private var pendingHoverWork: DispatchWorkItem?

    func setExpanded(_ expanded: Bool) {}

    func setExpandedFromWindow(_ expanded: Bool) {

        pendingHoverWork?.cancel()
        pendingHoverWork = nil

        guard expanded != hoverExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, expanded != self.hoverExpanded else { return }
            self.pendingHoverWork = nil
            let wasExpanded = self.isExpanded
            self.hoverExpanded = expanded
            self.refreshExpanded()

            if expanded && !wasExpanded {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
        pendingHoverWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (expanded ? Self.hoverEnterDelay : Self.hoverExitDelay),
            execute: work)
    }

    private func refreshExpanded() {
        let next = hoverExpanded || alertHold
        if next != isExpanded { isExpanded = next }
    }

    private func setAlertHold(_ hold: Bool) {
        guard hold != alertHold else { return }

        if hold, hasTrack { return }
        alertHold = hold
        refreshExpanded()
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    func applyContentWidthSetting() {

        recomputeGeometry(animate: false)
    }

    private var lastAppliedShouldShow: Bool?

    private var pendingHideWork: DispatchWorkItem?
    private var hideGeneration = 0

    private func updateActualVisibility(isPlayingNow: Bool) {

        let shouldShow = isVisible && (!hideWhenNotPlaying || isPlayingNow || alertHold)
        if shouldShow {

            cancelPendingHide()

            if lastAppliedShouldShow != true || isVanished { revealGeneration &+= 1 }
            if lastAppliedShouldShow != true {
                lastAppliedShouldShow = true

                window?.orderFrontRegardless()
            }

            if isVanished { isVanished = false }
            return
        }
        guard lastAppliedShouldShow != false else { cancelPendingHide(); return }

        let animatesVanish = isVisible && lastAppliedShouldShow == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animatesVanish else {
            cancelPendingHide()
            lastAppliedShouldShow = false
            if isVanished { isVanished = false }
            window?.orderOut(nil)
            return
        }

        guard pendingHideWork == nil else { return }
        isVanished = true
        hideGeneration &+= 1
        let generation = hideGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingHideWork = nil

                guard generation == self.hideGeneration else { return }
                let stillShow = self.isVisible
                    && (!self.hideWhenNotPlaying || PlaybackCoordinator.shared.isPlayingSmoothed || self.alertHold)
                if stillShow {

                    if self.isVanished { self.isVanished = false }
                    return
                }
                self.lastAppliedShouldShow = false
                self.window?.orderOut(nil)
            }
        }
        pendingHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchWindowRoot.vanishSettleDelay, execute: work)
    }

    private func cancelPendingHide() {
        hideGeneration &+= 1
        pendingHideWork?.cancel()
        pendingHideWork = nil
    }

    struct NotchGeometry {

        let notchHeight: CGFloat
        let centerX: CGFloat

        let notchWidth: CGFloat
    }

    static func geometry(for screen: NSScreen) -> NotchGeometry {
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX {
            let centerX = (leftArea.maxX + rightArea.minX) / 2
            let notchWidth = rightArea.minX - leftArea.maxX

            return NotchGeometry(notchHeight: max(notchHeight, menuBarHeight(of: screen)),
                                 centerX: centerX, notchWidth: notchWidth)
        }

        return NotchGeometry(
            notchHeight: menuBarHeight(of: screen), centerX: screen.frame.midX, notchWidth: 0)
    }

    static func contentWidth(baseWidth: CGFloat, notchWidth: CGFloat,
                             leftEar: NotchEarModule, rightEar: NotchEarModule,
                             showsEqualizer: Bool, equalizerEar: NotchEqualizerEar,
                             contentTopInset: CGFloat) -> CGFloat {
        let earBasedFloor = notchWidth
            + minEarWidth(leftEar: leftEar, rightEar: rightEar,
                          showsEqualizer: showsEqualizer, equalizerEar: equalizerEar,
                          contentTopInset: contentTopInset) * 2
            + NotchMetrics.cardHorizontalPadding * 2
        return max(baseWidth, earBasedFloor)
    }

    static func contentWidth(baseWidth: CGFloat, notchWidth: CGFloat,
                             contentTopInset: CGFloat) -> CGFloat {
        contentWidth(baseWidth: baseWidth, notchWidth: notchWidth,
                     leftEar: AppSettings.shared.notchLeftEar,
                     rightEar: AppSettings.shared.notchRightEar,
                     showsEqualizer: AppSettings.shared.notchShowsEqualizer,
                     equalizerEar: AppSettings.shared.notchEqualizerEar,
                     contentTopInset: contentTopInset)
    }

    static func targetScreen() -> NSScreen? {
        if let pinned = ScreenIdentity.screen(withID: AppSettings.shared.notchScreenID) {
            return pinned
        }
        return ScreenIdentity.notched ?? NSScreen.main
    }

    func applyScreenSetting() {
        recomputeGeometry(animate: false)
    }

    private func resolvedScreen() -> NSScreen? {
        if let pinnedScreenID {
            return ScreenIdentity.screen(withID: pinnedScreenID)
        }
        return Self.targetScreen()
    }

    func syncStateFromSettings(
        notchEnabled: Bool? = nil,
        hideWhenNotPlaying hide: Bool? = nil,
        hideDuringCapture: Bool? = nil,
        contentWidth: CGFloat? = nil,
        expandedContentWidth: CGFloat? = nil
    ) {
        let settings = AppSettings.shared
        let visible = notchEnabled ?? settings.notchOverlayEnabled
        if isVisible != visible { isVisible = visible }
        let hideValue = hide ?? settings.notchHideWhenNotPlaying
        if hideWhenNotPlaying != hideValue { hideWhenNotPlaying = hideValue }
        let captureHidden = hideDuringCapture ?? settings.notchHideDuringScreenCapture
        let sharing: NSWindow.SharingType = captureHidden ? .none : .readWrite
        if window?.sharingType != sharing { window?.sharingType = sharing }
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
        recomputeGeometry(animate: false, contentWidth: contentWidth,
                          expandedContentWidth: expandedContentWidth)
    }

    func teardown() {
        cancelPendingHide()
        window?.orderOut(nil)
        isPlayingObserver?.cancel()
        isPlayingObserver = nil
        adBreakObserver?.cancel()
        adBreakObserver = nil
        lyricPresenceObserver?.cancel()
        lyricPresenceObserver = nil
        durationObserver?.cancel()
        durationObserver = nil
        showLyricsObserver?.cancel()
        showLyricsObserver = nil
        leftEarObserver?.cancel()
        leftEarObserver = nil
        rightEarObserver?.cancel()
        rightEarObserver = nil
        showsEqualizerObserver?.cancel()
        showsEqualizerObserver = nil
        equalizerEarObserver?.cancel()
        equalizerEarObserver = nil

        collapsesWhenPausedObserver?.cancel()
        collapsesWhenPausedObserver = nil
        expandedShowsNextLineObserver?.cancel()
        expandedShowsNextLineObserver = nil
        expandedShowsControlsObserver?.cancel()
        expandedShowsControlsObserver = nil
        expandedTrackInfoShowsArtworkObserver?.cancel()
        expandedTrackInfoShowsArtworkObserver = nil
        expandedTrackInfoShowsTitleObserver?.cancel()
        expandedTrackInfoShowsTitleObserver = nil
        expandedTrackInfoShowsArtistObserver?.cancel()
        expandedTrackInfoShowsArtistObserver = nil
        expandedTrackInfoShowsAlbumObserver?.cancel()
        expandedTrackInfoShowsAlbumObserver = nil
        expandedShowsQuickActionsObserver?.cancel()
        expandedShowsQuickActionsObserver = nil
        trackPresenceObserver?.cancel()
        trackPresenceObserver = nil
        unknownPlayerAlertObserver?.cancel()
        unknownPlayerAlertObserver = nil
        if let screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
            self.screenParamsObserver = nil
        }
        pendingHoverWork?.cancel()
        pendingHoverWork = nil
        window?.contentView = nil
        hostingView = nil
    }

    private func recomputeGeometry(animate: Bool, contentWidth: CGFloat? = nil,
                                   expandedContentWidth: CGFloat? = nil,
                                   leftEar: NotchEarModule? = nil,
                                   rightEar: NotchEarModule? = nil,
                                   showsEqualizer: Bool? = nil,
                                   equalizerEar: NotchEqualizerEar? = nil,
                                   expandedShowsNextLine: Bool? = nil,
                                   expandedShowsControls: Bool? = nil,
                                   expandedTrackInfoShowsArtwork: Bool? = nil,
                                   expandedTrackInfoShowsTitle: Bool? = nil,
                                   expandedTrackInfoShowsArtist: Bool? = nil,
                                   expandedTrackInfoShowsAlbum: Bool? = nil,
                                   expandedShowsQuickActions: Bool? = nil) {
        guard let window, let screen = resolvedScreen() else { return }
        let geo = Self.geometry(for: screen)

        if contentTopInset != geo.notchHeight { contentTopInset = geo.notchHeight }
        if notchWidth != geo.notchWidth { notchWidth = geo.notchWidth }

        let newSteady = Self.contentWidth(
            baseWidth: contentWidth ?? AppSettings.shared.notchContentWidth,
            notchWidth: geo.notchWidth,
            leftEar: leftEar ?? AppSettings.shared.notchLeftEar,
            rightEar: rightEar ?? AppSettings.shared.notchRightEar,
            showsEqualizer: showsEqualizer ?? AppSettings.shared.notchShowsEqualizer,
            equalizerEar: equalizerEar ?? AppSettings.shared.notchEqualizerEar,
            contentTopInset: geo.notchHeight)
        if steadyCardWidth != newSteady { steadyCardWidth = newSteady }

        let newExpanded = NotchWidthBounds.expandedWidth(
            steady: newSteady,
            expandedSetting: expandedContentWidth ?? CGFloat(AppSettings.shared.notchExpandedContentWidth))
        if expandedCardWidth != newExpanded { expandedCardWidth = newExpanded }
        let newCollapsed = geo.notchWidth > 0 ? geo.notchWidth : Self.collapsedFallbackWidth
        if collapsedCardWidth != newCollapsed { collapsedCardWidth = newCollapsed }

        let size = NSSize(
            width: expandedCardWidth,
            height: geo.notchHeight + Self.contentHeight + self.expandedExtraHeight(
                expandedShowsNextLine: expandedShowsNextLine,
                expandedShowsControls: expandedShowsControls,
                expandedTrackInfoShowsArtwork: expandedTrackInfoShowsArtwork,
                expandedTrackInfoShowsTitle: expandedTrackInfoShowsTitle,
                expandedTrackInfoShowsArtist: expandedTrackInfoShowsArtist,
                expandedTrackInfoShowsAlbum: expandedTrackInfoShowsAlbum,
                expandedShowsQuickActions: expandedShowsQuickActions))
        let frame = NSRect(
            x: geo.centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        if window.frame != frame { window.setFrame(frame, display: true, animate: animate) }
        let hostFrame = NSRect(origin: .zero, size: size)
        if hostingView?.frame != hostFrame { hostingView?.frame = hostFrame }
    }
}
