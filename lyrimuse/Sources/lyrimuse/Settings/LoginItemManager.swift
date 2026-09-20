import LyrimuseCore
import Foundation
import OSLog
import ServiceManagement

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "login-item")

@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    private var legacyPlistURL: URL {
        LyrimusePaths.launchAgentPlist(label: LyrimuseIdentity.appLaunchdLabel)
    }

    private init() {}

    var status: SMAppService.Status { SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        removeLegacyLaunchAgentPlist()
        if enabled {
            register()

            if status == .requiresApproval {
                logger.notice("login item requires approval in System Settings; opening the pane")
                SMAppService.openSystemSettingsLoginItems()
            }
        } else {
            unregister()
        }
    }

    func syncAtLaunch(enabled: Bool) {
        removeLegacyLaunchAgentPlist()
        guard enabled else { return }
        register()
    }

    func unregisterForUninstall() {
        removeLegacyLaunchAgentPlist()
        unregister()
    }

    private func register() {
        do {
            try SMAppService.mainApp.register()
            logger.notice("login item registered status=\(String(describing: self.status), privacy: .public)")
        } catch {

            logger.error("login item register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            logger.notice("login item unregistered")
        } catch {

            logger.notice("login item unregister: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeLegacyLaunchAgentPlist() {
        let url = legacyPlistURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            logger.notice("removed legacy LaunchAgent plist \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("failed to remove legacy LaunchAgent plist: \(error.localizedDescription, privacy: .public)")
        }
    }
}
