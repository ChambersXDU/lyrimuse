import Foundation
import os

public final class SpotifyPositionProbe: @unchecked Sendable {
    public static let shared = SpotifyPositionProbe()
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "spotify-probe")

    public static let delayAfterTrackStart: TimeInterval = 2.0

    public static let retryAfterFailedLiveness: TimeInterval = 1.5

    public static let appleScriptTimeout: TimeInterval = 3

    public static let maxCorrectionAge: TimeInterval = 6

    public static let livenessGapSeconds: TimeInterval = 0.5

    public static func clockIsRunning(first: Double, second: Double, wallGap: TimeInterval) -> Bool {
        guard wallGap > 0 else { return false }
        let advance = second - first
        return advance >= 0.5 * wallGap && advance <= 1.5 * wallGap
    }

    private let lock = NSLock()
    private var scheduledKey: String?
    private var pending: (key: String, position: Double, at: Date)?

    private var artworkSink: (@Sendable (_ key: String, _ url: URL) -> Void)?

    private var resultSink: (@Sendable (_ key: String) -> Void)?

    public func setResultSink(_ sink: @escaping @Sendable (_ key: String) -> Void) {
        lock.lock()
        resultSink = sink
        lock.unlock()
    }

    public func setArtworkSink(_ sink: @escaping @Sendable (_ key: String, _ url: URL) -> Void) {
        lock.lock()
        artworkSink = sink
        lock.unlock()
    }

    private static let script = """
    if application "Spotify" is not running then
        return ""
    end if
    tell application "Spotify"
        set posMs to (player position * 1000) as integer
        set trackURI to (spotify url of current track) as text
        set artURL to (artwork url of current track) as text
        return (posMs as text) & "|" & trackURI & "|" & artURL
    end tell
    """

    public func trackChanged(to key: String, isSpotifyNative: Bool) {
        lock.lock()
        pending = nil
        scheduledKey = isSpotifyNative ? key : nil
        confirmationInFlight = false
        lock.unlock()
        guard isSpotifyNative else { return }
        runProbe(key: key, delay: Self.delayAfterTrackStart, isConfirmation: false, retriesLeft: 1)
    }

    public func requestConfirmation(forKey key: String) {
        lock.lock()
        let allowed = scheduledKey == key && !confirmationInFlight
        if allowed { confirmationInFlight = true }
        lock.unlock()
        guard allowed else { return }
        runProbe(key: key, delay: Self.delayAfterAnchorChange, isConfirmation: true, retriesLeft: 0)
    }

    public static let delayAfterAnchorChange: TimeInterval = 0.4
    private var confirmationInFlight = false

    private func clearConfirmationInFlight() {
        lock.lock()
        confirmationInFlight = false
        lock.unlock()
    }

    private func isKeyCurrent(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return scheduledKey == key
    }

    private func recordProbeResult(
        key: String,
        position: Double,
        midpoint: Date
    ) -> (stillScheduled: Bool, resultSink: (@Sendable (String) -> Void)?, artworkSink: (@Sendable (String, URL) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        let stillScheduled = scheduledKey == key
        if stillScheduled {
            pending = (key, position, midpoint)
        }
        return (stillScheduled, resultSink, artworkSink)
    }

    private func runProbe(key: String, delay: TimeInterval, isConfirmation: Bool, retriesLeft: Int) {
        let reason = isConfirmation ? "anchor change" : "track start"
        let deliverArtwork = !isConfirmation
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            defer {
                if isConfirmation {
                    self.clearConfirmationInFlight()
                }
            }
            guard self.isKeyCurrent(key) else { return }

            guard let first = Self.sample() else {
                Self.logger.notice("spotify position probe (\(reason, privacy: .public)): no answer for key=\(key, privacy: .public)")
                return
            }
            try? await Task.sleep(for: .seconds(Self.livenessGapSeconds))
            guard let second = Self.sample() else {
                Self.logger.notice("spotify position probe (\(reason, privacy: .public)): second sample returned nothing, discarding \(first.position, format: .fixed(precision: 3))s for key=\(key, privacy: .public)")
                return
            }
            let wallGap = second.midpoint.timeIntervalSince(first.midpoint)
            guard Self.clockIsRunning(first: first.position, second: second.position, wallGap: wallGap) else {
                Self.logger.notice("spotify position probe (\(reason, privacy: .public)): clock not advancing normally (\(first.position, format: .fixed(precision: 3)) -> \(second.position, format: .fixed(precision: 3)) over \(wallGap, format: .fixed(precision: 3))s), \(retriesLeft > 0 ? "retrying once" : "discarding", privacy: .public) for key=\(key, privacy: .public)")
                if retriesLeft > 0 {
                    self.runProbe(key: key, delay: Self.retryAfterFailedLiveness, isConfirmation: isConfirmation, retriesLeft: retriesLeft - 1)
                }
                return
            }
            let parsed = second.parsed
            let position = second.position
            let probeResult = self.recordProbeResult(key: key, position: position, midpoint: second.midpoint)
            if probeResult.stillScheduled { probeResult.resultSink?(key) }

            if deliverArtwork, probeResult.stillScheduled, let art = parsed.artworkURL, let uri = parsed.uri, SpotifyArtworkURL.isTrackURI(uri) {
                probeResult.artworkSink?(key, art)
            }
            Self.logger.notice("spotify position probe (\(reason, privacy: .public)): key=\(key, privacy: .public) position=\(position, format: .fixed(precision: 3)) (first \(first.position, format: .fixed(precision: 3)) over \(wallGap, format: .fixed(precision: 3))s) rtt=\(second.rtt, format: .fixed(precision: 3))")
        }
    }

    private struct Sample {
        let parsed: (position: Double, uri: String?, artworkURL: URL?)
        let midpoint: Date
        let rtt: TimeInterval
        var position: Double { parsed.position }
    }

    private static func sample() -> Sample? {
        let t0 = Date()
        guard let r = ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: appleScriptTimeout),
              r.succeeded,
              let parsed = parseProbeOutput(r.stdoutText)
        else { return nil }
        let t1 = Date()
        return Sample(parsed: parsed, midpoint: t0.addingTimeInterval(t1.timeIntervalSince(t0) / 2), rtt: t1.timeIntervalSince(t0))
    }

    public func consumeCorrection(forKey key: String, rate: Double, now: Date) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = pending, p.key == key else { return nil }
        pending = nil
        guard let value = Self.extrapolate(position: p.position, capturedAt: p.at, now: now, rate: rate) else { return nil }
        Self.logger.notice("spotify position probe: handing off \(value, format: .fixed(precision: 3))s for key=\(key, privacy: .public)")
        return value
    }

    public static func parseProbeOutput(_ raw: String) -> (position: Double, uri: String?, artworkURL: URL?)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let parts = s.components(separatedBy: "|")
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let position: Double
        if parts.count == 1 {
            guard let seconds = Double(first) else { return nil }
            position = seconds
        } else {
            guard let ms = Int(first) else { return nil }
            position = Double(ms) / 1000
        }
        let uriRaw = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let art = parts.count > 2 ? SpotifyArtworkURL.parse(parts[2]) : nil
        return (position, uriRaw.isEmpty ? nil : uriRaw, art)
    }

    public static func extrapolate(position: Double, capturedAt: Date, now: Date, rate: Double) -> Double? {
        let age = now.timeIntervalSince(capturedAt)
        guard age >= 0, age <= maxCorrectionAge else { return nil }
        return position + age * (rate > 0 ? rate : 1)
    }
}
