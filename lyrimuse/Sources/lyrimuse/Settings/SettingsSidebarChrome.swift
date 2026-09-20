import AppKit
import Combine
import LyrimuseCore
import SwiftUI

struct LastfmIdentityRow: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var lastfmConnect = LastfmConnectController.shared
    @ObservedObject private var mirrorStatus = LastfmMirrorStatusWatcher.shared
    @ObservedObject private var avatars = LastfmAvatarStore.shared

    @ObservedObject private var languageSettings = AppSettings.shared

    static let avatarSize: CGFloat = 36

    private var connected: Bool { !config.lastfmScrobbleSessionKey.isEmpty }
    private var name: String { lastfmDisplayName(config: config) }

    private var status: DestinationStatus {
        destinationStatus(for: .lastfm, config: config, lastfmConnect: lastfmConnect, mirrorInfo: mirrorStatus.info)
    }

    var body: some View {
        HStack(spacing: 10) {
            avatar
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .overlay(alignment: .topTrailing) {
                    if case .error(let message) = status {
                        SidebarAlertDot()
                            .offset(x: 3, y: -3)
                            .help(message)
                            .accessibilityLabel(message)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(connected && !name.isEmpty ? name : L10n.t("连接 Last.fm"))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(connected ? L10n.t("Last.fm 账户") : L10n.t("同步收听记录"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())

        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var avatar: some View {
        if connected, let image = avatars.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(Circle())
        } else if connected {

            lastfmBadge(size: Self.avatarSize)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(LinearGradient(
                    colors: [Color(nsColor: .systemGray).opacity(0.72), Color(nsColor: .systemGray)],
                    startPoint: .top, endPoint: .bottom))
                Image(systemName: "person.fill")
                    .font(.system(size: Self.avatarSize * 0.5, weight: .medium))
                    .foregroundStyle(.white)
                    .offset(y: 1)
            }
        }
    }
}

private struct SidebarAlertDot: View {
    var body: some View {
        ZStack {
            Circle().fill(.red)
            Text("!")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 14, height: 14)

        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
    }
}

struct SoftwareUpdateSidebarRow: View {
    @ObservedObject private var languageSettings = AppSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.t("有软件更新可用"))
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            SidebarCountBadge(count: 1)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SidebarCountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : String(count))
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(.red))
            .accessibilityHidden(true)
    }
}

@MainActor
final class LastfmAvatarStore: ObservableObject {
    static let shared = LastfmAvatarStore()

    @Published private(set) var image: NSImage?

    private var loadedUser = ""
    private var lastAttempt: Date?
    private var inflight: Task<Void, Never>?
    private var configObserver: AnyCancellable?
    private static let retryInterval: TimeInterval = 600

    private init() {

        configObserver = ConfigStore.shared.objectWillChange
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshFromConfig() }
    }

    func refreshFromConfig() {
        let config = ConfigStore.shared
        let user = config.lastfmScrobbleSessionKey.isEmpty ? "" : lastfmDisplayName(config: config)
        Task { await refresh(user: user) }
    }

    func refresh(user: String) async {
        if user.isEmpty {
            inflight?.cancel()
            inflight = nil
            loadedUser = ""
            image = nil
            return
        }
        if user == loadedUser {
            if image != nil { return }
            if let inflight { await inflight.value; return }
            if let last = lastAttempt, Date().timeIntervalSince(last) < Self.retryInterval { return }
        } else {
            inflight?.cancel()
            image = nil
        }
        loadedUser = user
        lastAttempt = Date()
        let task = Task { [weak self] in
            let fetched = await Self.download(user: user)
            guard !Task.isCancelled, let self, self.loadedUser == user else { return }
            self.image = fetched
        }
        inflight = task
        await task.value
        if inflight == task { inflight = nil }
    }

    private static func download(user: String) async -> NSImage? {
        guard let url = await LastfmStatsService.shared.fetchUserAvatarURL(user: user) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            NetworkAuditLog.record(service: "lastfm", operation: "user.avatar", host: url.host ?? "",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            guard status == 200 else { return nil }
            return NSImage(data: data)
        } catch {
            NetworkAuditLog.record(service: "lastfm", operation: "user.avatar", host: url.host ?? "",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
