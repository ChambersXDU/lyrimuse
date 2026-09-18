import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "media-control")

// Two independent snapshot acquisition paths dispatched based on `PlaybackPlayerPreference.selected`:
//
// - Apple Music: Uses AppleScript (JXA) to query Music.app directly for playback state without requiring
//   external helper processes. Requires `MusicAutomationPermission`. Provides real-time `playerPosition`
//   (~0.1s precision) without frozen anchor offsets during continuous playback.
//
// - Third-party players (QQ Music, NetEase Music, Spotify, Kugou):
//   Because these applications lack AppleScript dictionaries (.sdef) or scriptability support,
//   playback telemetry is extracted via the system-level MediaRemote framework using the bundled
//   `media-control` binary. Key considerations:
//   1. Raw `elapsedTime` and `timestamp` fields can freeze during steady playback; the `--now` flag
//      extrapolates elapsed time against wall-clock time within a ~0.5s tolerance.
//   2. MediaRemote queries are system-wide; to avoid attributing state from unrelated media sources
//      (e.g., web video or background audio), results are verified against `PlaybackPlayer.bundleIdentifier`.
public enum MediaControlClient {
    /// Status query timeout. This is executed on the 2-second polling path.
    static let snapshotTimeout: TimeInterval = 5
    /// Artwork extraction timeout. Artwork base64 data can be hundreds of kilobytes and is fetched only on track changes.
    static let artworkTimeout: TimeInterval = 10


    /// Retrieves current playback snapshot according to selected player preferences:
    ///   - Automatic detection enabled (`.auto`): invokes `fetchAutoDetectedSnapshot()`.
    ///   - Exclusively Apple Music: skips `media-control` subprocess overhead and queries
    ///     AppleScript directly via `radioAwareAppleMusicSnapshot()`, probing for radio
    ///     station hashes on track transitions.
    ///   - Other player combinations: queries `fetchMultiSelectedSnapshot(_:)`, ensuring
    ///     the active system Now Playing focus matches the designated player set.
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

    // 失败(没有"自动化"权限/Music.app 没在运行/没有曲目在加载/JSON 解析失败)一律
    // 返回 nil,不抛出——上层按"这次没拿到数据,下一轮再试"处理,理由跟旧版一致。
    // 没有权限时 osascript 会返回非零退出码(而不是抛出 Swift 异常),同样落进
    // `guard terminationStatus == 0` 这条分支,不需要单独处理。
    private static func fetchAppleMusicSnapshot() -> MediaControlSnapshot? {
        guard let r = ProcessRunner.run(
            "/usr/bin/osascript", ["-l", "JavaScript", "-e", script],
            timeout: MusicPlaybackController.appleScriptTimeout),
            r.succeeded
        else { return nil }
        return try? JSONDecoder().decode(MediaControlSnapshot.self, from: r.stdout)
    }

    // MARK: - Apple Music Radio Station State Resolution

    /// Augments the AppleScript snapshot with MediaRemote radio metadata (`radioStationHash`).
    ///
    /// When only Apple Music is selected without automatic detection, pure AppleScript queries cannot
    /// access `radioStationHash` (a MediaRemote-specific attribute). Without this probe, radio stream
    /// detection would fail and playback position would reflect total broadcast duration rather than
    /// individual track boundaries.
    ///
    /// The probe is executed once per unique track transition (`snapshot.trackKey`) rather than on every
    /// tick, preserving minimal subprocess overhead while maintaining accurate radio state.
    private static func radioAwareAppleMusicSnapshot() -> MediaControlSnapshot? {
        guard let snapshot = fetchAppleMusicSnapshot() else { return nil }
        guard let hash = probedRadioStationHash(forTrack: snapshot.trackKey) else {
            setRadioStationHash(nil)
            return snapshot
        }
        setRadioStationHash(hash)
        // Position is substituted with track-scoped clock; system duration and elapsed time reflect total show length.
        let position = advanceRadioClock(
            trackKey: snapshot.trackKey, playing: snapshot.playing == true, now: Date(),
            startedAt: lastTrackChangeObserved(forKey: snapshot.trackKey))
        return snapshot.withRadio(position: position)
    }

    /// 这一拍要不要为电台判据多问一次 media-control。纯函数,selftest 直接覆盖。
    /// 判据只有一条:曲目 key 变了 —— "是不是电台"在同一个 key 内不会翻转,理由见
    /// `radioAwareAppleMusicSnapshot` 头注。
    public static func radioProbeNeeded(cachedKey: String?, trackKey: String) -> Bool {
        cachedKey != trackKey
    }

    private static let appleMusicRadioProbeLock = NSLock()
    private static var appleMusicRadioProbedKey: String?
    private static var appleMusicRadioProbedHash: String?

    /// 这一首的电台标识(nil = 不是电台 / 问不出来)。结果按曲目 key 记一份,同一首歌只探一次。
    ///
    /// ⚠️ 探测失败(media-control 不在 / 超时 / 系统 Now Playing 焦点根本不是 Apple Music)
    /// **也**记进缓存、按"不是电台"处理:这样最坏情况是这首歌整首退回改动前的行为(改动前这条
    /// 路上电台本来就完全不生效,所以是退化不是回归),换歌时自愈,而每首歌最多只多 fork 一次。
    /// 反过来"失败就不记、下一拍再试"会在 media-control 彻底坏掉时变成每 2 秒白 fork 一个子进程。
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

    /// 只问 media-control 要两个字段:此刻系统在报谁、以及电台标识。
    ///
    /// **不复用** `fetchRawMediaControlSnapshot`:那个函数还会记未知播放器(设置页那张卡片的
    /// 数据源)、推进锚点目击表、动电台那块表 —— 在这条路上再跑一遍等于让两套位置逻辑同时写
    /// 同一份状态,而这里要的只是一个判据字段。
    private static func probeRadioStationHash() -> String? {
        guard let binaryPath = binaryPath(),
              let r = ProcessRunner.run(
                  binaryPath, ["get", "--now", "--no-artwork"], timeout: snapshotTimeout),
              r.succeeded,
              let raw = try? JSONDecoder().decode(RawPayload.self, from: r.stdout)
        else { return nil }
        // 系统 Now Playing 焦点不是 Apple Music 时,这个 hash 属于**别人**(网页视频/另一个
        // 播放器),不能扣到 Music.app 头上 —— 跟 matchMediaControlState 那道核对同一条理由。
        guard raw.bundleIdentifier == PlaybackPlayer.appleMusic.bundleIdentifier else { return nil }
        let hash = raw.radioStationHash ?? ""
        return hash.isEmpty ? nil : hash
    }

    // media-control 的原始输出形状(只取用得到的字段)——跟 MediaControlSnapshot 不能
    // 直接共用同一个 Decodable:elapsedTime/timestamp 会冻结(见文件顶部注释),真正
    // 拿来当"当前位置"用的是 elapsedTimeNow,需要在构造 MediaControlSnapshot 时手动
    // 做一次字段搬运,不是简单的一比一字段映射。
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
        /// elapsedTime 是"在这一刻"的位置。ISO8601(带 Z),用来在 elapsedTimeNow 不可信时
        /// 自己补算 —— 见 livePositionSeconds。
        let timestamp: String?
        /// Station identifier present only on radio and live broadcast streams.
        let radioStationHash: String?
    }

    /// Resolves the bundled `media-control` executable path inside `Contents/Resources/media-control/bin/`.
    /// The binary locates its companion frameworks and Perl scripts relative to its own path.
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

    /// Queries `media-control` for a snapshot and verifies that the reported `bundleIdentifier`
    /// matches `expectedBundleID`.
    private static func fetchMediaControlSnapshot(expectedBundleID: String) -> MediaControlSnapshot? {
        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot(), bundleID == expectedBundleID else {
            return nil
        }
        return snapshot
    }

    /// Queries snapshot for explicitly selected player preferences (without automatic detection).
    /// Accepts reported state if `bundleID` matches selected players or members of the trusted list
    /// (e.g. paired web browsers).
    private static func fetchMultiSelectedSnapshot(_ players: Set<PlaybackPlayer>) -> MediaControlSnapshot? {
        let acceptedBundleIDs = Set(players.map(\.bundleIdentifier))
        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot() else { return nil }
        if !acceptedBundleIDs.contains(bundleID) {
            guard TrustedPlayers.isTrusted(bundleID) else { return nil }
            // Additional guard for trusted third-party media sources (rejects non-music browser audio/video).
            guard !trustedPlaybackRejected(bundleID: bundleID, snapshot: snapshot) else {
                return nil
            }
            return refinedAppleMusicSnapshotIfNeeded(
                bundleID: bundleID, snapshot: snapshotWithProbedAlbum(snapshot))
        }
        return refinedAppleMusicSnapshotIfNeeded(bundleID: bundleID, snapshot: snapshot)
    }

    /// Automatic player detection path: queries `media-control` for active Now Playing focus.
    /// When Apple Music is detected, refines elapsed time with cached high-precision AppleScript
    /// readings asynchronously without blocking the primary polling tick.
    private static let appleMusicSnapshotCacheLock = NSLock()
    private static var cachedAppleMusicSnapshot: MediaControlSnapshot?
    private static var cachedAppleMusicSnapshotAt: Date?
    private static var isRefreshingAppleMusicSnapshot = false

    private static func fetchAutoDetectedSnapshot() -> MediaControlSnapshot? {
        // 闸门 = 内置五个播放器 + 用户显式信任的未知播放器(见 TrustedPlayers)。
        // 跟 collector 的 isAcceptedPlayerBundleID 是同一套语义,两侧必须同时改。
        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot(),
              TrustedPlayers.isAccepted(bundleID) else {
            return nil
        }
        // 信任的未知播放器再过一道"这是不是一首歌"的守卫:歌手名**或专辑名**为空的丢掉
        // (浏览器视频/播客)。见 TrustedPlayers.notASong —— 跟 collector 侧同一套语义。
        guard !trustedPlaybackRejected(bundleID: bundleID, snapshot: snapshot) else {
            return nil
        }
        return refinedAppleMusicSnapshotIfNeeded(
            bundleID: bundleID, snapshot: snapshotWithProbedAlbum(snapshot))
    }

    /// Populates empty album metadata from cached YouTube Music probe readings.
    /// Must be invoked after `trustedPlaybackRejected` so empty album checks correctly trigger ad gating.
    private static func snapshotWithProbedAlbum(_ snapshot: MediaControlSnapshot)
        -> MediaControlSnapshot {
        let key = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        guard let album = YouTubeMusicAdProbe.albumPatch(
            reported: snapshot.album,
            reading: YouTubeMusicAdProbe.shared.cachedReading(forKey: key))
        else { return snapshot }
        return snapshot.withAlbum(album)
    }

    /// Evaluates whether a trusted playback source should be rejected as non-music content or processed as an ad.
    /// Applies YouTube Music and Spotify web ad verification when standard song metadata requirements are incomplete.
    private static func trustedPlaybackRejected(
        bundleID: String, snapshot: MediaControlSnapshot
    ) -> Bool {
        guard TrustedPlayers.notASong(
            bundleID: bundleID, artist: snapshot.artist, album: snapshot.album) else {
            return false
        }
        // Spotify web ads report empty artist metadata; intercept before rejecting empty artist
        if spotifyWebAdAccepted(bundleID: bundleID, snapshot: snapshot) { return false }
        guard !(snapshot.artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
            return true
        }
        let key = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        YouTubeMusicAdProbe.shared.kickIfNeeded(bundleIdentifier: bundleID, key: key)
        let verdict = YouTubeMusicAdProbe.shared.cachedVerdict(forKey: key)
        return YouTubeMusicAdProbe.gate(artist: snapshot.artist, verdict: verdict) == .reject
    }

    /// Determines whether a stream item represents a Spotify web advertisement.
    ///
    /// Requires:
    /// 1. Browser paired with Spotify web player.
    /// 2. Field pattern matching ad signatures (title populated, artist empty).
    /// 3. Positive verification from page DOM ad state probe.
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

    /// Refines Apple Music snapshot with high-precision background AppleScript readings.
    /// Skips radio streams where system position reflects total broadcast show length.
    private static func refinedAppleMusicSnapshotIfNeeded(
        bundleID: String, snapshot: MediaControlSnapshot
    ) -> MediaControlSnapshot {
        guard bundleID == PlaybackPlayer.appleMusic.bundleIdentifier else { return snapshot }
        // Radio streams use custom track-scoped clocks; do not overwrite with show-level position.
        guard snapshot.isRadio != true else { return snapshot }
        // ⚠️ 只在**正在播放**时才起这个后台 AppleScript 子进程。
        //
        // 它唯一的用途是给下面借一个更精确的 elapsedTime,而那次借用必须过
        // ageCompensatedCachedElapsed 的第一道 guard:`freshPlaying == true,
        // cachedPlaying == true`。也就是说暂停时刷出来的缓存**在结构上不可能被用到** ——
        // 位置本来就是冻结的,精度这件事没有意义。
        //
        // 改动前这里是无条件调用:挂着 Lyrimuse 但没在听的时段(Music.app 常驻很常见),
        // 每 2 秒白 fork 一个 osascript。恢复播放后的第一次轮询会因为缓存还是空的而退回
        // snapshot 自己的 elapsedTime(精度稍低但一定对应当前这首歌,见下面那段注释),
        // 第二次起就正常了 —— 拿一次轮询的精度换掉整个暂停时段的进程噪声。
        if snapshot.playing == true {
            refreshAppleMusicSnapshotCacheInBackground()
        }
        appleMusicSnapshotCacheLock.lock()
        let cached = cachedAppleMusicSnapshot
        let cachedAt = cachedAppleMusicSnapshotAt
        appleMusicSnapshotCacheLock.unlock()
        // 只在缓存快照确认是"同一首歌"(标题+歌手都对得上)时才借用它更精确的
        // elapsedTime,其它字段一律用 media-control 这次刚给的最新值,不把整份缓存快照
        // 原样顶替上去——换歌恰好发生在"上一次后台刷新"和"这一次轮询"之间的这一小段
        // 窗口里,缓存里可能还是上一首歌的数据:如果直接整体替换,会在下一次后台刷新
        // 追上之前,把上一首歌的标题/播放位置错当成新歌的显示出来(进度条突然跳到中段
        // 这种更明显的错误);现在缓存不匹配时老老实实退回 snapshot 自己的 elapsedTime
        // (精度稍低,但一定对应当前这首歌),精度让位于正确性。
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

    /// Extrapolates cached AppleScript playback elapsed time based on sample age and playback rate.
    ///
    /// Validates extrapolated time against fresh `media-control` reading (`freshElapsed`). If the discrepancy
    /// exceeds 2.0s (indicating discontinuity such as a seek or loop reset), cache is invalidated.
    public static func ageCompensatedCachedElapsed(
        cachedElapsed: Double?, cachedPlaying: Bool?, cachedRate: Double?, cachedAt: Date?,
        freshElapsed: Double?, freshPlaying: Bool?, now: Date = Date()
    ) -> Double? {
        // Paused state does not extrapolate; frozen position from media-control is used directly.
        guard freshPlaying == true, cachedPlaying == true,
              let cachedElapsed, let cachedAt else { return nil }
        let age = now.timeIntervalSince(cachedAt)
        guard age >= 0 else { return nil }
        var rate = cachedRate ?? 1
        if rate <= 0 { rate = 1 } // Playback rate briefly reports 0 during track transitions; treat as active (1).
        let extrapolated = cachedElapsed + age * rate
        if let freshElapsed, abs(extrapolated - freshElapsed) > 2.0 { return nil }
        return extrapolated
    }

    /// Asynchronously refreshes the AppleScript snapshot cache on a background thread.
    /// NSLock synchronization ensures only one active refresh task executes at a time.
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

    /// Fetches cover artwork data and MIME type for the current track via `media-control get --now`.
    ///
    /// Extracted on track transitions to avoid decoding base64 image data during 2-second telemetry ticks.
    /// Matches `trackKey` against the active track to prevent stale artwork retention across song changes.
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

    /// Validates whether the reported artwork bundle ID matches selected player preferences or trusted sources.
    private static func artworkBundleIDMatches(_ bundleID: String, players: Set<PlaybackPlayer>) -> Bool {
        if players.contains(.auto) {
            return TrustedPlayers.isAccepted(bundleID)
        }
        if players.contains(where: { $0.bundleIdentifier == bundleID }) { return true }
        return TrustedPlayers.isTrusted(bundleID)
    }


    /// Age threshold (seconds) beyond which an anchor timestamp is considered stale.
    /// Sources that refresh anchors publish fresh timestamps on pause events.
    public nonisolated static let staleAnchorAfter: TimeInterval = 2.0
    /// Position drop threshold (seconds) between last active playback position and reported position
    /// to identify unseeded/frozen anchor values during pause events.
    public nonisolated static let frozenAnchorPauseDrop: Double = 3.0

    /// Estimates the true anchor moment from an integer-second truncated timestamp using interval bounding.
    ///
    /// Given that `timestamp` represents `floor(true_instant)`, the true moment `tau` satisfies:
    /// `ts <= tau < ts + 1` and `tau <= firstSeenAt`. Returns the midpoint of `[ts, min(ts + 1, firstSeenAt)]`.
    public nonisolated static func estimatedAnchorInstant(timestamp: Date, firstSeenAt: Date) -> Date {
        let observedGap = firstSeenAt.timeIntervalSince(timestamp)
        // Clock skew or parsing anomaly: fallback to timestamp.
        guard observedGap > 0 else { return timestamp }
        return timestamp.addingTimeInterval(min(1.0, observedGap) / 2)
    }

    /// Record of when a playback anchor was first observed.
    /// - `tight`: Captured via MediaRemote stream event arrival with low latency (~25ms).
    /// - `loose`: Captured via 2-second polling tick.
    public struct AnchorSighting: Sendable, Equatable {
        public let at: Date
        public let tight: Bool
        public init(at: Date, tight: Bool) {
            self.at = at
            self.tight = tight
        }
    }

    /// Typical latency (seconds) from anchor generation to stream watcher event delivery.
    public nonisolated static let streamAnchorLatency: TimeInterval = 0.025
    /// Maximum age (seconds) for a stream event to be classified as a tight sighting.
    public nonisolated static let tightSightingMaxAge: TimeInterval = 1.5

    /// Estimates anchor moment incorporating sighting precision.
    /// For tight sightings, deducts typical transit latency and clamps within `[ts, ts + 1)`.
    /// For loose sightings, uses interval midpoint bounding.
    public nonisolated static func estimatedAnchorInstant(timestamp: Date, sighting: AnchorSighting) -> Date {
        guard sighting.tight else { return estimatedAnchorInstant(timestamp: timestamp, firstSeenAt: sighting.at) }
        let guess = sighting.at.timeIntervalSince(timestamp) - streamAnchorLatency
        return timestamp.addingTimeInterval(min(max(guess, 0), 0.999))
    }

    /// Resolves playback position during pause state.
    ///
    /// Browser-based media players that do not publish position state report frozen elapsed times (often 0).
    /// When reported elapsed time is stale and significantly below the last active playback position,
    /// preserves `lastPlayingPosition`.
    public nonisolated static func pausedPositionSeconds(
        elapsedTime: Double?, anchorAge: TimeInterval?, lastPlayingPosition: Double?
    ) -> Double? {
        guard let last = lastPlayingPosition else { return elapsedTime }
        guard let reported = elapsedTime else { return last }
        guard let age = anchorAge, age > staleAnchorAfter else { return reported }
        return (last - reported) > frozenAnchorPauseDrop ? last : reported
    }

    /// Maximum tolerance (seconds) between anchor timestamp and pause event time.
    public nonisolated static let pauseAnchorMaxSkew: TimeInterval = 1.5

    /// Resolves paused playback position incorporating precise pause event observation time.
    ///
    /// When pause events are triggered externally without immediate anchor updates, extrapolates
    /// `lastPlaying` position to `pauseObservedAt` if the anchor precedes the pause event.
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

    /// lastPlayingPosition:**同一首曲目**播放期间最后一次算出来的位置。只有暂停分支会用到
    /// (见 pausedPositionSeconds);默认 nil = 调用方没有这个信息,行为跟改动前一致。
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
        // Uses sighting if provided, falling back to loose sighting from firstSeenAt.
        let effectiveSighting = sighting ?? firstSeenAt.map { AnchorSighting(at: $0, tight: false) }
        // During pause, elapsed time is not extrapolated against wall-clock time.
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
        // Stale anchor republish: extrapolates from calibrated original anchor instant.
        if let republishedAnchorInstant, let base = elapsedTime {
            let rate = (playbackRate ?? 0) > 0 ? (playbackRate ?? 1) : 1
            let aged = now.timeIntervalSince(republishedAnchorInstant)
            return aged > 0 ? base + aged * rate : base
        }
        // Frozen anchors: re-extrapolate from corrected anchor instant when anchor age exceeds stale threshold.
        if let rate = playbackRate, rate > 0, let base = elapsedTime, let timestamp,
           let effectiveSighting, now.timeIntervalSince(timestamp) > staleAnchorAfter {
            let corrected = estimatedAnchorInstant(timestamp: timestamp, sighting: effectiveSighting)
            let aged = now.timeIntervalSince(corrected)
            if aged > 0 { return base + aged * rate }
        }
        // rate 正常时信 media-control 自己的外推(更准)。
        if let rate = playbackRate, rate > 0, let now = elapsedTimeNow { return now }
        // When playbackRate is missing or 0, elapsedTimeNow collapses to raw elapsedTime.
        // Re-extrapolates using rate = 1 based on estimated anchor instant.
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

    /// Standard ISO8601 formatter without fractional seconds. Evaluated before fractional fallback.
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

    /// Raw observation of the system Now Playing source before application filters are applied.
    /// Used by settings UI to present unrecognized media players for user trust authorization.
    public struct UngatedNowPlaying: Sendable, Equatable {
        public let bundleID: String
        public let artist: String
        public let album: String
        public let title: String
        public let at: Date
    }

    // Retains last computed playing position for the current track to support `pausedPositionSeconds`.
    // Scoped to track identity and invalidated upon track transition.
    private static let playingPositionLock = NSLock()
    nonisolated(unsafe) private static var playingPositionTrack: String?
    nonisolated(unsafe) private static var playingPositionValue: Double?
    nonisolated(unsafe) private static var playingPositionSampledAt: Date?
    nonisolated(unsafe) private static var pauseObservedAt: Date?

    /// Records timestamp when player transitioned into paused state.
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

    /// Records track transition timestamp observed by the stream watcher to seed radio track-scoped clocks.
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

    // Cache of earliest anchor sightings. Keyed by composite anchor identity (track, elapsed, timestamp).
    // Prioritizes tight sightings from the stream watcher over loose sightings from polling.
    private static let anchorSeenLock = NSLock()
    nonisolated(unsafe) private static var anchorSightings: [String: AnchorSighting] = [:]
    private static let anchorSightingCapacity = 16

    /// Returns earliest recorded sighting for `anchorKey`, recording `now` as a loose sighting if absent.
    private nonisolated static func firstSeen(anchorKey: String, now: Date) -> AnchorSighting {
        anchorSeenLock.lock()
        defer { anchorSeenLock.unlock() }
        if let existing = anchorSightings[anchorKey] { return existing }
        let sighting = AnchorSighting(at: now, tight: false)
        anchorSightings[anchorKey] = sighting
        pruneAnchorSightingsLocked()
        return sighting
    }

    /// Records anchor sighting from stream watcher. Tight sightings take precedence over loose sightings.
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

    /// Constructs composite anchor key combining track key, millisecond-quantized elapsed time, and timestamp.
    public nonisolated static func anchorKey(artist: String?, title: String?, elapsedTime: Double?, timestamp: String?) -> String {
        let elapsed = elapsedTime.map { String(format: "%.3f", $0) } ?? "-"
        return "\(MediaControlSnapshot.trackKey(artist: artist, title: title))|\(elapsed)|\(timestamp ?? "-")"
    }

    // MARK: - Spotify Stale Anchor Republish Detection
    //
    // Spotify occasionally republishes identical `elapsedTime` values alongside newer timestamps
    // during active playback. When this occurs, MediaRemote wall-clock extrapolation would jump backwards.
    // Detected by matching identical elapsed time with a differing timestamp on the same track.
    // When detected, extrapolation uses the original anchor instant rather than the republished timestamp.

    /// Active playing anchor state with calibrated anchor instant.
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

    /// 这次读到的播放锚点是不是上一个播放锚点的陈旧重发。纯函数,selftest 直接覆盖。
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

    /// 记住"上一个播放锚点",并判定这次是不是它的陈旧重发。是 → 返回原锚点时刻(调用方据此自己
    /// 外推);否 → 记下这次的锚点,返回 nil。日志只在每个被忽略的新时间戳第一次出现时打一行。
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

    /// 最近一次观察。nil = 从没观察到过(App 刚起来、或者系统里压根没有 Now Playing)。
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
        // --now 让工具自己按内部时钟外推出一个不会冻结的 elapsedTimeNow(见文件顶部
        // 注释);--no-artwork 省掉几百 KB 的 base64 封面数据,这里从不使用。
        //
        // 这是 2 秒一轮的热路径 —— 它卡住,悬浮歌词就停住。超时是这里最要紧的东西。
        guard let r = ProcessRunner.run(
            binaryPath, ["get", "--now", "--no-artwork"], timeout: snapshotTimeout),
            r.succeeded
        else { return nil }
        let data = r.stdout
        // 没有任何 App 在报告 Now Playing 时,media-control 输出字面量 "null",
        // 退出码仍是 0——JSONDecoder 对着 "null" 解码 RawPayload 会失败,走
        // `try?` 落到下面的 guard raw != nil,行为跟"没有可报告的正在播放"一致。
        // 退出码已经由上面的 r.succeeded 判过。
        guard let raw = try? JSONDecoder().decode(RawPayload.self, from: data),
              let bundleID = raw.bundleIdentifier else {
            return nil
        }
        // 把"此刻系统在报谁"原样记一笔 —— **在过闸之前**。设置页那张"检测到未知播放器"
        // Records ungated Now Playing state prior to application filters for discovery UI.
        recordUngatedNowPlaying(bundleID: bundleID, artist: raw.artist, album: raw.album,
                                title: raw.title)
        // Position resolution: raw `elapsedTime` is used during pause, while `livePositionSeconds`
        // extrapolates during playback. Preserves last calculated playing position for browser players.
        let trackKey = MediaControlSnapshot.trackKey(artist: raw.artist, title: raw.title)
        let sampledAt = Date()
        // Anchor identity combines track key, raw elapsed time, and raw timestamp.
        let anchorKey = Self.anchorKey(
            artist: raw.artist, title: raw.title, elapsedTime: raw.elapsedTime, timestamp: raw.timestamp)
        let timestampDate = Self.parseTimestamp(raw.timestamp)
        let sighting = Self.firstSeen(anchorKey: anchorKey, now: sampledAt)
        // Active anchors are checked for stale republishing.
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
        // Radio streams: system duration and elapsed time reflect total show broadcast length.
        // Replaces position and anchor with synthetic track-scoped clock seeded from track transitions.
        // Duration must be passed through for progress denominator calculations in `LocalPlaybackSource.apply`.
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

    // MARK: - Radio Track-Scoped Clock

    private static let radioClockLock = NSLock()
    private static var radioClockState: RadioTrackClock.State?
    /// Cached record of disk snapshot to gate write frequency (`RadioClockFile.shouldWrite`).
    private static var radioClockWritten: RadioClockRecord?
    /// Ensures cold-start disk recovery is attempted at most once.
    private static var radioClockRestoreTried = false
    /// Active radio station hash (`radioStationHash`), nil if not a radio stream.
    ///
    /// 走静态旁路而不是加进 `MediaControlSnapshot`:那个结构体有十三处构造点、还是 Decodable
    /// (加字段会顺带从 media-control 的 JSON 自动解),而这个值只有 `LocalPlaybackSource.apply`
    /// 一处要用 —— 用它给台卡分台(见 `RadioStationCard`)。同一时刻系统只有一个 Now Playing
    /// 会话,所以"当前那个台"是明确的;每次取快照都写一遍(非电台写 nil),不会留陈旧值。
    nonisolated(unsafe) private static var radioStationHashValue: String?

    public nonisolated static func currentRadioStationHash() -> String? {
        radioClockLock.lock()
        defer { radioClockLock.unlock() }
        return radioStationHashValue
    }

    /// 两条取快照的路径共用这一个写入点(轮询的 fetchRawMediaControlSnapshot,以及只勾
    /// Apple Music 时的 radioAwareAppleMusicSnapshot)—— 每次取快照都写一遍(非电台写 nil),
    /// 不会留陈旧值。
    private static func setRadioStationHash(_ hash: String?) {
        radioClockLock.lock()
        radioStationHashValue = hash
        radioClockLock.unlock()
    }

    /// 推进电台那块曲内表并取当前位置。状态只有一块(系统同一时刻只有一个 Now Playing 会话)。
    /// 纯算术在 `RadioTrackClock.advance`(selftest 钉住),这里只管加锁存取。
    private static func advanceRadioClock(trackKey: String, playing: Bool, now: Date, startedAt: Date?) -> Double {
        radioClockLock.lock()
        defer { radioClockLock.unlock() }
        // 冷启动:内存里没有表,先看看上一个进程留下的账能不能接(判据见 RadioClockFile 头注)。
        // 接不上就是 nil,后面照旧按 startedAt 播种 —— 跟没有这份文件时逐字相同。
        if radioClockState == nil, !radioClockRestoreTried {
            radioClockRestoreTried = true
            if let restored = RadioClockFile.restorable(RadioClockFile.load(), trackKey: trackKey, now: now) {
                radioClockState = restored
                logger.notice("radio clock: restored key=\(trackKey, privacy: .public) position=\(restored.position, format: .fixed(precision: 3)) gap=\(now.timeIntervalSince(restored.tickedAt), format: .fixed(precision: 3))")
            }
        }
        let next = RadioTrackClock.advance(radioClockState, trackKey: trackKey, playing: playing, now: now,
                                           startedAt: startedAt)
        // 只在起表那一拍打一行:换歌是低频事件,而"播种了多少"是这套机制唯一看得见的产物 —— 没有它,
        // 链路断掉(startedAt 恒 nil、key 对不上)只会安静地退回从 0 起,表现成"整首歌恒慢一点"。
        if radioClockState?.trackKey != trackKey {
            logger.notice("radio clock: start key=\(trackKey, privacy: .public) seed=\(next.position, format: .fixed(precision: 3)) observed=\(startedAt == nil ? "no" : "yes", privacy: .public)")
        }
        radioClockState = next
        // 落盘,好让下一个进程接得上。写不写由 shouldWrite 定(换歌/播放翻转立刻写,平凡推进 15 秒一次)。
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
