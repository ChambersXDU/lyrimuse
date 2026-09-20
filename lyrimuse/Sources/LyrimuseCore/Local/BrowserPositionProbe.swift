import Foundation
import os

public final class BrowserPositionProbe: @unchecked Sendable {
    public static let shared = BrowserPositionProbe()
    private init() {}

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "browserprobe")

    private static let probeTimeout: TimeInterval = 3

    public static let flooredMidpointBiasSecs: Double = 0.5

    public static let livenessGapSeconds: TimeInterval = 1.5

    public static func pageClockIsRunning(first: Double, second: Double) -> Bool {
        second > first
    }

    public static let pageDurationToleranceSecs: Double = 2

    public static let maxProbeAttempts = 3

    public static let probeRetryBackoffSecs: TimeInterval = 3

    private static let probeEventTimeoutSeconds = 1
    private static let selfTestEventTimeoutSeconds = 2

    private static func activeTabExpression(
        family: BrowserAutomationPermission.Family, windowIndex: String
    ) -> String {
        switch family {
        case .chromium: return "active tab of window \(windowIndex)"
        case .safari:   return "current tab of window \(windowIndex)"
        }
    }

    public struct BrowserMusicPlatform: Identifiable, Equatable, Hashable, Sendable {
        public let id: String
        public let displayName: String
    }

    public static let supportedPlatforms: [BrowserMusicPlatform] = [
        BrowserMusicPlatform(id: "youtubeMusic", displayName: "YouTube Music"),
        BrowserMusicPlatform(id: "spotifyWeb", displayName: "Spotify"),
    ]

    private struct SiteRule {
        let platformID: String
        let urlContains: String
        let script: String
    }

    private static let siteRules: [SiteRule] = [
        SiteRule(platformID: "youtubeMusic", urlContains: "music.youtube.com", script: youtubeMusicScript),
        SiteRule(platformID: "spotifyWeb", urlContains: "open.spotify.com", script: spotifyWebScript),
    ]

    private static let youtubeMusicScript = """
    (function(){
      var el = document.querySelector('.time-info');
      if (!el) return 'NOTFOUND';
      var text = (el.textContent || '').trim();
      var parts = text.split('/');
      if (parts.length !== 2) return 'NOTFOUND';
      function toSecs(s) {
        var f = s.trim().split(':');
        if (f.length < 2 || f.length > 3) return -1;
        var n = 0;
        for (var i = 0; i < f.length; i++) {
          var v = parseInt(f[i], 10);
          if (isNaN(v)) return -1;
          n = n * 60 + v;
        }
        return n;
      }
      var cur = toSecs(parts[0]);
      var total = toSecs(parts[1]);
      if (cur < 0 || total < 0) return 'NOTFOUND';
      if (__EXPECT__ > 0 && Math.abs(total - __EXPECT__) > __TOL__) return 'NOTFOUND';
      var video = document.querySelector('video');
      var paused = video ? video.paused : false;
      return cur + '|' + (paused ? '1' : '0');
    })()
    """

    private static let spotifyWebScript = """
    (function(){
      function toSecs(s) {
        var f = s.trim().split(':');
        if (f.length < 2 || f.length > 3) return -1;
        var n = 0;
        for (var i = 0; i < f.length; i++) {
          var v = parseInt(f[i], 10);
          if (isNaN(v)) return -1;
          n = n * 60 + v;
        }
        return n;
      }
      var el = document.querySelector('[data-testid=playback-position]');
      if (!el) return 'NOTFOUND';
      var cur = toSecs(el.textContent || '');
      if (cur < 0) return 'NOTFOUND';
      if (__EXPECT__ > 0) {
        var dEl = document.querySelector('[data-testid=playback-duration]');
        var total = dEl ? toSecs(dEl.textContent || '') : -1;
        if (total >= 0 && Math.abs(total - __EXPECT__) > __TOL__) return 'NOTFOUND';
      }
      var sep = ' ' + String.fromCharCode(8226) + ' ';
      var paused = document.title.indexOf(sep) < 0;
      var img = document.querySelector('[data-testid=now-playing-widget] img[data-testid=cover-art-image]');
      var art = img ? (img.currentSrc || img.src || '') : '';
      return cur + '|' + (paused ? '1' : '0') + '|' + art;
    })()
    """

    public static func probeTargetBundleID(forReported bundleID: String?) -> String? {
        TrustedPlayers.mediaProxyOwner(of: bundleID) ?? bundleID
    }

    public static var platformIDsWithSiteRules: Set<String> { Set(siteRules.map(\.platformID)) }

    private struct CachedResult {
        let key: String
        let seconds: Double
        let capturedAt: Date
    }

    private let lock = NSLock()
    private var cached: CachedResult?
    private var inFlightKey: String?
    private var consumedKey: String?
    private var generation = 0

    private var attemptKey: String?
    private var attemptCount = 0
    private var lastAttemptEndedAt: Date?
    private var platformBrowserPairsStorage: [String: Set<String>] = [:]

    private var lastMatch: (bundleID: String, platformID: String, at: Date)?

    private var artworkSink: (@Sendable (_ key: String, _ url: URL) -> Void)?

    public func setArtworkSink(_ sink: @escaping @Sendable (_ key: String, _ url: URL) -> Void) {
        lock.lock()
        artworkSink = sink
        lock.unlock()
    }

    public var platformBrowserPairs: [String: Set<String>] {
        get { lock.lock(); defer { lock.unlock() }; return platformBrowserPairsStorage }
        set { lock.lock(); platformBrowserPairsStorage = newValue; lock.unlock() }
    }

    private func pairedPlatformIDs(forBundleID bundleID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var ids: Set<String> = []
        for (platformID, bundleIDs) in platformBrowserPairsStorage where bundleIDs.contains(bundleID) {
            ids.insert(platformID)
        }
        return ids
    }

    public func isPaired(bundleID: String?, platformID: String) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return pairedPlatformIDs(forBundleID: bundleID).contains(platformID)
    }

    public static let matchedPlatformMaxAge: TimeInterval = 15 * 60

    public func playingPlatformID(forBundleID bundleID: String?, now: Date = Date()) -> String? {
        guard let host = Self.probeTargetBundleID(forReported: bundleID), !host.isEmpty else {
            return nil
        }
        lock.lock()
        var recent: String?
        if let lastMatch, lastMatch.bundleID == host {
            let age = now.timeIntervalSince(lastMatch.at)
            if age >= 0, age <= Self.matchedPlatformMaxAge { recent = lastMatch.platformID }
        }
        var paired: Set<String> = []
        for (platformID, bundleIDs) in platformBrowserPairsStorage where bundleIDs.contains(host) {
            paired.insert(platformID)
        }
        lock.unlock()
        return Self.resolvePlayingPlatformID(pairedPlatformIDs: paired, recentMatch: recent)
    }

    public static func resolvePlayingPlatformID(
        pairedPlatformIDs: Set<String>, recentMatch: String?
    ) -> String? {
        if let recentMatch, pairedPlatformIDs.contains(recentMatch) { return recentMatch }
        return pairedPlatformIDs.count == 1 ? pairedPlatformIDs.first : nil
    }

    public func consumeCorrection(forKey key: String, rate: Double, now: Date, maxAge: TimeInterval = 6) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard consumedKey != key else { return nil }
        guard let snapshot = cached, snapshot.key == key else { return nil }
        let age = now.timeIntervalSince(snapshot.capturedAt)
        guard age >= 0, age <= maxAge else { return nil }
        consumedKey = key
        let corrected = snapshot.seconds + Self.flooredMidpointBiasSecs + rate * age

        Self.logger.notice("probe: handing off correction \(corrected, privacy: .public)s (reading \(snapshot.seconds, privacy: .public)s + midpoint + \(age, privacy: .public)s lag), per-track budget exhausted")
        return corrected
    }

    public func trackChanged(from previousKey: String = "-", to newKey: String = "-") {
        lock.lock()
        cached = nil
        inFlightKey = nil
        consumedKey = nil
        generation += 1

        attemptKey = nil
        attemptCount = 0
        lastAttemptEndedAt = nil
        lock.unlock()
        Self.logger.notice("probe: track key changed, reopening per-track probe budget (old=\(previousKey, privacy: .public) new=\(newKey, privacy: .public))")
    }

    public func kickIfNeeded(bundleIdentifier: String?, key: String, expectedDuration: Double) {

        guard let hostBundleID = Self.probeTargetBundleID(forReported: bundleIdentifier),
              let family = BrowserAutomationPermission.family(forBundleID: hostBundleID)
        else { return }
        let platformIDs = pairedPlatformIDs(forBundleID: hostBundleID)
        guard !platformIDs.isEmpty else { return }
        lock.lock()
        guard inFlightKey != key, consumedKey != key else { lock.unlock(); return }

        if attemptKey != key {
            attemptKey = key
            attemptCount = 0
            lastAttemptEndedAt = nil
        }
        guard attemptCount < Self.maxProbeAttempts else { lock.unlock(); return }
        if let last = lastAttemptEndedAt,
           Date().timeIntervalSince(last) < Self.probeRetryBackoffSecs {
            lock.unlock()
            return
        }
        attemptCount += 1
        let attemptNumber = attemptCount
        inFlightKey = key
        let myGeneration = generation
        lock.unlock()

        Task.detached(priority: .utility) {
            let hit = await Self.probeAdvancing(
                bundleID: hostBundleID, family: family, platformIDs: platformIDs,
                expectedDuration: expectedDuration, attempt: attemptNumber)
            self.applyProbeResult(hit, key: key, generation: myGeneration,
                                  bundleID: hostBundleID)
        }
    }

    private func applyProbeResult(_ hit: ProbeHit?, key: String, generation myGeneration: Int,
                                  bundleID: String) {
        lock.lock()
        defer { lock.unlock() }
        lastAttemptEndedAt = Date()
        guard myGeneration == generation else { return }
        if inFlightKey == key { inFlightKey = nil }
        guard let hit else { return }
        cached = CachedResult(key: key, seconds: hit.seconds, capturedAt: Date())

        lastMatch = (bundleID: bundleID, platformID: hit.platformID, at: Date())
        if let art = hit.artworkURL { artworkSink?(key, art) }
    }

    public enum SelfTestResult: Equatable {
        case ok

        case noTab

        case blocked

        case noReply

        case failed(String)
    }

    public static func selfTest(bundleID: String, family: BrowserAutomationPermission.Family) -> SelfTestResult {
        guard BrowserAutomationPermission.isRunning(bundleID: bundleID) else { return .noTab }

        let tab = activeTabExpression(family: family, windowIndex: "1")
        let executeLine: String
        switch family {
        case .chromium: executeLine = "execute (\(tab)) javascript \"1+1\""
        case .safari:   executeLine = "do JavaScript \"1+1\" in \(tab)"
        }

        let source = """
        tell application id "\(bundleID)"
            if (count of windows) is 0 then return "NOWINDOW"
            if (count of tabs of window 1) is 0 then return "NOWINDOW"
            try
                with timeout of \(selfTestEventTimeoutSeconds) seconds
                    return "OK:" & ((\(executeLine)) as text)
                end timeout
            on error errMsg number errNum
                return "ERR:" & errNum & ":" & errMsg
            end try
        end tell
        """
        guard let tempURL = writeTempScript(source) else { return .failed("cannot write script") }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let result = ProcessRunner.run("/usr/bin/osascript", [tempURL.path], timeout: probeTimeout) else {

            return .failed("osascript didn't start")
        }

        if result.timedOut { return .noReply }
        var out = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("\""), out.hasSuffix("\""), out.count >= 2 { out.removeFirst(); out.removeLast() }
        if out == "NOWINDOW" { return .noTab }
        if out.hasPrefix("OK:") { return .ok }
        guard out.hasPrefix("ERR:") else {
            return .failed(out.isEmpty ? "osascript exit \(result.status), no output" : out)
        }

        let body = String(out.dropFirst(4))
        let pieces = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let errNumber = pieces.count == 2 ? Int(pieces[0].trimmingCharacters(in: .whitespaces)) : nil
        let err = pieces.count == 2 ? String(pieces[1]) : body
        if errNumber == -1712 { return .noReply }

        if BrowserAutomationPermission.status(forBundleID: bundleID) == .disabled { return .blocked }

        let lower = err.lowercased()
        if lower.contains("applescript"),
           lower.contains("turned off") || err.contains("已关闭") || lower.contains("disabled") {
            return .blocked
        }
        if lower.contains("apple event"), lower.contains("javascript") {
            return .blocked
        }
        return .failed(err)
    }

    private struct ProbeHit {
        let seconds: Double
        let platformID: String
        let artworkURL: URL?
    }

    private static func probeAdvancing(
        bundleID: String, family: BrowserAutomationPermission.Family,
        platformIDs: Set<String>, expectedDuration: Double, attempt: Int
    ) async -> ProbeHit? {
        let expect = Int(expectedDuration.rounded())
        guard let first = probeOnce(bundleID: bundleID, family: family,
                                    platformIDs: platformIDs, expectedDuration: expectedDuration) else {
            logger.info("probe #\(attempt, privacy: .public): no tab produced a usable reading (expected duration \(expect, privacy: .public)s)")
            return nil
        }
        try? await Task.sleep(nanoseconds: UInt64(livenessGapSeconds * 1_000_000_000))
        guard let second = probeOnce(bundleID: bundleID, family: family,
                                     platformIDs: platformIDs, expectedDuration: expectedDuration) else {
            logger.info("probe #\(attempt, privacy: .public): second sample returned nothing, discarding \(first.seconds, privacy: .public)s")
            return nil
        }

        guard first.platformID == second.platformID else {
            logger.notice("probe #\(attempt, privacy: .public): samples landed on different platforms (\(first.platformID, privacy: .public) -> \(second.platformID, privacy: .public)), discarding")
            return nil
        }
        guard pageClockIsRunning(first: first.seconds, second: second.seconds) else {
            logger.notice("probe #\(attempt, privacy: .public): page position is not advancing (\(first.seconds, privacy: .public)s -> \(second.seconds, privacy: .public)s), discarding")
            return nil
        }
        logger.notice("probe #\(attempt, privacy: .public): accepting \(second.seconds, privacy: .public)s (previous \(first.seconds, privacy: .public)s, expected duration \(expect, privacy: .public)s, platform \(second.platformID, privacy: .public))")
        return second
    }

    private static func probeOnce(bundleID: String, family: BrowserAutomationPermission.Family, platformIDs: Set<String>, expectedDuration: Double) -> ProbeHit? {
        for rule in siteRules where platformIDs.contains(rule.platformID) {
            if let reading = probe(bundleID: bundleID, family: family, rule: rule, expectedDuration: expectedDuration) {
                return ProbeHit(seconds: reading.seconds, platformID: rule.platformID, artworkURL: reading.artworkURL)
            }
        }
        return nil
    }

    private static func probe(bundleID: String, family: BrowserAutomationPermission.Family, rule: SiteRule, expectedDuration: Double) -> Reading? {
        let appleScript = buildAppleScript(bundleID: bundleID, family: family, urlContains: rule.urlContains, script: rule.script, expectedDuration: expectedDuration)
        guard let tempURL = writeTempScript(appleScript) else { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let result = ProcessRunner.run("/usr/bin/osascript", [tempURL.path], timeout: probeTimeout),
              result.succeeded
        else { return nil }
        return parseReading(fromOsascriptOutput: result.stdoutText)
    }

    private static func buildAppleScript(
        bundleID: String, family: BrowserAutomationPermission.Family, urlContains: String,
        script rawScript: String, expectedDuration: Double
    ) -> String {

        let expect = expectedDuration > 0 ? Int(expectedDuration.rounded()) : 0
        let script = rawScript
            .replacingOccurrences(of: "__EXPECT__", with: String(expect))
            .replacingOccurrences(of: "__TOL__", with: String(Int(pageDurationToleranceSecs)))
        let activeTab = activeTabExpression(family: family, windowIndex: "wi")
        let executeLine: String
        let executeActiveLine: String
        switch family {
        case .chromium:
            executeLine = "execute (tab ti of window wi) javascript \"\(script)\""
            executeActiveLine = "execute (\(activeTab)) javascript \"\(script)\""
        case .safari:
            executeLine = "do JavaScript \"\(script)\" in tab ti of window wi"
            executeActiveLine = "do JavaScript \"\(script)\" in \(activeTab)"
        }
        return """
        tell application id "\(bundleID)"
            set winCount to count of windows
            repeat with wi from 1 to winCount
                try
                    if (URL of \(activeTab)) contains "\(urlContains)" then
                        with timeout of \(probeEventTimeoutSeconds) seconds
                            set r to \(executeActiveLine)
                        end timeout
                        if r does not contain "NOTFOUND" and r does not contain "|1" then
                            return r
                        end if
                    end if
                end try
            end repeat
            repeat with wi from 1 to winCount
                set tabCount to count of tabs of window wi
                repeat with ti from 1 to tabCount
                    if (URL of tab ti of window wi) contains "\(urlContains)" then
                        try
                            with timeout of \(probeEventTimeoutSeconds) seconds
                                set r to \(executeLine)
                            end timeout
                            if r does not contain "NOTFOUND" and r does not contain "|1" then
                                return r
                            end if
                        end try
                    end if
                end repeat
            end repeat
            return "NOTFOUND"
        end tell
        """
    }

    private static func writeTempScript(_ source: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-browser-probe-\(UUID().uuidString).applescript")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    public static func parseSeconds(fromOsascriptOutput raw: String) -> Double? {
        parseReading(fromOsascriptOutput: raw)?.seconds
    }

    public struct Reading: Equatable, Sendable {
        public let seconds: Double
        public let artworkURL: URL?
        public init(seconds: Double, artworkURL: URL?) {
            self.seconds = seconds
            self.artworkURL = artworkURL
        }
    }

    public static func parseReading(fromOsascriptOutput raw: String) -> Reading? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text.removeFirst()
            text.removeLast()
        }
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[1] == "0", let seconds = Double(parts[0]) else { return nil }
        let artwork = parts.count >= 3 ? SpotifyArtworkURL.parse(String(parts[2])) : nil
        return Reading(seconds: seconds, artworkURL: artwork)
    }
}
