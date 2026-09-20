import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

private let overlayPositionKey = "np:overlayPositionTop"

private let overlayPositionLegacyOriginKey = "np:overlayPositionOrigin"

private let hasShownDragHintKey = "np:hasShownOverlayDragHint"

private let overlayDefaultHeight: CGFloat = 120

@MainActor
final class LyricsOverlayWindowController: NSWindowController, ObservableObject, OverlayChromeSource {
    static let shared = LyricsOverlayWindowController()

    @Published private(set) var isVisible: Bool = AppSettings.shared.classicOverlayEnabled

    @Published private(set) var isPositionLocked: Bool = AppSettings.shared.lockPosition

    @Published private(set) var hideWhenNotPlaying: Bool = false

    private var moveObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    private var isBorrowingScreen = false

    private enum PositionSaveSource { case windowMoved, programmaticResize }
    private var moveDebounceTimer: Timer?
    private var isPlayingObserver: AnyCancellable?
    private var shadowObserver: AnyCancellable?
    private var placementModeObserver: AnyCancellable?

    private var placementMode: OverlayPlacementMode = AppSettings.shared.overlayPlacementMode

    private var lastContentHeight: CGFloat = 0

    @Published private(set) var isHoveringForControls: Bool = false

    @Published private(set) var isHoveringLyrics: Bool = false

    @Published private(set) var isHoveringControlPill: Bool = false

    @Published private(set) var hoveredControl: OverlayControlID?

    @Published private(set) var isDragArmed: Bool = false

    @Published private(set) var showDragHint: Bool = false

    @Published private(set) var transientHint: String?

    @Published private(set) var placementLockNotice: String?
    @Published private(set) var placementLockShakeTick = 0
    private var placementLockNoticeTimer: Timer?

    func controlsDidBecomeVisible() {
        PlaybackCoordinator.shared.refreshFavorited()
    }

    private func clearControlsHoverState() {
        if isHoveringForControls { isHoveringForControls = false }
        if isHoveringControlPill { isHoveringControlPill = false }
        if hoveredControl != nil { hoveredControl = nil }
    }

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var longPressTimer: Timer?
    private var dragHintDismissTimer: Timer?
    private var transientHintDismissTimer: Timer?

    private var pressStartLocation: NSPoint?

    private var controlsHotZoneLocal: CGRect?

    private var lyricsHotZoneLocal: CGRect?

    private var chromeHoverZoneLocal: CGRect?

    private var controlRectsRaw: [OverlayControlID: CGRect] = [:]
    private var controlsHotZoneRaw: CGRect?
    private var lyricsHotZoneRaw: CGRect?

    private let longPressThresholdSecs: TimeInterval = 0.35

    private let dragMoveTolerance: CGFloat = 4

    private let presetDragIntentDistance: CGFloat = 12

    private var presetDragRejectedThisPress = false

    convenience init() {
        let size = NSSize(width: AppSettings.shared.overlayWidth, height: overlayDefaultHeight)
        let placement = Self.restoredPlacement(size: size)

        let origin = Self.presetOrigin(
            mode: AppSettings.shared.overlayPlacementMode, restored: placement.origin, size: size
        ) ?? placement.origin
        let panel = LyricsOverlayWindow(contentRect: NSRect(origin: origin, size: size))
        self.init(window: panel)

        isBorrowingScreen = placement.wasRescued

        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: LyricsOverlayView(
            overlayController: self,
            onContentHeightChange: { [weak self] height in
                self?.updateHeight(height)
            },
            onControlsFrameChange: { [weak self] rect in
                self?.updateControlsHotZone(rect)
            },
            onControlRectsChange: { [weak self] rects in
                self?.updateControlRects(rects)
            },
            onLyricsTextRectChange: { [weak self] rect in
                self?.updateLyricsHotZone(rect)
            }
        ))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        hosting.sizingOptions = []
        panel.contentView = hosting

        shadowObserver = AppSettings.shared.$backgroundIsVisible.sink { [weak self] visible in
            self?.window?.hasShadow = visible
        }

        placementModeObserver = AppSettings.shared.$overlayPlacementMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] mode in
                self?.applyPlacementMode(mode)
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcilePlacementWithScreens()
            }
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in

            MainActor.assumeIsolated {
                guard let self, !self.isDragArmed, self.animatingTargetFrame == nil else { return }
                self.scheduleSavePosition(.windowMoved)
            }
        }

        isPlayingObserver = PlaybackCoordinator.shared.$isPlayingSmoothed.sink { [weak self] isPlaying in
            self?.updateActualVisibility(isPlayingNow: isPlaying)
        }
    }

    deinit {
        moveDebounceTimer?.invalidate()
        placementLockNoticeTimer?.invalidate()
        longPressTimer?.invalidate()
        dragHintDismissTimer?.invalidate()
        transientHintDismissTimer?.invalidate()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        AppSettings.shared.classicOverlayEnabled = visible
        if visible {
            setHiddenFromCapture(AppSettings.shared.hideDuringScreenCapture)
            setHideWhenNotPlaying(AppSettings.shared.hideWhenNotPlaying)

            setLocked(AppSettings.shared.lockPosition)

            let wanted = CGFloat(AppSettings.shared.overlayWidth)
            if let window, baseFrame(of: window).width != wanted { setWidth(wanted) }
        }
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    func setHideWhenNotPlaying(_ hide: Bool) {
        hideWhenNotPlaying = hide
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    private func updateActualVisibility(isPlayingNow: Bool) {
        let shouldShow = isVisible && (!hideWhenNotPlaying || isPlayingNow)
        if shouldShow { window?.orderFront(nil) } else { window?.orderOut(nil) }
        syncMouseMonitors()
    }

    func setLocked(_ locked: Bool) {
        isPositionLocked = locked
        window?.isMovableByWindowBackground = false
        window?.ignoresMouseEvents = true
        if locked {

            cancelPendingPress()
            clearControlsHoverState()
        } else {
            maybeShowDragHintOnFirstUnlock()
        }

        syncMouseMonitors()
    }

    private func maybeShowDragHintOnFirstUnlock() {

        guard !placementMode.isPreset else { return }
        guard !UserDefaults.standard.bool(forKey: hasShownDragHintKey) else { return }
        UserDefaults.standard.set(true, forKey: hasShownDragHintKey)
        dragHintDismissTimer?.invalidate()
        showDragHint = true
        dragHintDismissTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showDragHint = false }
        }
    }

    func flashTransientHint(_ text: String) {
        transientHintDismissTimer?.invalidate()
        transientHint = text
        transientHintDismissTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.transientHint = nil }
        }
    }

    func setHiddenFromCapture(_ hidden: Bool) {
        window?.sharingType = hidden ? .none : .readWrite
    }

    private func updateHeight(_ contentHeight: CGFloat) {
        guard let window else { return }
        let contentChanged = abs(contentHeight - lastContentHeight) >= 0.5
        lastContentHeight = contentHeight
        let current = baseFrame(of: window)

        let newFrame = OverlayPlacement.grownFrame(
            current: current, contentHeight: contentHeight, minHeight: overlayDefaultHeight,
            anchorsBottom: placementMode.anchorsBottom, visibleFrame: Self.hostVisibleFrame(of: current))
        guard abs(newFrame.height - current.height) >= 0.5 else {

            if contentChanged, placementMode.anchorsBottom { recomputeHitRegions() }
            return
        }
        setFrameAnimated(window, to: newFrame)

        recomputeHitRegions()
    }

    private var animatingTargetFrame: NSRect?

    private func baseFrame(of window: NSWindow) -> NSRect {
        animatingTargetFrame ?? window.frame
    }

    private func setFrameAnimated(_ window: NSWindow, to frame: NSRect) {
        animatingTargetFrame = frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = window.animationResizeTime(frame)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {

                guard let self, self.animatingTargetFrame == frame else { return }
                self.animatingTargetFrame = nil

                self.scheduleSavePosition(.programmaticResize)
            }
        })
    }

    func setWidth(_ width: CGFloat) {
        guard let window else { return }
        let current = baseFrame(of: window)
        let centerX = current.origin.x + current.width / 2

        let wanted = NSRect(x: centerX - width / 2, y: current.origin.y, width: width, height: current.height)
        let newX = Self.hostVisibleFrame(of: wanted)
            .map { OverlayPlacement.clamped(frame: wanted, into: $0).x } ?? wanted.origin.x
        let newFrame = NSRect(x: newX, y: current.origin.y, width: width, height: current.height)
        setFrameAnimated(window, to: newFrame)
    }

    func setFadeOnHover(_ enabled: Bool) {
        syncMouseMonitors()

        if !enabled { clearControlsHoverState() }
        if !enabled, isHoveringLyrics { isHoveringLyrics = false }
    }

    private func syncMouseMonitors() {

        let needed = window?.isVisible ?? false
        if needed {
            installMouseMonitors()
        } else {
            removeMouseMonitors()
        }
    }

    private func removeMouseMonitors() {
        guard globalMouseMonitor != nil || localMouseMonitor != nil else { return }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil

        cancelPendingPress()
        clearControlsHoverState()
    }

    private func installMouseMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouseEvent(type: type) }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouseEvent(type: type) }
            return event
        }
    }

    private var controlRectsLocal: [OverlayControlID: CGRect] = [:]

    private let overlayQuickSettingsMenu = OverlayQuickSettingsMenu()

    private func performControlAction(_ id: OverlayControlID) {
        switch id {
        case .previous: withMusicPermission { MusicPlaybackController.previousTrack() }

        case .playPause: withMusicPermission { PlaybackCoordinator.shared.userTogglePlayPause() }
        case .next: withMusicPermission { MusicPlaybackController.nextTrack() }

        case .favorite: PlaybackCoordinator.shared.toggleFavorited()

        case .lock:
            AppSettings.shared.lockPosition = true
            setLocked(true)

        case .unlockPill:
            AppSettings.shared.lockPosition = false
            setLocked(false)

        case .expandToLyricsWindow:
            AppActions.shared.openLyricsWindow?()

        case .settingsMenu:
            overlayQuickSettingsMenu.popUp()

        case .closeOverlay:
            setVisible(false)
        }
    }

    private func withMusicPermission(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                NSSound.beep()
                return
            }
            action()
        }
    }

    private func updateControlRects(_ rects: [OverlayControlID: CGRect]) {
        controlRectsRaw = rects.filter { $0.value != .zero }
        recomputeHitRegions()
    }

    private func updateLyricsHotZone(_ rect: CGRect) {
        lyricsHotZoneRaw = rect == .zero ? nil : rect
        recomputeHitRegions()
    }

    private func updateControlsHotZone(_ rect: CGRect) {
        controlsHotZoneRaw = rect == .zero ? nil : rect
        recomputeHitRegions()
    }

    private func recomputeHitRegions() {
        guard let window else {
            if !controlRectsLocal.isEmpty { controlRectsLocal = [:] }
            controlsHotZoneLocal = nil
            lyricsHotZoneLocal = nil
            chromeHoverZoneLocal = nil
            return
        }

        let windowHeight = baseFrame(of: window).height

        let inset = OverlayControlHitTest.contentTopInset(
            anchorsBottom: placementMode.anchorsBottom, windowHeight: windowHeight, contentHeight: lastContentHeight)
        var out: [OverlayControlID: CGRect] = [:]
        for (id, rect) in controlRectsRaw {
            out[id] = OverlayControlHitTest.windowLocalRect(
                swiftUI: rect, windowHeight: windowHeight, contentTopInset: inset)
        }
        controlRectsLocal = out
        controlsHotZoneLocal = controlsHotZoneRaw.map {
            OverlayControlHitTest.windowLocalRect(swiftUI: $0, windowHeight: windowHeight, contentTopInset: inset)
        }
        lyricsHotZoneLocal = lyricsHotZoneRaw.map {
            OverlayControlHitTest.windowLocalRect(swiftUI: $0, windowHeight: windowHeight, contentTopInset: inset)
        }

        chromeHoverZoneLocal = OverlayControlHitTest.chromeHoverZone(
            lyrics: lyricsHotZoneLocal, controlsPill: controlsHotZoneLocal, controlRects: controlRectsLocal)
    }

    private func handleMouseEvent(type: NSEvent.EventType) {
        guard let window else { return }

        if isPositionLocked {
            if type == .leftMouseDown, isHoveringForControls, window.isVisible,
               OverlayControlHitTest.control(
                   at: window.convertPoint(fromScreen: NSEvent.mouseLocation), in: controlRectsLocal
               ) == .unlockPill {
                performControlAction(.unlockPill)
            }
            guard type == .mouseMoved else { return }
        }

        guard window.isVisible else {
            if !isDragArmed {
                cancelPendingPress()
                clearControlsHoverState()
                if isHoveringLyrics { isHoveringLyrics = false }
            }
            return
        }
        let loc = NSEvent.mouseLocation
        let frame = window.frame

        let localPoint = window.convertPoint(fromScreen: loc)

        let controlsShown = isHoveringForControls && !AppSettings.shared.lockPosition
        let insideHotZone = controlsShown && (controlsHotZoneLocal?.contains(localPoint) ?? false)

        switch type {
        case .mouseMoved:
            let insideWindow = frame.contains(loc)

            let insideChrome = insideWindow
                && (chromeHoverZoneLocal.map { $0.contains(localPoint) } ?? true)
            if isHoveringForControls != insideChrome {
                isHoveringForControls = insideChrome
            }

            let hit = OverlayControlHitTest.control(at: localPoint, in: controlRectsLocal)
            let onControlPill = insideWindow
                && ((controlsHotZoneLocal?.contains(localPoint) ?? false) || hit != nil)
            if isHoveringControlPill != onControlPill {
                isHoveringControlPill = onControlPill
            }

            let nowHovered = OverlayControlHitTest.hoveredControl(
                at: localPoint, in: controlRectsLocal,
                insideWindow: insideWindow, positionLocked: isPositionLocked)
            if hoveredControl != nowHovered {
                hoveredControl = nowHovered
            }

            let insideLyrics = insideWindow
                && (lyricsHotZoneLocal.map { $0.contains(localPoint) } ?? true)
            if isHoveringLyrics != insideLyrics {
                isHoveringLyrics = insideLyrics
            }

        case .leftMouseDown:

            if controlsShown, let id = OverlayControlHitTest.control(at: localPoint, in: controlRectsLocal) {
                performControlAction(id)
                return
            }
            guard frame.contains(loc), !insideHotZone else { return }

            if placementMode.isPreset {
                if let zone = lyricsHotZoneLocal, zone.contains(localPoint) {
                    pressStartLocation = loc
                    presetDragRejectedThisPress = false
                }
                return
            }
            pressStartLocation = loc
            longPressTimer?.invalidate()

            if !AppSettings.shared.overlayDragNeedsLongPress,
               let zone = lyricsHotZoneLocal, zone.contains(localPoint)
            {
                armDragIfStillPressed()
                return
            }
            let timer = Timer(timeInterval: longPressThresholdSecs, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.armDragIfStillPressed() }
            }
            RunLoop.main.add(timer, forMode: .common)
            longPressTimer = timer

        case .leftMouseDragged:

            guard !isDragArmed, let start = pressStartLocation else { return }
            let moved = hypot(loc.x - start.x, loc.y - start.y)
            if placementMode.isPreset {

                if !presetDragRejectedThisPress, moved > presetDragIntentDistance {
                    presetDragRejectedThisPress = true
                    rejectDragForPreset()
                }
                return
            }
            if moved > dragMoveTolerance {

                cancelPendingPress()
            }

        case .leftMouseUp:

            guard !isDragArmed else { return }
            cancelPendingPress()

        default:
            break
        }
    }

    private func armDragIfStillPressed() {

        guard let window, pressStartLocation != nil, NSEvent.pressedMouseButtons & 1 != 0 else {
            cancelPendingPress()
            return
        }

        if placementMode.isPreset {
            cancelPendingPress()
            return
        }
        isDragArmed = true
        window.ignoresMouseEvents = false
        defer {
            window.ignoresMouseEvents = true
            cancelPendingPress()
        }

        guard let syntheticDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: window.mouseLocationOutsideOfEventStream,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }

        window.performDrag(with: syntheticDown)

        isBorrowingScreen = false

        UserDefaults.standard.set(
            "\(window.frame.origin.x),\(window.frame.maxY)", forKey: overlayPositionKey
        )
    }

    private func rejectDragForPreset() {
        let label = OverlayPlacementSegmentedControl.label(for: placementMode)
        placementLockNotice = String(format: L10n.t("位置已固定为「%@」，在 ⚙ 菜单里可改"), label)
        placementLockShakeTick += 1
        placementLockNoticeTimer?.invalidate()
        placementLockNoticeTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.placementLockNotice = nil }
        }
    }

    private func cancelPendingPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        pressStartLocation = nil
        isDragArmed = false
        presetDragRejectedThisPress = false
    }

    private func reconcilePlacementWithScreens() {
        guard let window else { return }
        let screens = Self.allVisibleFrames()

        if placementMode.isPreset {
            reconcilePresetPlacement(window: window, screens: screens)
            return
        }

        if let home = Self.homeFrame(size: window.frame.size),
           OverlayPlacement.isSufficientlyVisible(frame: home, screens: screens) {

            let movedToAnotherScreen =
                OverlayPlacement.hostVisibleFrame(of: window.frame, screens: screens)
                    != OverlayPlacement.hostVisibleFrame(of: home, screens: screens)
            if isBorrowingScreen || (isPositionLocked && movedToAnotherScreen) {
                isBorrowingScreen = false
                window.setFrameOrigin(home.origin)
                return
            }
        }

        guard let target = OverlayPlacement.repositionIfOffscreen(frame: window.frame, screens: screens) else {
            return
        }
        isBorrowingScreen = true
        window.setFrameOrigin(target)

    }

    private static func presetOrigin(mode: OverlayPlacementMode, restored: NSPoint, size: NSSize) -> NSPoint? {
        guard mode.isPreset else { return nil }
        let screens = allVisibleFrames()
        let frame = NSRect(origin: restored, size: size)
        guard let host = OverlayPlacement.hostVisibleFrame(of: frame, screens: screens) ?? screens.first else {
            return nil
        }
        return OverlayPlacement.presetFrame(mode: mode, size: size, visibleFrame: host)?.origin
    }

    private func applyPlacementMode(_ mode: OverlayPlacementMode) {
        guard mode != placementMode else { return }
        placementMode = mode
        guard let window else { return }

        recomputeHitRegions()
        guard mode.isPreset else { return }
        let current = baseFrame(of: window)
        let screens = Self.allVisibleFrames()
        guard let host = OverlayPlacement.hostVisibleFrame(of: current, screens: screens) ?? screens.first,
              let target = OverlayPlacement.presetFrame(mode: mode, size: current.size, visibleFrame: host)
        else { return }
        if target != current { setFrameAnimated(window, to: target) }
    }

    private func reconcilePresetPlacement(window: NSWindow, screens: [CGRect]) {
        let current = baseFrame(of: window)
        let anchorHost = Self.homeFrame(size: current.size)
            .flatMap { OverlayPlacement.hostVisibleFrame(of: $0, screens: screens) }
        let currentHost = OverlayPlacement.hostVisibleFrame(of: current, screens: screens)
        let host: CGRect
        if isBorrowingScreen, let anchorHost {

            host = anchorHost
            isBorrowingScreen = false
        } else if let currentHost {
            host = currentHost

            if Self.savedAnchor() != nil, anchorHost == nil { isBorrowingScreen = true }
        } else if let primary = screens.first {
            host = primary
            isBorrowingScreen = true
        } else {
            return
        }
        guard let target = OverlayPlacement.presetFrame(mode: placementMode, size: current.size, visibleFrame: host)
        else { return }

        if abs(target.minX - current.minX) < 0.5, abs(target.minY - current.minY) < 0.5 { return }
        window.setFrameOrigin(target.origin)
    }

    private func scheduleSavePosition(_ source: PositionSaveSource) {

        guard !isBorrowingScreen else { return }

        if source == .windowMoved, isPositionLocked { return }
        moveDebounceTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let frame = self?.window?.frame else { return }
            let value = "\(frame.origin.x),\(frame.maxY)"

            if UserDefaults.standard.string(forKey: overlayPositionKey) != value {
                UserDefaults.standard.set(value, forKey: overlayPositionKey)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        moveDebounceTimer = t
    }

    private static func allVisibleFrames() -> [CGRect] {
        var screens: [CGRect] = []
        if let main = NSScreen.main { screens.append(main.visibleFrame) }
        for s in NSScreen.screens where s != NSScreen.main { screens.append(s.visibleFrame) }
        return screens
    }

    private static func hostVisibleFrame(of frame: NSRect) -> NSRect? {
        OverlayPlacement.hostVisibleFrame(of: frame, screens: allVisibleFrames())
    }

    private static func savedAnchor() -> (x: Double, top: Double)? {
        func parsePair(_ key: String) -> (x: Double, y: Double)? {
            guard let saved = UserDefaults.standard.string(forKey: key) else { return nil }
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }
        if let p = parsePair(overlayPositionKey) { return (p.x, p.y) }
        if let p = parsePair(overlayPositionLegacyOriginKey) {
            return (p.x, p.y + Double(overlayDefaultHeight))
        }
        return nil
    }

    private static func homeFrame(size: NSSize) -> NSRect? {
        guard let anchor = savedAnchor() else { return nil }
        return NSRect(x: anchor.x, y: anchor.top - Double(size.height),
                      width: size.width, height: size.height)
    }

    private static func restoredPlacement(size: NSSize) -> OverlayPlacement.RestoredPlacement {
        let screens = allVisibleFrames()
        guard let frame = homeFrame(size: size) else {
            let screenFrame = screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return .init(
                origin: NSPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height - 40),
                wasRescued: false
            )
        }
        return OverlayPlacement.restored(frame: frame, screens: screens)
    }
}
