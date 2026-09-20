import AppKit

@MainActor
enum AppIconResolver {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }

    static func icon(bundledResourceName name: String) -> NSImage? {
        let key = "bundled:" + name
        if let cached = cache[key] { return cached }
        guard let path = Bundle.main.path(forResource: name, ofType: "png"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        cache[key] = image
        return image
    }
}
