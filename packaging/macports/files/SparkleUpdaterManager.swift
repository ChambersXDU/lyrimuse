import Foundation

@MainActor
final class SparkleUpdaterManager: ObservableObject {
    static let shared = SparkleUpdaterManager()

    struct AvailableUpdate: Equatable {
        let version: String
        let releaseNotesURL: URL?
        var downloaded: Bool
    }

    static let updatesSupported = false

    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var betaFeedURL: URL?

    static var appVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    var isInstallingUpdate: Bool { false }
    var lastUpdateCheckDate: Date? { nil }

    var automaticallyChecksForUpdates: Bool {
        get { false }
        set { _ = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { false }
        set { _ = newValue }
    }

    func checkForUpdates() {}

    func betaChannelPreferenceChanged(enabled: Bool) { _ = enabled }

    private init() {}
}
