import Foundation

public enum LyrimuseIdentity {
    public struct Resolved: Equatable {

        public let displayName: String

        public let bundleIdentifier: String

        public let configDirName: String
        public let collectorLaunchdLabel: String

        public let logFileName: String

        public let appLogFileName: String

        public let defaultAppBundlePath: String

        public let urlScheme: String

        public var appLaunchdLabel: String { bundleIdentifier }
    }

    public static let current = Resolved(
        displayName: "Lyrimuse",
        bundleIdentifier: "me.yudaotor.lyrimuse",
        configDirName: "lyrimuse",
        collectorLaunchdLabel: "com.lyrimuse.collector",
        logFileName: "lyrimuse.log",
        appLogFileName: "lyrimuse-app.log",
        defaultAppBundlePath: "/Applications/Lyrimuse.app",
        urlScheme: "lyrimuse"
    )

    public static var displayName: String { current.displayName }
    public static var bundleIdentifier: String { current.bundleIdentifier }
    public static var configDirName: String { current.configDirName }
    public static var collectorLaunchdLabel: String { current.collectorLaunchdLabel }
    public static var appLaunchdLabel: String { current.appLaunchdLabel }
    public static var urlScheme: String { current.urlScheme }
}

public enum LyrimusePaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var configDir: URL { home.appendingPathComponent(".config/\(LyrimuseIdentity.configDirName)") }

    public static func configFile(_ name: String) -> URL { configDir.appendingPathComponent(name) }

    public static var launchAgentsDir: URL { home.appendingPathComponent("Library/LaunchAgents") }
    public static func launchAgentPlist(label: String) -> URL { launchAgentsDir.appendingPathComponent("\(label).plist") }

    public static var defaultAppBundleURL: URL { URL(fileURLWithPath: LyrimuseIdentity.current.defaultAppBundlePath) }

    public static var collectorEnvironment: [String: String] {
        [
            "LYRIMUSE_CONFIG_DIR": configDir.path,
            "LYRIMUSE_LOG_FILE": LogFiles.collector.path,

            "LYRIMUSE_APP_BUNDLE_ID": LyrimuseIdentity.bundleIdentifier,
        ]
    }

    public static func collectorProcessEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for (key, value) in collectorEnvironment { env[key] = value }
        return env
    }
}

public enum LogFiles {
    private static var logsDir: URL { LyrimusePaths.home.appendingPathComponent("Library/Logs") }

    public static var collector: URL { logsDir.appendingPathComponent(LyrimuseIdentity.current.logFileName) }

    public static var appStderr: URL { logsDir.appendingPathComponent(LyrimuseIdentity.current.appLogFileName) }
}
