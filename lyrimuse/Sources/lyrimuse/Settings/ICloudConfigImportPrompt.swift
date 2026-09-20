import AppKit
import Foundation
import LyrimuseCore

enum ICloudConfigImportPrompt {

    @MainActor
    static func offerIfNeeded(then continuation: @escaping () -> Void) {
        let settings = AppSettings.shared
        guard !settings.hasOfferedICloudImport,
              let snapshot = ICloudConfigStore.latestSnapshot()
        else {
            continuation()
            return
        }

        Task { @MainActor in

            guard let data = await ICloudConfigStore.read(snapshot.url, timeout: 8) else {

                continuation()
                return
            }
            settings.hasOfferedICloudImport = true

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let when = formatter.string(from: snapshot.exportedAt ?? snapshot.modifiedAt)
            let detail: String
            if let device = snapshot.deviceName, !device.isEmpty {
                detail = String(format: L10n.t("导出时间 %1$@，来自 %2$@。"), when, device)
            } else {
                detail = String(format: L10n.t("导出时间 %@。"), when)
            }

            let sidecarURL = snapshot.url.deletingLastPathComponent().appendingPathComponent(
                LyricsBackupArchive.sidecarName(forConfigName: snapshot.url.lastPathComponent))
            let lyricsData = await ICloudConfigStore.read(sidecarURL, timeout: 60)
            let lyricsCount = lyricsData == nil ? 0 : (await LyricsBackupStore.peek(lyricsData!)?.files ?? 0)

            let alert = NSAlert()
            alert.messageText = L10n.t("在 iCloud 里发现一份 Lyrimuse 备份")
            let lyricsLine = lyricsCount > 0
                ? String(format: L10n.t("其中含 %@ 个歌词文件，会一并恢复。"), "\(lyricsCount)")
                : ""
            alert.informativeText = detail + L10n.t("导入会带上账号和所有个人设置，随后重启 Lyrimuse。") + lyricsLine
            alert.addButton(withTitle: L10n.t("导入并重启"))
            alert.addButton(withTitle: L10n.t("跳过"))

            NSApp.activate(ignoringOtherApps: true)

            guard alert.runModal() == .alertFirstButtonReturn else {
                continuation()
                return
            }
            await ConfigPortability.importData(data)

            if let lyricsData {
                await LyricsBackupStore.restore(from: lyricsData)
            }

            ICloudConfigStore.adoptFolder(snapshot.folderURL)
            ConfigPortability.restartApp()
        }
    }
}
