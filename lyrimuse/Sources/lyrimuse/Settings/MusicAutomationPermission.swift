import AppKit
import CoreServices
import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "automation-permission")

enum MusicAutomationPermissionStatus {
    case authorized
    case denied
    case notDetermined

    var isAuthorized: Bool { self == .authorized }
}

enum MusicAutomationPermission {
    private static let musicBundleID = MusicPlaybackController.appleMusicBundleIdentifier

    @discardableResult
    static func check(askIfNeeded: Bool) -> MusicAutomationPermissionStatus {
        check(bundleID: musicBundleID, askIfNeeded: askIfNeeded)
    }

    @discardableResult
    static func check(bundleID: String, askIfNeeded: Bool) -> MusicAutomationPermissionStatus {
        var target = AEAddressDesc()
        let bundleIDBytes = Array(bundleID.utf8)
        guard AECreateDesc(
            DescType(typeApplicationBundleID),
            bundleIDBytes,
            bundleIDBytes.count,
            &target
        ) == noErr else {
            return .notDetermined
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askIfNeeded
        )
        switch status {
        case noErr:
            return .authorized
        case OSStatus(errAEEventNotPermitted):
            return .denied
        default:

            return .notDetermined
        }
    }

    static var systemSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    }

    @MainActor
    static func checkForCurrentPlayerSafely(askIfNeeded: Bool) async -> Bool {
        return await checkAppleMusicSafely(askIfNeeded: askIfNeeded)
    }

    static func checkAppleMusicSafely(askIfNeeded: Bool) async -> Bool {
        let current = check(askIfNeeded: false)
        if current != .notDetermined { return current.isAuthorized }
        guard askIfNeeded else { return false }
        let result = await requestWithTimeout(launchMusicAppIfNeeded: false)
        return result?.isAuthorized ?? false
    }

    static func requestWithTimeout(seconds: Double = 8, launchMusicAppIfNeeded: Bool = true) async -> MusicAutomationPermissionStatus? {
        await requestWithTimeout(bundleID: musicBundleID, seconds: seconds,
                                 launchIfNeeded: launchMusicAppIfNeeded)
    }

    static func requestWithTimeout(bundleID: String, seconds: Double = 8,
                                   launchIfNeeded: Bool = true) async -> MusicAutomationPermissionStatus? {

        if launchIfNeeded {
            await ensureAppRunning(bundleID: bundleID)
        }
        return await withTaskGroup(of: MusicAutomationPermissionStatus?.self) { group in
            group.addTask { check(bundleID: bundleID, askIfNeeded: true) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    static func ensureMusicAppRunning() async {
        await ensureAppRunning(bundleID: musicBundleID)
    }

    static func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    static func ensureAppRunning(bundleID: String) async {
        guard !isRunning(bundleID: bundleID) else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.error("cannot resolve app URL by bundle id, skip pre-launch")
            return
        }
        logger.notice("target app not running, launching in background before requesting automation permission")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            logger.error("failed to launch app before permission request: \(error.localizedDescription, privacy: .public)")
        }
    }
}
