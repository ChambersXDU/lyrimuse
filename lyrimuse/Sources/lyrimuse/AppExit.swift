import AppKit
import OSLog

enum AppExit {
    enum Reason: String {
        case menuQuit = "menu_quit"
        case restartAfterConfigChange = "restart_after_config_change"

        case olderInstanceReplaced = "older_instance_replaced"
        case sigterm = "sigterm"
        case externalRequest = "external_request"

        case unregisterLoginItemHelper = "unregister_login_item_helper"
    }

    static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lifecycle")

    @MainActor private static var pendingReason: Reason?
    @MainActor private static var sigtermSource: DispatchSourceSignal?

    @MainActor static func request(_ reason: Reason) {
        pendingReason = reason
        NSApp.terminate(nil)
    }

    @MainActor static func logTermination() {
        let reason = pendingReason ?? .externalRequest
        pendingReason = nil
        logger.notice("exiting reason=\(reason.rawValue, privacy: .public)")
    }

    static func logTerminatingOlderInstance(pid: pid_t, forced: Bool) {
        logger.notice("terminating older instance pid=\(pid, privacy: .public) reason=\(Reason.olderInstanceReplaced.rawValue, privacy: .public) forced=\(forced, privacy: .public)")
    }

    @MainActor static func installSigtermHandler() {

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { request(.sigterm) }
        }
        source.resume()
        sigtermSource = source
    }
}
