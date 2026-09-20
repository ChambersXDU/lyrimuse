import AppKit
import LyrimuseCore
import OSLog
import Sparkle

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "updates")

enum SoftwareUpdateFlow: Equatable {
    case idle
    case checking

    case downloading(received: UInt64, expected: UInt64?)
    case extracting(progress: Double)
    case readyToInstall
    case installing(applicationTerminated: Bool)
    case failed(message: String)

    var isBusyInBackground: Bool {
        switch self {
        case .downloading, .extracting, .installing: return true
        case .idle, .checking, .readyToInstall, .failed: return false
        }
    }
}

struct SoftwareUpdateItem: Equatable {
    let version: String

    let contentLength: UInt64
    let date: Date?

    var notesHTML: String?

    var notesArePlainText: Bool

    let releaseURL: URL

    var downloaded: Bool

    init(appcastItem item: SUAppcastItem, downloaded: Bool) {
        version = item.displayVersionString
        contentLength = item.contentLength
        date = item.date
        notesHTML = item.itemDescription
        notesArePlainText = item.itemDescriptionFormat == "plain-text"
        releaseURL = item.fullReleaseNotesURL ?? item.infoURL
            ?? UpdateChannel.releasePageURL(displayVersion: item.displayVersionString)
        self.downloaded = downloaded
    }

    init(version: String, contentLength: UInt64, date: Date?, notesHTML: String?, notesArePlainText: Bool,
         releaseURL: URL, downloaded: Bool) {
        self.version = version
        self.contentLength = contentLength
        self.date = date
        self.notesHTML = notesHTML
        self.notesArePlainText = notesArePlainText
        self.releaseURL = releaseURL
        self.downloaded = downloaded
    }

    static func preview(version: String) -> SoftwareUpdateItem {
        SoftwareUpdateItem(version: version, contentLength: 12_800_000, date: Date(),
                           notesHTML: "<p>" + L10n.t("这是预览：真有新版本时这里显示发版日志") + "</p>",
                           notesArePlainText: false,
                           releaseURL: UpdateChannel.releasePageURL(displayVersion: version), downloaded: false)
    }
}

@MainActor
final class SparkleUpdaterManager: ObservableObject {
    static let shared = SparkleUpdaterManager()

    struct AvailableUpdate: Equatable {
        let version: String

        var downloaded: Bool
    }
    @Published private(set) var availableUpdate: AvailableUpdate?

    @Published private(set) var flow: SoftwareUpdateFlow = .idle

    @Published private(set) var pendingItem: SoftwareUpdateItem?

    @Published private(set) var installOnQuit = false

    @Published private(set) var updatedToVersion: String?

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    static let previewUpdateVersionKey = "settings:previewUpdateVersion"

    private var previewItem: SoftwareUpdateItem? {
        guard let version = UserDefaults.standard.string(forKey: Self.previewUpdateVersionKey),
              !version.isEmpty else { return nil }
        return SoftwareUpdateItem.preview(version: version)
    }

    var shownItem: SoftwareUpdateItem? { previewItem ?? pendingItem }

    private enum PageIntent { case none, check, install }
    private var pageIntent: PageIntent = .none

    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var cancelCheck: (() -> Void)?
    private var cancelDownload: (() -> Void)?
    private var retryTerminating: (() -> Void)?

    func installPendingUpdate() {
        if let reply = foundReply {
            foundReply = nil
            flow = pendingItem?.downloaded == true ? .readyToInstall : .downloading(received: 0, expected: nil)
            reply(.install)
            return
        }
        if let reply = readyReply {
            readyReply = nil
            reply(.install)
            return
        }
        guard canCheckForUpdates else { return }
        pageIntent = .install
        flow = .checking
        startCheck()
    }

    func installOnQuitInstead() {
        guard let reply = readyReply else { return }
        readyReply = nil
        installOnQuit = true
        flow = .idle
        reply(.dismiss)
    }

    func cancel() {
        switch flow {
        case .checking:
            cancelCheck?()
            cancelCheck = nil
            pageIntent = .none
            flow = .idle
        case .downloading:
            cancelDownload?()
            cancelDownload = nil

            flow = .idle
        default:
            break
        }
    }

    func retryTerminatingForInstall() {
        retryTerminating?()
    }

    func settingsWindowClosed() {
        if let reply = foundReply {
            foundReply = nil
            reply(.dismiss)
        }
        if let reply = readyReply {
            readyReply = nil
            installOnQuit = true
            reply(.dismiss)
        }
        if case .checking = flow {
            cancelCheck?()
            cancelCheck = nil
            pageIntent = .none
        }
        if flow != .idle, !flow.isBusyInBackground { flow = .idle }
    }

    func showUpdatePage() {
        AppActions.shared.requestSettings(.softwareUpdate)
        AppActions.shared.openSettings?()
    }

    private func clearSessionClosures() {
        foundReply = nil
        readyReply = nil
        cancelCheck = nil
        cancelDownload = nil
        retryTerminating = nil
    }

    private func handleDriver(_ event: SoftwareUpdateDriver.Event) {
        switch event {
        case .permissionRequest(let reply):

            reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticallyChecksForUpdates, sendSystemProfile: false))
        case .userInitiatedCheck(let cancel):
            cancelCheck = cancel
            flow = .checking
        case .found(let item, let state, let reply):
            cancelCheck = nil
            let downloaded = state.stage != .notDownloaded
            var next = SoftwareUpdateItem(appcastItem: item, downloaded: downloaded)

            if next.notesHTML == nil, let kept = pendingItem, kept.version == next.version {
                next.notesHTML = kept.notesHTML
                next.notesArePlainText = kept.notesArePlainText
            }
            pendingItem = next
            updatedToVersion = nil
            switch pageIntent {
            case .install:
                pageIntent = .none
                flow = downloaded ? .readyToInstall : .downloading(received: 0, expected: nil)
                reply(.install)
            case .check:
                pageIntent = .none
                flow = .idle

                foundReply = reply
            case .none:

                flow = .idle
                if downloaded { installOnQuit = true }
                reply(.dismiss)
            }
        case .releaseNotes(let download):
            guard var item = pendingItem else { return }
            let encoding = Self.encoding(ianaName: download.textEncodingName)
            item.notesHTML = String(data: download.data, encoding: encoding) ?? String(decoding: download.data, as: UTF8.self)
            item.notesArePlainText = (download.mimeType ?? "").hasPrefix("text/plain")
            pendingItem = item
        case .releaseNotesFailed(let error):
            logger.notice("release notes download failed: \(error.localizedDescription, privacy: .public)")
        case .notFound(_, let acknowledge):
            cancelCheck = nil
            foundReply = nil
            pageIntent = .none
            pendingItem = nil
            installOnQuit = false
            flow = .idle
            acknowledge()
        case .failed(let error, let acknowledge):
            clearSessionClosures()
            pageIntent = .none
            flow = .failed(message: error.localizedDescription)
            acknowledge()
        case .downloadStarted(let cancel):
            cancelDownload = cancel
            flow = .downloading(received: 0, expected: nil)
        case .downloadExpectedLength(let expected):
            if case .downloading(let received, _) = flow {
                flow = .downloading(received: received, expected: expected)
            } else {
                flow = .downloading(received: 0, expected: expected)
            }
        case .downloadReceived(let length):
            if case .downloading(let received, let expected) = flow {
                flow = .downloading(received: received + length, expected: expected)
            }
        case .extractionStarted:
            cancelDownload = nil
            flow = .extracting(progress: 0)
        case .extractionProgress(let progress):
            flow = .extracting(progress: progress)
        case .readyToInstall(let reply):
            readyReply = reply
            pendingItem?.downloaded = true
            installOnQuit = false
            flow = .readyToInstall
        case .installing(let applicationTerminated, let retry):
            retryTerminating = retry
            isInstallingUpdate = true
            flow = .installing(applicationTerminated: applicationTerminated)
        case .installedAndRelaunched(_, let acknowledge):

            updatedToVersion = Self.appVersionString
            pendingItem = nil
            installOnQuit = false
            flow = .idle
            acknowledge()
        case .dismissed:
            clearSessionClosures()
            if case .installing = flow { return }
            flow = .idle
        case .focusRequested:
            showUpdatePage()
        }
    }

    private static func encoding(ianaName: String?) -> String.Encoding {
        guard let name = ianaName else { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private(set) var isInstallingUpdate = false

    @Published private(set) var betaFeedURL: URL?
    private var betaFeedFetchedAt: Date?

    private var betaRetryNotBefore: Date?
    private var betaInflight: Task<Void, Never>?
    private static let betaFeedURLKey = "betaFeedURL"

    static var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    let updater: SPUUpdater
    private let driver: SoftwareUpdateDriver
    private let bridge: UpdaterDelegateBridge

    private init() {
        let bridge = UpdaterDelegateBridge()
        self.bridge = bridge
        if let stored = UserDefaults.standard.string(forKey: Self.betaFeedURLKey), let url = URL(string: stored) {
            betaFeedURL = url
        }

        bridge.feedURLProvider = {
            guard AppSettings.shared.receiveBetaUpdates else { return nil }
            return UserDefaults.standard.string(forKey: SparkleUpdaterManager.betaFeedURLKey)
        }
        bridge.allowedChannelsProvider = {
            AppSettings.shared.receiveBetaUpdates ? [UpdateChannel.betaChannelName] : []
        }
        let driver = SoftwareUpdateDriver()
        self.driver = driver
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: bridge)
        self.updater = updater

        bridge.onEvent = { [weak self] event in self?.handle(event) }
        driver.onEvent = { [weak self] event in self?.handleDriver(event) }
        do {
            try updater.start()
        } catch {
            logger.error("updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
        if AppSettings.shared.receiveBetaUpdates {
            Task { await refreshBetaFeed(force: false) }
        }
    }

    private func handle(_ event: UpdaterDelegateBridge.Event) {
        switch event {
        case .found(let version):
            if availableUpdate?.version != version {
                availableUpdate = AvailableUpdate(version: version, downloaded: false)
            }
        case .downloaded(let version):
            availableUpdate = AvailableUpdate(version: version, downloaded: true)
        case .willInstall:
            isInstallingUpdate = true
            if availableUpdate != nil { availableUpdate = nil }
        case .notFound, .skipped:

            if availableUpdate != nil { availableUpdate = nil }
        case .cycleFinished:

            if AppSettings.shared.receiveBetaUpdates {
                Task { await refreshBetaFeed(force: false) }
            }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() {
        showUpdatePage()
        guard canCheckForUpdates else { return }
        pageIntent = .check
        flow = .checking
        startCheck()
    }

    private func startCheck() {
        guard AppSettings.shared.receiveBetaUpdates else {
            updater.checkForUpdates()
            return
        }
        Task {
            await refreshBetaFeed(force: false)
            updater.checkForUpdates()
        }
    }

    func betaChannelPreferenceChanged(enabled: Bool) {
        if enabled {
            Task {
                await refreshBetaFeed(force: true)
                updater.checkForUpdatesInBackground()
            }
        } else {
            betaFeedURL = nil
            betaFeedFetchedAt = nil
            UserDefaults.standard.removeObject(forKey: Self.betaFeedURLKey)
            logger.notice("beta channel off, feed back to default")
        }
    }

    private func refreshBetaFeed(force: Bool) async {
        if !force, !UpdateChannel.shouldRefresh(now: Date(), fetchedAt: betaFeedFetchedAt, retryNotBefore: betaRetryNotBefore) {
            return
        }
        if let betaInflight {
            await betaInflight.value
            return
        }
        let task = Task { await self.fetchReleases() }
        betaInflight = task
        await task.value
        betaInflight = nil
    }

    private func fetchReleases() async {
        let url = UpdateChannel.releasesAPIURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lyrimuse/\(Self.appVersionString)", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode
            NetworkAuditLog.record(service: "github", operation: "releases", host: url.host ?? "api.github.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            if status == 403 || status == 429 {
                betaRetryNotBefore = GitHubStars.retryDate(now: Date(), rateLimitReset: http?.value(forHTTPHeaderField: "X-RateLimit-Reset"))
                logger.notice("releases: http \(status ?? -1, privacy: .public), backing off")
                return
            }
            guard status == 200, let releases = UpdateChannel.parseReleases(data) else {
                betaRetryNotBefore = Date().addingTimeInterval(UpdateChannel.failureBackoff)
                logger.notice("releases: http \(status ?? -1, privacy: .public) or parse failed, keeping cached feed")
                return
            }
            betaFeedFetchedAt = Date()
            betaRetryNotBefore = nil
            let chosen = UpdateChannel.betaFeedURL(releases: releases)
            if chosen != betaFeedURL {
                betaFeedURL = chosen
                if let chosen {
                    UserDefaults.standard.set(chosen.absoluteString, forKey: Self.betaFeedURLKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.betaFeedURLKey)
                }
            }
            logger.info("releases: newest=\(UpdateChannel.newestRelease(releases)?.tag ?? "-", privacy: .public) feed=\(chosen?.lastPathComponent ?? "default", privacy: .public)")
        } catch {
            NetworkAuditLog.record(service: "github", operation: "releases", host: url.host ?? "api.github.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            betaRetryNotBefore = Date().addingTimeInterval(UpdateChannel.failureBackoff)
        }
    }
}

private final class UpdaterDelegateBridge: NSObject, SPUUpdaterDelegate {
    enum Event {
        case found(version: String)
        case downloaded(version: String)
        case notFound
        case skipped
        case willInstall
        case cycleFinished
    }

    var onEvent: (@MainActor (Event) -> Void)?

    var feedURLProvider: (@MainActor () -> String?)?
    var allowedChannelsProvider: (@MainActor () -> Set<String>)?

    private func emit(_ event: Event) {
        MainActor.assumeIsolated { onEvent?(event) }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        emit(.found(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        emit(.notFound)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        emit(.downloaded(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        emit(.willInstall)
    }

    func updater(_ updater: SPUUpdater, userDidSkipThisVersion item: SUAppcastItem) {
        emit(.skipped)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        emit(.cycleFinished)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feedURLProvider?() ?? nil }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { allowedChannelsProvider?() ?? [] }
    }
}
