import AppKit
import LyrimuseCore

@MainActor
enum BrowserPairing {

    static func rememberManualBrowser(
        _ bundleID: String, family: BrowserAutomationPermission.Family
    ) {
        let settings = AppSettings.shared
        guard !BrowserAutomationPermission.knownBrowserBundleIDs.contains(bundleID) else { return }
        guard settings.manualBrowserFamilies[bundleID] != family.rawValue else { return }
        var families = settings.manualBrowserFamilies
        families[bundleID] = family.rawValue
        settings.manualBrowserFamilies = families
        BrowserAutomationPermission.manuallyAddedFamilies[bundleID] = family
    }

    static func pair(_ bundleID: String, platformID: String) {
        let settings = AppSettings.shared
        var pairs = settings.browserPlatformPairs
        pairs[platformID, default: []].insert(bundleID)
        settings.browserPlatformPairs = pairs
        BrowserPositionProbe.shared.platformBrowserPairs = pairs
    }

    static func trustAndPair(
        _ bundleID: String, platformID: String,
        revealPairing: @escaping () -> Void = {},
        automationDidResolve: @escaping () -> Void = {}
    ) {
        let features = FeatureSettingsStore.shared
        if let family = BrowserAutomationPermission.resolvedFamily(forBundleID: bundleID) {
            rememberManualBrowser(bundleID, family: family)
        }
        pair(bundleID, platformID: platformID)
        Task {
            if features.trustedPlayers[bundleID] == nil {
                await features.trust(bundleID: bundleID)
            }
        }
        Task {

            try? await Task.sleep(nanoseconds: 250_000_000)
            revealPairing()

            guard MusicAutomationPermission.isRunning(bundleID: bundleID) else { return }
            _ = await MusicAutomationPermission.requestWithTimeout(
                bundleID: bundleID, launchIfNeeded: false)
            automationDidResolve()
        }
    }

    static func chooseFromApplications(
        platformID: String,
        revealPairing: @escaping (String) -> Void = { _ in },
        automationDidResolve: @escaping () -> Void = {}
    ) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.t("选择")
        panel.message = L10n.t("挑一个用来播放这个网站的浏览器")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            return L10n.t("读不出这个应用的标识，换一个试试。")
        }

        if let known = BrowserAutomationPermission.family(forBundleID: bundleID) {
            rememberManualBrowser(bundleID, family: known)
            trustAndPair(bundleID, platformID: platformID,
                         revealPairing: { revealPairing(bundleID) },
                         automationDidResolve: automationDidResolve)
            return nil
        }
        guard let family = BrowserAutomationPermission.detectedFamily(forAppAt: url) else {

            let name = FileManager.default.displayName(atPath: url.path)
            return String(
                format: L10n.t("「%@」不能用来同步歌词进度。这项功能要靠浏览器执行一小段 JavaScript 来读播放进度，而这个应用没有提供对应的脚本命令。Firefox 至今没有提供，非浏览器的应用也一样。"),
                name)
        }
        rememberManualBrowser(bundleID, family: family)
        trustAndPair(bundleID, platformID: platformID,
                     revealPairing: { revealPairing(bundleID) },
                     automationDidResolve: automationDidResolve)
        return nil
    }

    static func addableBrowsers(platformID: String) -> [String] {
        let paired = AppSettings.shared.browserPlatformPairs[platformID] ?? []
        return candidateBrowsers(platformID: platformID).filter { !paired.contains($0) }
    }

    static func candidateBrowsers(platformID: String) -> [String] {
        let settings = AppSettings.shared
        let features = FeatureSettingsStore.shared
        let known = BrowserAutomationPermission.knownBrowserBundleIDs

        var extras = Set(settings.manualBrowserFamilies.keys)
        extras.formUnion(features.trustedPlayers.keys.filter {
            BrowserAutomationPermission.isInstalled(bundleID: $0)
                && BrowserAutomationPermission.resolvedFamily(forBundleID: $0) != nil
        })

        let rest = extras.subtracting(known)
            .sorted { (FeatureSettingsStore.appDisplayName(forBundleID: $0) ?? $0)
                        .localizedCaseInsensitiveCompare(FeatureSettingsStore.appDisplayName(forBundleID: $1) ?? $1) == .orderedAscending }
        return (known + rest)
            .filter { BrowserAutomationPermission.isInstalled(bundleID: $0) }
    }

    static func isPaired(_ bundleID: String, platformID: String) -> Bool {
        (AppSettings.shared.browserPlatformPairs[platformID] ?? []).contains(bundleID)
    }

    static func hasAnyPair(platformID: String) -> Bool {
        !pairedBrowsers(platformID: platformID).isEmpty
    }

    static func forgetManualBrowserIfUnpaired(_ bundleID: String) {
        let settings = AppSettings.shared
        guard settings.manualBrowserFamilies[bundleID] != nil else { return }
        guard !settings.browserPlatformPairs.values.contains(where: { $0.contains(bundleID) }) else { return }
        var families = settings.manualBrowserFamilies
        families.removeValue(forKey: bundleID)
        settings.manualBrowserFamilies = families
        BrowserAutomationPermission.manuallyAddedFamilies.removeValue(forKey: bundleID)
    }

    static func unpair(_ bundleID: String, platformID: String) {
        let settings = AppSettings.shared
        var pairs = settings.browserPlatformPairs
        pairs[platformID]?.remove(bundleID)
        if pairs[platformID]?.isEmpty == true { pairs.removeValue(forKey: platformID) }
        settings.browserPlatformPairs = pairs
        BrowserPositionProbe.shared.platformBrowserPairs = pairs
        forgetManualBrowserIfUnpaired(bundleID)
    }

    static func pairedBrowsers(platformID: String) -> [String] {
        (AppSettings.shared.browserPlatformPairs[platformID] ?? [])
            .filter { BrowserAutomationPermission.isInstalled(bundleID: $0) }
            .sorted()
    }
}
