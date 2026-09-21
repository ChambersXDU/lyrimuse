import Foundation

public enum LyrimuseIdentity {
    public struct Resolved: Equatable {

        public let displayName: String

        public let bundleIdentifier: String

        public let configDirName: String
        public let appLogFileName: String

        public let defaultAppBundlePath: String

        public let urlScheme: String

    }

    public static let current = Resolved(
        displayName: "Lyrimuse",
        bundleIdentifier: "me.yudaotor.lyrimuse",
        configDirName: "lyrimuse",
        appLogFileName: "lyrimuse-app.log",
        defaultAppBundlePath: "/Applications/Lyrimuse.app",
        urlScheme: "lyrimuse"
    )

    public static var displayName: String { current.displayName }
    public static var bundleIdentifier: String { current.bundleIdentifier }
    public static var configDirName: String { current.configDirName }
    public static var urlScheme: String { current.urlScheme }
}

public enum LyrimusePaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var configDir: URL { home.appendingPathComponent(".config/\(LyrimuseIdentity.configDirName)") }

    public static func configFile(_ name: String) -> URL { configDir.appendingPathComponent(name) }

    public static var defaultAppBundleURL: URL { URL(fileURLWithPath: LyrimuseIdentity.current.defaultAppBundlePath) }

}

public enum LogFiles {
    private static var logsDir: URL { LyrimusePaths.home.appendingPathComponent("Library/Logs") }

    public static var appStderr: URL { logsDir.appendingPathComponent(LyrimuseIdentity.current.appLogFileName) }
}
