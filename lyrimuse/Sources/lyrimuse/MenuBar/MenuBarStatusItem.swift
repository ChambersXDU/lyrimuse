import AppKit
import Combine
import LyrimuseCore
import os
import SwiftUI

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "menubar-item")

@MainActor
final class MenuBarStatusItem: NSObject {
    static let shared = MenuBarStatusItem()

    private var statusItem: NSStatusItem?
    private let scrollingLabel = MenuBarScrollingLabel()
    private let menuController = MenuBarStatusMenu()
    private var cancellables: [AnyCancellable] = []
    private var started = false

    private var spacer: (size: NSSize, image: NSImage)?

    private let liveIconView = MenuBarLiveIconView()

    private let panelController = MenuBarPanelController()

    private let positionHintController = MenuBarPositionHintController()

    private let hoverControls = MenuBarHoverControlsView()

    private override init() { super.init() }

    func start() {
        guard !started else { return }
        started = true

        panelController.onVisibilityChange = { [weak self] on in
            self?.scrollingLabel.setHighlighted(on)
            self?.liveIconView.setHighlighted(on)
            self?.hoverControls.setHighlighted(on)
            self?.setPanelOpen(on)
        }
        hoverControls.onHoverChange = { [weak self] inside in self?.handleHoverChange(inside) }

        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared

        coordinator.$compactLine
            .map { line -> String in
                guard let line else { return "" }
                return "\(line.words?.first?.startMs ?? -1)#\(line.plainText ?? "")"
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        coordinator.$currentLine
            .map { line -> String in
                guard let line else { return "" }
                return "\(line.words?.first?.startMs ?? -1)#\(line.plainText ?? "")#\(line.translation ?? "")#\(line.romanization ?? "")"
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        settings.$showLyricsInMenuBar.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)

        settings.$menuBarLyricsWidth.dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarLyricsWidthMode.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)

        settings.$menuBarLyricsAlignment.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarIconStyle.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarIconAnimates.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)

        settings.$menuBarLyricsIconPosition.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        coordinator.$isPlayingNow.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)

        coordinator.$title.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        coordinator.$isCurrentTrackAdBreak.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarShowsTitleWhenNoLyrics.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)

        settings.$menuBarHoverShowsControls.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluateHoverEngagement() }.store(in: &cancellables)
        coordinator.$isPlayingSmoothed.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] on in self?.hoverControls.setPlaying(on) }.store(in: &cancellables)
        settings.$menuBarLyricsKaraoke.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)

        settings.$menuBarLyricsFontWeight.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarLyricsFontSize.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarSecondaryLine.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        coordinator.$allLines.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        coordinator.$nextLineText.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)

        settings.$menuBarLyricsTextColorHex.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scrollingLabel.refreshColors()
                self?.scheduleRefresh()
            }.store(in: &cancellables)
        settings.$menuBarLyricsFillColorHex.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scrollingLabel.refreshColors() }.store(in: &cancellables)

        coordinator.$anchor.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncKaraokeClock()
                self?.syncProgressClock()
            }.store(in: &cancellables)
        coordinator.$pausedPositionMs.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncKaraokeClock()
                self?.syncProgressClock()
            }.store(in: &cancellables)

        coordinator.$currentLyricsOffsetMs.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncKaraokeClock(force: true) }.store(in: &cancellables)

        coordinator.$currentDurationMs.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncProgressClock(force: true) }.store(in: &cancellables)

        refresh()

        if !AppSettings.shared.hasShownMenuBarPositionHint,
           AppSettings.shared.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                AppSettings.shared.hasShownMenuBarPositionHint = true
                self.positionHintController.show(relativeTo: button)
            }
        }
    }

    private var correctionEndRefresh: DispatchWorkItem?

    private func syncKaraokeClock(force: Bool = false) {
        correctionEndRefresh?.cancel()
        correctionEndRefresh = nil
        if let anchor = PlaybackCoordinator.shared.anchor, let end = anchor.correctionEndDate,
           end.timeIntervalSinceNow > 0 {
            let work = DispatchWorkItem { [weak self] in
                self?.syncKaraokeClock(force: true)
                self?.syncProgressClock(force: true)
            }
            correctionEndRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + end.timeIntervalSinceNow, execute: work)
        }
        let coordinator = PlaybackCoordinator.shared
        let raw: Int?
        if let anchor = coordinator.anchor {
            raw = anchor.extrapolatedPositionMs(now: Date())
        } else {
            raw = coordinator.pausedPositionMs
        }
        scrollingLabel.updateKaraokeClock(
            positionMs: raw.map { $0 + coordinator.currentLyricsOffsetMs },
            rate: coordinator.anchor?.instantaneousRate() ?? 0,
            playing: coordinator.isPlayingNow,
            force: force)
    }

    private func syncProgressClock(force: Bool = false) {
        let coordinator = PlaybackCoordinator.shared
        let anchor = coordinator.anchor
        let raw: Int? = anchor.map { $0.extrapolatedPositionMs(now: Date()) }
            ?? coordinator.pausedPositionMs
        let duration = [anchor?.durationMs, coordinator.currentDurationMs]
            .compactMap { $0 }.first { $0 > 0 }
        scrollingLabel.updateProgressClock(
            positionMs: raw, durationMs: duration,
            rate: anchor?.instantaneousRate() ?? 0, playing: coordinator.isPlayingNow, force: force)
    }

    private func lyricsIconBadge() -> MenuBarScrollingLabel.IconBadge? {
        let settings = AppSettings.shared
        let position = settings.menuBarLyricsIconPosition
        guard position != .off else { return nil }
        return MenuBarScrollingLabel.IconBadge(style: settings.menuBarIconStyle,
                                               position: position)
    }

    private func karaokeFillPath(for text: String) -> [MenuBarMarquee.KaraokeFillPoint]? {
        guard AppSettings.shared.menuBarLyricsKaraoke else { return nil }
        guard let line = PlaybackCoordinator.shared.currentLine,
              let words = line.words, !words.isEmpty,
              line.plainText == text else { return nil }
        let path = MenuBarMarquee.karaokeFillPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words, font: rowState.mainFont))
        return path.isEmpty ? nil : path
    }

    private func followReadingPath(for text: String) -> [MenuBarMarquee.KaraokeFillPoint]? {
        guard let line = PlaybackCoordinator.shared.currentLine,
              let words = line.words, !words.isEmpty,
              line.plainText == text else { return nil }
        let path = MenuBarMarquee.followReadingPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words, font: rowState.mainFont))
        return path.isEmpty ? nil : path
    }

    private static let statusItemAutosaveBaseName = "lyrimuse-status-item"
    private static let autosaveGenerationDefaultsKey = "np:menuBarAutosaveGeneration"

    private static var currentAutosaveName: String {
        let gen = UserDefaults.standard.integer(forKey: autosaveGenerationDefaultsKey)
        return gen <= 0 ? statusItemAutosaveBaseName : "\(statusItemAutosaveBaseName)-g\(gen)"
    }

    private static func preferredPositionDefaultsKey(for autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    private static let usesLegacyPositionDefaults: Bool = {
        CFPreferencesCopyAppValue(
            "TrailingItemPreferredPositions" as CFString,
            "com.apple.MenuBarAgent" as CFString) == nil
    }()

    private func attachButtonChrome(to item: NSStatusItem) {
        item.autosaveName = Self.currentAutosaveName
        guard let button = item.button else { return }
        button.font = MenuBarMarqueeRenderer.font
        scrollingLabel.removeFromSuperview()
        scrollingLabel.frame = button.bounds
        scrollingLabel.autoresizingMask = [.width, .height]
        scrollingLabel.isHidden = true
        button.addSubview(scrollingLabel)
        liveIconView.removeFromSuperview()
        liveIconView.frame = button.bounds
        liveIconView.autoresizingMask = [.width, .height]
        button.addSubview(liveIconView)

        hoverControls.removeFromSuperview()
        hoverControls.frame = button.bounds
        hoverControls.autoresizingMask = [.width, .height]
        button.addSubview(hoverControls)
        hoverControls.installTracking(on: button)
        button.target = self
        button.action = #selector(statusButtonClicked)

        button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
    }

    private var displayClass = ""

    private static let fixedSlotPadding: CGFloat = 18

    private static let rebuildQuietSecs: TimeInterval = 3

    private static let slotReleaseSecs: TimeInterval = 8

    private static let iconContentHoldSecs: TimeInterval = 3

    private static let iconExitSettleSecs: TimeInterval = 0.12
    private var lastRebuildAt = Date.distantPast
    private var pendingRefresh: DispatchWorkItem?

    private var panelIsOpen = false

    private func setPanelOpen(_ open: Bool) {
        panelIsOpen = open
        logger.notice("panel \(open ? "opened" : "closed", privacy: .public)")
        if !open { refresh() }
        evaluateHoverEngagement()
    }

    private var collapseObserveBegan: Date?

    private var iconExitSettleBegan: Date?

    private var slotFloor = MenuBarSlotFloor()
    private struct SongWidthKey: Equatable {
        let lines: [MenuBarLyricLine]
        let fontWeight: OverlayFontWeight
        let fontSize: CGFloat
        let secondary: LyricSecondaryLine
        let maxWidth: CGFloat
    }
    private var songWidthKey: SongWidthKey?
    private var songWidth: CGFloat = 0

    private func preparedSongWidth() -> CGFloat {
        let settings = AppSettings.shared
        let lines = PlaybackCoordinator.shared.allLines
        let key = SongWidthKey(lines: lines, fontWeight: settings.menuBarLyricsFontWeight,
                               fontSize: settings.menuBarLyricsFontSize,
                               secondary: settings.menuBarSecondaryLine, maxWidth: settings.menuBarLyricsWidth)
        guard key != songWidthKey else { return songWidth }
        songWidthKey = key
        slotFloor.reset()
        songWidth = 0
        for (index, entry) in lines.enumerated() {
            let text = entry.line.plainText ?? ""
            let main = MenuBarMarqueeRenderer.width(of: text,
                font: MenuBarMarqueeRenderer.mainFont(for: text, twoRows: key.secondary.showsSecondaryRow))
            let next = index + 1 < lines.count ? lines[index + 1].line.plainText : nil
            let secondary = key.secondary.secondaryText(currentLine: entry.line, nextLineText: next)
                .map { MenuBarMarqueeRenderer.width(of: $0, font: MenuBarMarqueeRenderer.doubleRowSecondaryFont) } ?? 0
            songWidth = min(key.maxWidth, max(songWidth, main, secondary))
        }
        return songWidth
    }

    private func present(class cls: String, length: CGFloat, collapseDelay: TimeInterval,
                         dwellSeconds: TimeInterval? = nil,
                         targetIsProvisional: Bool = false,
                         interim: ((NSStatusBarButton) -> Void)? = nil,
                         render: (NSStatusBarButton) -> Void) {

        pendingRefresh?.cancel()
        pendingRefresh = nil

        let lyricSlotClasses: Set<String> = ["text", "fixed"]
        if let item = statusItem, let button = item.button, let interim,
           lyricSlotClasses.contains(cls), lyricSlotClasses.contains(displayClass),
           MenuBarSlotPolicy.skipsResize(currentLength: item.length, targetLength: length,
                                         dwellSeconds: dwellSeconds,
                                         quietSecs: Self.rebuildQuietSecs)
        {
            let direction = length > item.length ? "widen" : "shrink"
            logger.debug("""
                slot resize skipped (\(direction, privacy: .public), dwell \
                \(dwellSeconds ?? -1, privacy: .public)s): \
                \(item.length, privacy: .public) -> \(length, privacy: .public)
                """)
            collapseObserveBegan = nil
            iconExitSettleBegan = nil
            interim(button)
            return
        }

        let needsRebuild: Bool
        if let item = statusItem {
            needsRebuild = item.length != length
        } else {
            needsRebuild = true
        }
        guard needsRebuild else {
            collapseObserveBegan = nil
            iconExitSettleBegan = nil
            displayClass = cls
            if let button = statusItem?.button { render(button) }
            return
        }

        if panelIsOpen, statusItem != nil {
            logger.notice("slot rebuild suppressed (panel open): \(self.displayClass, privacy: .public) -> \(cls, privacy: .public)(\(length, privacy: .public))")
            if let button = statusItem?.button {
                if cls == "icon" { render(button) } else { interim?(button) }
            }
            return
        }

        let settleOpen = iconExitSettleBegan != nil
        if statusItem != nil, displayClass == "icon" || targetIsProvisional || settleOpen,
           lyricSlotClasses.contains(cls) {
            let now = Date()
            let began = iconExitSettleBegan ?? now
            iconExitSettleBegan = began
            let remaining = Self.iconExitSettleSecs - now.timeIntervalSince(began)
            if remaining > 0 {
                logger.debug("""
                    slot icon-exit settling \(remaining, privacy: .public)s: \
                    -> \(cls, privacy: .public)(\(length, privacy: .public))
                    """)
                let work = DispatchWorkItem { [weak self] in self?.refresh() }
                pendingRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.01, execute: work)
                return
            }
        }
        iconExitSettleBegan = nil

        if statusItem != nil {
            let now = Date()
            let observeRemaining: TimeInterval
            if collapseDelay > 0 {
                let began = collapseObserveBegan ?? now
                collapseObserveBegan = began
                observeRemaining = max(0, collapseDelay - now.timeIntervalSince(began))
            } else {
                collapseObserveBegan = nil
                observeRemaining = 0
            }
            let delay = max(observeRemaining, Self.rebuildQuietSecs - now.timeIntervalSince(lastRebuildAt))
            if delay > 0 {
                logger.debug("slot rebuild deferred \(delay, privacy: .public)s: \(self.displayClass, privacy: .public) -> \(cls, privacy: .public)(\(length, privacy: .public))")
                var nextWake = delay
                if let button = statusItem?.button {
                    if cls == "icon" {
                        let heldFor = collapseObserveBegan.map { now.timeIntervalSince($0) } ?? .infinity
                        if heldFor >= Self.iconContentHoldSecs { render(button) }
                        else { nextWake = min(delay, max(0.01, Self.iconContentHoldSecs - heldFor)) }
                    } else {
                        interim?(button)
                    }
                }
                let work = DispatchWorkItem { [weak self] in self?.refresh() }
                pendingRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + nextWake + 0.05, execute: work)
                return
            }
        }

        collapseObserveBegan = nil
        logger.notice("slot rebuild: \(self.displayClass, privacy: .public)(\(self.statusItem?.length ?? -1, privacy: .public)) -> \(cls, privacy: .public)(\(length, privacy: .public))")
        displayClass = cls
        lastRebuildAt = Date()
        rebuildStatusItem(length: length)
        if let button = statusItem?.button { render(button) }
    }

    private func rebuildStatusItem(length: CGFloat) {
        let defaults = UserDefaults.standard
        let preservedPosition = Self.usesLegacyPositionDefaults
            ? defaults.object(forKey: Self.preferredPositionDefaultsKey(for: Self.currentAutosaveName))
            : nil
        if preservedPosition != nil {
            let gen = defaults.integer(forKey: Self.autosaveGenerationDefaultsKey) + 1
            defaults.set(gen, forKey: Self.autosaveGenerationDefaultsKey)
            defaults.set(preservedPosition, forKey: Self.preferredPositionDefaultsKey(for: Self.currentAutosaveName))
        }
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        let item = NSStatusBar.system.statusItem(withLength: length)
        statusItem = item
        attachButtonChrome(to: item)
        if preservedPosition != nil {
            let keep = Self.preferredPositionDefaultsKey(for: Self.currentAutosaveName)
            let prefix = Self.preferredPositionDefaultsKey(for: Self.statusItemAutosaveBaseName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for key in UserDefaults.standard.dictionaryRepresentation().keys
                where key.hasPrefix(prefix) && key != keep {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    @objc private func statusButtonClicked() {
        guard let button = statusItem?.button, let event = NSApp.currentEvent else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.type {
        case .rightMouseUp:
            popUpFullMenu()
        case .leftMouseUp:
            if flags.contains(.control) { popUpFullMenu() }
        case .leftMouseDown:
            guard !flags.contains(.command), !flags.contains(.control) else { return }

            let pointInButton = button.window.map {
                button.convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            }
            if let point = pointInButton, let control = hoverControls.control(at: point) {
                performTransportControl(control)
                return
            }
            panelController.toggle(relativeTo: button)
        default:
            break
        }
    }

    private func popUpFullMenu() {
        guard let item = statusItem else { return }
        let menu = menuController.makeMenu(
            onHighlightChange: { [weak self] on in
                self?.scrollingLabel.setHighlighted(on)
                self?.liveIconView.setHighlighted(on)
                self?.hoverControls.setHighlighted(on)
            })
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private var hoverInside = false

    private var hoverControlsEngaged = false

    private func handleHoverChange(_ inside: Bool) {
        hoverInside = inside
        evaluateHoverEngagement()
    }

    private func evaluateHoverEngagement() {

        if !hoverControlsEngaged { hoverControls.setSlot(currentLyricsSlot()) }
        let want = hoverInside
            && AppSettings.shared.menuBarHoverShowsControls
            && !panelIsOpen
            && (displayClass == "text" || displayClass == "fixed")
            && hoverControls.fitsControls
        guard want != hoverControlsEngaged else { return }
        hoverControlsEngaged = want

        logger.notice("hover controls \(want ? "engaged" : "released", privacy: .public) (class=\(self.displayClass, privacy: .public))")
        if want {
            hoverControls.setPlaying(PlaybackCoordinator.shared.isPlayingSmoothed)
            hideLyricsForHoverControls()
            hoverControls.setEngaged(true)
        } else {
            hoverControls.setEngaged(false)
            hoverControls.setSlot(nil)

            refresh()
        }
    }

    private func currentLyricsSlot() -> CGRect? {
        guard let item = statusItem, let button = item.button else { return nil }
        let icon = lyricsIconBadge()
        guard let slot = MenuBarHoverControls.lyricsSlot(
            buttonWidth: button.bounds.width,
            contentWidth: item.length - Self.fixedSlotPadding,
            reservedIconWidth: MenuBarProgressIcon.reservedWidth(for: icon?.style),
            iconLeading: icon?.position == .leading)
        else { return nil }
        return CGRect(x: slot.x, y: button.bounds.minY,
                      width: slot.width, height: button.bounds.height)
    }

    private func hideLyricsForHoverControls() {
        if scrollingLabel.showsIconBadge {
            scrollingLabel.clearLyricsKeepingIcon()
        } else {
            scrollingLabel.clear()
        }
        liveIconView.clear()
        statusItem?.button?.attributedTitle = NSAttributedString(string: "")
        statusItem?.button?.title = ""
    }

    private func performTransportControl(_ control: MenuBarTransportControl) {
        switch control {
        case .previous: withMusicPermission { MusicPlaybackController.previousTrack() }
        case .playPause: withMusicPermission { PlaybackCoordinator.shared.userTogglePlayPause() }
        case .next: withMusicPermission { MusicPlaybackController.nextTrack() }
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

    private struct RowState {

        var kind: LyricSecondaryLine
        var secondaryText: String?

        var mainFont: NSFont
        var twoRows: Bool { kind.showsSecondaryRow }
    }
    private var rowState = RowState(kind: .off, secondaryText: nil, mainFont: NSFont.menuBarFont(ofSize: 0))

    private var titleFallbackActive = false

    private func scheduleRefresh() {
        guard started, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private var refreshScheduled = false

    private func refresh() {
        guard started else { return }
        guard !hoverControlsEngaged else { return }
        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared

        let secondaryKind = settings.menuBarSecondaryLine
        let line = secondaryKind.showsSecondaryRow ? coordinator.currentLine : coordinator.compactLine
        let lyricText = line?.plainText
            ?? (coordinator.compactShowsPlaceholder ? MenuBarMarqueeRenderer.placeholderGlyph : "")

        let display = MenuBarSlotPolicy.displayText(
            lyricText: lyricText, title: coordinator.title,
            isPlaying: coordinator.isPlayingNow, isAdBreak: coordinator.isCurrentTrackAdBreak,
            showsTitleWhenNoLyrics: settings.menuBarShowsTitleWhenNoLyrics,
            placeholderGlyph: MenuBarMarqueeRenderer.placeholderGlyph)
        let text = display?.text ?? ""
        titleFallbackActive = display?.isFallback ?? false

        let twoRows = secondaryKind.showsSecondaryRow && !titleFallbackActive

        let dwell: Double? = titleFallbackActive ? nil
            : (twoRows ? coordinator.currentLineDwellSeconds : coordinator.compactDwellSeconds)

        let leadIn = twoRows ? 0 : coordinator.compactLeadInSeconds
        rowState = RowState(
            kind: twoRows ? secondaryKind : .off,
            secondaryText: twoRows
                ? secondaryKind.secondaryText(currentLine: line, nextLineText: coordinator.nextLineText) : nil,
            mainFont: MenuBarMarqueeRenderer.mainFont(for: text, twoRows: twoRows))
        let lyricsActive = display != nil
        let placeholderNow = titleFallbackActive || text == MenuBarMarqueeRenderer.placeholderGlyph

        guard settings.showLyricsInMenuBar, lyricsActive else {
            let iconWidth = MenuBarIconStyle.cachedImage(for: settings.menuBarIconStyle).size.width
            present(class: "icon", length: iconWidth + Self.fixedSlotPadding,
                    collapseDelay: settings.showLyricsInMenuBar ? Self.slotReleaseSecs : 0) {
                showIcon($0)
            }
            return
        }

        var renderWidth = settings.menuBarLyricsWidth
        if settings.menuBarLyricsWidthMode == .adaptive, renderWidth > 0 {
            let preparedWidth = preparedSongWidth()
            let natural = MenuBarMarqueeRenderer.width(of: text, font: rowState.mainFont)
            let target = coordinator.allLines.isEmpty ? renderWidth : min(renderWidth, max(preparedWidth, natural))
            renderWidth = slotFloor.width(target: target, preparedWidth: preparedWidth, maxWidth: renderWidth,
                trackKey: coordinator.title + "\u{1F}" + coordinator.artist + "\u{1F}" + coordinator.album)
        }
        let provisional = placeholderNow || slotFloor.didResetOnLastCall
        switch MenuBarMarqueeRenderer.presentation(
            for: text,
            windowWidth: renderWidth,

            dwellSeconds: dwell,
            leadInSeconds: leadIn,
            widthMode: renderWidth > 0 ? .fixed : settings.menuBarLyricsWidthMode,
            font: rowState.mainFont
        ) {
        case .text(let visible):
            let width = MenuBarMarqueeRenderer.width(of: visible, font: rowState.mainFont)
            present(class: "text", length: width + Self.fixedSlotPadding, collapseDelay: 0,
                    dwellSeconds: dwell, targetIsProvisional: provisional,
                    interim: { [weak self] in self?.renderInterimLyrics($0, text: text) }) {
                showStaticText($0, visible: visible, full: text)
            }
        case .fixed(let lineText, let windowWidth, let pacing):
            let icon = lyricsIconBadge()
            let slotWidth = windowWidth + MenuBarProgressIcon.reservedWidth(for: icon?.style)
            present(class: "fixed", length: slotWidth + Self.fixedSlotPadding, collapseDelay: 0,
                    dwellSeconds: dwell, targetIsProvisional: provisional,
                    interim: { [weak self] in self?.renderInterimLyrics($0, text: text) }) {
                showFixedWidth($0, text: lineText, windowWidth: windowWidth, pacing: pacing,
                               fillPath: karaokeFillPath(for: lineText),
                               followPath: followReadingPath(for: lineText), icon: icon)
            }
        }
    }

    private func renderInterimLyrics(_ button: NSStatusBarButton, text: String) {
        guard displayClass == "text" || displayClass == "fixed", let item = statusItem else { return }

        let icon = lyricsIconBadge()
        let usable = item.length - Self.fixedSlotPadding
            - MenuBarProgressIcon.reservedWidth(for: icon?.style)
        guard usable > 0 else { return }

        let coordinator = PlaybackCoordinator.shared
        let dwell: Double? = titleFallbackActive ? nil
            : (rowState.twoRows ? coordinator.currentLineDwellSeconds : coordinator.compactDwellSeconds)
        switch MenuBarMarqueeRenderer.presentation(
            for: text, windowWidth: usable,
            dwellSeconds: dwell,

            leadInSeconds: rowState.twoRows ? 0 : coordinator.compactLeadInSeconds,
            widthMode: .fixed, font: rowState.mainFont
        ) {
        case .text(let visible):
            showStaticText(button, visible: visible, full: text)
        case .fixed(let lineText, let win, let pacing):

            showFixedWidth(button, text: lineText, windowWidth: win, pacing: pacing,
                           fillPath: karaokeFillPath(for: lineText),
                           followPath: followReadingPath(for: lineText), icon: icon)
        }
    }

    private func showIcon(_ button: NSStatusBarButton) {
        scrollingLabel.clear()
        let settings = AppSettings.shared
        let style = settings.menuBarIconStyle
        let staticImage = MenuBarIconStyle.cachedImage(for: style)
        if settings.menuBarIconAnimates, PlaybackCoordinator.shared.isPlayingNow {
            button.image = spacerImage(width: staticImage.size.width,
                                       height: staticImage.size.height)
            liveIconView.frame = button.bounds
            liveIconView.present(style: style)
        } else {
            liveIconView.clear()
            button.image = staticImage
        }
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = nil
        button.setAccessibilityLabel(L10n.t("Lyrimuse"))
    }

    private func showStaticText(_ button: NSStatusBarButton, visible: String, full: String) {
        scrollingLabel.clear()
        liveIconView.clear()
        button.image = nil

        button.imagePosition = .noImage

        button.font = MenuBarMarqueeRenderer.font(for: visible)
        let textHex = AppSettings.shared.menuBarLyricsTextColorHex
        if textHex.isEmpty {
            button.title = visible
        } else {
            button.attributedTitle = NSAttributedString(string: visible, attributes: [
                .font: MenuBarMarqueeRenderer.font(for: visible),
                .foregroundColor: NSColor(Color(hexWithAlpha: textHex,
                                                fallback: Color(nsColor: .labelColor))),
            ])
        }

        button.toolTip = full
        button.setAccessibilityLabel(full)
    }

    private func showFixedWidth(_ button: NSStatusBarButton, text: String, windowWidth: CGFloat,
                                pacing: MenuBarMarquee.ScrollPacing?,
                                fillPath: [MenuBarMarquee.KaraokeFillPoint]? = nil,
                                followPath: [MenuBarMarquee.KaraokeFillPoint]? = nil,
                                icon: MenuBarScrollingLabel.IconBadge? = nil) {
        liveIconView.clear()

        button.image = spacerImage(
            width: windowWidth + MenuBarProgressIcon.reservedWidth(for: icon?.style),
            height: MenuBarMarqueeRenderer.lineHeight)
        button.imagePosition = .imageOnly
        button.title = ""

        let spoken = [text, rowState.secondaryText].compactMap { $0 }.joined(separator: "\n")
        button.toolTip = spoken

        button.setAccessibilityLabel(spoken)

        scrollingLabel.frame = button.bounds
        scrollingLabel.present(text: text, windowWidth: windowWidth, pacing: pacing,
                               fillPath: fillPath, followPath: followPath, icon: icon,
                               secondaryText: rowState.secondaryText, secondaryKind: rowState.kind)

        if fillPath != nil || followPath != nil { syncKaraokeClock(force: true) }

        if icon != nil { syncProgressClock(force: true) }
    }

    private func spacerImage(width: CGFloat, height: CGFloat) -> NSImage {
        let size = NSSize(width: ceil(width), height: ceil(height))
        if let spacer, spacer.size == size { return spacer.image }

        let image = NSImage(size: size, flipped: false) { _ in true }
        image.isTemplate = true
        spacer = (size, image)
        return image
    }
}
