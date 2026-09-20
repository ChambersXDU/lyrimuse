import AppKit
import Combine
import OSLog
import CoreServices
import LyrimuseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var isUnregisterLoginItemRun: Bool {
        CommandLine.arguments.contains("--unregister-login-item")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {

        StandardStreamRedirect.installIfNeeded()

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

    private func terminateOlderInstances() {
        let me = NSRunningApplication.current
        guard let myID = me.bundleIdentifier,
              let myStart = Self.processStartTime(getpid()) else { return }
        for other in NSWorkspace.shared.runningApplications
        where other.bundleIdentifier == myID && other.processIdentifier != me.processIdentifier {
            guard let theirStart = Self.processStartTime(other.processIdentifier),
                  theirStart < myStart else { continue }

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

    private var cancellables = Set<AnyCancellable>()

    private let dockMenuController = DockMenuController()

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

        if url.host == "settings" {
            AppActions.shared.openSettings?()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        if isUnregisterLoginItemRun { return }

        LoginItemManager.shared.syncAtLaunch(enabled: AppSettings.shared.launchAtLoginEnabled)

        AppSettingsMirror.restoreIfPristine()
        AppSettingsMirror.startObserving()
        AppSettingsMirror.write()

        ICloudConfigStore.ensureFolderIconIfPresent()

        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])

        let settings = AppSettings.shared

        try? FileManager.default.createDirectory(
            at: LyrimusePaths.configDir,
            withIntermediateDirectories: true)

        CollectorServiceManager.reconcileAfterLaunch()

        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        LocalPlaybackSource.shared.chineseVariant = settings.lyricsChineseVariant
        LocalPlaybackSource.shared.romanizationScripts = settings.romanizationScripts

        settings.$showTranslation
            .sink { on in
                MainActor.assumeIsolated { LocalPlaybackSource.shared.showsTranslation = on }
            }
            .store(in: &cancellables)
        BrowserPositionProbe.shared.platformBrowserPairs = settings.browserPlatformPairs
        BrowserAutomationPermission.manuallyAddedFamilies = settings.manualBrowserFamilies
            .compactMapValues { BrowserAutomationPermission.Family(rawValue: $0) }

        PlaybackCoordinator.shared.start()
        MenuBarStatusItem.shared.start()

        if !settings.hasSeenChineseLyrics {
            LocalPlaybackSource.shared.$sawChineseLyrics
                .filter { $0 }
                .first()
                .sink { _ in AppSettings.shared.hasSeenChineseLyrics = true }
                .store(in: &cancellables)
        }

        if settings.classicOverlayEnabled {
            LyricsOverlayWindowController.shared.setLocked(settings.lockPosition)
            LyricsOverlayWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
            LyricsOverlayWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
        }
        MediaControlHealth.shared.checkInBackground()
        startObservingScreenLock()
        installScrollForwardMonitor()
        SpaceDiagnostics.start()

        UnknownPlayerNotifier.shared.registerCategory()
        UnknownPlayerNotifier.shared.start()

        MenuBarSceneActions.install()

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

        PlayerQuitWatcher.shared.start()

        GlobalHotkeys.registerAll()

    }

    private var isActiveForReopen = false
    private var becameActiveAt = Date.distantPast

    private let reopenLogger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "reopen")

    func applicationDidBecomeActive(_ notification: Notification) {
        isActiveForReopen = true
        becameActiveAt = Date()
    }

    func applicationDidResignActive(_ notification: Notification) {
        isActiveForReopen = false
    }

    private var wasAlreadyActiveBeforeReopen: Bool {
        isActiveForReopen && Date().timeIntervalSince(becameActiveAt) > 1.0
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {

        let aeSender = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?
            .stringValue ?? "(no AE)"
        reopenLogger.notice("reopen: hasVisibleWindows=\(flag, privacy: .public) from=\(aeSender, privacy: .public)")
        if AuxiliaryWindowActivation.hasAnyOpen {
            let wasActive = wasAlreadyActiveBeforeReopen
            let r = AuxiliaryWindowActivation.bringOpenWindowsForward()
            reopenLogger.notice("reopen: auxiliary window(s) open → restored=\(r.restored, privacy: .public) fronted=\(r.fronted, privacy: .public) alreadyFront=\(r.alreadyFront, privacy: .public) wasActive=\(wasActive, privacy: .public)")
            if r.foundNone {

                reopenLogger.notice("reopen: counter says open but no window found")
            } else if r.alreadyFront && wasActive {
                reopenLogger.notice("reopen: app already in front and nothing to bring forward")
            } else {
                return false
            }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppExit.logTermination()
        guard ConfigStore.shared.isDirty else { return .terminateNow }
        Task {
            _ = await ConfigStore.shared.save()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private var scrollForwardMonitor: Any?

    private func installScrollForwardMonitor() {
        scrollForwardMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                AppDelegate.forwardScrollIfStranded(event)
            }
        }
    }

    private static let scrollForwardLog = Logger(
        subsystem: "me.yudaotor.lyrimuse", category: "scroll-forward")
    private static var lastForwardLogAt = Date.distantPast

    private static var lastScrollDecision: (windowNumber: Int, point: CGPoint,
                                            at: Date, target: NSScrollView?)?

    private static func forwardScrollIfStranded(_ event: NSEvent) -> NSEvent? {
        guard let win = event.window else { return event }
        let loc = event.locationInWindow

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

}
