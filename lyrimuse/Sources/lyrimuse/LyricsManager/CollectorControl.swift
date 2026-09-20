import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "collector-control")

public enum CollectorControl {

    public static let label = LyrimuseIdentity.collectorLaunchdLabel

    private static let restartConfirmTimeout: TimeInterval = 3
    private static let restartPollInterval: TimeInterval = 0.15

    @discardableResult
    public static func restartAndWait() -> Bool {

        var previousPid: Int32?
        if case .running(let pid) = CollectorServiceManager.state { previousPid = pid }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("launchctl kickstart failed to launch: \(String(describing: error), privacy: .public)")
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logger.error("launchctl kickstart exited with status \(process.terminationStatus)")
            return false
        }

        let deadline = Date().addingTimeInterval(restartConfirmTimeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: restartPollInterval)
            let state = CollectorServiceManager.state
            if case .running(let pid) = state {

                if let previousPid, pid == previousPid { continue }
                logger.info("collector restarted and confirmed running (pid \(pid))")
                return true
            }
        }

        logger.error("collector did not come back after kickstart — state=\(String(describing: CollectorServiceManager.state), privacy: .public)")
        return false
    }

    public static func restartAndWaitAsync() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            restartAndWait()
        }.value
    }
}
