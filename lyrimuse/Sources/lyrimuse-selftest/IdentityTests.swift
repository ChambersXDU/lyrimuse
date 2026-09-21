import LyrimuseCore
import Foundation

@MainActor
func runIdentityTests() {
    do {
        print("\n== 身份与路径 ==")
        let id = LyrimuseIdentity.current
        expectEqual(id.displayName, "Lyrimuse")
        expectEqual(id.bundleIdentifier, "me.yudaotor.lyrimuse")
        expectEqual(id.configDirName, "lyrimuse")
        expectEqual(id.appLogFileName, "lyrimuse-app.log")
        expectEqual(id.defaultAppBundlePath, "/Applications/Lyrimuse.app")
        expectEqual(id.urlScheme, "lyrimuse")
        expectEqual(id.appLogFileName, id.configDirName + "-app.log")
        expectEqual(LyrimuseIdentity.displayName, id.displayName)

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        expectEqual(LyrimusePaths.configDir.path, homePath + "/.config/lyrimuse")
        expectEqual(LyrimusePaths.configFile("config.json").path, homePath + "/.config/lyrimuse/config.json")
        expectEqual(LogFiles.appStderr.path, homePath + "/Library/Logs/lyrimuse-app.log")
        expectEqual(LyrimusePaths.defaultAppBundleURL.path, "/Applications/Lyrimuse.app")
    }
}
