import SwiftUI
import LyrimuseCore

struct ConfigFileDamageBanner: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    @State private var busy = false

    var body: some View {
        if config.loadFailure != nil || features.loadFailure != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let reason = config.loadFailure {
                    row(url: ConfigStore.fileURL, reason: reason) {
                        await config.discardCorruptFileAndSave()
                    }
                }
                if let reason = features.loadFailure {
                    row(url: FeatureSettingsStore.fileURL, reason: reason) {
                        await features.discardCorruptFileAndSave()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    @ViewBuilder
    private func row(url: URL, reason: String, discard: @escaping @MainActor () async -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(String(format: L10n.t("配置文件 %@ 无法读取，为避免覆盖，所有保存已暂停"), url.lastPathComponent))
                    .font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                    .environment(\.locale, Locale(identifier: "en"))
            }
            Text(L10n.t("修好文件后重新打开 Lyrimuse；或放弃这份文件，用当前界面上的值重建（原文件会改名保留，不会删除）。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(reason)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            HStack(spacing: 8) {
                Button(L10n.t("在访达中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button(L10n.t("放弃坏文件并重建")) {
                    busy = true
                    Task {
                        _ = await discard()
                        busy = false
                    }
                }
                .disabled(busy)
            }
            .controlSize(.small)
        }
    }
}
