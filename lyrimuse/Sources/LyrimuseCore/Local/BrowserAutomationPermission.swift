import AppKit
import Foundation

public enum BrowserAutomationPermission {

    public enum Family: String, Equatable {
        case chromium
        case safari
    }

    private static let chromiumPrefsPaths: [String: String] = [
        "company.thebrowser.Browser": "\(NSHomeDirectory())/Library/Application Support/Arc/User Data/Default/Preferences",
        "com.google.Chrome": "\(NSHomeDirectory())/Library/Application Support/Google/Chrome/Default/Preferences",
        "com.microsoft.edgemac": "\(NSHomeDirectory())/Library/Application Support/Microsoft Edge/Default/Preferences",
    ]
    private static let safariBundleID = "com.apple.Safari"
    private static let safariPrefKey = "AllowJavaScriptFromAppleEvents" as CFString
    private static let chromiumPrefKey = "allow_javascript_apple_events"

    public static let knownBrowserBundleIDs: [String] = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        safariBundleID,
    ]

    public static func family(forBundleID bundleID: String) -> Family? {
        if chromiumPrefsPaths[bundleID] != nil { return .chromium }
        if bundleID == safariBundleID { return .safari }
        return manuallyAddedFamilies[bundleID]
    }

    public static var manuallyAddedFamilies: [String: Family] = [:]

    private static let chromiumJavaScriptCode = "CrSuExJa"
    private static let safariJavaScriptCode = "sfridojs"

    public static func detectedFamily(forAppAt appURL: URL) -> Family? {
        guard let bundle = Bundle(url: appURL),
              let rawName = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String
        else { return nil }

        let sdefName = (rawName as NSString).lastPathComponent
        guard !sdefName.isEmpty else { return nil }
        let sdefURL = appURL
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent(sdefName)
        guard let data = FileManager.default.contents(atPath: sdefURL.path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        if text.contains(chromiumJavaScriptCode) { return .chromium }
        if text.contains(safariJavaScriptCode) { return .safari }
        return nil
    }

    @MainActor
    public static func resolvedFamily(forBundleID bundleID: String) -> Family? {
        if let known = family(forBundleID: bundleID) { return known }
        if let cached = detectedFamilyCache[bundleID] { return cached }
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { detectedFamily(forAppAt: $0) }
        detectedFamilyCache[bundleID] = resolved
        return resolved
    }

    @MainActor
    private static var detectedFamilyCache: [String: Family?] = [:]

    public static func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    public static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public enum Status: Equatable {
        case enabled
        case disabled

        case unknown
        case unsupported
    }

    public static func status(forBundleID bundleID: String) -> Status {
        guard let family = family(forBundleID: bundleID) else { return .unsupported }
        switch family {
        case .safari:
            return safariStatus(fromPrefValue:
                CFPreferencesCopyAppValue(safariPrefKey, safariBundleID as CFString))
        case .chromium:
            guard let dict = readChromiumPrefs(bundleID: bundleID) else { return .unknown }
            let browserDict = dict["browser"] as? [String: Any]
            return (browserDict?[chromiumPrefKey] as? Bool) == true ? .enabled : .disabled
        }
    }

    public static func safariStatus(fromPrefValue value: CFPropertyList?) -> Status {
        guard let value else {

                return .unknown
            }
        return (value as? Bool) == true || (value as? NSNumber)?.boolValue == true ? .enabled : .disabled
    }

    private static func readChromiumPrefs(bundleID: String) -> [String: Any]? {
        guard let path = chromiumPrefsPaths[bundleID],
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
