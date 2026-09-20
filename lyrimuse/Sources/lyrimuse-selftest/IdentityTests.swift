import LyrimuseCore
import Foundation

@MainActor
func runIdentityTests() {
    do {
        print("\n== 身份与路径 ==")
        let id = LyrimuseIdentity.current
        expectEqual(id.displayName, "Lyrimuse")
        expectEqual(id.bundleIdentifier, "me.yudaotor.lyrimuse")
        expectEqual(id.appLaunchdLabel, id.bundleIdentifier)
        expectEqual(id.configDirName, "lyrimuse")
        expectEqual(id.collectorLaunchdLabel, "com.lyrimuse.collector")
        expectEqual(id.logFileName, "lyrimuse.log")
        expectEqual(id.appLogFileName, "lyrimuse-app.log")
        expectEqual(id.defaultAppBundlePath, "/Applications/Lyrimuse.app")
        expectEqual(id.urlScheme, "lyrimuse")
        expectEqual(id.logFileName, id.configDirName + ".log")
        expectEqual(id.appLogFileName, id.configDirName + "-app.log")
        expectEqual(LyrimuseIdentity.displayName, id.displayName)
        expectEqual(LyrimuseIdentity.collectorLaunchdLabel, id.collectorLaunchdLabel)

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        expectEqual(LyrimusePaths.configDir.path, homePath + "/.config/lyrimuse")
        expectEqual(LyrimusePaths.configFile("config.json").path, homePath + "/.config/lyrimuse/config.json")
        expectEqual(LogFiles.collector.path, homePath + "/Library/Logs/lyrimuse.log")
        expectEqual(LogFiles.appStderr.path, homePath + "/Library/Logs/lyrimuse-app.log")
        expectEqual(LyrimusePaths.launchAgentPlist(label: "x.y").path, homePath + "/Library/LaunchAgents/x.y.plist")
        expectEqual(LyrimusePaths.defaultAppBundleURL.path, "/Applications/Lyrimuse.app")

        let env = LyrimusePaths.collectorEnvironment
        expectEqual(env["LYRIMUSE_CONFIG_DIR"], LyrimusePaths.configDir.path)
        expectEqual(env["LYRIMUSE_LOG_FILE"], LogFiles.collector.path)
        expectEqual(env["LYRIMUSE_APP_BUNDLE_ID"], LyrimuseIdentity.bundleIdentifier)
        expectEqual(env.count, 3)
        let merged = LyrimusePaths.collectorProcessEnvironment(base: ["PATH": "/usr/bin", "LYRIMUSE_CONFIG_DIR": "/stale"])
        expectEqual(merged["PATH"], "/usr/bin")
        expectEqual(merged["LYRIMUSE_CONFIG_DIR"], LyrimusePaths.configDir.path)
        expectEqual(merged.count, 4)
    }
}
