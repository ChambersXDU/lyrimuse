import AppKit
import LyrimuseCore
import OSLog
import UserNotifications

@MainActor
final class UnknownPlayerNotifier: NSObject {
    static let shared = UnknownPlayerNotifier()

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")

    static let categoryID = "unknown-player"
    static let trustActionID = "unknown-player.trust"

    static let bundleIDKey = "bundleID"

    private static let logKey = "np:unknownPlayerNotices"

    private var pendingBundleID: String?
    private var pendingSince: Date?
    private var pendingHits = 0

    private var timer: Timer?
    private var askedAuthorization = false

    func registerCategory() {

        let trust = UNNotificationAction(
            identifier: Self.trustActionID, title: L10n.t("加入信任列表"),
            options: [.authenticationRequired])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [trust],
            intentIdentifiers: [], options: [])
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([category])
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 1
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    private func tick() {
        let prompt = NotchUnknownPlayerPrompt.shared
        guard let seen = MediaControlClient.lastUngatedNowPlaying else {
            resetPending(); prompt.update(offer: nil); return
        }
        let features = FeatureSettingsStore.shared

        guard UnknownPlayerAlert.shouldOffer(
            bundleID: seen.bundleID, artist: seen.artist, album: seen.album,
            observedAt: seen.at, isAutoDetect: features.players.contains(.auto), now: Date(),
            isAccepted: { TrustedPlayers.isAccepted($0) })
        else { resetPending(); prompt.update(offer: nil); return }

        if pendingBundleID != seen.bundleID {
            pendingBundleID = seen.bundleID
            pendingSince = Date()
            pendingHits = 0
        }
        pendingHits += 1
        let stableFor = pendingSince.map { Date().timeIntervalSince($0) } ?? 0
        let displayName = FeatureSettingsStore.appDisplayName(forBundleID: seen.bundleID)

        let qualifies = UnknownPlayerAlert.qualifiesForAnnounce(
            bundleID: seen.bundleID, artist: seen.artist, album: seen.album,
            observedAt: seen.at, isAutoDetect: true, now: Date(),
            isAccepted: { TrustedPlayers.isAccepted($0) },
            hasDisplayName: displayName != nil, stableFor: stableFor, stableHits: pendingHits)
        if qualifies, AppSettings.shared.notchOverlayEnabled {
            prompt.update(offer: .init(
                bundleID: seen.bundleID, displayName: displayName ?? seen.bundleID,
                nowPlayingText: UnknownPlayerAlert.nowPlayingDescription(artist: seen.artist, title: seen.title)
                    ?? seen.bundleID))
        } else {
            prompt.update(offer: nil)
        }

        guard UnknownPlayerAlert.shouldAnnounce(
            bundleID: seen.bundleID, artist: seen.artist, album: seen.album,
            observedAt: seen.at, isAutoDetect: true, now: Date(),
            isAccepted: { TrustedPlayers.isAccepted($0) },
            hasDisplayName: displayName != nil,
            stableFor: stableFor, stableHits: pendingHits, log: loadLog())
        else { return }

        Task { await announce(seen) }
    }

    private func resetPending() {
        pendingBundleID = nil
        pendingSince = nil
        pendingHits = 0
    }

    private func announce(_ seen: MediaControlClient.UngatedNowPlaying) async {
        let alerted = NotchUnknownPlayerPrompt.shared.alert()
        let notified = await deliverNotification(seen)
        if alerted || notified { recordAnnounced(seen.bundleID) }
    }

    private func deliverNotification(_ seen: MediaControlClient.UngatedNowPlaying) async -> Bool {
        guard await ensureAuthorized() else { return false }

        guard !TrustedPlayers.isAccepted(seen.bundleID) else { return false }
        let name = FeatureSettingsStore.appDisplayName(forBundleID: seen.bundleID) ?? seen.bundleID
        let what = UnknownPlayerAlert.nowPlayingDescription(artist: seen.artist, title: seen.title)

        let content = UNMutableNotificationContent()
        content.title = L10n.t("检测到新的播放器")
        content.subtitle = name
        content.body = what.map { String(format: L10n.t("正在放：%@"), $0) } ?? seen.bundleID
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.bundleIDKey: seen.bundleID]

        content.threadIdentifier = Self.categoryID
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(Self.categoryID).\(seen.bundleID)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.notice("announced unknown player \(seen.bundleID, privacy: .public)")
            return true
        } catch {
            log.error("announce failed for \(seen.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            guard !askedAuthorization else { return false }
            askedAuthorization = true
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.notice("notification authorization granted=\(granted, privacy: .public)")
                return granted
            } catch {
                log.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        default:

            log.notice("notification not authorized (status=\(settings.authorizationStatus.rawValue, privacy: .public))")
            return false
        }
    }

    func dismissDelivered(bundleID: String) {
        let id = "\(Self.categoryID).\(bundleID)"
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func loadLog() -> [String: UnknownPlayerAlert.AnnounceLog] {
        guard let raw = UserDefaults.standard.string(forKey: Self.logKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                [String: UnknownPlayerAlert.AnnounceLog].self, from: data)
        else { return [:] }
        return decoded
    }

    private func recordAnnounced(_ bundleID: String) {
        var log = loadLog()
        let previous = log[bundleID]?.count ?? 0
        log[bundleID] = .init(count: previous + 1, lastAt: Date())

        guard let data = try? JSONEncoder().encode(log),
              let text = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(text, forKey: Self.logKey)
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

extension UnknownPlayerNotifier: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
            .notice("willPresent fired")
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
            .notice("didReceive action=\(response.actionIdentifier, privacy: .public)")

        await MainActor.run {
            AppActions.shared.suppressLyricsOnReopenUntil = Date().addingTimeInterval(2)
            Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
                .notice("suppress-lyrics flag set")
        }
        let info = response.notification.request.content.userInfo
        guard let bundleID = info[Self.bundleIDKey] as? String, !bundleID.isEmpty else { return }
        switch response.actionIdentifier {
        case Self.trustActionID:
            await Self.trust(bundleID)
        case UNNotificationDefaultActionIdentifier:

            await MainActor.run {
                AppActions.shared.requestSettings(.tab(.player))
                NSApp.activate(ignoringOtherApps: true)
                AppActions.shared.openSettings?()
            }
        default:
            break
        }
    }

    static func trust(_ bundleID: String) async {

        guard !TrustedPlayers.isAccepted(bundleID) else { return }
        await FeatureSettingsStore.shared.trust(bundleID: bundleID)
        await MainActor.run { UnknownPlayerNotifier.shared.dismissDelivered(bundleID: bundleID) }
    }
}
