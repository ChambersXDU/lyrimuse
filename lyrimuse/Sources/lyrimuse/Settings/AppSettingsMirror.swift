import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "settings-mirror")

enum AppSettingsMirror {
    static let filename = "lyrimuse-app-settings.json"

    static var fileURL: URL {
        ConfigPortability.configFolderURL.appendingPathComponent(filename)
    }

    private static let debounce: Duration = .seconds(2)

    @MainActor private static var pendingWrite: Task<Void, Never>?

    static func write() {
        let payload = ConfigPortability.exportableAppSettings()
        guard !payload.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: ConfigPortability.configFolderURL, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])

            try data.writeSecurely(to: fileURL)
        } catch {

            logger.error("mirror write failed — \(String(describing: error), privacy: .public)")
        }
    }

    @MainActor
    static func startObserving() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                pendingWrite?.cancel()
                pendingWrite = Task { @MainActor in
                    try? await Task.sleep(for: debounce)
                    guard !Task.isCancelled else { return }
                    write()
                }
            }
        }
    }

    @discardableResult
    static func restoreIfPristine() -> Bool {

        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !dict.isEmpty
        else { return false }

        let applied = ConfigPortability.applyAppSettings(dict)
        logger.notice("restored \(applied) app setting(s) from the config folder mirror")
        return applied > 0
    }

    static func remove() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("removed the app-settings mirror")
        } catch {
            logger.error("removing the mirror failed — \(String(describing: error), privacy: .public)")
        }
    }
}
