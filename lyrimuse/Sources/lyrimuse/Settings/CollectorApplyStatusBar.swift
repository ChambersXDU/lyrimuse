import SwiftUI

struct CollectorApplyStatusBar: View {
    @ObservedObject private var features = FeatureSettingsStore.shared
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var coordinator = CollectorRestartCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var retrying = false

    private enum Phase: Equatable {
        case failed(String)
        case applying
        case pendingServiceEnable
    }

    private var phase: Phase? {
        if let error = features.lastError ?? config.lastError { return .failed(error) }
        if coordinator.isRestarting { return .applying }
        if (features.pendingUntilServiceEnabled || config.pendingUntilServiceEnabled) && !settings.collectorServiceEnabled {
            return .pendingServiceEnable
        }
        return nil
    }

    var body: some View {
        Group {
            switch phase {
            case .failed(let error):
                strip {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                        .environment(\.locale, Locale(identifier: "en"))
                    Text(error)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L10n.t("重试")) { retry() }
                        .disabled(retrying || coordinator.isRestarting)
                    dismissButton
                }
            case .applying:
                strip {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在应用到后台服务…"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            case .pendingServiceEnable:
                strip {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.secondary)
                    Text(L10n.t("后台采集服务已停用，改动会在下次启用时生效"))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    dismissButton
                }
            case nil:
                EmptyView()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: phase)
    }

    private var dismissButton: some View {
        Button {
            features.clearApplyStatus()
            config.clearApplyStatus()
        } label: {
            Image(systemName: "xmark")
        }
        .accessibilityLabel(L10n.t("关闭"))
    }

    @ViewBuilder
    private func strip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .font(.system(size: 12))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
        .transition(.opacity)
    }

    private func retry() {
        retrying = true
        Task {

            let featuresFailed = features.lastError != nil
            let configFailed = config.lastError != nil
            async let f: Bool = featuresFailed ? features.save() : true
            async let c: Bool = configFailed ? config.save() : true
            _ = await (f, c)
            retrying = false
        }
    }
}
