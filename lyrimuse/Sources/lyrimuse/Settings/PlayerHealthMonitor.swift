import AppKit
import Combine
import LyrimuseCore

@MainActor
final class PlayerHealthMonitor: ObservableObject {
    @Published private(set) var warnings: [PlayerHealth.Warning] = []

    var warningText: String? {
        guard !warnings.isEmpty else { return nil }
        return warnings.map(Self.description).joined(separator: "；")
    }

    private var timer: AnyCancellable?
    private var activationObserver: AnyCancellable?
    private var refreshInFlight = false

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }

        activationObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer = nil
        activationObserver = nil
    }

    private func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true

        let appleMusicSelected = FeatureSettingsStore.shared.players.contains(.appleMusic)
        let collectorEnabled = AppSettings.shared.collectorServiceEnabled

        Task { [weak self] in
            let (automationDenied, collectorRunning) = await Task.detached(priority: .utility) {
                (MusicAutomationPermission.check(askIfNeeded: false) == .denied,
                 CollectorServiceManager.isRunning)
            }.value
            guard let self else { return }
            self.refreshInFlight = false
            let latest = PlayerHealth.warnings(.init(
                appleMusicSelected: appleMusicSelected, automationDenied: automationDenied,
                collectorServiceEnabled: collectorEnabled, collectorRunning: collectorRunning))
            if latest != self.warnings { self.warnings = latest }
        }
    }

    static func description(_ warning: PlayerHealth.Warning) -> String {
        switch warning {
        case .automationDenied: return L10n.t("Apple Music 自动化权限被拒，读不到播放状态")
        case .collectorNotRunning: return L10n.t("后台采集服务未运行，歌词不会更新")
        }
    }
}
