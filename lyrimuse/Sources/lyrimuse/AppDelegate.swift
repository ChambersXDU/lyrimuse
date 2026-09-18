import AppKit
import Combine
import OSLog
import CoreServices
import LyrimuseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Handles `lyrimuse://` URL schemes (e.g. Last.fm authorization callback; see CFBundleURLTypes).
    // Uses `NSAppleEventManager` rather than SwiftUI `.onOpenURL` to ensure reliable delivery
    // without requiring an active WindowGroup scene. Must be registered in `applicationWillFinishLaunching`
    // prior to LaunchServices delivering queued cold-start URL events.
    /// `lyrimuse --unregister-login-item`(scripts/uninstall.sh 在删 App 包之前调):只注销登录项就退出,
    /// 不建窗口、不起服务。见 LoginItemManager.unregisterForUninstall。
    private var isUnregisterLoginItemRun: Bool {
        CommandLine.arguments.contains("--unregister-login-item")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Redirect stdout/stderr to ~/Library/Logs/lyrimuse-app.log early in startup.
        StandardStreamRedirect.installIfNeeded()
        // Install SIGTERM signal handler so terminal launches and process signals log termination reasons.
        AppExit.installSigtermHandler()
        if isUnregisterLoginItemRun {
            LoginItemManager.shared.unregisterForUninstall()
            AppExit.request(.unregisterLoginItemHelper)
            return
        }
        terminateOlderInstances()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// When multiple instances of the app run concurrently, terminates instances strictly older than self.
    ///
    /// LaunchServices single-instance constraints do not prevent duplicate processes if one was launched
    /// directly via LaunchAgent / CLI. Older instances are gracefully terminated first, then force-terminated
    /// after a 3-second grace period to allow cache flushing.
    ///
    /// Process start time must be read via `sysctl` (`kinfo_proc`) rather than `NSRunningApplication.launchDate`,
    /// because `launchDate` is nil for processes spawned directly without LaunchServices.
    private func terminateOlderInstances() {
        let me = NSRunningApplication.current
        guard let myID = me.bundleIdentifier,
              let myStart = Self.processStartTime(getpid()) else { return }
        for other in NSWorkspace.shared.runningApplications
        where other.bundleIdentifier == myID && other.processIdentifier != me.processIdentifier {
            guard let theirStart = Self.processStartTime(other.processIdentifier),
                  theirStart < myStart else { continue }
            // Log via lifecycle subsystem for diagnostic exports.
            AppExit.logTerminatingOlderInstance(pid: other.processIdentifier, forced: false)
            other.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !other.isTerminated {
                    AppExit.logTerminatingOlderInstance(pid: other.processIdentifier, forced: true)
                    other.forceTerminate()
                }
            }
        }
    }

    /// 进程启动时间(Unix 秒),取自内核的 kinfo_proc。任何来路的进程都有,不像
    /// NSRunningApplication.launchDate 只对经 LaunchServices 启动的有效。
    private var cancellables = Set<AnyCancellable>()

    /// Dock 图标右键菜单的自定义部分(设置/歌词管理/歌词窗口/Last.fm 四个跳转)。
    /// 见 DockMenu.swift 顶部注释——跟 applicationDockMenu(_:) 配对使用。
    private let dockMenuController = DockMenuController()

    /// Custom items for the Dock icon context menu (Settings, Lyrics Manager, Lyrics Window, Last.fm).
    /// Items are placed above AppKit's automatic window list and system menu items.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenuController.makeMenu()
    }

    private static func processStartTime(_ pid: pid_t) -> TimeInterval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, UInt32(buf.count), &info, &size, nil, 0)
        }
        guard rc == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString), url.scheme == LyrimuseIdentity.urlScheme else {
            return
        }
        // Routes incoming URLs by host:
        // - `lyrimuse://settings/software-update` opens the Software Update settings pane;
        //   `?check=1` triggers an update check immediately.
        // - `lyrimuse://lastfm-auth-callback` delivers the Last.fm OAuth web callback.
        if url.host == "settings" {
            if url.path == "/software-update" {
                let wantsCheck = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains { $0.name == "check" && $0.value != "0" } ?? false
                if wantsCheck {
                    SparkleUpdaterManager.shared.checkForUpdates()
                } else {
                    SparkleUpdaterManager.shared.showUpdatePage()
                }
            } else {
                AppActions.shared.openSettings?()
            }
            return
        }
        LastfmConnectController.shared.handleAuthCallback()
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        // 卸载辅助模式:willFinishLaunching 里已经请求退出,这里什么都不建。
        if isUnregisterLoginItemRun { return }
        // Initialize login item registration with SMAppService.
        // Also cleans up legacy launchd agent plist if present.
        LoginItemManager.shared.syncAtLaunch(enabled: AppSettings.shared.launchAtLoginEnabled)
        // Restore settings snapshot prior to first access of AppSettings.shared.
        AppSettingsMirror.restoreIfPristine()
        AppSettingsMirror.startObserving()
        AppSettingsMirror.write()
        // 备份文件夹贴上 App 图标(仅在它已经存在时),让它在 Finder 里认得出来。
        ICloudConfigStore.ensureFolderIconIfPresent()
        // Configure generous URLCache memory and disk capacities for cover art and avatars.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        // Prewarm Last.fm metadata images in memory after startup window to avoid placeholder flickers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            _ = LastfmStatsService.shared
        }
        // Configure NSInitialToolTipDelay in app user defaults to 150ms for responsive hover tooltips.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])

        let settings = AppSettings.shared

        // Ensure config directory exists idempotently.
        try? FileManager.default.createDirectory(
            at: LyrimusePaths.configDir,
            withIntermediateDirectories: true)

        // Reconcile background collector launchd job on launch (handles Sparkle/Homebrew updates).
        CollectorServiceManager.reconcileAfterLaunch()

        // Configure app activation policy based on `showInDock` preference:
        // .regular (Dock icon + Cmd-Tab) or .accessory (menu bar only).
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        LocalPlaybackSource.shared.chineseVariant = settings.lyricsChineseVariant
        LocalPlaybackSource.shared.romanizationScripts = settings.romanizationScripts
        // Observe showTranslation preference to update LocalPlaybackSource.
        settings.$showTranslation
            .sink { on in
                MainActor.assumeIsolated { LocalPlaybackSource.shared.showsTranslation = on }
            }
            .store(in: &cancellables)
        BrowserPositionProbe.shared.platformBrowserPairs = settings.browserPlatformPairs
        BrowserAutomationPermission.manuallyAddedFamilies = settings.manualBrowserFamilies
            .compactMapValues { BrowserAutomationPermission.Family(rawValue: $0) }

        // Start playback coordinator and menu bar status item early in the launch sequence.
        // Initializing early favors rightmost placement among contemporaneous login items,
        // while ensuring core playback singletons are populated first.
        PlaybackCoordinator.shared.start()
        MenuBarStatusItem.shared.start()

        // Core 见到中文歌词就会置一个粘性标记;这里把它持久化下来,好让"简繁切换"这一项
        // 在下次启动、还没播中文歌之前就已经该露出来(见 SettingsView 里那个条件)。
        if !settings.hasSeenChineseLyrics {
            LocalPlaybackSource.shared.$sawChineseLyrics
                .filter { $0 }
                .first()
                .sink { _ in AppSettings.shared.hasSeenChineseLyrics = true }
                .store(in: &cancellables)
        }

        // Desktop lyrics overlay and Notch lyrics overlay operate independently.
        // Touch `.shared` only for enabled overlays to prevent constructing unused windows.
        // `setVisible` is omitted here to preserve user-persisted visibility from `init()`.
        if settings.classicOverlayEnabled {
            LyricsOverlayWindowController.shared.setLocked(settings.lockPosition)
            LyricsOverlayWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
            LyricsOverlayWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
        }
        if settings.notchOverlayEnabled {
            // Read `notchHide*` preferences for Notch overlay.
            NotchLyricsWindowController.shared.setHiddenFromCapture(settings.notchHideDuringScreenCapture)
            NotchLyricsWindowController.shared.setHideWhenNotPlaying(settings.notchHideWhenNotPlaying)
        }

        // Media control private channel health check.
        MediaControlHealth.shared.checkInBackground()
        startObservingScreenLock()
        installScrollForwardMonitor()
        startObservingVolumeBannerPreference()
        NotchMirrorManager.start()
        SpaceDiagnostics.start()
        // Register notification categories before posting notifications.
        UnknownPlayerNotifier.shared.registerCategory()
        UnknownPlayerNotifier.shared.start()
        // Install hidden anchor window capturing SwiftUI environment actions.
        MenuBarSceneActions.install()

        // Launch configured companion players if enabled.
        let playersToLaunch = PlayerLinkage.effective(settings.launchPlayersOnLyrimuseOpen,
                                                      selectedPlayers: FeatureSettingsStore.shared.players)
        for player in playersToLaunch where !player.bundleIdentifier.isEmpty {
            let bundleID = player.bundleIdentifier
            if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }),
               let playerURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: playerURL, configuration: config)
            }
        }
        // Observe companion player termination.
        PlayerQuitWatcher.shared.start()

        GlobalHotkeys.registerAll()

        // Initialize SparkleUpdaterManager for automatic background update checks.
        _ = SparkleUpdaterManager.shared
    }

    // 这个 App 没有传统意义上的"主窗口"(内容是菜单栏图标+悬浮歌词窗口+按需打开的
    // 设置/歌词窗口),不实现这个 delegate 方法的话,点 Dock 图标(只在"showInDock"开着、
    // 走 .regular 激活策略时才会有 Dock 图标)完全没有默认行为。
    //
    // Dock icon click handling:
    // 1. Reopening focuses or shows the lyrics window, never reviving dismissed Settings windows.
    // 2. Returns false to prevent AppKit default behavior from restoring hidden SwiftUI Settings scenes.
    // 3. Ignores `hasVisibleWindows` (which is always true due to overlay/notch NSPanels and status items);
    //    queries `AuxiliaryWindowActivation.hasAnyOpen` instead.
    // 4. Manually restores and fronts minimized auxiliary windows via `bringOpenWindowsForward()`.
    // 5. If the app is already frontmost (`wasAlreadyActiveBeforeReopen`), falls through to opening the lyrics window.
    private var isActiveForReopen = false
    private var becameActiveAt = Date.distantPast
    /// 见 applicationShouldHandleReopen —— 延后开歌词窗口的那个任务。
    private var reopenLyricsTask: Task<Void, Never>?
    private let reopenLogger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "reopen")

    func applicationDidBecomeActive(_ notification: Notification) {
        isActiveForReopen = true
        becameActiveAt = Date()
    }

    func applicationDidResignActive(_ notification: Notification) {
        isActiveForReopen = false
    }

    /// 这次 reopen 之前 App 是否早已在前台(而不是被这一下点击激活的)。
    private var wasAlreadyActiveBeforeReopen: Bool {
        isActiveForReopen && Date().timeIntervalSince(becameActiveAt) > 1.0
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // System notification clicks also trigger reopen; suppress lyrics window if notification
        // intends to open settings (tracked via `AppActions.shared.suppressLyricsOnReopenUntil`).
        let aeSender = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?
            .stringValue ?? "(no AE)"
        reopenLogger.notice("reopen: hasVisibleWindows=\(flag, privacy: .public) from=\(aeSender, privacy: .public)")
        if isLyricsOnReopenSuppressed() {
            reopenLogger.notice("reopen: lyrics window suppressed (immediate)")
            return false
        }
        // 设置/歌词管理/歌词窗口/引导四扇里只要还有一扇开着(哪怕被最小化),就把它们带回来——
        // 还原被最小化的、把最前那扇带到前台;只有一扇都没开、或者 App 本来就在前台且开着的
        // 窗口本来就全在最前面(这一下什么都没变)时才落到下面开歌词窗口。理由见上面声明前那段注释。
        if AuxiliaryWindowActivation.hasAnyOpen {
            let wasActive = wasAlreadyActiveBeforeReopen
            let r = AuxiliaryWindowActivation.bringOpenWindowsForward()
            reopenLogger.notice("reopen: auxiliary window(s) open → restored=\(r.restored, privacy: .public) fronted=\(r.fronted, privacy: .public) alreadyFront=\(r.alreadyFront, privacy: .public) wasActive=\(wasActive, privacy: .public)")
            if r.foundNone {
                // 计数器说有窗口开着、枚举却一扇都没找到:按"一扇都没开"处理,别卡在什么都不做上。
                reopenLogger.notice("reopen: counter says open but no window found, falling through to lyrics window")
            } else if r.alreadyFront && wasActive {
                reopenLogger.notice("reopen: app already in front and nothing to bring forward, falling through to lyrics window")
            } else {
                return false
            }
        }
        reopenLyricsTask?.cancel()
        reopenLyricsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            // 第二道:通知回调可能在这 0.3 秒里才把标记设上(reopen 先到的那种顺序)
            if self.isLyricsOnReopenSuppressed() {
                self.reopenLogger.notice("reopen: lyrics window suppressed (deferred)")
                return
            }
            self.reopenLogger.notice("reopen: opening lyrics window")
            AppActions.shared.openLyricsWindow?()
        }
        return false
    }

    private func isLyricsOnReopenSuppressed() -> Bool {
        guard let until = AppActions.shared.suppressLyricsOnReopenUntil else { return false }
        return Date() < until
    }

    // Graceful termination handler:
    // Flushes debounced config changes (ConfigStore) before exiting, using `.terminateLater`
    // to complete asynchronous persistence prior to confirming termination.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppExit.logTermination(sparkleInstalling: SparkleUpdaterManager.shared.isInstallingUpdate)
        guard ConfigStore.shared.isDirty else { return .terminateNow }
        Task {
            _ = await ConfigStore.shared.save()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Scroll Forwarding Fallback

    private var scrollForwardMonitor: Any?

    private func installScrollForwardMonitor() {
        scrollForwardMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                AppDelegate.forwardScrollIfStranded(event)
            }
        }
    }

    // Workaround for AppKit/SwiftUI split-view hit testing anomalies:
    // When scroll wheel events land on a view whose subview hitTest returns nil rather than
    // traversing to the inner NSScrollView, this monitor identifies candidate scroll views:
    // 1. Frame contains mouse location.
    // 2. Visible and non-transparent (alpha > 0.99).
    // 3. Has scrollable content (`documentView` larger than `contentView`).
    // 4. Chooses the innermost candidate with the smallest bounds area.
    private static let scrollForwardLog = Logger(
        subsystem: "me.yudaotor.lyrimuse", category: "scroll-forward")
    private static var lastForwardLogAt = Date.distantPast

    /// 上一次判定的结果,给同一次滚动手势复用。⚠️ 存 `NSScrollView?` 而不是 Bool:
    /// "放行"和"转发给某个具体视图"都要能原样重放。
    private static var lastScrollDecision: (windowNumber: Int, point: CGPoint,
                                            at: Date, target: NSScrollView?)?

    /// 返回值直接交给监听闭包:nil = 我们已代为处理,event = 原样放行。
    private static func forwardScrollIfStranded(_ event: NSEvent) -> NSEvent? {
        guard let win = event.window else { return event }
        let loc = event.locationInWindow
        // Re-use cached target during active gestures to avoid deep recursive SwiftUI hitTest overhead.
        let nowDate = Date()
        if let cached = lastScrollDecision,
           ScrollForwardDecision.canReuse(cachedWindow: cached.windowNumber,
                                          cachedPoint: cached.point, cachedAt: cached.at,
                                          window: win.windowNumber, point: loc, now: nowDate) {
            guard let cachedTarget = cached.target else { return event }
            cachedTarget.scrollWheel(with: event)
            return nil
        }
        let root = win.contentView?.superview ?? win.contentView
        // 命中测试本来就能走进滚动视图 → 正常路径,**绝不插手**。
        var v = root?.hitTest(loc)
        var depth = 0
        while let cur = v, depth < 12 {
            if cur is NSScrollView {
                lastScrollDecision = (win.windowNumber, loc, nowDate, nil)
                return event
            }
            v = cur.superview
            depth += 1
        }
        guard let target = fallbackScrollTarget(in: win, at: loc) else {
            lastScrollDecision = (win.windowNumber, loc, nowDate, nil)
            return event
        }
        lastScrollDecision = (win.windowNumber, loc, nowDate, target)
        let now = Date()
        if now.timeIntervalSince(lastForwardLogAt) > 0.5 {
            lastForwardLogAt = now
            let f = target.convert(target.bounds, to: nil)
            scrollForwardLog.notice("""
                兜底转发 win=\(win.title, privacy: .public) \
                at=(\(Int(loc.x), privacy: .public),\(Int(loc.y), privacy: .public)) \
                → \(String(describing: type(of: target)), privacy: .public)\
                (\(Int(f.minX), privacy: .public),\(Int(f.minY), privacy: .public) \
                \(Int(f.width), privacy: .public)x\(Int(f.height), privacy: .public))
                """)
        }
        target.scrollWheel(with: event)
        return nil
    }

    /// 见上面那段注释里的四条硬条件。
    private static func fallbackScrollTarget(in window: NSWindow, at loc: NSPoint) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        var all: [NSScrollView] = []
        var stack = root.subviews
        while let v = stack.popLast() {
            if let sv = v as? NSScrollView { all.append(sv) }
            stack.append(contentsOf: v.subviews)
        }
        return all
            .filter { sv in
                guard !sv.isHidden, sv.alphaValue > 0.99 else { return false }
                let f = sv.convert(sv.bounds, to: nil)
                guard f.contains(loc), f.width > 1, f.height > 1 else { return false }
                guard let doc = sv.documentView else { return false }
                return doc.bounds.height > sv.contentView.bounds.height + 1
                    || doc.bounds.width > sv.contentView.bounds.width + 1
            }
            .min { a, b in
                let fa = a.convert(a.bounds, to: nil), fb = b.convert(b.bounds, to: nil)
                return fa.width * fa.height < fb.width * fb.height
            }
    }

    /// Pauses/resumes syllable rendering when screen is locked/unlocked.
    /// Uses DistributedNotificationCenter to receive system-wide screen lock notifications.
    private func startObservingScreenLock() {
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            center.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    LocalPlaybackSource.shared.setScreenLocked(locked)
                }
            }
        }
    }

    /// Volume banner follows the Notch overlay preference; active only when Notch overlay is enabled.
    /// Uses the sink closure parameter directly to observe the updated preference value.
    private func startObservingVolumeBannerPreference() {
        AppSettings.shared.$notchOverlayEnabled
            .sink { notchEnabled in
                MainActor.assumeIsolated {
                    VolumeMonitor.apply(enabled: notchEnabled)
                }
            }
            .store(in: &cancellables)
    }
}
