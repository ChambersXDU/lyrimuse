import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "spotifyad")

public final class SpotifyWebAdProbe: @unchecked Sendable {
    public static let shared = SpotifyWebAdProbe()

    public enum Verdict: Equatable, Sendable {
        case ad
        case song
    }

    public enum Gate: Equatable, Sendable {

        case acceptAsAd

        case reject
    }

    public static func gate(verdict: Verdict?) -> Gate {
        verdict == .ad ? .acceptAsAd : .reject
    }

    public static func fieldShapeNeedsProbe(title: String?, artist: String?) -> Bool {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let a = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && a.isEmpty
    }

    public static let probeJS = """
    (function(){\
    var w = document.querySelector('[data-testid=now-playing-widget]');\
    if (!w) return 'NOTFOUND';\
    function h(id){ return document.querySelector('[data-testid=' + id + ']') ? '1' : '0'; }\
    return h('ad-controls') + '|' + h('context-item-info-ad-subtitle') + '|'\
    + h('ad-countdown-timer') + '|' + h('ad-link');\
    })()
    """

    public static let hostMarker = "open.spotify.com"

    public static let eventTimeoutSeconds = 4

    static let processTimeout: TimeInterval = 6

    public static let verdictMaxAge: TimeInterval = 60

    public static let refreshInterval: TimeInterval = 45

    private let lock = NSLock()
    private var cachedKey: String?
    private var cachedVerdictValue: Verdict?
    private var cachedAt: Date?
    private var inFlightKey: String?

    private var resultSink: (@Sendable (_ key: String) -> Void)?

    private init() {}

    public func setResultSink(_ sink: @escaping @Sendable (_ key: String) -> Void) {
        lock.lock()
        resultSink = sink
        lock.unlock()
    }

    public static func parse(_ raw: String) -> Verdict? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.contains("NOTFOUND") { return nil }
        let parts = s.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var isAd = false
        for part in parts {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "1": isAd = true
            case "0": break
            default: return nil
            }
        }
        return isAd ? .ad : .song
    }

    public func cachedVerdict(forKey key: String, now: Date = Date()) -> Verdict? {
        lock.lock()
        defer { lock.unlock() }
        guard cachedKey == key, let verdict = cachedVerdictValue, let at = cachedAt else { return nil }
        let age = now.timeIntervalSince(at)
        guard age >= 0, age <= Self.verdictMaxAge else { return nil }
        return verdict
    }

    public func kickIfNeeded(bundleIdentifier: String?, key: String) {
        guard let hostBundleID = BrowserPositionProbe.probeTargetBundleID(forReported: bundleIdentifier),
              let family = BrowserAutomationPermission.family(forBundleID: hostBundleID)
        else { return }
        lock.lock()
        if inFlightKey == key {
            lock.unlock()
            return
        }

        if cachedKey == key, let at = cachedAt, Date().timeIntervalSince(at) <= Self.refreshInterval,
           cachedVerdictValue != nil {
            lock.unlock()
            return
        }
        inFlightKey = key
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let verdict = Self.probeOnce(bundleID: hostBundleID, family: family)
            self.lock.lock()
            if self.inFlightKey == key { self.inFlightKey = nil }

            if let verdict {
                self.cachedKey = key
                self.cachedVerdictValue = verdict
                self.cachedAt = Date()
                if verdict == .ad {

                    logger.notice("spotify web: classified as advertisement, passing through and flagging")
                }
            }

            let sink = verdict != nil ? self.resultSink : nil
            self.lock.unlock()
            sink?(key)
        }
    }

    private static func probeOnce(bundleID: String, family: BrowserAutomationPermission.Family) -> Verdict? {
        guard let out = BrowserTabProbeScript.run(
            bundleID: bundleID, family: family, hostMarker: hostMarker, js: probeJS,
            eventTimeoutSeconds: eventTimeoutSeconds, processTimeout: processTimeout,
            label: "spotify-ad")
        else { return nil }
        return parse(out)
    }

    public static func buildAppleScript(bundleID: String, family: BrowserAutomationPermission.Family) -> String {
        BrowserTabProbeScript.build(bundleID: bundleID, family: family, hostMarker: hostMarker,
                                    js: probeJS, eventTimeoutSeconds: eventTimeoutSeconds)
    }

    public static func trackKey(artist: String?, title: String?) -> String {
        let a = (artist ?? "").trimmingCharacters(in: .whitespaces)
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        return a + "\u{0}" + t
    }
}
