import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "ytmusic-skip")

public enum YouTubeMusicAdSkipper {
    public enum Outcome: Equatable, Sendable {

        case skipped

        case notYetSkippable(secondsUntilSkippable: Int?)

        case clickedNoEffect

        case notFound

        case needsAccessibility

        case tabNotFrontmost
    }

    public enum ClickResult: Equatable, Sendable {

        case skippable(desc: String, badge: String, videoTime: Int)
        case notYet(seconds: Int?)
        case notFound
    }

    public enum VerifyResult: Equatable, Sendable {

        case still(badge: String, videoTime: Int)

        case clear
        case notFound
    }

    public static let skipJS = """
    (function(){\
    var p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');\
    if (!p) return 'NOTFOUND';\
    if ((p.className || '').indexOf('ad-showing') < 0) return 'NOTFOUND';\
    var badgeEl = document.querySelector('.ytp-ad-simple-ad-badge, .ytp-ad-badge');\
    var badge = badgeEl ? String(badgeEl.textContent || '').trim() : '';\
    var v = p.querySelector('video');\
    var vt = v ? Math.floor(v.currentTime) : -1;\
    var sel = ['.ytp-skip-ad-button', '.ytp-ad-skip-button-modern', '.ytp-ad-skip-button', '.ytp-ad-skip-button-slot button', '.ytp-ad-skip-button-container button', '.ytp-skip-ad button', 'button[id^=skip-button]'];\
    var b = null;\
    for (var i = 0; i < sel.length && !b; i++) {\
    var list = p.querySelectorAll(sel[i]);\
    for (var j = 0; j < list.length; j++) {\
    var rr = list[j].getBoundingClientRect();\
    if (rr.width > 0 && rr.height > 0) { b = list[j]; break; }\
    }\
    }\
    if (!b) {\
    var prev = document.querySelector('.ytp-ad-preview-text-modern, .ytp-preview-ad__text, .ytp-ad-preview-text, .ytp-ad-preview-container');\
    var m = prev ? String(prev.textContent || '').match(/[0-9]+/) : null;\
    return 'NOTYET|' + (m ? m[0] : '');\
    }\
    var desc = b.tagName + '.' + String(b.className || '').split(' ').join('.');\
    return 'SKIPPABLE|' + desc + '|' + badge + '|' + vt;\
    })()
    """

    public static let verifyJS = """
    (function(){\
    var p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');\
    if (!p) return 'NOTFOUND';\
    if ((p.className || '').indexOf('ad-showing') < 0) return 'CLEAR';\
    var badgeEl = document.querySelector('.ytp-ad-simple-ad-badge, .ytp-ad-badge');\
    var badge = badgeEl ? String(badgeEl.textContent || '').trim() : '';\
    var v = p.querySelector('video');\
    var vt = v ? Math.floor(v.currentTime) : -1;\
    return 'STILL|' + badge + '|' + vt;\
    })()
    """

    public static let verifyDelay: TimeInterval = 0.8

    public static func parseClick(_ raw: String) -> ClickResult? {
        let parts = fields(raw)
        switch parts.first {
        case "SKIPPABLE":
            guard parts.count >= 4 else { return nil }
            return .skippable(desc: parts[1], badge: parts[2], videoTime: Int(parts[3]) ?? -1)
        case "NOTYET":
            return .notYet(seconds: parts.count > 1 ? Int(parts[1]) : nil)
        case "NOTFOUND":
            return .notFound
        default:
            return nil
        }
    }

    public static func parseVerify(_ raw: String) -> VerifyResult? {
        let parts = fields(raw)
        switch parts.first {
        case "STILL":
            guard parts.count >= 3 else { return nil }
            return .still(badge: parts[1], videoTime: Int(parts[2]) ?? -1)
        case "CLEAR": return .clear
        case "NOTFOUND": return .notFound
        default: return nil
        }
    }

    public static func adAdvanced(afterClick click: ClickResult, verify: VerifyResult) -> Bool {
        switch verify {
        case .clear, .notFound:
            return true
        case .still(let badge, _):
            guard case .skippable(_, let gateBadge, _) = click else { return false }
            return !badge.isEmpty && !gateBadge.isEmpty && badge != gateBadge
        }
    }

    private static func fields(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }

    public static func isYouTubeMusicAd(artist: String, title: String, now: Date = Date()) -> Bool {
        let key = YouTubeMusicAdProbe.trackKey(artist: artist, title: title)
        return YouTubeMusicAdProbe.shared.cachedBadgeVerdict(forKey: key, now: now) == .ad
    }

    public static func skip(reportedBundleID: String?) -> Outcome? {
        guard let host = BrowserPositionProbe.probeTargetBundleID(forReported: reportedBundleID),
              !host.isEmpty,
              let family = BrowserAutomationPermission.family(forBundleID: host)
        else {
            logger.info("skip: no browser family for bundle \(reportedBundleID ?? "nil", privacy: .public)")
            return nil
        }
        guard let out = run(js: skipJS, host: host, family: family, label: "ytmusic-skip") else {
            logger.info("skip: script did not run (osascript failed / timed out)")
            return nil
        }
        guard let click = parseClick(out) else {
            logger.info("skip: unparseable output \(out, privacy: .public)")
            return nil
        }
        switch click {
        case .notYet(let seconds):
            logger.info("skip: not yet skippable (\(seconds.map(String.init) ?? "?", privacy: .public)s)")
            return .notYetSkippable(secondsUntilSkippable: seconds)
        case .notFound:
            logger.info("skip: no ad-showing player")
            return .notFound
        case .skippable(let desc, let badge, let videoTime):
            let press = AccessibilitySkipPress.press(browserBundleID: host, hostMarker: YouTubeMusicAdProbe.hostMarker)
            switch press {
            case .notTrusted:
                logger.info("skip: gate open (\(desc, privacy: .public)) but no accessibility trust")
                return .needsAccessibility
            case .webAreaNotFound:
                logger.info("skip: gate open but no YT Music web area in the AX tree (tab not frontmost?)")
                return .tabNotFrontmost
            case .buttonNotFound, .pressFailed, .browserNotRunning:

                logger.info("skip: gate open but AX press failed: \(String(describing: press), privacy: .public)")
                return .clickedNoEffect
            case .pressed(let pressedDesc):
                Thread.sleep(forTimeInterval: verifyDelay)
                let verifyRaw = run(js: verifyJS, host: host, family: family, label: "ytmusic-skip-verify")
                let verify = verifyRaw.flatMap(parseVerify)
                logger.info("skip: pressed \(pressedDesc, privacy: .public) (dom \(desc, privacy: .public)) badge=\(badge, privacy: .public) t=\(videoTime) → verify=\(verifyRaw ?? "nil", privacy: .public)")
                if let verify, adAdvanced(afterClick: click, verify: verify) { return .skipped }
                return .clickedNoEffect
            }
        }
    }

    public enum Skippability: Equatable, Sendable {

        case ready

        case after(seconds: Int)

        case never

        case notInAd
    }

    public static func skippability(from click: ClickResult) -> Skippability {
        switch click {
        case .skippable: return .ready
        case .notYet(let seconds): return seconds.map { .after(seconds: $0) } ?? .never
        case .notFound: return .notInAd
        }
    }

    public static func showsSkipButton(_ state: Skippability?) -> Bool {
        guard let state else { return true }
        return state == .ready
    }

    public static let fastStartRounds = 4
    public static let fastStartDelay: TimeInterval = 1.2

    public static func gateRetryDelay(after state: Skippability, round: Int = .max) -> TimeInterval {
        switch state {
        case .after(let seconds): return min(max(Double(seconds), 1), 20) + 0.4
        case .never: return round < fastStartRounds ? fastStartDelay : YouTubeMusicAdProbe.adRefreshInterval
        case .ready: return YouTubeMusicAdProbe.adRefreshInterval
        case .notInAd: return 0
        }
    }

    public static let gateMaxRounds = 12

    private static let gateCacheTTL: TimeInterval = 1.5
    private static let gateCacheLock = NSLock()
    private static var gateCache: (state: Skippability, host: String, at: Date)?

    public static func probeSkippability(reportedBundleID: String?) -> Skippability? {
        guard let host = BrowserPositionProbe.probeTargetBundleID(forReported: reportedBundleID),
              !host.isEmpty,
              let family = BrowserAutomationPermission.family(forBundleID: host)
        else {
            logger.info("gate: no browser family for bundle \(reportedBundleID ?? "nil", privacy: .public)")
            return nil
        }
        gateCacheLock.lock()
        let cached = gateCache
        gateCacheLock.unlock()
        if let cached, cached.host == host, Date().timeIntervalSince(cached.at) < gateCacheTTL {
            return cached.state
        }
        guard let out = run(js: skipJS, host: host, family: family, label: "ytmusic-skip-gate") else {
            logger.info("gate: script did not run (host \(host, privacy: .public))")
            return nil
        }
        guard let click = parseClick(out) else {
            logger.info("gate: unparseable output \(out, privacy: .public)")
            return nil
        }
        let state = skippability(from: click)

        logger.info("gate: \(String(describing: state), privacy: .public) (host \(host, privacy: .public))")
        gateCacheLock.lock()
        gateCache = (state, host, Date())
        gateCacheLock.unlock()
        return state
    }

    private static func run(js: String, host: String, family: BrowserAutomationPermission.Family, label: String) -> String? {
        BrowserTabProbeScript.run(
            bundleID: host, family: family,
            hostMarker: YouTubeMusicAdProbe.hostMarker, js: js,
            eventTimeoutSeconds: YouTubeMusicAdProbe.eventTimeoutSeconds,
            processTimeout: YouTubeMusicAdProbe.processTimeout,
            label: label)
    }
}
