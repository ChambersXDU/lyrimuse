import Foundation

public enum MediaControlClient {
    public static let snapshotTimeout: TimeInterval = 5
    public static let artworkTimeout: TimeInterval = 10

    private static let appleMusicScript = #"""
    (() => {
        const music = Application("Music");
        try {
            if (!music.running()) return JSON.stringify(null);
            const state = music.playerState();
            if (state === "stopped") return JSON.stringify(null);
            const track = music.currentTrack;
            if (!track.exists()) return JSON.stringify(null);
            return JSON.stringify({
                title: track.name(),
                artist: track.artist(),
                album: track.album(),
                duration: track.duration(),
                elapsedTime: music.playerPosition(),
                playing: state === "playing",
                playbackRate: state === "playing" ? 1 : 0,
                isMusicApp: true,
                bundleIdentifier: "com.apple.Music"
            });
        } catch (error) {
            return JSON.stringify(null);
        }
    })()
    """#

    public static func fetchSnapshot(players: Set<PlaybackPlayer> = [.appleMusic]) -> MediaControlSnapshot? {
        guard players.isEmpty || players.contains(.appleMusic) else { return nil }
        guard let result = ProcessRunner.run(
            "/usr/bin/osascript", ["-l", "JavaScript", "-e", appleMusicScript],
            timeout: MusicPlaybackController.appleScriptTimeout), result.succeeded else { return nil }
        return try? JSONDecoder().decode(MediaControlSnapshot.self, from: result.stdout)
    }

    public static func systemPlaybackBundleID() -> String? {
        fetchSnapshot() == nil ? nil : PlaybackPlayer.appleMusic.bundleIdentifier
    }

    public static func currentRadioStationHash() -> String? { nil }

    public static func fetchArtwork(players: Set<PlaybackPlayer> = [.appleMusic]) -> (data: Data, mimeType: String, trackKey: String)? {
        nil
    }

    public static func ageCompensatedCachedElapsed(
        cachedElapsed: Double?, cachedPlaying: Bool?, cachedRate: Double?, cachedAt: Date?,
        freshElapsed: Double?, freshPlaying: Bool?, now: Date = Date()
    ) -> Double? {
        guard freshPlaying == true, cachedPlaying == true,
              let cachedElapsed, let cachedAt else { return nil }
        let age = now.timeIntervalSince(cachedAt)
        guard age >= 0 else { return nil }
        let rate = (cachedRate ?? 1) > 0 ? (cachedRate ?? 1) : 1
        let extrapolated = cachedElapsed + age * rate
        if let freshElapsed, abs(extrapolated - freshElapsed) > 2 { return nil }
        return extrapolated
    }

    public nonisolated static let staleAnchorAfter: TimeInterval = 2
    public nonisolated static let frozenAnchorPauseDrop: Double = 3

    public nonisolated static func estimatedAnchorInstant(timestamp: Date, firstSeenAt: Date) -> Date {
        let gap = firstSeenAt.timeIntervalSince(timestamp)
        return gap > 0 ? timestamp.addingTimeInterval(min(1, gap) / 2) : timestamp
    }

    public struct AnchorSighting: Sendable, Equatable {
        public let at: Date
        public let tight: Bool
        public init(at: Date, tight: Bool) { self.at = at; self.tight = tight }
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
        return last - reported > frozenAnchorPauseDrop ? last : reported
    }

    public nonisolated static let pauseAnchorMaxSkew: TimeInterval = 1.5

    public nonisolated static func pausedPositionSeconds(
        elapsedTime: Double?, anchorTimestamp: Date?,
        lastPlaying: (position: Double, sampledAt: Date)?, pauseObservedAt: Date?, now: Date
    ) -> Double? {
        guard let lastPlaying else { return elapsedTime }
        guard let reported = elapsedTime else { return lastPlaying.position }
        if let pauseObservedAt,
           pauseObservedAt >= lastPlaying.sampledAt.addingTimeInterval(-0.5),
           pauseObservedAt <= now.addingTimeInterval(0.5) {
            if let anchorTimestamp, pauseObservedAt.timeIntervalSince(anchorTimestamp) > pauseAnchorMaxSkew {
                return lastPlaying.position + max(0, pauseObservedAt.timeIntervalSince(lastPlaying.sampledAt))
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
            let rate = (playbackRate ?? 1) > 0 ? (playbackRate ?? 1) : 1
            let age = now.timeIntervalSince(republishedAnchorInstant)
            return age > 0 ? base + age * rate : base
        }
        if let rate = playbackRate, rate > 0, let base = elapsedTime, let timestamp,
           let effectiveSighting, now.timeIntervalSince(timestamp) > staleAnchorAfter {
            let anchor = estimatedAnchorInstant(timestamp: timestamp, sighting: effectiveSighting)
            let age = now.timeIntervalSince(anchor)
            if age > 0 { return base + age * rate }
        }
        if let rate = playbackRate, rate > 0, let elapsedTimeNow { return elapsedTimeNow }
        guard let base = elapsedTime, let timestamp else { return elapsedTimeNow ?? elapsedTime }
        let anchor = effectiveSighting.map { estimatedAnchorInstant(timestamp: timestamp, sighting: $0) } ?? timestamp
        let age = now.timeIntervalSince(anchor)
        return age > 0 ? base + age : base
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public nonisolated static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return plainTimestampFormatter.date(from: value) ?? timestampFormatter.date(from: value)
    }
}
