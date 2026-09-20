import AppKit
import ApplicationServices
import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "ytmusic-skip")

public enum AccessibilitySkipPress {
    public enum Outcome: Equatable, Sendable {

        case pressed(desc: String)

        case notTrusted

        case webAreaNotFound

        case browserNotRunning

        case buttonNotFound

        case pressFailed(code: Int32)
    }

    public static let skipButtonClassPrefixes = ["ytp-ad-skip-button", "ytp-skip-ad-button"]

    public static let skipButtonTitles = ["跳过", "略過", "Skip", "スキップ", "건너뛰기"]

    public static func matchesSkipClass(_ classes: [String]) -> Bool {
        classes.contains { cls in
            skipButtonClassPrefixes.contains { prefix in
                guard cls.hasPrefix(prefix) else { return false }
                let rest = cls.dropFirst(prefix.count)
                return rest.isEmpty || rest == "-modern" || rest.hasPrefix("-icon-")
            }
        }
    }

    public static func matchesSkipTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return skipButtonTitles.contains { t == $0 || t.hasPrefix($0 + " ") }
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func promptForTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static let webAreaRetryDelay: TimeInterval = 0.25

    public static func press(browserBundleID: String, hostMarker: String) -> Outcome {
        guard isTrusted else { return .notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browserBundleID).first else {
            logger.info("ax: browser \(browserBundleID, privacy: .public) not running")
            return .browserNotRunning
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var webArea = locateWebArea(appElement, hostMarker: hostMarker)
        if webArea == nil {

            Thread.sleep(forTimeInterval: webAreaRetryDelay)
            webArea = locateWebArea(appElement, hostMarker: hostMarker)
        }
        guard let webArea else {

            let windows = children(appElement).filter { role($0) == "AXWindow" }
            var urls: [String] = []
            for window in windows { collectWebAreaURLs(window, depth: 0, into: &urls) }
            logger.info("""
                ax: no web area for \(hostMarker, privacy: .public) in \(browserBundleID, privacy: .public)                 (pid \(app.processIdentifier), windows=\(windows.count),                 webAreas=\(urls.count): \(urls.joined(separator: " | "), privacy: .public))
                """)
            return .webAreaNotFound
        }
        guard let button = findSkipButton(webArea, depth: 0) else { return .buttonNotFound }
        let desc = describe(button)
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else {
            logger.info("ax: press failed \(result.rawValue) on \(desc, privacy: .public)")
            return .pressFailed(code: result.rawValue)
        }
        return .pressed(desc: desc)
    }

    private static let maxDepth = 60

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func role(_ element: AXUIElement) -> String {
        (attribute(element, kAXRoleAttribute) as? String) ?? ""
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func locateWebArea(_ appElement: AXUIElement, hostMarker: String) -> AXUIElement? {
        for window in children(appElement) where role(window) == "AXWindow" {
            if let hit = findWebArea(window, hostMarker: hostMarker, depth: 0) { return hit }
        }
        return nil
    }

    private static func collectWebAreaURLs(_ element: AXUIElement, depth: Int, into out: inout [String]) {
        guard depth <= maxDepth else { return }
        if role(element) == "AXWebArea" {
            let raw = (attribute(element, "AXURL") as? URL)?.absoluteString
                ?? (attribute(element, "AXURL") as? String) ?? "(无 AXURL)"
            out.append(URL(string: raw)?.host ?? String(raw.prefix(40)))
            return
        }
        for child in children(element) { collectWebAreaURLs(child, depth: depth + 1, into: &out) }
    }

    private static func findWebArea(_ element: AXUIElement, hostMarker: String, depth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        if role(element) == "AXWebArea" {
            let url = (attribute(element, "AXURL") as? URL)?.absoluteString
                ?? (attribute(element, "AXURL") as? String) ?? ""
            return url.contains(hostMarker) ? element : nil
        }
        for child in children(element) {
            if let hit = findWebArea(child, hostMarker: hostMarker, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func findSkipButton(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        if role(element) == "AXButton" {
            let classes = (attribute(element, "AXDOMClassList") as? [String]) ?? []
            if matchesSkipClass(classes) { return element }
            if classes.isEmpty, matchesSkipTitle((attribute(element, kAXTitleAttribute) as? String) ?? "") {
                return element
            }
        }
        for child in children(element) {
            if let hit = findSkipButton(child, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func describe(_ element: AXUIElement) -> String {
        let classes = ((attribute(element, "AXDOMClassList") as? [String]) ?? []).joined(separator: ".")
        let title = (attribute(element, kAXTitleAttribute) as? String) ?? ""
        return "AXButton[\(title)].\(classes)"
    }
}
