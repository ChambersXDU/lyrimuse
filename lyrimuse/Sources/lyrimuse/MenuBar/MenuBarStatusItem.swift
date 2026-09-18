import AppKit
import Combine
import LyrimuseCore
import os
import SwiftUI

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "menubar-item")

// Fallback status bar icon (displayed when playback is paused or menu bar lyrics are disabled).
// Rendered as a vector SF Symbol (`music.note`) combined with three custom-drawn lyric lines,
// avoiding bitmap scaling distortion within the 22pt status bar height.
// Visual styles and selection criteria are defined in `MenuBarIconStyle`.

/// Controller managing the macOS status bar item for lyrics display, hover transport controls,
/// and popover panels. Observes `AppSettings` and `PlaybackCoordinator` via Combine.
@MainActor
final class MenuBarStatusItem: NSObject {
    static let shared = MenuBarStatusItem()

    private var statusItem: NSStatusItem?
    private let scrollingLabel = MenuBarScrollingLabel()
    private let menuController = MenuBarStatusMenu()
    private var cancellables: [AnyCancellable] = []
    private var started = false
    /// Cached transparent spacer image used to fix status item width without drawing pixels.
    private var spacer: (size: NSSize, image: NSImage)?
    /// Dynamic icon rendering layer with Core Animation-driven equalizers and pulses.
    private let liveIconView = MenuBarLiveIconView()
    /// Control Center-style popover panel opened by left-clicking the status item.
    private let panelController = MenuBarPanelController()
    /// First-launch position hint controller.
    private let positionHintController = MenuBarPositionHintController()
    /// Hover playback controls layer positioned over the lyric slot.
    private let hoverControls = MenuBarHoverControlsView()

    private override init() { super.init() }

    /// Initializes and starts observing settings and playback state.
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
        // Note: Combine publishers emit on willSet; receive on main runloop so handler reads observed state.
        // Compact line determines which lyric line to display. Deduplicate by start timestamp and plain text.
        coordinator.$compactLine
            .map { line -> String in
                guard let line else { return "" }
                return "\(line.words?.first?.startMs ?? -1)#\(line.plainText ?? "")"
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        // Current line updates karaoke fill paths and secondary rows (translations, romanizations).
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
        // Debounce width adjustments to avoid triggering high-frequency status item rebuilds while sliding.
        settings.$menuBarLyricsWidth.dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarLyricsWidthMode.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        // Alignment changes require refresh to update layer and text layout.
        settings.$menuBarLyricsAlignment.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarIconStyle.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarIconAnimates.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        // Adjust slot width for leading/trailing progress icon badges.
        settings.$menuBarLyricsIconPosition.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        coordinator.$isPlayingNow.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        // Track title changes, ad break state, and title fallback toggle.
        coordinator.$title.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        coordinator.$isCurrentTrackAdBreak.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarShowsTitleWhenNoLyrics.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        // Hover controls toggle and play/pause state synchronization.
        settings.$menuBarHoverShowsControls.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluateHoverEngagement() }.store(in: &cancellables)
        coordinator.$isPlayingSmoothed.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] on in self?.hoverControls.setPlaying(on) }.store(in: &cancellables)
        settings.$menuBarLyricsKaraoke.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        // Font weight, size, and secondary row configuration.
        settings.$menuBarLyricsFontWeight.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarLyricsFontSize.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        settings.$menuBarSecondaryLine.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        coordinator.$nextLineText.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        // Custom color adjustments.
        settings.$menuBarLyricsTextColorHex.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scrollingLabel.refreshColors()
                self?.scheduleRefresh()
            }.store(in: &cancellables)
        settings.$menuBarLyricsFillColorHex.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scrollingLabel.refreshColors() }.store(in: &cancellables)
        // Clock synchronization: anchor updates feed karaoke fill animation and progress icon badge.
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
        // Lyric offset updates karaoke timing without altering physical playback position.
        coordinator.$currentLyricsOffsetMs.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncKaraokeClock(force: true) }.store(in: &cancellables)
        // Track duration updates progress badge geometry.
        coordinator.$currentDurationMs.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncProgressClock(force: true) }.store(in: &cancellables)

        refresh()

        // First-launch position hint: prompt once after onboarding finishes.
        if !AppSettings.shared.hasShownMenuBarPositionHint,
           AppSettings.shared.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                AppSettings.shared.hasShownMenuBarPositionHint = true
                self.positionHintController.show(relativeTo: button)
            }
        }
    }

    /// 把播放时钟(外推位置 + 歌词时间轴校准)喂给标签的填色动画。位置公式与歌词窗口
    /// KaraokeWordText 逐字填色完全同一条:anchor 外推 ?? 暂停位置,再加偏移校准。
    private func syncKaraokeClock(force: Bool = false) {
        let coordinator = PlaybackCoordinator.shared
        let raw: Int?
        if let anchor = coordinator.anchor {
            raw = anchor.extrapolatedPositionMs(now: Date())
        } else {
            raw = coordinator.pausedPositionMs
        }
        scrollingLabel.updateKaraokeClock(
            positionMs: raw.map { $0 + coordinator.currentLyricsOffsetMs },
            rate: coordinator.anchor?.rate ?? 0,
            playing: coordinator.isPlayingNow,
            force: force)
    }

    /// 把播放时钟喂给歌词旁那枚进度图标。跟 `syncKaraokeClock` 是**两条**通道,差别只有
    /// 一处,但那一处正是这个功能对不对的关键:
    ///
    /// ⚠️ **这里不加 `currentLyricsOffsetMs`**。那个偏移是把歌词往前/往后挪(让字跟得上
    /// 人声),歌本身放到第几秒并没有变 —— 加上去的话,用户把歌词调快 2 秒,进度图标也跟着
    /// 虚报 2 秒。染色那条**必须**加(它对的是歌词时间轴),这条**必须**不加(它对的是
    /// 播放位置)。两个函数长得像,改其中一个之前先看清是哪一条。
    ///
    /// 曲长优先取锚点里那份(跟位置是同一次采样、最配套),它缺/为 0 时退回
    /// `currentDurationMs`;两个都没有就传 nil —— 标签那边会整枚只画基础色,不假装有进度。
    private func syncProgressClock(force: Bool = false) {
        let coordinator = PlaybackCoordinator.shared
        let anchor = coordinator.anchor
        let raw: Int? = anchor.map { $0.extrapolatedPositionMs(now: Date()) }
            ?? coordinator.pausedPositionMs
        let duration = [anchor?.durationMs, coordinator.currentDurationMs]
            .compactMap { $0 }.first { $0 > 0 }
        scrollingLabel.updateProgressClock(
            positionMs: raw, durationMs: duration,
            rate: anchor?.rate ?? 0, playing: coordinator.isPlayingNow, force: force)
    }

    /// 歌词旁那枚带播放进度的图标(nil = 设置里关着)。
    ///
    /// 款式跟"图标独占那一格"时用的是**同一个** `menuBarIconStyle` —— 那本来就是这个 App
    /// 在菜单栏上的脸,没有理由在两个地方各挑一款。这个函数只回答"要不要画、画哪款、摆哪边";
    /// 进度画到哪儿由 syncProgressClock 那条通道管。
    private func lyricsIconBadge() -> MenuBarScrollingLabel.IconBadge? {
        let settings = AppSettings.shared
        let position = settings.menuBarLyricsIconPosition
        guard position != .off else { return nil }
        return MenuBarScrollingLabel.IconBadge(style: settings.menuBarIconStyle,
                                               position: position)
    }

    /// Generates the karaoke fill path for character-by-character color fill.
    private func karaokeFillPath(for text: String) -> [MenuBarMarquee.KaraokeFillPoint]? {
        guard AppSettings.shared.menuBarLyricsKaraoke else { return nil }
        guard let line = PlaybackCoordinator.shared.currentLine,
              let words = line.words, !words.isEmpty,
              line.plainText == text else { return nil }
        let path = MenuBarMarquee.karaokeFillPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words, font: rowState.mainFont))
        return path.isEmpty ? nil : path
    }

    /// Generates reading position path for marquee tracking during playback.
    private func followReadingPath(for text: String) -> [MenuBarMarquee.KaraokeFillPoint]? {
        guard let line = PlaybackCoordinator.shared.currentLine,
              let words = line.words, !words.isEmpty,
              line.plainText == text else { return nil }
        let path = MenuBarMarquee.followReadingPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words, font: rowState.mainFont))
        return path.isEmpty ? nil : path
    }

    /// Base autosave identifier for the status bar item.
    /// On macOS versions prior to macOS 27, AppKit deletes the position key when a status item is deallocated.
    /// To preserve user-dragged item positioning across item rebuilds, a generational suffix is incremented (`<base>-g<N>`).
    private static let statusItemAutosaveBaseName = "lyrimuse-status-item"
    private static let autosaveGenerationDefaultsKey = "np:menuBarAutosaveGeneration"

    /// Current generational autosave name.
    private static var currentAutosaveName: String {
        let gen = UserDefaults.standard.integer(forKey: autosaveGenerationDefaultsKey)
        return gen <= 0 ? statusItemAutosaveBaseName : "\(statusItemAutosaveBaseName)-g\(gen)"
    }

    /// UserDefaults key used by legacy AppKit to persist status item position.
    private static func preferredPositionDefaultsKey(for autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// Indicates whether the host OS relies on legacy AppKit position keys rather than MenuBarAgent.
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
        // Add hover controls as top subview layer.
        hoverControls.removeFromSuperview()
        hoverControls.frame = button.bounds
        hoverControls.autoresizingMask = [.width, .height]
        button.addSubview(hoverControls)
        hoverControls.installTracking(on: button)
        button.target = self
        button.action = #selector(statusButtonClicked)
        // Left click triggers on mouseDown for responsive presentation; right/control click triggers on mouseUp.
        button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
    }

    /// Current display class ("icon", "text", or "fixed").
    private var displayClass = ""

    /// Fixed slot horizontal padding (status bar button margins).
    private static let fixedSlotPadding: CGFloat = 18

    /// Minimum quiet interval between status item rebuilds.
    private static let rebuildQuietSecs: TimeInterval = 3
    /// Delay before releasing the status bar slot width geometry (upstream 761df776).
    private static let slotReleaseSecs: TimeInterval = 8
    /// Duration to hold previous lyrics content before switching to the icon (upstream 761df776).
    private static let iconContentHoldSecs: TimeInterval = 3
    /// Settle duration before rebuilding the status item when leaving the icon slot or handling provisional targets (upstream 761df776).
    private static let iconExitSettleSecs: TimeInterval = 0.12
    private var lastRebuildAt = Date.distantPast
    private var pendingRefresh: DispatchWorkItem?

    /// Flag indicating whether the popover panel is currently open.
    /// Rebuilding the status item is suppressed while open to preserve popover anchor geometry.
    private var panelIsOpen = false

    private func setPanelOpen(_ open: Bool) {
        panelIsOpen = open
        logger.notice("panel \(open ? "opened" : "closed", privacy: .public)")
        if !open { refresh() }
        evaluateHoverEngagement()
    }
    /// Timestamp when current collapse observation window began.
    private var collapseObserveBegan: Date?
    /// Start timestamp of the settle window when exiting the icon slot or during provisional targets (upstream 761df776).
    private var iconExitSettleBegan: Date?
    /// Per-song monotonic slot floor in adaptive mode to eliminate oscillation (upstream 761df776).
    private var slotFloor = MenuBarSlotFloor()

    /// Presents layout changes to the status bar.
    /// macOS status bar layout invariants:
    /// 1. Status bar item spacing is calculated upon item creation; dynamic length adjustments
    ///    require rebuilding the status item to update neighbor positions.
    /// 2. Successive rapid rebuilds can cause layout desynchronization. Changes are throttled
    ///    via `rebuildQuietSecs`, collapse observation windows, and settle delays.
    ///
    /// 重建/推迟各落一条 notice 级日志(info 不落盘,上次排查就是因此拿不到现场):
    /// 再出错位,`/usr/bin/log show --predicate 'subsystem == "me.yudaotor.lyrimuse"
    /// && category == "menubar-item"'` 能对出完整时间线。
    private func present(class cls: String, length: CGFloat, collapseDelay: TimeInterval,
                         dwellSeconds: TimeInterval? = nil,
                         targetIsProvisional: Bool = false,
                         interim: ((NSStatusBarButton) -> Void)? = nil,
                         render: (NSStatusBarButton) -> Void) {
        // 每次都从最新状态重算目标,历史挂起的目标一律作废。
        pendingRefresh?.cancel()
        pendingRefresh = nil

        // Do not resize slot for short-lived lines (`MenuBarSlotPolicy.skipsResize`).
        // Resizing for a line that does not outlast the quiet window would consume rebuild quota and delay subsequent lines.
        // Applies between lyric slot classes (text and fixed).
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

        // Rebuild only when target length differs from current item length.
        // Identical-length transitions (such as text ↔ fixed at max width) bypass rebuilds,
        // invoking `render` directly on the existing button to update presentation.
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

        // Suppress geometry rebuilds while popover panel is open:
        // The status item button serves as the anchor view for the popover panel; tearing down the item
        // invalidates the anchor. Content updates render into the existing button via interim rendering.
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

    /// Rebuilds NSStatusItem with the specified length.
    ///
    /// ## macOS Preferred Position Persistence (Legacy Systems):
    /// On macOS versions prior to MenuBarAgent centralized position tracking, destroying and recreating
    /// a status item deletes the AppKit `NSStatusItem Preferred Position <autosaveName>` preference key on dealloc.
    /// To preserve user-arranged menu bar positions across rebuilds, a generational autosave name (`<base>-g<N>`)
    /// is rotated and written to UserDefaults before the previous item is released.
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
        attachButtonChrome(to: item) // Uses updated currentAutosaveName
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

    // MARK: - Click Routing

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
            // Transport controls take precedence when engaged and clicked.
            // Remaining area routes to panel toggling.
            // Coordinates must be converted from screen coordinates (`NSEvent.mouseLocation`)
            // rather than `event.locationInWindow` to maintain accurate hit-testing under MenuBarAgent.
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

    /// Presents full context menu temporarily attached to item.menu.
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

    // MARK: - Hover Controls

    /// 指针在不在这一项上(由 MenuBarHoverControlsView 的 tracking area 上报)。
    private var hoverInside = false
    /// 正在接管中:歌词收掉、三个键画着、refresh() 早退。
    private var hoverControlsEngaged = false

    /// Handles cursor hover entry and exit for transport controls.
    /// Immediately toggles control engagement without debounce delays.
    private func handleHoverChange(_ inside: Bool) {
        hoverInside = inside
        evaluateHoverEngagement()
    }

    /// 现在到底该不该接管。所有进出接管态的路径都收口在这里(hover 进出、开关拨动、
    /// 面板开合),各自算一遍完整条件而不是各改一半状态。
    ///
    /// 五个条件缺一不可:
    ///  1. 指针在这一项上(不等待,见 handleHoverChange);
    ///  2. 用户开了这个开关;
    ///  3. 面板没开 —— 面板自己就有三键,而且状态栏这一项**就是那张 popover 的锚点视图**;
    ///  4. 当前是歌词形态(text/fixed)。图标形态不接管:那个槽只有 38pt 上下,三个键画不下,
    ///     而且那时候本来就没在放歌;
    ///  5. **歌词那一格**装得下三个键(见 MenuBarHoverControls.layout —— 自适应宽度模式下
    ///     一句 ♪ 的槽宽只有二三十点)。开着「歌词旁的图标」时这一格比整个按钮窄一截
    ///     (图标宽 + 5pt 间距),门槛按窄的那个算。
    ///
    /// ⚠️ 第 4、5 条合起来还有一个副作用值得知道:**暂停之后歌词槽会收成图标槽**(refresh()
    /// 里那道 lyricsActive guard,收缩延时 3s),所以"暂停 → 想再点播放"这条路只在指针
    /// 一直停在这一项上时才走得通 —— 接管期间 refresh() 早退,那次收缩根本不会发生,三个
    /// 键就停在原地等着。指针一离开,收缩才照旧进行。
    private func evaluateHoverEngagement() {
        // 先把"三个键该落在哪一格"喂进去,再判装不装得下 —— 顺序反了就是拿整个按钮的宽度去
        // 过门槛、结果画出一排压在图标上的键。**只在没接管时取**:接管期间几何是冻住的,
        // 没有重算的理由。
        if !hoverControlsEngaged { hoverControls.setSlot(currentLyricsSlot()) }
        let want = hoverInside
            && AppSettings.shared.menuBarHoverShowsControls
            && !panelIsOpen
            && (displayClass == "text" || displayClass == "fixed")
            && hoverControls.fitsControls
        guard want != hoverControlsEngaged else { return }
        hoverControlsEngaged = want
        // notice 级:跟上面那些 slot rebuild / panel 日志对同一条时间线 —— "歌词莫名不见了"
        // 这类反馈只有对上时间线才分得清是接管、是收缩、还是重建错位。
        logger.notice("hover controls \(want ? "engaged" : "released", privacy: .public) (class=\(self.displayClass, privacy: .public))")
        if want {
            hoverControls.setPlaying(PlaybackCoordinator.shared.isPlayingSmoothed)
            hideLyricsForHoverControls()
            hoverControls.setEngaged(true)
        } else {
            hoverControls.setEngaged(false)
            hoverControls.setSlot(nil)
            // 接管期间 refresh() 一直早退,歌词和几何都停在接管那一刻。这里补一次,把这段
            // 时间里换过的句子、被挡下来的槽宽变化一次性落地 —— 跟面板收起那一刻补一次
            // refresh() 是同一个模型(见 present 头注的 panelIsOpen 分支)。
            refresh()
        }
    }

    /// Derives lyrics slot from `item.length` rather than ephemeral layer geometries.
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

    /// Hides lyrics and preserves icon when hover controls engage without altering status item geometry.
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

    /// 悬停三键点下去干什么。跟悬浮歌词那排按钮逐字同一套语义:
    ///  - 播放/暂停走 PlaybackCoordinator 的**乐观回声版**(见 userTogglePlayPause),不直接
    ///    调 MusicPlaybackController.playPause();
    ///  - 三个动作都套"点了才校验权限"的守卫。
    private func performTransportControl(_ control: MenuBarTransportControl) {
        switch control {
        case .previous: withMusicPermission { MusicPlaybackController.previousTrack() }
        case .playPause: withMusicPermission { PlaybackCoordinator.shared.userTogglePlayPause() }
        case .next: withMusicPermission { MusicPlaybackController.nextTrack() }
        }
    }

    /// "点了才校验权限":没问过就顺手弹一次系统授权对话框,已经拒绝过就 NSSound.beep() 给
    /// 一个"没有生效"的听觉反馈。必须用异步版 checkForCurrentPlayerSafely(同步版可能永久
    /// 挂起主线程,坑在它定义处)。
    private func withMusicPermission(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                NSSound.beep()
                return
            }
            action()
        }
    }

    // MARK: - Layout & Refresh

    /// Snapshot of dual-row display state calculated in `refresh()`.
    private struct RowState {
        /// `.off` = 单行(含副行开着、但此刻显示的是「♪ 歌名」兜底的情况)。
        var kind: LyricSecondaryLine
        var secondaryText: String?
        /// 主行长图 / 测宽 / 逐字边界共用的字体,由 `MenuBarMarqueeRenderer.mainFont(for:twoRows:)` 算。
        var mainFont: NSFont
        var twoRows: Bool { kind.showsSecondaryRow }
    }
    private var rowState = RowState(kind: .off, secondaryText: nil, mainFont: NSFont.menuBarFont(ofSize: 0))

    /// 这一刻显示的是「♪ 歌名」兜底而不是歌词句(见 MenuBarSlotPolicy.displayText):配速与中间态渲染
    /// 据此不按歌词时长算(dwellSeconds 传 nil 走固定速度那条退路)。
    private var titleFallbackActive = false

    /// Coalesces multiple notification wakeups within the same runloop turn.
    /// Direct calls from lifecycle methods (such as start and panel dismissal) remain synchronous.
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
        // Dual-row secondary line uses `currentLine` without lead-in anticipation.
        let secondaryKind = settings.menuBarSecondaryLine
        let line = secondaryKind.showsSecondaryRow ? coordinator.currentLine : coordinator.compactLine
        let lyricText = line?.plainText
            ?? (coordinator.compactShowsPlaceholder ? MenuBarMarqueeRenderer.placeholderGlyph : "")
        // When no lyrics line is available (no lyrics / searching), show "♪ Track Title" placeholder
        // if configured, instead of collapsing to icon. Invariants and boundaries (paused, ad breaks,
        // missing track title) are handled by Core `MenuBarSlotPolicy.displayText`. nil collapses to icon.
        let display = MenuBarSlotPolicy.displayText(
            lyricText: lyricText, title: coordinator.title,
            isPlaying: coordinator.isPlayingNow, isAdBreak: coordinator.isCurrentTrackAdBreak,
            showsTitleWhenNoLyrics: settings.menuBarShowsTitleWhenNoLyrics,
            placeholderGlyph: MenuBarMarqueeRenderer.placeholderGlyph)
        let text = display?.text ?? ""
        titleFallbackActive = display?.isFallback ?? false
        // Title fallback is rendered as a single line (13pt) without secondary row.
        let twoRows = secondaryKind.showsSecondaryRow && !titleFallbackActive
        // Fallback text does not have a line dwell duration; pacing falls back to constant speed.
        let dwell: Double? = titleFallbackActive ? nil
            : (twoRows ? coordinator.currentLineDwellSeconds : coordinator.compactDwellSeconds)
        // During the lead-in window, the upcoming line is visible but uncolored; marquee scroll
        // must wait for lead-in to elapse before scrolling starts. Dual-row mode renders the currently
        // active line directly without lead-in delay (constant 0).
        let leadIn = twoRows ? 0 : coordinator.compactLeadInSeconds
        rowState = RowState(
            kind: twoRows ? secondaryKind : .off,
            secondaryText: twoRows
                ? secondaryKind.secondaryText(currentLine: line, nextLineText: coordinator.nextLineText) : nil,
            mainFont: MenuBarMarqueeRenderer.mainFont(for: text, twoRows: twoRows))
        let lyricsActive = display != nil
        // Placeholder state ("♪ Title" fallback or interlude ♪) sizes the slot based on the upcoming line
        // to prevent double slot-width resizes when the first lyric line arrives (see `upcomingLineSlotWidth`).
        let placeholderNow = titleFallbackActive || text == MenuBarMarqueeRenderer.placeholderGlyph
        let upcomingW = upcomingLineSlotWidth(isPlaceholder: placeholderNow)

        // When menu bar lyrics are disabled, paused, or text is empty: collapse to icon slot.
        // Slot width = icon width + fixed padding, preserving the explicit initial width rule
        // to avoid layout recalculation gaps with variable-length status items.
        // The collapse observation window applies to transient lyric pauses; disabling lyrics
        // explicitly triggers an immediate collapse.
        guard settings.showLyricsInMenuBar, lyricsActive else {
            let iconWidth = MenuBarIconStyle.cachedImage(for: settings.menuBarIconStyle).size.width
            present(class: "icon", length: iconWidth + Self.fixedSlotPadding,
                    collapseDelay: settings.showLyricsInMenuBar ? Self.slotReleaseSecs : 0) {
                showIcon($0)
            }
            return
        }
        // "装得下还是要滚"这个判定跟设置页那条预览共用同一个函数,两边不可能漂 ——
        // 见 MenuBarMarqueeRenderer.Presentation。
        switch MenuBarMarqueeRenderer.presentation(
            for: text,
            windowWidth: settings.menuBarLyricsWidth,
            // 让长句子在换到下一句之前滚完,而不是永远按固定速度爬。
            // 单行用 compactDwellSeconds 而不是 currentLineDwellSeconds:显示窗口变了(唱完就
            // 切走),用旧口径会把 dwell 算大 —— 长句后面接长间奏时按偏大的 dwell 配速,
            // 句子会在只滚出开头一小截时就被换掉,比改动前更糟。见 CompactLyricLead
            // .displayDurationMs。双排显示的就是 currentLine,用它自己的时长。
            dwellSeconds: dwell,
            leadInSeconds: leadIn,
            widthMode: settings.menuBarLyricsWidthMode,
            font: rowState.mainFont
        ) {
        case .text(let visible):
            // 自适应态:槽宽跟着这一句的文字宽走 —— 每次变宽都是一次重建
            // (macOS 26 下这是唯一能让邻居让位的做法,见 present 头注)。
            //
            // visible != text 只发生在 windowWidth<=0 的截断退化路径 —— 那里既不染色也不
            // 画图标(格子小到画不出来),所以 icon 直接跟着这个条件取 nil,槽宽自然也不会
            // 白让出一块空地。
            let icon = visible == text ? lyricsIconBadge() : nil
            let reserved = MenuBarProgressIcon.reservedWidth(for: icon?.style)
            let mainW = MenuBarMarqueeRenderer.width(of: visible, font: rowState.mainFont)
            // 双排:格宽取两行里宽的那个(副行比主行宽是常态 —— 译文往往更长),上限仍是「最大宽度」;
            // 超过上限的副行在格里尾部渐隐。单行:就是主行宽,跟改动前逐点相同。
            let secondaryW = rowState.secondaryText.map {
                MenuBarMarqueeRenderer.width(of: $0, font: MenuBarMarqueeRenderer.doubleRowSecondaryFont)
            } ?? 0
            let naturalW = rowState.twoRows ? min(settings.menuBarLyricsWidth, max(mainW, secondaryW)) : mainW
            // 占位态给槽宽兜个底:让它现在就有即将到来那一句要的宽度,那一句出现时几何
            // 已经到位、不必再改一次。判据是 Core 的纯函数(有 selftest),这里只喂数 ——
            // "下一句"怎么量在 `upcomingLineSlotWidth`,"该不该用它"在 `MenuBarSlotPolicy.slotWidth`。
            let textW = MenuBarSlotPolicy.slotWidth(
                naturalWidth: naturalW, upcomingWidth: upcomingW,
                isPlaceholder: placeholderNow, maxWidth: settings.menuBarLyricsWidth)
            let w = slotFloor.width(
                target: textW + reserved + Self.fixedSlotPadding,
                trackKey: coordinator.title + "\u{1F}" + coordinator.artist)
            let provisional = placeholderNow || slotFloor.didResetOnLastCall
            let fillPath = visible == text ? karaokeFillPath(for: text) : nil
            if fillPath != nil || icon != nil || rowState.twoRows {
                // Layer-based rendering via `scrollingLabel` is required for:
                // 1. Karaoke syllable highlighting (AppKit `button.title` cannot overlay accent color fills).
                // 2. Progress icons (dynamic partial fill cannot be drawn in standard button image/title).
                // 3. Dual-row layout (`button.title` only supports single-line text).
                // Slot width formula matches static text, preserving the identical footprint.
                present(class: "text", length: w, collapseDelay: 0,
                        dwellSeconds: dwell, targetIsProvisional: provisional,
                        interim: { [weak self] in self?.renderInterimLyrics($0, text: text) }) {
                    showFixedWidth($0, text: text, windowWidth: textW,
                                   pacing: nil, fillPath: fillPath, icon: icon)
                }
            } else {
                present(class: "text", length: w, collapseDelay: 0,
                        dwellSeconds: dwell, targetIsProvisional: provisional,
                        interim: { [weak self] in self?.renderInterimLyrics($0, text: text) }) {
                    showStaticText($0, visible: visible, full: text)
                }
            }
        case .fixed(let lineText, let windowWidth, let pacing):
            let icon = lyricsIconBadge()
            let slotWidth = windowWidth + MenuBarProgressIcon.reservedWidth(for: icon?.style)
            present(class: "fixed", length: slotWidth + Self.fixedSlotPadding, collapseDelay: 0,
                    dwellSeconds: dwell,
                    interim: { [weak self] in self?.renderInterimLyrics($0, text: text) }) {
                showFixedWidth($0, text: lineText, windowWidth: windowWidth, pacing: pacing,
                               fillPath: karaokeFillPath(for: lineText),
                               followPath: followReadingPath(for: lineText), icon: icon)
            }
        }
    }

    /// In placeholder state ("♪ Title" fallback or interlude ♪), calculates the slot width required by
    /// the upcoming lyric line (returns 0 in non-placeholder states).
    ///
    /// Pre-allocating slot width during the placeholder prevents a double resize:
    /// 1. Without pre-allocation: icon -> text (placeholder width) -> fixed/text (lyric line width).
    /// 2. With pre-allocation: icon -> target width directly, avoiding layout shifts when lyrics begin.
    ///
    /// If lyrics are not yet parsed or `nextLineText` is nil, returns 0 and sizes by placeholder text.
    private func upcomingLineSlotWidth(isPlaceholder: Bool) -> CGFloat {
        guard isPlaceholder,
              let next = PlaybackCoordinator.shared.nextLineText?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !next.isEmpty
        else { return 0 }
        return MenuBarMarqueeRenderer.width(
            of: next, font: MenuBarMarqueeRenderer.mainFont(for: next, twoRows: false))
    }

    /// Interim rendering while slot geometry change is postponed: renders the latest lyric line
    /// within the existing slot width so content updates in real time while geometry awaits the quiet window.
    /// Only active when already displaying a text/fixed slot; icon slots (38pt) are preserved until rebuild.
    private func renderInterimLyrics(_ button: NSStatusBarButton, text: String) {
        guard displayClass == "text" || displayClass == "fixed", let item = statusItem else { return }
        // Deduct space occupied by the progress icon badge from the current slot width.
        let icon = lyricsIconBadge()
        let usable = item.length - Self.fixedSlotPadding
            - MenuBarProgressIcon.reservedWidth(for: icon?.style)
        guard usable > 0 else { return }
        // Use .fixed mode during interim rendering to conform to the existing slot width.
        // Pacing, dwell, and lead-in match `refresh()` invariants.
        let coordinator = PlaybackCoordinator.shared
        let dwell: Double? = titleFallbackActive ? nil
            : (rowState.twoRows ? coordinator.currentLineDwellSeconds : coordinator.compactDwellSeconds)
        switch MenuBarMarqueeRenderer.presentation(
            for: text, windowWidth: usable,
            dwellSeconds: dwell,
            // 过渡渲染画的是同一句,提前量口径也必须同一份 —— 这里给 0 的话,几何推迟期间
            // (自适应模式下逐句都有,最多 3s)那一句又会在开唱前先滚起来。双排取正在唱的那一句,恒 0。
            leadInSeconds: rowState.twoRows ? 0 : coordinator.compactLeadInSeconds,
            widthMode: .fixed, font: rowState.mainFont
        ) {
        case .text(let visible):
            showStaticText(button, visible: visible, full: text)
        case .fixed(let lineText, let win, let pacing):
            // 过渡渲染同样带上填色和图标 —— 自适应模式逐句都有一段几何推迟窗(最多 3s),
            // 不带的话每句开头 3 秒都没有染色/没有图标,槽宽落地那一刻才突然冒出来。
            showFixedWidth(button, text: lineText, windowWidth: win, pacing: pacing,
                           fillPath: karaokeFillPath(for: lineText),
                           followPath: followReadingPath(for: lineText), icon: icon)
        }
    }

    /// 没开菜单栏歌词 / 没在播放 / 还没解析出这一句:图标(槽位由 showIconSlot 管,
    /// 这里只管内容)。静态图靠按钮自己居中,活体渲染靠 MenuBarLiveIconView.layout()
    /// 按 bounds 居中,两条路都天然适应槽宽。
    /// 「随播放律动」开着且正在播放时走活体渲染:按钮里只放一张撑尺寸的透明占位图
    /// (footprint 跟静态款逐像素一致),真身画在 liveIconView 的图层上,动画全部
    /// 交给 Core Animation(见 MenuBarLiveIconView 头注)。其余情况就是一张静态模板图。
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

    /// Fallback path: rendered when slot width is too small for layer marquee.
    /// Uses native button title truncated by AppKit.
    private func showStaticText(_ button: NSStatusBarButton, visible: String, full: String) {
        scrollingLabel.clear()
        liveIconView.clear()
        button.image = nil
        // Reset imagePosition to .noImage to explicitly clear .imageOnly set by marquee rendering.
        // Even though AppKit renders title when image is nil, resetting ensures button state does
        // not rely on implicit mode residuals.
        button.imagePosition = .noImage
        // Custom text color uses attributedTitle; default styling sets title directly.
        // Font matches weight settings dynamically.
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
        // tooltip 始终给完整这一行:"想看全文就悬停"这条出路在三种模式下都在。
        button.toolTip = full
        button.setAccessibilityLabel(full)
    }

    /// Standard rendering path: allocates `windowWidth` with text rendered in a layer.
    /// Fits without scrolling when `pacing == nil`; uses Core Animation marquee when overflowing.
    /// Lines fitting within slot also route here rather than button.title to preserve fixed slot width
    /// across varying line lengths, preventing menu bar jitter.
    private func showFixedWidth(_ button: NSStatusBarButton, text: String, windowWidth: CGFloat,
                                pacing: MenuBarMarquee.ScrollPacing?,
                                fillPath: [MenuBarMarquee.KaraokeFillPoint]? = nil,
                                followPath: [MenuBarMarquee.KaraokeFillPoint]? = nil,
                                icon: MenuBarScrollingLabel.IconBadge? = nil) {
        liveIconView.clear()
        // A fully transparent spacer image provides the structural footprint for variable-length
        // status items, allowing AppKit to handle internal bar button padding naturally while
        // decoupling item width from text content.
        // Space occupied by the progress icon badge is added to the spacer image width to match
        // the total slot width allocated in refresh().
        button.image = spacerImage(
            width: windowWidth + MenuBarProgressIcon.reservedWidth(for: icon?.style),
            height: MenuBarMarqueeRenderer.lineHeight)
        button.imagePosition = .imageOnly
        button.title = ""
        // 双排时 tooltip / 读屏都给两行(副行同样是图层上的字,读屏读不到)。
        let spoken = [text, rowState.secondaryText].compactMap { $0 }.joined(separator: "\n")
        button.toolTip = spoken
        // 图层上的文字读屏软件读不到,这里显式补上这一行歌词。
        button.setAccessibilityLabel(spoken)

        scrollingLabel.frame = button.bounds
        scrollingLabel.present(text: text, windowWidth: windowWidth, pacing: pacing,
                               fillPath: fillPath, followPath: followPath, icon: icon,
                               secondaryText: rowState.secondaryText, secondaryKind: rowState.kind)
        // 换句后立刻对一次表,填色 / 跟唱滚动从此刻的真实播放位置起步,不等下一次锚点更新(~2s)。
        if fillPath != nil || followPath != nil { syncKaraokeClock(force: true) }
        // 进度图标同理:重排位图会把裁剪层的几何重设,不立刻对表的话它会停在 0 直到下一次
        // 锚点更新。force 是因为位置往往一点没变(换句而已),过不了漂移门。
        if icon != nil { syncProgressClock(force: true) }
    }

    private func spacerImage(width: CGFloat, height: CGFloat) -> NSImage {
        let size = NSSize(width: ceil(width), height: ceil(height))
        if let spacer, spacer.size == size { return spacer.image }
        // drawingHandler 里什么都不画,只 return true —— 得到的是一张有正确尺寸、
        // 但完全透明的图。
        let image = NSImage(size: size, flipped: false) { _ in true }
        image.isTemplate = true
        spacer = (size, image)
        return image
    }
}
