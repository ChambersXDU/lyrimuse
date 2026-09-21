import LyrimuseCore
import Foundation
import OSLog
import ServiceManagement

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "login-item")

@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    private init() {}

    var status: SMAppService.Status { SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
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
        guard enabled else { return }
        register()
    }

    func unregisterForUninstall() {
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

}
