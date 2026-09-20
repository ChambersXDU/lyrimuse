import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "media-control")

public enum MediaControlClient {

    static let snapshotTimeout: TimeInterval = 5

    static let artworkTimeout: TimeInterval = 10

    public static func fetchSnapshot(players: Set<PlaybackPlayer> = PlaybackPlayerPreference.selected) -> MediaControlSnapshot? {
        if players.contains(.auto) { return fetchAutoDetectedSnapshot() }
        if players == [.appleMusic] { return radioAwareAppleMusicSnapshot() }
        guard !players.isEmpty else { return nil }
        return fetchMultiSelectedSnapshot(players)
    }

    private static let script = """
    (() => {
        const Music = Application("Music");
        try {
            if (!Music.running()) return JSON.stringify(null);
        } catch (e) {
            return JSON.stringify(null);
        }
        let state;
        try {
            state = Music.playerState();
        } catch (e) {
            return JSON.stringify(null);
        }
        if (state === "stopped") return JSON.stringify(null);
        let track;
        try {
            track = Music.currentTrack;
            if (!track.exists()) return JSON.stringify(null);
        } catch (e) {
            return JSON.stringify(null);
        }
        try {
            return JSON.stringify({
                title: track.name(),
                artist: track.artist(),
                album: track.album(),
                duration: track.duration(),
                elapsedTime: Music.playerPosition(),
                playing: state === "playing",
                playbackRate: state === "playing" ? 1 : 0,
                isMusicApp: true,
                bundleIdentifier: "com.apple.Music"
            });
        } catch (e) {
            return JSON.stringify(null);
        }
    })()
    """

    private static func fetchAppleMusicSnapshot() -> MediaControlSnapshot? {
        guard let r = ProcessRunner.run(
            "/usr/bin/osascript", ["-l", "JavaScript", "-e", script],
            timeout: MusicPlaybackController.appleScriptTimeout),
            r.succeeded
        else { return nil }
        return try? JSONDecoder().decode(MediaControlSnapshot.self, from: r.stdout)
    }

    private static func radioAwareAppleMusicSnapshot() -> MediaControlSnapshot? {
        guard let snapshot = fetchAppleMusicSnapshot() else { return nil }
        guard let hash = probedRadioStationHash(forTrack: snapshot.trackKey) else {
            setRadioStationHash(nil)
            return snapshot
        }
        setRadioStationHash(hash)

        let position = advanceRadioClock(
            trackKey: snapshot.trackKey, playing: snapshot.playing == true, now: Date(),
            startedAt: lastTrackChangeObserved(forKey: snapshot.trackKey))
        return snapshot.withRadio(position: position)
    }

    public static func radioProbeNeeded(cachedKey: String?, trackKey: String) -> Bool {
        cachedKey != trackKey
    }

    private static let appleMusicRadioProbeLock = NSLock()
    private static var appleMusicRadioProbedKey: String?
    private static var appleMusicRadioProbedHash: String?

    private static func probedRadioStationHash(forTrack trackKey: String) -> String? {
        appleMusicRadioProbeLock.lock()
        if !radioProbeNeeded(cachedKey: appleMusicRadioProbedKey, trackKey: trackKey) {
            defer { appleMusicRadioProbeLock.unlock() }
            return appleMusicRadioProbedHash
        }
        appleMusicRadioProbeLock.unlock()
        let hash = probeRadioStationHash()
        appleMusicRadioProbeLock.lock()
        appleMusicRadioProbedKey = trackKey
        appleMusicRadioProbedHash = hash
        appleMusicRadioProbeLock.unlock()
        return hash
    }

    private static func probeRadioStationHash() -> String? {
        guard let binaryPath = binaryPath(),
              let r = ProcessRunner.run(
                  binaryPath, ["get", "--now", "--no-artwork"], timeout: snapshotTimeout),
              r.succeeded,
              let raw = try? JSONDecoder().decode(RawPayload.self, from: r.stdout)
        else { return nil }

        guard raw.bundleIdentifier == PlaybackPlayer.appleMusic.bundleIdentifier else { return nil }
        let hash = raw.radioStationHash ?? ""
        return hash.isEmpty ? nil : hash
    }

    private struct RawPayload: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let bundleIdentifier: String?
        let duration: Double?
        let elapsedTime: Double?
        let elapsedTimeNow: Double?
        let playing: Bool?
        let playbackRate: Double?

        let timestamp: String?

        let radioStationHash: String?
    }

    public static func binaryPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else {
            logger.error("app bundle resourcePath unavailable")
            return nil
        }
        let binaryPath = resourcePath + "/media-control/bin/media-control"
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            logger.error("media-control binary not found in app bundle")
            return nil
        }
        return binaryPath
    }

    private static func fetchMediaControlSnapshot(expectedBundleID: String) -> MediaControlSnapshot? {
        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot(), bundleID == expectedBundleID else {
            return nil
        }
        return snapshot
    }

    private static func fetchMultiSelectedSnapshot(_ players: Set<PlaybackPlayer>) -> MediaControlSnapshot? {
        let acceptedBundleIDs = Set(players.map(\.bundleIdentifier))
        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot() else { return nil }
        if !acceptedBundleIDs.contains(bundleID) {
            guard TrustedPlayers.isTrusted(bundleID) else { return nil }

            guard !trustedPlaybackRejected(bundleID: bundleID, snapshot: snapshot) else {
                return nil
            }
            return refinedAppleMusicSnapshotIfNeeded(
                bundleID: bundleID, snapshot: snapshotWithProbedAlbum(snapshot))
        }
        return refinedAppleMusicSnapshotIfNeeded(bundleID: bundleID, snapshot: snapshot)
    }

    private static let appleMusicSnapshotCacheLock = NSLock()
    private static var cachedAppleMusicSnapshot: MediaControlSnapshot?
    private static var cachedAppleMusicSnapshotAt: Date?
    private static var isRefreshingAppleMusicSnapshot = false

    private static func fetchAutoDetectedSnapshot() -> MediaControlSnapshot? {

        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot(),
              TrustedPlayers.isAccepted(bundleID) else {
            return nil
        }

        guard !trustedPlaybackRejected(bundleID: bundleID, snapshot: snapshot) else {
            return nil
        }
        return refinedAppleMusicSnapshotIfNeeded(
            bundleID: bundleID, snapshot: snapshotWithProbedAlbum(snapshot))
    }

    private static func snapshotWithProbedAlbum(_ snapshot: MediaControlSnapshot)
        -> MediaControlSnapshot {
        let key = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        guard let album = YouTubeMusicAdProbe.albumPatch(
            reported: snapshot.album,
            reading: YouTubeMusicAdProbe.shared.cachedReading(forKey: key))
        else { return snapshot }
        return snapshot.withAlbum(album)
    }

    private static func trustedPlaybackRejected(
        bundleID: String, snapshot: MediaControlSnapshot
    ) -> Bool {
        guard TrustedPlayers.notASong(
            bundleID: bundleID, artist: snapshot.artist, album: snapshot.album) else {
            return false
        }

        if spotifyWebAdAccepted(bundleID: bundleID, snapshot: snapshot) { return false }
        guard !(snapshot.artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
            return true
        }
        let key = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        YouTubeMusicAdProbe.shared.kickIfNeeded(bundleIdentifier: bundleID, key: key)
        let verdict = YouTubeMusicAdProbe.shared.cachedVerdict(forKey: key)
        return YouTubeMusicAdProbe.gate(artist: snapshot.artist, verdict: verdict) == .reject
    }

    private static func spotifyWebAdAccepted(
        bundleID: String, snapshot: MediaControlSnapshot
    ) -> Bool {
        guard SpotifyWebAdProbe.fieldShapeNeedsProbe(title: snapshot.title,
                                                     artist: snapshot.artist) else { return false }
        let host = BrowserPositionProbe.probeTargetBundleID(forReported: bundleID)
        guard BrowserPositionProbe.shared.isPaired(bundleID: host, platformID: "spotifyWeb") else {
            return false
        }
        let key = SpotifyWebAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        SpotifyWebAdProbe.shared.kickIfNeeded(bundleIdentifier: bundleID, key: key)
        let verdict = SpotifyWebAdProbe.shared.cachedVerdict(forKey: key)
        return SpotifyWebAdProbe.gate(verdict: verdict) == .acceptAsAd
    }

    private static func refinedAppleMusicSnapshotIfNeeded(
        bundleID: String, snapshot: MediaControlSnapshot
    ) -> MediaControlSnapshot {
        guard bundleID == PlaybackPlayer.appleMusic.bundleIdentifier else { return snapshot }

        guard snapshot.isRadio != true else { return snapshot }

        if snapshot.playing == true {
            refreshAppleMusicSnapshotCacheInBackground()
        }
        appleMusicSnapshotCacheLock.lock()
        let cached = cachedAppleMusicSnapshot
        let cachedAt = cachedAppleMusicSnapshotAt
        appleMusicSnapshotCacheLock.unlock()

        guard let cached, cached.title == snapshot.title, cached.artist == snapshot.artist,
              let compensated = ageCompensatedCachedElapsed(
                  cachedElapsed: cached.elapsedTime, cachedPlaying: cached.playing,
                  cachedRate: cached.playbackRate, cachedAt: cachedAt,
                  freshElapsed: snapshot.elapsedTime, freshPlaying: snapshot.playing
              ) else {
            return snapshot
        }
        return MediaControlSnapshot(
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            duration: snapshot.duration,
            elapsedTime: compensated,
            playing: snapshot.playing,
            playbackRate: snapshot.playbackRate,
            isMusicApp: snapshot.isMusicApp,
            bundleIdentifier: snapshot.bundleIdentifier,
            anchorElapsedTime: snapshot.anchorElapsedTime,
            isRadio: snapshot.isRadio
        )
    }

    public static func ageCompensatedCachedElapsed(
        cachedElapsed: Double?, cachedPlaying: Bool?, cachedRate: Double?, cachedAt: Date?,
        freshElapsed: Double?, freshPlaying: Bool?, now: Date = Date()
    ) -> Double? {

        guard freshPlaying == true, cachedPlaying == true,
              let cachedElapsed, let cachedAt else { return nil }
        let age = now.timeIntervalSince(cachedAt)
        guard age >= 0 else { return nil }
        var rate = cachedRate ?? 1
        if rate <= 0 { rate = 1 }
        let extrapolated = cachedElapsed + age * rate
        if let freshElapsed, abs(extrapolated - freshElapsed) > 2.0 { return nil }
        return extrapolated
    }

    private static func refreshAppleMusicSnapshotCacheInBackground() {
        appleMusicSnapshotCacheLock.lock()
        guard !isRefreshingAppleMusicSnapshot else {
            appleMusicSnapshotCacheLock.unlock()
            return
        }
        isRefreshingAppleMusicSnapshot = true
        appleMusicSnapshotCacheLock.unlock()
        Thread.detachNewThread {
            let result = fetchAppleMusicSnapshot()
            let capturedAt = Date()
            appleMusicSnapshotCacheLock.lock()
            cachedAppleMusicSnapshot = result
            cachedAppleMusicSnapshotAt = capturedAt
            isRefreshingAppleMusicSnapshot = false
            appleMusicSnapshotCacheLock.unlock()
        }
    }

    public static func fetchArtwork(players: Set<PlaybackPlayer> = PlaybackPlayerPreference.selected) -> (data: Data, mimeType: String, trackKey: String)? {
        guard let binaryPath = binaryPath() else { return nil }
        guard let r = ProcessRunner.run(
            binaryPath, ["get", "--now"], timeout: artworkTimeout),
            r.succeeded
        else { return nil }
        guard let raw = try? JSONDecoder().decode(ArtworkPayload.self, from: r.stdout),
              let bundleID = raw.bundleIdentifier,
              artworkBundleIDMatches(bundleID, players: players),
              let base64 = raw.artworkData,
              let imageData = Data(base64Encoded: base64) else {
            return nil
        }
        return (imageData, raw.artworkMimeType ?? "image/jpeg",
                MediaControlSnapshot.trackKey(artist: raw.artist, title: raw.title))
    }

    private struct ArtworkPayload: Decodable {
        let bundleIdentifier: String?
        let artworkData: String?
        let artworkMimeType: String?
        let title: String?
        let artist: String?
    }

    private static func artworkBundleIDMatches(_ bundleID: String, players: Set<PlaybackPlayer>) -> Bool {
        if players.contains(.auto) {
            return TrustedPlayers.isAccepted(bundleID)
        }
        if players.contains(where: { $0.bundleIdentifier == bundleID }) { return true }
        return TrustedPlayers.isTrusted(bundleID)
    }

    public nonisolated static let staleAnchorAfter: TimeInterval = 2.0

    public nonisolated static let frozenAnchorPauseDrop: Double = 3.0

    public nonisolated static func estimatedAnchorInstant(timestamp: Date, firstSeenAt: Date) -> Date {
        let observedGap = firstSeenAt.timeIntervalSince(timestamp)

        guard observedGap > 0 else { return timestamp }
        return timestamp.addingTimeInterval(min(1.0, observedGap) / 2)
    }

    public struct AnchorSighting: Sendable, Equatable {
        public let at: Date
        public let tight: Bool
        public init(at: Date, tight: Bool) {
            self.at = at
            self.tight = tight
        }
    }

    public nonisolated static let streamAnchorLatency: TimeInterval = 0.025

    public nonisolated static let tightSightingMaxAge: TimeInterval = 1.5

    public nonisolated static func estimatedAnchorInstant(timestamp: Date, sighting: AnchorSighting) -> Date {
        guard sighting.tight else { return estimatedAnchorInstant(timestamp: timestamp, firstSeenAt: sighting.at) }
        let guess = sighting.at.timeIntervalSince(timestamp) - streamAnchorLatency
        return timestamp.addingTimeInterval(min(max(guess, 0), 0.999))
    }

    public nonisolated static func pausedPositionSeconds(
        elapsedTime: Double?, anchorAge: TimeInterval?, lastPlayingPosition: Double?
    ) -> Double? {
        guard let last = lastPlayingPosition else { return elapsedTime }
        guard let reported = elapsedTime else { return last }
        guard let age = anchorAge, age > staleAnchorAfter else { return reported }
        return (last - reported) > frozenAnchorPauseDrop ? last : reported
    }

    public nonisolated static let pauseAnchorMaxSkew: TimeInterval = 1.5

    public nonisolated static func pausedPositionSeconds(
        elapsedTime: Double?, anchorTimestamp: Date?,
        lastPlaying: (position: Double, sampledAt: Date)?, pauseObservedAt: Date?, now: Date
    ) -> Double? {
        guard let lastPlaying else { return elapsedTime }
        guard let reported = elapsedTime else { return lastPlaying.position }
        if let pauseAt = pauseObservedAt,
           pauseAt >= lastPlaying.sampledAt.addingTimeInterval(-0.5), pauseAt <= now.addingTimeInterval(0.5) {
            if let anchorTimestamp, pauseAt.timeIntervalSince(anchorTimestamp) > pauseAnchorMaxSkew {
                return lastPlaying.position + max(0, pauseAt.timeIntervalSince(lastPlaying.sampledAt))
            }
            return reported
        }
        return pausedPositionSeconds(
            elapsedTime: reported,
            anchorAge: anchorTimestamp.map { now.timeIntervalSince($0) },
            lastPlayingPosition: lastPlaying.position)
    }

    public nonisolated static func livePositionSeconds(
        playing: Bool?, elapsedTime: Double?, elapsedTimeNow: Double?,
        playbackRate: Double?, timestamp: Date?, now: Date,
        lastPlayingPosition: Double? = nil,
        firstSeenAt: Date? = nil,
        sighting: AnchorSighting? = nil,
        republishedAnchorInstant: Date? = nil,
        lastPlayingSampledAt: Date? = nil,
        pauseObservedAt: Date? = nil
    ) -> Double? {

        let effectiveSighting = sighting ?? firstSeenAt.map { AnchorSighting(at: $0, tight: false) }

        guard playing == true else {
            if let lastPlayingPosition, let lastPlayingSampledAt {
                return pausedPositionSeconds(
                    elapsedTime: elapsedTime, anchorTimestamp: timestamp,
                    lastPlaying: (lastPlayingPosition, lastPlayingSampledAt),
                    pauseObservedAt: pauseObservedAt, now: now)
            }
            return pausedPositionSeconds(
                elapsedTime: elapsedTime,
                anchorAge: timestamp.map { now.timeIntervalSince($0) },
                lastPlayingPosition: lastPlayingPosition)
        }

        if let republishedAnchorInstant, let base = elapsedTime {
            let rate = (playbackRate ?? 0) > 0 ? (playbackRate ?? 1) : 1
            let aged = now.timeIntervalSince(republishedAnchorInstant)
            return aged > 0 ? base + aged * rate : base
        }

        if let rate = playbackRate, rate > 0, let base = elapsedTime, let timestamp,
           let effectiveSighting, now.timeIntervalSince(timestamp) > staleAnchorAfter {
            let corrected = estimatedAnchorInstant(timestamp: timestamp, sighting: effectiveSighting)
            let aged = now.timeIntervalSince(corrected)
            if aged > 0 { return base + aged * rate }
        }

        if let rate = playbackRate, rate > 0, let now = elapsedTimeNow { return now }

        guard let base = elapsedTime, let timestamp else { return elapsedTimeNow ?? elapsedTime }
        let anchorInstant = effectiveSighting.map { estimatedAnchorInstant(timestamp: timestamp, sighting: $0) } ?? timestamp
        let aged = now.timeIntervalSince(anchorInstant)
        return aged > 0 ? base + aged : base
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated static let plainTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public nonisolated static func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = plainTimestampFormatter.date(from: s) { return d }
        return timestampFormatter.date(from: s)
    }

    public struct UngatedNowPlaying: Sendable, Equatable {
        public let bundleID: String
        public let artist: String
        public let album: String
        public let title: String
        public let at: Date
    }

    private static let playingPositionLock = NSLock()
    nonisolated(unsafe) private static var playingPositionTrack: String?
    nonisolated(unsafe) private static var playingPositionValue: Double?
    nonisolated(unsafe) private static var playingPositionSampledAt: Date?
    nonisolated(unsafe) private static var pauseObservedAt: Date?

    nonisolated static func notePauseObserved(at: Date) {
        playingPositionLock.lock()
        pauseObservedAt = at
        playingPositionLock.unlock()
    }

    private nonisolated static func lastPauseObservedAt() -> Date? {
        playingPositionLock.lock()
        defer { playingPositionLock.unlock() }
        return pauseObservedAt
    }

    nonisolated(unsafe) private static var trackChangeKey: String?
    nonisolated(unsafe) private static var trackChangeAt: Date?

    nonisolated static func noteTrackChangeObserved(key: String, at: Date) {
        playingPositionLock.lock()
        trackChangeKey = key
        trackChangeAt = at
        playingPositionLock.unlock()
    }

    private nonisolated static func lastTrackChangeObserved(forKey key: String) -> Date? {
        playingPositionLock.lock()
        defer { playingPositionLock.unlock() }
        guard trackChangeKey == key else { return nil }
        return trackChangeAt
    }

    private nonisolated static func rememberedPlayingSampledAt(forTrack track: String) -> Date? {
        playingPositionLock.lock()
        defer { playingPositionLock.unlock() }
        guard playingPositionTrack == track else { return nil }
        return playingPositionSampledAt
    }

    private static let anchorSeenLock = NSLock()
    nonisolated(unsafe) private static var anchorSightings: [String: AnchorSighting] = [:]
    private static let anchorSightingCapacity = 16

    private nonisolated static func firstSeen(anchorKey: String, now: Date) -> AnchorSighting {
        anchorSeenLock.lock()
        defer { anchorSeenLock.unlock() }
        if let existing = anchorSightings[anchorKey] { return existing }
        let sighting = AnchorSighting(at: now, tight: false)
        anchorSightings[anchorKey] = sighting
        pruneAnchorSightingsLocked()
        return sighting
    }

    nonisolated static func noteStreamAnchorSighting(anchorKey: String, at: Date, tight: Bool) {
        anchorSeenLock.lock()
        defer { anchorSeenLock.unlock() }
        if let existing = anchorSightings[anchorKey] {
            if existing.tight {
                guard tight, at < existing.at else { return }
            } else {
                guard tight || at < existing.at else { return }
            }
        }
        anchorSightings[anchorKey] = AnchorSighting(at: at, tight: tight)
        pruneAnchorSightingsLocked()
    }

    private nonisolated static func pruneAnchorSightingsLocked() {
        guard anchorSightings.count > anchorSightingCapacity else { return }
        let oldestFirst = anchorSightings.sorted { $0.value.at < $1.value.at }
        for (key, _) in oldestFirst.prefix(anchorSightings.count - anchorSightingCapacity) {
            anchorSightings.removeValue(forKey: key)
        }
    }

    public nonisolated static func anchorKey(artist: String?, title: String?, elapsedTime: Double?, timestamp: String?) -> String {
        let elapsed = elapsedTime.map { String(format: "%.3f", $0) } ?? "-"
        return "\(MediaControlSnapshot.trackKey(artist: artist, title: title))|\(elapsed)|\(timestamp ?? "-")"
    }

    public struct PlayingAnchor: Sendable, Equatable {
        public let track: String
        public let elapsed: Double
        public let timestamp: String
        public let instant: Date
        public init(track: String, elapsed: Double, timestamp: String, instant: Date) {
            self.track = track
            self.elapsed = elapsed
            self.timestamp = timestamp
            self.instant = instant
        }
    }

    public nonisolated static func isStaleAnchorRepublish(
        last: PlayingAnchor?, track: String, elapsed: Double?, timestamp: String?, duration: Double?, now: Date
    ) -> Bool {
        guard let last, let elapsed, let timestamp,
              last.track == track, last.elapsed == elapsed, elapsed > 0, last.timestamp != timestamp
        else { return false }
        if let duration, duration > 0, last.elapsed + now.timeIntervalSince(last.instant) > duration + 1 {
            return false
        }
        return true
    }

    private static let playingAnchorLock = NSLock()
    nonisolated(unsafe) private static var lastPlayingAnchor: PlayingAnchor?
    nonisolated(unsafe) private static var lastIgnoredRepublishTimestamp: String?

    private nonisolated static func trackPlayingAnchor(
        track: String, elapsed: Double, timestamp: String, candidateInstant: Date, duration: Double?, now: Date
    ) -> Date? {
        playingAnchorLock.lock()
        defer { playingAnchorLock.unlock() }
        if let last = lastPlayingAnchor,
           isStaleAnchorRepublish(last: last, track: track, elapsed: elapsed, timestamp: timestamp, duration: duration, now: now) {
            if lastIgnoredRepublishTimestamp != timestamp {
                lastIgnoredRepublishTimestamp = timestamp
                logger.notice("stale anchor republish ignored: elapsed=\(elapsed, format: .fixed(precision: 3)) newTs=\(timestamp, privacy: .public) keepingAnchorTs=\(last.timestamp, privacy: .public) track=\(track, privacy: .public)")
            }
            return last.instant
        }
        lastPlayingAnchor = PlayingAnchor(track: track, elapsed: elapsed, timestamp: timestamp, instant: candidateInstant)
        lastIgnoredRepublishTimestamp = nil
        return nil
    }

    private nonisolated static func rememberedPlayingPosition(forTrack track: String) -> Double? {
        playingPositionLock.lock()
        defer { playingPositionLock.unlock() }
        guard playingPositionTrack == track else { return nil }
        return playingPositionValue
    }

    private nonisolated static func rememberPlayingPosition(_ position: Double, forTrack track: String, at sampledAt: Date) {
        playingPositionLock.lock()
        playingPositionTrack = track
        playingPositionValue = position
        playingPositionSampledAt = sampledAt
        playingPositionLock.unlock()
    }

    private static let ungatedLock = NSLock()
    nonisolated(unsafe) private static var lastUngated: UngatedNowPlaying?

    public static var lastUngatedNowPlaying: UngatedNowPlaying? {
        ungatedLock.lock()
        defer { ungatedLock.unlock() }
        return lastUngated
    }

    private static func recordUngatedNowPlaying(bundleID: String, artist: String?,
                                               album: String?, title: String?) {
        guard !bundleID.isEmpty else { return }
        let observed = UngatedNowPlaying(
            bundleID: bundleID, artist: artist ?? "", album: album ?? "",
            title: title ?? "", at: Date())
        ungatedLock.lock()
        lastUngated = observed
        ungatedLock.unlock()
    }

    private static func fetchRawMediaControlSnapshot() -> (MediaControlSnapshot, String)? {
        guard let binaryPath = binaryPath() else { return nil }

        guard let r = ProcessRunner.run(
            binaryPath, ["get", "--now", "--no-artwork"], timeout: snapshotTimeout),
            r.succeeded
        else { return nil }
        let data = r.stdout

        guard let raw = try? JSONDecoder().decode(RawPayload.self, from: data),
              let bundleID = raw.bundleIdentifier else {
            return nil
        }

        recordUngatedNowPlaying(bundleID: bundleID, artist: raw.artist, album: raw.album,
                                title: raw.title)

        let trackKey = MediaControlSnapshot.trackKey(artist: raw.artist, title: raw.title)
        let sampledAt = Date()

        let anchorKey = Self.anchorKey(
            artist: raw.artist, title: raw.title, elapsedTime: raw.elapsedTime, timestamp: raw.timestamp)
        let timestampDate = Self.parseTimestamp(raw.timestamp)
        let sighting = Self.firstSeen(anchorKey: anchorKey, now: sampledAt)

        var republishedAnchorInstant: Date?
        if raw.playing == true, let timestampDate, let elapsedRaw = raw.elapsedTime, let timestampString = raw.timestamp {
            let candidate = Self.estimatedAnchorInstant(timestamp: timestampDate, sighting: sighting)
            republishedAnchorInstant = Self.trackPlayingAnchor(
                track: trackKey, elapsed: elapsedRaw, timestamp: timestampString,
                candidateInstant: candidate, duration: raw.duration, now: sampledAt)
        }
        let elapsed = Self.livePositionSeconds(
            playing: raw.playing, elapsedTime: raw.elapsedTime, elapsedTimeNow: raw.elapsedTimeNow,
            playbackRate: raw.playbackRate, timestamp: timestampDate, now: sampledAt,
            lastPlayingPosition: Self.rememberedPlayingPosition(forTrack: trackKey),
            sighting: sighting, republishedAnchorInstant: republishedAnchorInstant,
            lastPlayingSampledAt: Self.rememberedPlayingSampledAt(forTrack: trackKey),
            pauseObservedAt: Self.lastPauseObservedAt())
        if raw.playing == true, let elapsed {
            Self.rememberPlayingPosition(elapsed, forTrack: trackKey, at: sampledAt)
        }

        let isRadio = !(raw.radioStationHash ?? "").isEmpty
        Self.setRadioStationHash(isRadio ? raw.radioStationHash : nil)
        let radioPosition: Double? = isRadio
            ? Self.advanceRadioClock(trackKey: trackKey, playing: raw.playing == true, now: sampledAt,
                                     startedAt: Self.lastTrackChangeObserved(forKey: trackKey))
            : nil
        let snapshot = MediaControlSnapshot(
            title: raw.title,
            artist: raw.artist,
            album: raw.album,
            duration: raw.duration,
            elapsedTime: radioPosition ?? elapsed,
            playing: raw.playing,
            playbackRate: raw.playbackRate,
            isMusicApp: true,
            bundleIdentifier: bundleID,
            anchorElapsedTime: radioPosition ?? raw.elapsedTime,
            isRadio: isRadio ? true : nil
        )
        return (snapshot, bundleID)
    }

    private static let radioClockLock = NSLock()
    private static var radioClockState: RadioTrackClock.State?

    private static var radioClockWritten: RadioClockRecord?

    private static var radioClockRestoreTried = false

    nonisolated(unsafe) private static var radioStationHashValue: String?

    public nonisolated static func currentRadioStationHash() -> String? {
        radioClockLock.lock()
        defer { radioClockLock.unlock() }
        return radioStationHashValue
    }

    private static func setRadioStationHash(_ hash: String?) {
        radioClockLock.lock()
        radioStationHashValue = hash
        radioClockLock.unlock()
    }

    private static func advanceRadioClock(trackKey: String, playing: Bool, now: Date, startedAt: Date?) -> Double {
        radioClockLock.lock()
        defer { radioClockLock.unlock() }

        if radioClockState == nil, !radioClockRestoreTried {
            radioClockRestoreTried = true
            if let restored = RadioClockFile.restorable(RadioClockFile.load(), trackKey: trackKey, now: now) {
                radioClockState = restored
                logger.notice("radio clock: restored key=\(trackKey, privacy: .public) position=\(restored.position, format: .fixed(precision: 3)) gap=\(now.timeIntervalSince(restored.tickedAt), format: .fixed(precision: 3))")
            }
        }
        let next = RadioTrackClock.advance(radioClockState, trackKey: trackKey, playing: playing, now: now,
                                           startedAt: startedAt)

        if radioClockState?.trackKey != trackKey {
            logger.notice("radio clock: start key=\(trackKey, privacy: .public) seed=\(next.position, format: .fixed(precision: 3)) observed=\(startedAt == nil ? "no" : "yes", privacy: .public)")
        }
        radioClockState = next

        let record = RadioClockRecord(trackKey: next.trackKey, position: next.position,
                                      tickedAtMs: Int64(next.tickedAt.timeIntervalSince1970 * 1000),
                                      playing: next.playing)
        if RadioClockFile.shouldWrite(previous: radioClockWritten, next: record, now: now) {
            radioClockWritten = record
            RadioClockFile.write(record)
        }
        return next.position
    }
}
