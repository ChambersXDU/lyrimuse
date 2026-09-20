import Foundation

public final class YouTubeMusicAdProbe: @unchecked Sendable {
    public static let shared = YouTubeMusicAdProbe()

    public enum Verdict: Equatable, Sendable {
        case ad
        case song
    }

    public enum Gate: Equatable, Sendable {

        case acceptAsSong

        case acceptAsAd

        case reject
    }

    public static func showsAdBadge(verdict: Verdict?) -> Bool {
        verdict == .ad
    }

    public static func gate(artist: String?, verdict: Verdict?) -> Gate {
        let trimmed = (artist ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .reject }
        switch verdict {
        case .song: return .acceptAsSong
        case .ad: return .acceptAsAd
        case nil: return .reject
        }
    }

    public static let probeJS = """
    (function(){\
    var p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');\
    var hasTime = !!document.querySelector('.time-info');\
    if (!p && !hasTime) return 'NOTFOUND';\
    var cls = p ? (p.className || '') : '';\
    var adShowing = cls.indexOf('ad-showing') >= 0 ? '1' : '0';\
    var badge = document.querySelector('.ytp-ad-badge, .ytp-ad-simple-ad-badge, .ytp-ad-text, .ytp-ad-preview-container') ? '1' : '0';\
    var slotEl = document.querySelector('.ytp-ad-simple-ad-badge, .ytp-ad-badge');\
    var slot = '';\
    if (slotEl) { var st = String(slotEl.textContent || '').replace(new RegExp('[0-9]+:[0-9]+', 'g'), ''); var sm = st.match(new RegExp('([0-9]+)[^0-9]{1,12}([0-9]+)')); if (sm) { slot = sm[1] + '/' + sm[2]; } }\
    var t = (document.title || '').trim();\
    var bare = (t === 'YouTube Music') ? '1' : '0';\
    var bl = document.querySelectorAll('ytmusic-player-bar .byline a');\
    var album = '';\
    for (var i = 0; i < bl.length; i++) {\
    var h = bl[i].getAttribute('href') || '';\
    if (h.indexOf('browse/MPREb') >= 0) { album = (bl[i].textContent || '').trim(); break; }\
    }\
    return adShowing + '|' + badge + '|' + bare + '|' + slot + '|' + album;\
    })()
    """

    public static let hostMarker = "music.youtube.com"

    public static let eventTimeoutSeconds = 4

    static let processTimeout: TimeInterval = 6

    public static let verdictMaxAge: TimeInterval = 60

    public static let adRefreshInterval: TimeInterval = 5

    public static let songRefreshInterval: TimeInterval = 45

    public static func refreshInterval(for verdict: Verdict) -> TimeInterval {
        switch verdict {
        case .ad: return adRefreshInterval
        case .song: return songRefreshInterval
        }
    }

    private let lock = NSLock()
    private var cachedKey: String?
    private var cachedReadingValue: Reading?
    private var cachedAt: Date?
    private var inFlightKey: String?

    private var resultSink: (@Sendable (_ key: String) -> Void)?

    private init() {}

    public func setResultSink(_ sink: @escaping @Sendable (_ key: String) -> Void) {
        lock.lock()
        resultSink = sink
        lock.unlock()
    }

    public struct Reading: Equatable, Sendable {
        public let verdict: Verdict

        public let strongAd: Bool

        public let album: String

        public let adSlot: AdSlot?

        public init(verdict: Verdict, strongAd: Bool, album: String, adSlot: AdSlot? = nil) {
            self.verdict = verdict
            self.strongAd = verdict == .ad && strongAd
            self.album = album
            self.adSlot = adSlot
        }
    }

    public struct AdSlot: Equatable, Sendable {
        public static let maxTotal = 20
        public let index: Int
        public let total: Int

        public init?(rawPair: String) {
            let parts = rawPair.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let total = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  index >= 1, total >= index, total <= Self.maxTotal
            else { return nil }
            self.index = index
            self.total = total
        }

        public init(index: Int, total: Int) {
            self.index = index
            self.total = total
        }
    }

    public static func parse(_ raw: String) -> Reading? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.contains("NOTFOUND") { return nil }
        let parts = s.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        var isAd = false
        var strongAd = false
        for (index, part) in parts.prefix(3).enumerated() {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "1":
                isAd = true

                if index < 2 { strongAd = true }
            case "0": break
            default: return nil
            }
        }

        let adSlot = parts.count == 5 ? AdSlot(rawPair: String(parts[3])) : nil
        let albumField: Substring? = parts.count == 5 ? parts[4] : nil

        let album = albumField
            .map {
                $0.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
        return Reading(verdict: isAd ? .ad : .song, strongAd: strongAd, album: album, adSlot: adSlot)
    }

    public static func badgeVerdict(_ reading: Reading?) -> Verdict? {
        guard let reading else { return nil }
        if reading.verdict == .ad, !reading.strongAd { return nil }
        return reading.verdict
    }

    public func cachedBadgeVerdict(forKey key: String, now: Date = Date()) -> Verdict? {
        Self.badgeVerdict(cachedReading(forKey: key, now: now))
    }

    public static func albumPatch(reported: String?, reading: Reading?) -> String? {
        guard (reported ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let reading, reading.verdict == .song else { return nil }
        let album = reading.album.trimmingCharacters(in: .whitespaces)
        return album.isEmpty ? nil : album
    }

    public func cachedReading(forKey key: String, now: Date = Date()) -> Reading? {
        lock.lock()
        defer { lock.unlock() }
        guard cachedKey == key, let reading = cachedReadingValue, let at = cachedAt else { return nil }
        let age = now.timeIntervalSince(at)
        guard age >= 0, age <= Self.verdictMaxAge else { return nil }
        return reading
    }

    public func cachedVerdict(forKey key: String, now: Date = Date()) -> Verdict? {
        cachedReading(forKey: key, now: now)?.verdict
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

        if cachedKey == key, let at = cachedAt, let reading = cachedReadingValue,
           Date().timeIntervalSince(at) <= Self.refreshInterval(for: reading.verdict) {
            lock.unlock()
            return
        }
        inFlightKey = key
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let reading = Self.probeOnce(bundleID: hostBundleID, family: family)
            self.lock.lock()
            if self.inFlightKey == key { self.inFlightKey = nil }

            if let reading {
                self.cachedKey = key
                self.cachedReadingValue = reading
                self.cachedAt = Date()
            }

            let sink = reading != nil ? self.resultSink : nil
            self.lock.unlock()

            sink?(key)
        }
    }

    public func trackChanged() {
        lock.lock()
        cachedKey = nil
        cachedReadingValue = nil
        cachedAt = nil
        inFlightKey = nil
        lock.unlock()
    }

    private static func probeOnce(bundleID: String, family: BrowserAutomationPermission.Family) -> Reading? {
        guard let out = BrowserTabProbeScript.run(
            bundleID: bundleID, family: family, hostMarker: hostMarker, js: probeJS,
            eventTimeoutSeconds: eventTimeoutSeconds, processTimeout: processTimeout,
            label: "ytmusic-ad")
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
