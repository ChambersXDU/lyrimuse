import AppKit
import LyrimuseCore

@MainActor
final class PlayerQuitWatcher {
    static let shared = PlayerQuitWatcher()

    private var observers: [NSObjectProtocol] = []
    private var pendingQuit: DispatchWorkItem?

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let bundleID = Self.bundleID(from: note) else { return }
            MainActor.assumeIsolated { self?.playerTerminated(bundleID) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let bundleID = Self.bundleID(from: note) else { return }
            MainActor.assumeIsolated { self?.playerLaunched(bundleID) }
        })
    }

    private static func bundleID(from note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    private var boundBundleIDs: Set<String> {
        let bound = PlayerLinkage.effective(AppSettings.shared.quitWithPlayers,
                                            selectedPlayers: FeatureSettingsStore.shared.players)
        return Set(bound.map(\.bundleIdentifier)).subtracting([""])
    }

    private static var runningBundleIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private func playerTerminated(_ bundleID: String) {
        guard PlayerLinkage.shouldQuit(terminatedBundleID: bundleID,
                                       boundBundleIDs: boundBundleIDs,
                                       runningBundleIDs: Self.runningBundleIDs) else { return }
        pendingQuit?.cancel()
        AppExit.logger.notice("followed player quit bundle=\(bundleID, privacy: .public) grace=\(PlayerLinkage.quitGraceSeconds, privacy: .public)s")
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fireIfStillDue() }
        }
        pendingQuit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerLinkage.quitGraceSeconds, execute: work)
    }

    private func playerLaunched(_ bundleID: String) {
        guard pendingQuit != nil, boundBundleIDs.contains(bundleID) else { return }
        pendingQuit?.cancel()
        pendingQuit = nil
        AppExit.logger.notice("followed player relaunched bundle=\(bundleID, privacy: .public); quit cancelled")
    }

    private func fireIfStillDue() {
        pendingQuit = nil
        let bound = boundBundleIDs

        guard !bound.isEmpty, bound.isDisjoint(with: Self.runningBundleIDs) else { return }
        if Self.userIsUsingLyrimuseWindows {
            AppExit.logger.notice("followed player quit skipped: a Lyrimuse window is open")
            return
        }
        AppExit.request(.followedPlayerQuit)
    }

    private static var userIsUsingLyrimuseWindows: Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.canBecomeKey
                && !(window is LyricsOverlayWindow)
        }
    }
}
