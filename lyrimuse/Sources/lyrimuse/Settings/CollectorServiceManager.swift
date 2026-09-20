import Foundation
import LyrimuseCore
import OSLog

public enum CollectorServiceManager {
    public static let label = CollectorControl.label

    private static var bundledCollectorPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/collector").path
    }
    private static var plistURL: URL {
        LyrimusePaths.launchAgentPlist(label: label)
    }
    private static let configDir = LyrimusePaths.configDir

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "collector-service")

    static let installedFingerprintKey = "np:collectorInstalledFingerprint"

    private static let enabledKey = "np:collectorServiceEnabled"

    private static func currentBinaryFingerprint() -> String? {
        let path = bundledCollectorPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return "\(path)|\(size)|\(Int(mtime.timeIntervalSince1970 * 1000))"
    }

    public static func reconcileAfterLaunch() {
        operationQueue.async {

            guard UserDefaults.standard.bool(forKey: enabledKey) else { return }

            let fingerprint = currentBinaryFingerprint()
            let recorded = UserDefaults.standard.string(forKey: installedFingerprintKey)

            let binaryChanged = fingerprint != nil && fingerprint != recorded
            let running = isRunning
            guard binaryChanged || !running else { return }

            logger.notice(
                "collector reconcile on launch: binaryChanged=\(binaryChanged, privacy: .public) running=\(running, privacy: .public) — reinstalling job")
            install()
        }
    }

    private static func recordInstalledFingerprint() {
        if isRunning, let fingerprint = currentBinaryFingerprint() {
            UserDefaults.standard.set(fingerprint, forKey: installedFingerprintKey)
        } else {
            UserDefaults.standard.removeObject(forKey: installedFingerprintKey)
        }
    }

    public static var state: LaunchdJobState {
        let (status, output) = runCapturing("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
        return LaunchdPrintParser.parse(printExitCode: status, printOutput: output)
    }

    public static var isRunning: Bool { state.isRunning }

    public static func bundledCollectorVersion() -> String? {

        let (status, output) = runCapturing(
            bundledCollectorPath, ["version"], environment: LyrimusePaths.collectorProcessEnvironment())
        guard status == 0 else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let operationQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.collector-service-manager", qos: .userInitiated)

    public static func setEnabled(_ enabled: Bool) {
        operationQueue.async {
            if enabled { install() } else { uninstall() }
        }
    }

    @discardableResult
    public static func setEnabledAndWait(_ enabled: Bool) async -> LaunchdJobState {
        await withCheckedContinuation { continuation in
            operationQueue.async {
                if enabled { install() } else { uninstall() }
                continuation.resume(returning: state)
            }
        }
    }

    private static func install() {

        defer { recordInstalledFingerprint() }

        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let logPath = LogFiles.collector.path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [bundledCollectorPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,

            "EnvironmentVariables": LyrimusePaths.collectorEnvironment,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return }
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        guard (try? data.write(to: plistURL)) != nil else { return }
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])

        if waitUntilRunning() { return }

        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
        if waitUntilRunning() { return }

        run("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        _ = waitUntilRunning()
    }

    private static func waitUntilRunning(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return isRunning
    }

    private static func uninstall() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)

        UserDefaults.standard.removeObject(forKey: installedFingerprintKey)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        runCapturing(path, args).status
    }

    private static func runCapturing(
        _ path: String, _ args: [String], environment: [String: String]? = nil
    ) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }
}
