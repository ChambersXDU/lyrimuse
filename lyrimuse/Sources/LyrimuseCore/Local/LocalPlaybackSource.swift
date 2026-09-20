import Foundation
import Combine
import CoreImage
import CoreGraphics
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "local")

@MainActor
public final class LocalPlaybackSource: ObservableObject {
    public static let shared = LocalPlaybackSource()

    @Published public private(set) var title: String = ""
    @Published public private(set) var artist: String = ""
    @Published public private(set) var album: String = ""
    @Published public private(set) var isPlayingNow: Bool = false
    @Published public private(set) var currentLine: SyncedLyricLine?
    @Published public private(set) var nextLineText: String?

    @Published public private(set) var nextLineSide: LyricDuet.Side?

    @Published public private(set) var currentLineIndex: Int?

    @Published public private(set) var scrollLineIndex: Int?

    @Published public private(set) var compactLine: SyncedLyricLine?

    @Published public private(set) var compactShowsPlaceholder: Bool = false

    @Published public private(set) var compactDwellMs: Int?

    @Published public private(set) var compactLeadInMs: Int?
    @Published public private(set) var allLines: [LyricsWindowLine] = []

    @Published public private(set) var lyricsGapMarkers: [LyricsGapMarker] = []

    @Published public private(set) var currentGapIndex: Int?

    @Published public private(set) var currentLineFillSettled: Bool = true

    @Published public private(set) var hasLyricsContent: Bool = false

    @Published public private(set) var isCurrentTrackInstrumental: Bool = false

    @Published public private(set) var currentTrackHasNoLyrics: Bool = false

    @Published public private(set) var currentTrackPlainLyrics: String = ""

    @Published public private(set) var collectorNetworkDown: Bool = false

    @Published public private(set) var isCurrentTrackAdBreak: Bool = false

    @Published public private(set) var currentAdSlot: YouTubeMusicAdProbe.AdSlot? = nil

    @Published public private(set) var currentLyricsOffsetMs: Int = 0

    @Published public private(set) var trackLyricsOffsetMs: Int = 0

    @Published public private(set) var artworkData: Data?

    @Published public private(set) var artworkAverageHex: String?

    @Published public private(set) var spotifyArtworkURL: URL?

    @Published public private(set) var pausedPositionMs: Int?

    @Published public private(set) var currentDurationMs: Int?

    private var radioTrackFinished = false

    @Published public private(set) var isRadioTalkBreak = false

    @Published public private(set) var radioStationName: String?
    @Published public private(set) var radioStationArtwork: Data?

    private var radioStationCard: RadioStationCard?
    private var radioStationCardLoaded = false
    private var pendingStationCardKey: String?

    @Published public var romanizationScripts: RomanizationScripts = .default {
        didSet { reloadCurrentLyrics() }
    }

    @Published public var chineseVariant: ChineseVariant = .off {
        didSet { reloadCurrentLyrics() }
    }

    @Published public private(set) var sawChineseLyrics = false

    @Published public private(set) var currentLyricsSupportsChineseVariant = false

    @Published public var showsTranslation = false {
        didSet { reloadCurrentLyrics() }
    }

    public nonisolated static func supportsChineseVariant(
        lyrics: String, translation: String, translationVisible: Bool
    ) -> Bool {
        ChineseVariant.affects(lyrics)
            || (translationVisible && ChineseVariant.affects(translation))
    }

    private let syncEngine = LyricsSyncEngine()

    @Published public private(set) var anchor: ProgressAnchor?
    private var lastKey = ""
    private var lastSnapshot: MediaControlSnapshot?

    private var lastAppliedBundleID: String?

    private var lastPersistedPlayerBundleID: String?
    private var lastPersistedTrackTitle: String?

    public var lastResolvedBundleID: String? {
        let id = lastSnapshot?.bundleIdentifier ?? ""
        return id.isEmpty ? nil : id
    }

    private var trackPosSeconds: Double = 0
    private var posTrackingKey = ""
    private var posWasPlaying = false
    private var posPrevWall: Date?

    private var posPrevReported: Double?

    private var posErrEMA: Double = 0
    private static let seekJumpToleranceSecs = 2.0

    private nonisolated static let flooredForwardSnapEpsilonSecs = 0.05

    public enum PositionSourceTier {

        case precise

        case cleanExtrapolated

        case noisyFloored
    }

    public nonisolated static func positionSourceTier(forBundleID bundleID: String?) -> PositionSourceTier {
        if bundleID == PlaybackPlayer.appleMusic.bundleIdentifier { return .precise }

        if bundleID == PlaybackPlayer.qqMusic.bundleIdentifier
            || bundleID == PlaybackPlayer.netease.bundleIdentifier {
            return .noisyFloored
        }
        return .cleanExtrapolated
    }

    public static let groundTruthSnapToleranceSecs: Double = 0.30

    public nonisolated static func shouldRatchetForward(
        reported: Double, predicted: Double, tier: PositionSourceTier
    ) -> Bool {
        tier == .noisyFloored && reported - predicted > flooredForwardSnapEpsilonSecs
    }

    public nonisolated static func servoDecision(errEMA: Double, error: Double, tier: PositionSourceTier) -> (newEMA: Double, snap: Bool) {
        let alpha: Double, threshold: Double
        switch tier {
        case .precise: (alpha, threshold) = (0.5, 0.15)
        case .cleanExtrapolated: (alpha, threshold) = (0.3, 0.4)
        case .noisyFloored: (alpha, threshold) = (0.3, 1.0)
        }

        let clamped = tier == .cleanExtrapolated ? max(-0.75, min(0.75, error)) : error
        let newEMA = errEMA * (1 - alpha) + clamped * alpha
        return (newEMA, abs(newEMA) > threshold)
    }

    public nonisolated static func isFrozenReport(
        reportedAdvance: Double, gap: Double, rate: Double, tier: PositionSourceTier
    ) -> Bool {
        tier == .cleanExtrapolated && gap >= 0.75
            && abs(reportedAdvance) < max(0.1, 0.15 * gap * rate)
    }

    public nonisolated static let naturalAdvanceWindowSecs = 4.0

    public nonisolated static let naturalAdvanceMaxBiasSecs = 2.5
    public nonisolated static let naturalAdvanceMinBiasSecs = 0.05

    public nonisolated static func naturalAdvanceCorrection(
        reported: Double, overrun: Double
    ) -> (seed: Double, bias: Double)? {
        guard abs(overrun) <= naturalAdvanceWindowSecs else { return nil }
        let bias = reported - overrun
        guard bias > naturalAdvanceMinBiasSecs, bias <= naturalAdvanceMaxBiasSecs else { return nil }
        return (overrun, bias)
    }

    private var posReportedBiasSecs: Double = 0

    private var posBiasAnchorElapsed: Double?

    private func setReportedBias(_ bias: Double, anchorElapsed: Double?, fromProbe: Bool = false) {
        posReportedBiasSecs = bias
        posBiasAnchorElapsed = bias == 0 ? nil : anchorElapsed
        posBiasFromProbe = bias != 0 && fromProbe
        }

    private var posBiasFromProbe = false

    private static let probeLeadByDeviceDefaultsKey = "np:spotifyProbeLeadByDevice"
    private static let legacyProbeLeadDefaultsKey = "np:spotifyProbeLeadSecs"
    private nonisolated static let probeLeadLearnAlpha = 0.5
    private nonisolated static let probeLeadMaxResidualSecs = 1.5

    public nonisolated static func probeLeadPrior(for transport: AudioOutputRoute.Transport) -> Double {
        switch transport {
        case .bluetooth: return 0.5
        case .builtIn: return 0.1
        case .airPlay, .display, .usb, .other: return 0
        }
    }

    public nonisolated static func learnedProbeLead(current: Double, residual: Double, hasPrior: Bool) -> Double {
        guard abs(residual) <= probeLeadMaxResidualSecs else { return current }
        guard hasPrior else { return current + residual }
        return current + residual * probeLeadLearnAlpha
    }

    private lazy var probeLeadByDevice: [String: Double] = {
        var table: [String: Double] = [:]
        if let json = UserDefaults.standard.string(forKey: Self.probeLeadByDeviceDefaultsKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            table = decoded
        }
        if UserDefaults.standard.object(forKey: Self.legacyProbeLeadDefaultsKey) != nil {
            let legacy = UserDefaults.standard.double(forKey: Self.legacyProbeLeadDefaultsKey)
            if table.isEmpty, let route = AudioOutputRoute.current() {
                table[route.uid] = legacy
                logger.notice("probe lead: migrated legacy value \(legacy, format: .fixed(precision: 3)) to device \(route.name, privacy: .public)")
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyProbeLeadDefaultsKey)
            Self.persistProbeLeadTable(table)
        }
        return table
    }()

    private static func persistProbeLeadTable(_ table: [String: Double]) {
        if let data = try? JSONEncoder().encode(table), let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: probeLeadByDeviceDefaultsKey)
        }
    }

    private var currentOutputRoute: AudioOutputRoute.Current? = AudioOutputRoute.current()

    private var probeLeadSecs: Double {
        guard let route = currentOutputRoute else { return 0 }
        return probeLeadByDevice[route.uid] ?? Self.probeLeadPrior(for: route.transport)
    }

    private func learnProbeLead(residual: Double) {
        guard let route = currentOutputRoute else { return }
        let prior = probeLeadByDevice[route.uid]
        let next = Self.learnedProbeLead(current: prior ?? Self.probeLeadPrior(for: route.transport),
                                         residual: residual, hasPrior: prior != nil)
        logger.notice("probe lead learned: residual=\(residual, format: .fixed(precision: 3)) device=\(route.name, privacy: .public) (\(route.transport.rawValue, privacy: .public)) lead \(self.probeLeadSecs, format: .fixed(precision: 3)) -> \(next, format: .fixed(precision: 3))")
        guard prior != next else { return }
        probeLeadByDevice[route.uid] = next
        Self.persistProbeLeadTable(probeLeadByDevice)
    }

    private func outputRouteChanged() {
        let route = AudioOutputRoute.current()
        guard route != currentOutputRoute else { return }
        let before = probeLeadSecs
        currentOutputRoute = route
        logger.notice("output route changed: \(route?.name ?? "-", privacy: .public) (\(route?.transport.rawValue ?? "-", privacy: .public)) probe lead \(before, format: .fixed(precision: 3)) -> \(self.probeLeadSecs, format: .fixed(precision: 3))")
        if posBiasFromProbe, posWasPlaying,
           lastSnapshot?.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier {
            SpotifyPositionProbe.shared.requestConfirmation(forKey: posTrackingKey)
        }
    }

    private var lastPublishedBias: PositionBiasRecord?

    private func publishPositionBiasIfChanged(snapshot: MediaControlSnapshot, isSpotifyNative: Bool, now: Date) {
        let record = PositionBiasRecord(
            artist: snapshot.artist ?? "", title: snapshot.title ?? "",
            bundleID: snapshot.bundleIdentifier ?? "",
            anchorElapsed: posBiasAnchorElapsed, biasSecs: posReportedBiasSecs,
            writtenAtMs: Int64(now.timeIntervalSince1970 * 1000))
        if let last = lastPublishedBias, last.sameContent(as: record) { return }
        guard isSpotifyNative || (lastPublishedBias?.biasSecs ?? 0) != 0 else { return }
        lastPublishedBias = record
        PositionBiasFile.write(record)
    }

    public nonisolated static func biasSurvivesAnchor(anchorElapsedTime: Double?, measuredAgainst: Double? = nil) -> Bool {
        guard let anchorElapsedTime else { return true }
        guard let measuredAgainst else { return anchorElapsedTime <= 0.001 }
        return abs(anchorElapsedTime - measuredAgainst) <= 0.001
    }

    public struct ClockSnapshot: Sendable {
        public var tier: String
        public var posErrEMASecs: Double
        public var reportedBiasSecs: Double
        public var anchorRate: Double?
        public var anchorFresh: Bool?
        public var anchorAgeSecs: Double?
        public var effectiveLyricsOffsetMs: Int
        public var lrcOffsetMs: Int
        public var fillSettled: Bool
        public var hasLyrics: Bool
        public var isPlaying: Bool
    }

    public var clockSnapshot: ClockSnapshot {
        let tier = Self.positionSourceTier(forBundleID: lastSnapshot?.bundleIdentifier)
        return ClockSnapshot(
            tier: String(describing: tier),
            posErrEMASecs: posErrEMA,
            reportedBiasSecs: posReportedBiasSecs,
            anchorRate: anchor?.rate,
            anchorFresh: anchor?.fresh,
            anchorAgeSecs: anchor.map { Date().timeIntervalSince($0.fetchedAt) },
            effectiveLyricsOffsetMs: currentLyricsOffsetMs,
            lrcOffsetMs: syncEngine.lrcOffsetMs,
            fillSettled: currentLineFillSettled,
            hasLyrics: hasLyricsContent,
            isPlaying: isPlayingNow
        )
    }

    private var posPrevDurationSecs: Double = 0

    private var posPrevTierCleanExtrapolated = false

    private var posPausedRawSecs: Double?

    public static func adBreakByFields(
        isSpotifyNative: Bool, title: String, artist: String, album: String,
        youTubeMusicVerdict: YouTubeMusicAdProbe.Verdict?, spotifyWebVerdict: SpotifyWebAdProbe.Verdict?
    ) -> Bool {
        if YouTubeMusicAdProbe.showsAdBadge(verdict: youTubeMusicVerdict) { return true }
        if spotifyWebVerdict == .ad { return true }
        return isSpotifyNative && !title.isEmpty && (album.isEmpty || artist.isEmpty || title == "—")
    }

    public static func nextAdBreakState(
        previous: Bool, isNewTrack: Bool, adByFields: Bool, pageVerdict: YouTubeMusicAdProbe.Verdict?
    ) -> Bool {
        if isNewTrack { return adByFields }
        if adByFields { return true }
        if pageVerdict == .song { return false }
        return previous
    }

    private func spotifyNativeAdCheckForNewTrack(snapshot: MediaControlSnapshot) {
        if let hint = spotifyNotificationHint, hint.matches(title: snapshot.title, artist: snapshot.artist) {
            if hint.isAd, !isCurrentTrackAdBreak { isCurrentTrackAdBreak = true }
            logger.debug("spotify ad check: notification says \(hint.isAd ? "ad" : "track", privacy: .public) for key=\(snapshot.trackKey, privacy: .public)")
            return
        }
        verifySpotifyAdViaAppleScript(forKey: snapshot.trackKey)
    }

    public func noteSpotifyArtwork(url: URL, forKey key: String) {
        guard lastSnapshot?.trackKey == key else {
            logger.notice("spotify artwork url: dropped, track moved on (for key=\(key, privacy: .public))")
            return
        }
        if spotifyArtworkURL != url {
            spotifyArtworkURL = url
            logger.notice("spotify artwork url: \(url.lastPathComponent, privacy: .public) for key=\(key, privacy: .public)")
        }
    }

    private func verifySpotifyAdViaAppleScript(forKey key: String) {
        Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "tell application \"Spotify\" to spotify url of current track"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else { return }
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let out = String(data: data, encoding: .utf8),
                  out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("spotify:ad")
            else { return }
            await MainActor.run { [weak self] in
                guard let self, self.lastSnapshot?.trackKey == key else { return }
                if !self.isCurrentTrackAdBreak { self.isCurrentTrackAdBreak = true }
            }
        }
    }

    private func resolvePositionSeconds(reported rawReported: Double, rate: Double, key: String, now: Date, tier: PositionSourceTier, isGroundTruthSeed: Bool = false, anchorElapsedTime: Double? = nil, streamRaw: Double? = nil) -> (seconds: Double, didReanchor: Bool) {
        if tier != .cleanExtrapolated, posReportedBiasSecs != 0 {

            setReportedBias(0, anchorElapsed: nil)
        }
        let reported = rawReported - posReportedBiasSecs

        let reportedAdvance = rawReported - (posPrevReported ?? rawReported)
        defer { if !isGroundTruthSeed { posPrevReported = rawReported } }

        if key == posTrackingKey,
           let target = lastSeekTargetSecs, let prev = lastSeekPrevSecs, let at = lastSeekAt,
           Self.shouldRejectStalePositionAfterSeek(
               reported: reported, target: target, previous: prev, elapsedSinceSeek: now.timeIntervalSince(at)
           ) {
            return (trackPosSeconds, false)
        }
        guard key == posTrackingKey, posWasPlaying, let prevWall = posPrevWall else {
            if key != posTrackingKey {

                var corrected: (seed: Double, bias: Double)?
                if tier == .cleanExtrapolated, posPrevTierCleanExtrapolated,
                   posWasPlaying, let prevWall = posPrevWall,
                   posPrevDurationSecs > 0 {
                    let overrun = trackPosSeconds
                        + now.timeIntervalSince(prevWall) * (rate > 0 ? rate : 1)
                        - posPrevDurationSecs
                    corrected = Self.naturalAdvanceCorrection(reported: rawReported, overrun: overrun)
                    if let corrected {
                        logger.notice("natural advance: seed \(corrected.seed, format: .fixed(precision: 3))s, anchor leads audio by \(corrected.bias, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
                    }
                }
                setReportedBias(corrected?.bias ?? 0, anchorElapsed: anchorElapsedTime)
                trackPosSeconds = corrected?.seed ?? rawReported
            } else {
                trackPosSeconds = reported
            }
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        let gap = now.timeIntervalSince(prevWall)
        let predicted = trackPosSeconds + gap * rate

        if isGroundTruthSeed {
            let delta = reported - predicted
            guard abs(delta) > Self.groundTruthSnapToleranceSecs else {
                if tier == .cleanExtrapolated {
                    trackPosSeconds = predicted
                    return (trackPosSeconds, false)
                }
                return resolveSteadyState(reported: reported, predicted: predicted, key: key, tier: tier)
            }
            if tier == .cleanExtrapolated, let streamRaw {

                setReportedBias(streamRaw - reported, anchorElapsed: anchorElapsedTime, fromProbe: true)
            }
            logger.notice("browser probe reanchor: reported=\(reported, format: .fixed(precision: 3)) predicted=\(predicted, format: .fixed(precision: 3)) delta=\(delta, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3))")
            trackPosSeconds = reported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }

        if Self.isFrozenReport(reportedAdvance: reportedAdvance, gap: gap, rate: rate, tier: tier) {
            trackPosSeconds = predicted
            return (trackPosSeconds, false)
        }

        if tier == .cleanExtrapolated, posPrevDurationSecs > 0,
           let corr = Self.naturalAdvanceCorrection(reported: rawReported, overrun: predicted - posPrevDurationSecs) {
            logger.notice("repeat-one wrap: seed \(corr.seed, format: .fixed(precision: 3))s, anchor leads audio by \(corr.bias, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
            setReportedBias(corr.bias, anchorElapsed: anchorElapsedTime)
            trackPosSeconds = corr.seed
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        if abs(reported - predicted) > Self.seekJumpToleranceSecs {

            setReportedBias(0, anchorElapsed: nil)
            trackPosSeconds = rawReported
            posErrEMA = 0

            if tier == .cleanExtrapolated {
                SpotifyPositionProbe.shared.requestConfirmation(forKey: key)
            }
            return (trackPosSeconds, true)
        }
        return resolveSteadyState(reported: reported, predicted: predicted, key: key, tier: tier)
    }

    private func resolveSteadyState(reported: Double, predicted: Double, key: String, tier: PositionSourceTier) -> (seconds: Double, didReanchor: Bool) {
        if Self.shouldRatchetForward(reported: reported, predicted: predicted, tier: tier) {

            trackPosSeconds = reported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }

        let (newEMA, snap) = Self.servoDecision(errEMA: posErrEMA, error: reported - predicted, tier: tier)
        posErrEMA = newEMA
        if snap {
            trackPosSeconds = tier == .precise ? reported : predicted + newEMA
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        trackPosSeconds = predicted
        return (trackPosSeconds, false)
    }

    private var pollTimer: Timer?
    private var fastTimer: Timer?
    private var screenLocked = false

    private var playerInfoObserver: NSObjectProtocol?
    private var spotifyInfoObserver: NSObjectProtocol?

    private var spotifyNotificationHint: SpotifyNotificationHint?

    private var streamWatcher: MediaControlStreamWatcher?

    private var pendingNotificationPoll: Task<Void, Never>?
    private static let playerInfoDebounce: Duration = .milliseconds(250)

    private init() {}

    public func start() {
        reschedulePollTimer()
        startObservingPlayerInfoNotification()

        EnrichCacheReader.installMemoryPressureRelief()

        EnrichCacheReader.onContentAdopted = { [weak self] in self?.handleEnrichContentAdopted() }
        EnrichCacheReader.startWatching()

        poll()
    }

    public func stop() {
        EnrichCacheReader.stopWatching()
        EnrichCacheReader.onContentAdopted = nil
        pollTimer?.invalidate(); pollTimer = nil
        for observer in [playerInfoObserver, spotifyInfoObserver].compactMap({ $0 }) {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        playerInfoObserver = nil
        spotifyInfoObserver = nil
        streamWatcher?.stop()
        streamWatcher = nil
        pendingNotificationPoll?.cancel()
        pendingNotificationPoll = nil
        stopFastTimer()
    }

    private func handleEnrichContentAdopted() {
        let version = EnrichCacheReader.decodedContentVersion
        if enrichContentVersion != version { enrichContentVersion = version }
        guard version != lastEnrichMTime else { return }

        lastEnrichMTime = version
        reloadCurrentLyrics()

        if anchor == nil {
            stopFastTimer()
            resolveLinesForPausedPosition()
        } else if syncEngine.hasContent {
            ensureFastTimerRunning()
            fastTick()
        } else {
            fastTick()
            stopFastTimer()
        }
    }

    private func startObservingPlayerInfoNotification() {
        startStreamWatcher()

        SpotifyPositionProbe.shared.setArtworkSink { [weak self] key, url in
            Task { @MainActor [weak self] in self?.noteSpotifyArtwork(url: url, forKey: key) }
        }

        BrowserPositionProbe.shared.setArtworkSink { [weak self] key, url in
            Task { @MainActor [weak self] in self?.noteSpotifyArtwork(url: url, forKey: key) }
        }

        SpotifyPositionProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }

        YouTubeMusicAdProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        SpotifyWebAdProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }

        AudioOutputRoute.startObserving { [weak self] in
            Task { @MainActor [weak self] in self?.outputRouteChanged() }
        }
        guard playerInfoObserver == nil else { return }
        let center = DistributedNotificationCenter.default()
        let handler: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePlayerInfoChanged(from: PlaybackPlayer.appleMusic.bundleIdentifier) }
        }
        playerInfoObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main, using: handler)
        spotifyInfoObserver = center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main) { [weak self] note in
                let hint = SpotifyNotificationHint(userInfo: note.userInfo)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let hint, self.spotifyNotificationHint != hint { self.spotifyNotificationHint = hint }
                    self.handlePlayerInfoChanged(from: PlaybackPlayer.spotify.bundleIdentifier)
                }
            }
    }

    private func startStreamWatcher() {
        guard streamWatcher == nil else { return }
        let watcher = MediaControlStreamWatcher { [weak self] bundleID in
            MainActor.assumeIsolated { self?.handlePlayerInfoChanged(from: bundleID) }
        }
        streamWatcher = watcher
        watcher.start()
    }

    public nonisolated static func shouldFreezeForPlayerEvent(currentBundleID: String?, eventBundleID: String?) -> Bool {
        guard let currentBundleID, !currentBundleID.isEmpty else { return false }
        return currentBundleID == eventBundleID
    }

    private func handlePlayerInfoChanged(from bundleID: String?) {
        if Self.shouldFreezeForPlayerEvent(currentBundleID: lastResolvedBundleID, eventBundleID: bundleID) {
            freezeExtrapolationUntilNextPoll()
        }
        pendingNotificationPoll?.cancel()
        pendingNotificationPoll = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.playerInfoDebounce)
            guard !Task.isCancelled else { return }
            self?.pendingNotificationPoll = nil
            self?.poll()
        }
    }

    private func freezeExtrapolationUntilNextPoll() {
        guard let current = anchor, current.rate > 0 else { return }
        let now = Date()
        anchor = ProgressAnchor(
            durationMs: current.durationMs,
            progressMs: current.extrapolatedPositionMs(now: now),
            rate: 0,
            progressTs: nil,
            baseAgeMs: nil,
            fetchedAt: now,
            fresh: current.fresh)
    }

    private enum PollInterval {
        static let playing: TimeInterval = 2
        static let paused: TimeInterval = 6
        static let idle: TimeInterval = 10

        static let nilGraceTicks = 3
    }

    private var currentPollInterval: TimeInterval = PollInterval.playing

    private var desiredPollInterval: TimeInterval {
        if isPlayingNow { return PollInterval.playing }
        if consecutiveNilSnapshots > 0, consecutiveNilSnapshots <= PollInterval.nilGraceTicks {
            return PollInterval.playing
        }
        return title.isEmpty ? PollInterval.idle : PollInterval.paused
    }

    private func reschedulePollTimer() {
        reschedulePollTimer(interval: PollInterval.playing)
    }

    private func reschedulePollTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        currentPollInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func adjustPollCadence() {
        let desired = desiredPollInterval
        if desired != currentPollInterval { reschedulePollTimer(interval: desired) }
    }

    public func setScreenLocked(_ locked: Bool) {
        guard screenLocked != locked else { return }
        screenLocked = locked
        logger.info("screen \(locked ? "locked" : "unlocked", privacy: .public); word-level tick \(locked ? "paused" : "resumed", privacy: .public)")
        if locked {
            stopFastTimer()
        } else if anchor != nil {

            if syncEngine.hasContent { ensureFastTimerRunning() }
            fastTick()
        }
    }

    private func ensureFastTimerRunning() {

        guard !screenLocked else { return }
        guard fastTimer == nil else { return }

        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fastTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        fastTimer = t
    }

    private func stopFastTimer() {
        fastTimer?.invalidate()
        fastTimer = nil
    }

    private func noteRadioStationCard(name: String, hash: String, trackKey: String) {
        pendingStationCardKey = trackKey
        guard radioStationCard?.stationHash != hash || radioStationCard?.name != name else { return }

        let keptArtwork = radioStationCard?.stationHash == hash ? radioStationCard?.artwork : nil
        let card = RadioStationCard(stationHash: hash, name: name, artwork: keptArtwork)
        radioStationCard = card
        RadioStationCardFile.write(card)
        logger.notice("radio station card: name=\(name, privacy: .public) hasArtwork=\(keptArtwork != nil)")
    }

    private func noteRadioStationArtwork(_ data: Data?, forKey key: String) {
        guard let data, !data.isEmpty, key == pendingStationCardKey,
              var card = radioStationCard, card.artwork != data else { return }
        card.artwork = data
        radioStationCard = card
        RadioStationCardFile.write(card)
        if radioStationName == card.name { radioStationArtwork = data }
        logger.notice("radio station card: artwork attached bytes=\(data.count)")
    }

    private func clearLineDisplay() {
        if currentLine != nil { currentLine = nil }
        if nextLineText != nil { nextLineText = nil }
        if nextLineSide != nil { nextLineSide = nil }
        if currentLineIndex != nil { currentLineIndex = nil }
        if scrollLineIndex != nil { scrollLineIndex = nil }
        if compactLine != nil { compactLine = nil }
        if compactShowsPlaceholder { compactShowsPlaceholder = false }
        if compactDwellMs != nil { compactDwellMs = nil }
        if compactLeadInMs != nil { compactLeadInMs = nil }

        if currentGapIndex != nil { currentGapIndex = nil }
        if !currentLineFillSettled { currentLineFillSettled = true }
        settledThresholdIndex = nil
    }

    private func resolveLinesForPausedPosition() {
        guard let frozen = pausedPositionMs, syncEngine.hasContent, !radioTrackFinished else {
            clearLineDisplay()
            return
        }
        let r = syncEngine.tickQuery(atMs: frozen, trackEndMs: currentDurationMs)
        if r.line != currentLine { currentLine = r.line }
        if r.compactLine != compactLine { compactLine = r.compactLine }
        if r.compactPlaceholder != compactShowsPlaceholder { compactShowsPlaceholder = r.compactPlaceholder }
        if r.compactDwellMs != compactDwellMs { compactDwellMs = r.compactDwellMs }
        if r.compactLeadInMs != compactLeadInMs { compactLeadInMs = r.compactLeadInMs }
        if r.nextText != nextLineText { nextLineText = r.nextText }
        if r.nextSide != nextLineSide { nextLineSide = r.nextSide }
        if r.index != currentLineIndex { currentLineIndex = r.index }
        if r.scrollIndex != scrollLineIndex { scrollLineIndex = r.scrollIndex }
        if r.gapIndex != currentGapIndex { currentGapIndex = r.gapIndex }
        updateLineFillSettled(line: r.line, index: r.index, atRawMs: frozen)
    }

    private func fastTick() {
        if radioTrackFinished {
            clearLineDisplay()
            return
        }
        guard let anchor else {
            resolveLinesForPausedPosition()
            return
        }
        let pos = anchor.extrapolatedPositionMs()
        let r = syncEngine.tickQuery(atMs: pos, trackEndMs: currentDurationMs)
        if r.line != currentLine { currentLine = r.line }
        if r.compactLine != compactLine { compactLine = r.compactLine }
        if r.compactPlaceholder != compactShowsPlaceholder { compactShowsPlaceholder = r.compactPlaceholder }
        if r.compactDwellMs != compactDwellMs { compactDwellMs = r.compactDwellMs }
        if r.compactLeadInMs != compactLeadInMs { compactLeadInMs = r.compactLeadInMs }
        if r.nextText != nextLineText { nextLineText = r.nextText }
        if r.nextSide != nextLineSide { nextLineSide = r.nextSide }
        if r.index != currentLineIndex { currentLineIndex = r.index }
        if r.scrollIndex != scrollLineIndex { scrollLineIndex = r.scrollIndex }
        if r.gapIndex != currentGapIndex { currentGapIndex = r.gapIndex }
        updateLineFillSettled(line: r.line, index: r.index, atRawMs: pos)
    }

    private var settledThresholdIndex: Int?
    private var settledThresholdMs = 0

    private func updateLineFillSettled(line: SyncedLyricLine?, index: Int?, atRawMs rawMs: Int) {
        let settled: Bool
        if let words = line?.words, let index {
            if index != settledThresholdIndex {
                settledThresholdIndex = index
                settledThresholdMs = KaraokeFill.lineFillSettledMs(words: words, groups: line?.wordGroups)
            }
            settled = rawMs + syncEngine.effectiveOffsetMs >= settledThresholdMs
        } else {
            settled = true
            settledThresholdIndex = nil
        }
        if settled != currentLineFillSettled { currentLineFillSettled = settled }
    }

    private func clearIfWasPlaying() {
        if isPlayingNow {
            isPlayingNow = false
            anchor = nil
            currentLine = nil
            nextLineText = nil
            nextLineSide = nil
            currentLineIndex = nil
            scrollLineIndex = nil
            compactLine = nil
            compactShowsPlaceholder = false
            compactDwellMs = nil
            compactLeadInMs = nil
            allLines = []
            lyricsGapMarkers = []
            currentGapIndex = nil
            if !currentLineFillSettled { currentLineFillSettled = true }
            settledThresholdIndex = nil
            artworkData = nil
            artworkAverageHex = nil
            if spotifyArtworkURL != nil { spotifyArtworkURL = nil }
            pausedPositionMs = nil
            currentDurationMs = nil
            if !title.isEmpty { title = "" }
            if !artist.isEmpty { artist = "" }
            if !album.isEmpty { album = "" }
            if hasLyricsContent { hasLyricsContent = false }
            if isCurrentTrackInstrumental { isCurrentTrackInstrumental = false }
            if currentTrackHasNoLyrics { currentTrackHasNoLyrics = false }
            if isCurrentTrackAdBreak { isCurrentTrackAdBreak = false }

            lastReloadSnapshot = nil
            lastKey = ""

            posWasPlaying = false
            posPrevWall = nil
            posPrevDurationSecs = 0
            setReportedBias(0, anchorElapsed: nil)
            stopFastTimer()
        }
    }

    private var pollGeneration = 0

    private var consecutiveNilSnapshots = 0

    private func poll() {
        pollGeneration += 1
        let generation = pollGeneration

        Task {
            let snapshot = await Task.detached {
                MediaControlClient.fetchSnapshot()
            }.value
            guard generation == self.pollGeneration else {
                logger.debug("poll result discarded: stale generation (\(generation) vs \(self.pollGeneration))")
                return
            }
            guard let snapshot else {

                self.consecutiveNilSnapshots += 1
                if self.consecutiveNilSnapshots == 1 || self.consecutiveNilSnapshots % 30 == 0 {
                    let streakSuffix = self.consecutiveNilSnapshots > 1
                        ? " streak=\(self.consecutiveNilSnapshots)" : ""
                    logger.notice("snapshot failed (no automation permission, Music.app not running, or nothing playing)\(streakSuffix, privacy: .public)")
                }
                clearIfWasPlaying()
                self.adjustPollCadence()
                return
            }
            if self.consecutiveNilSnapshots > 0 {
                logger.info("snapshot recovered after \(self.consecutiveNilSnapshots) consecutive failures")
                self.consecutiveNilSnapshots = 0
            }

            guard snapshot.isMusicApp == true else {
                logger.debug("snapshot ignored: not Apple Music (isMusicApp=\(String(describing: snapshot.isMusicApp)))")
                clearIfWasPlaying()
                self.adjustPollCadence()
                return
            }
            logger.debug("snapshot ok: playing=\(snapshot.playing == true)")
            self.apply(snapshot)

            self.adjustPollCadence()
        }
    }

    private func apply(_ rawSnapshot: MediaControlSnapshot) {

        var snapshot = rawSnapshot
        if rawSnapshot.isRadio == true,
           let cached = EnrichCacheReader.trackDurationSecs(
               artist: rawSnapshot.artist ?? "", title: rawSnapshot.title ?? "", album: rawSnapshot.album ?? ""),
           cached > 0, cached != rawSnapshot.duration {
            snapshot = rawSnapshot.withDuration(cached)
        }

        let stationHash = MediaControlClient.currentRadioStationHash()
        if stationHash != nil, !radioStationCardLoaded {
            radioStationCardLoaded = true
            radioStationCard = RadioStationCardFile.load()
        }
        let stationCardName = stationHash.flatMap {
            RadioStationCardFile.stationName(isRadio: snapshot.isRadio == true, stationHash: $0,
                                             title: snapshot.title, artist: snapshot.artist)
        }
        if let hash = stationHash, let name = stationCardName {
            noteRadioStationCard(name: name, hash: hash, trackKey: snapshot.trackKey)
        }

        let finished = stationCardName != nil || RadioTrackClock.passedTrackEnd(
            position: snapshot.isRadio == true ? (snapshot.elapsedTime ?? 0) : 0,
            durationSecs: snapshot.isRadio == true ? snapshot.duration : nil)

        if currentStationHash != stationHash { currentStationHash = stationHash }
        let station = RadioStationCardFile.card(radioStationCard, forStation: stationHash)
        if station?.name != radioStationName { radioStationName = station?.name }
        if station?.artwork != radioStationArtwork { radioStationArtwork = station?.artwork }
        if finished != isRadioTalkBreak { isRadioTalkBreak = finished }
        if finished != radioTrackFinished {
            radioTrackFinished = finished
            logger.notice("radio track finished=\(finished) card=\(stationCardName != nil) pos=\(snapshot.elapsedTime ?? -1, format: .fixed(precision: 1)) dur=\(snapshot.duration ?? -1, format: .fixed(precision: 1))")
        }
        lastSnapshot = snapshot

        let newTitle = snapshot.title ?? ""
        if newTitle != title { title = newTitle }
        let newArtist = snapshot.artist ?? ""
        if newArtist != artist { artist = newArtist }
        let newAlbum = snapshot.album ?? ""
        if newAlbum != album { album = newAlbum }
        let newIsPlayingNow = snapshot.playing == true
        if newIsPlayingNow != isPlayingNow { isPlayingNow = newIsPlayingNow }

        let bid = snapshot.bundleIdentifier ?? ""
        if !bid.isEmpty, !newTitle.isEmpty, bid != lastPersistedPlayerBundleID {
            UserDefaults.standard.set(bid, forKey: "np:lastPlayerBundleID")
            lastPersistedPlayerBundleID = bid
        }

        let isSpotifyNative = snapshot.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier
        let resolvedBundleID = BrowserPositionProbe.probeTargetBundleID(forReported: snapshot.bundleIdentifier)
        let isSpotifyWeb = BrowserPositionProbe.shared.isPaired(bundleID: resolvedBundleID, platformID: "spotifyWeb")

        let youTubeMusicAdKey = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)

        let youTubeMusicVerdict = YouTubeMusicAdProbe.shared.cachedBadgeVerdict(forKey: youTubeMusicAdKey)

        let spotifyWebVerdict: SpotifyWebAdProbe.Verdict? = isSpotifyWeb
            ? SpotifyWebAdProbe.shared.cachedVerdict(
                forKey: SpotifyWebAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title))
            : nil
        let adByFields = Self.adBreakByFields(
            isSpotifyNative: isSpotifyNative, title: newTitle, artist: newArtist, album: newAlbum,
            youTubeMusicVerdict: youTubeMusicVerdict, spotifyWebVerdict: spotifyWebVerdict)
        if !newTitle.isEmpty, !adByFields, newTitle != lastPersistedTrackTitle {
            UserDefaults.standard.set(newTitle, forKey: "np:lastTrackTitle")
            UserDefaults.standard.set(newArtist, forKey: "np:lastTrackArtist")
            UserDefaults.standard.set(newAlbum, forKey: "np:lastTrackAlbum")
            lastPersistedTrackTitle = newTitle
        }

        let nextAd = Self.nextAdBreakState(
            previous: isCurrentTrackAdBreak, isNewTrack: snapshot.trackKey != lastKey,
            adByFields: adByFields, pageVerdict: isSpotifyNative ? nil : youTubeMusicVerdict)
        if isCurrentTrackAdBreak != nextAd { isCurrentTrackAdBreak = nextAd }

        let nextAdSlot = nextAd
            ? YouTubeMusicAdProbe.shared.cachedReading(forKey: youTubeMusicAdKey)?.adSlot
            : nil
        if currentAdSlot != nextAdSlot { currentAdSlot = nextAdSlot }

        if nextAd, !isSpotifyNative, spotifyWebVerdict != .ad {
            YouTubeMusicAdProbe.shared.kickIfNeeded(
                bundleIdentifier: snapshot.bundleIdentifier, key: youTubeMusicAdKey)
        }

        if snapshot.trackKey != lastKey, isSpotifyNative, !adByFields {
            spotifyNativeAdCheckForNewTrack(snapshot: snapshot)
        }

        let key = snapshot.trackKey
        let trackChanged = key != lastKey

        let previousKey = lastKey

        let networkDown = CollectorStatus.networkLooksDown
        if networkDown != collectorNetworkDown { collectorNetworkDown = networkDown }

        EnrichCacheReader.refreshIfNeeded()
        let enrichMTime = EnrichCacheReader.decodedContentVersion
        if enrichContentVersion != enrichMTime { enrichContentVersion = enrichMTime }
        if trackChanged || !syncEngine.hasContent || enrichMTime != lastEnrichMTime {
            if trackChanged {
                logger.info("track changed: \(snapshot.artist ?? "", privacy: .public) - \(snapshot.title ?? "", privacy: .public)")
                if spotifyArtworkURL != nil { spotifyArtworkURL = nil }
            }
            lastKey = key
            lastEnrichMTime = enrichMTime
            reloadCurrentLyrics()
        }

        let bundleID = snapshot.bundleIdentifier
        if bundleID != lastAppliedBundleID {
            lastAppliedBundleID = bundleID
            if !trackChanged, syncEngine.hasContent { applyOffsets() }
        }

        if trackChanged {

            scheduleArtworkStaleTimeout(forKey: key)
            fetchArtworkForCurrentTrack(expectedKey: key)
        }

        let now = Date()
        let playing = snapshot.playing == true
        var pauseShownMs: Int?
        var pauseAnchorWasFrozenByEvent = false

        if isSpotifyNative, key == posTrackingKey, posReportedBiasSecs != 0,
           !Self.biasSurvivesAnchor(anchorElapsedTime: snapshot.anchorElapsedTime, measuredAgainst: posBiasAnchorElapsed) {
            logger.notice("anchor bias dropped: player republished anchor elapsed=\(snapshot.anchorElapsedTime ?? -1, format: .fixed(precision: 3)) measuredAgainst=\(self.posBiasAnchorElapsed ?? -1, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3)) playing=\(playing)")
            if !playing, posBiasFromProbe, let frozen = snapshot.anchorElapsedTime {
                let oursMs = anchor == nil ? pausedPositionMs : anchor?.extrapolatedPositionMs(now: now)
                if let oursMs {
                    learnProbeLead(residual: Double(oursMs) / 1000 - frozen)
                }
            }
            setReportedBias(0, anchorElapsed: nil)
            if playing {
                SpotifyPositionProbe.shared.requestConfirmation(forKey: key)
            }
        }
        if playing, let duration = snapshot.duration, duration > 0 {

            var rate = snapshot.playbackRate ?? 1
            if rate <= 0 { rate = 1 }

            let tier = Self.positionSourceTier(forBundleID: snapshot.bundleIdentifier)
            if trackChanged {
                BrowserPositionProbe.shared.trackChanged(from: previousKey, to: key)
                SpotifyPositionProbe.shared.trackChanged(to: key, isSpotifyNative: isSpotifyNative)
            }

            BrowserPositionProbe.shared.kickIfNeeded(
                bundleIdentifier: snapshot.bundleIdentifier, key: key, expectedDuration: duration)
            let rawReportedForResolve: Double
            let effectiveTier: PositionSourceTier
            var usedBrowserProbe = false

            if let probed = BrowserPositionProbe.shared.consumeCorrection(forKey: key, rate: rate, now: now) {
                rawReportedForResolve = probed
                effectiveTier = .noisyFloored
                usedBrowserProbe = true
            } else if posWasPlaying, key == posTrackingKey,
                      let probed = SpotifyPositionProbe.shared.consumeCorrection(forKey: key, rate: rate, now: now) {
                rawReportedForResolve = probed - probeLeadSecs
                effectiveTier = tier
                usedBrowserProbe = true
            } else {
                rawReportedForResolve = snapshot.elapsedTime ?? 0
                effectiveTier = tier
            }
            let (positionSeconds, didReanchor) = resolvePositionSeconds(
                reported: rawReportedForResolve, rate: rate, key: key, now: now,
                tier: effectiveTier, isGroundTruthSeed: usedBrowserProbe,
                anchorElapsedTime: snapshot.anchorElapsedTime, streamRaw: snapshot.elapsedTime)
            if !posWasPlaying, key == posTrackingKey, let prevPaused = pausedPositionMs {
                logger.notice("resume transition: paused=\(Double(prevPaused) / 1000, format: .fixed(precision: 3)) resumed=\(positionSeconds, format: .fixed(precision: 3)) raw=\(rawReportedForResolve, format: .fixed(precision: 3)) delta=\(positionSeconds - Double(prevPaused) / 1000, format: .fixed(precision: 3)) rate=\(snapshot.playbackRate ?? -1, format: .fixed(precision: 2))")
            }

            let needsNewAnchor = anchor == nil || trackChanged || didReanchor
                || anchor?.rate != rate || anchor?.durationMs != Int(duration * 1000)
            if needsNewAnchor {
                let targetMs = Int(positionSeconds * 1000)
                let correction = ProgressAnchor.correctionForContinuousPlayback(
                    displayedMs: anchor?.extrapolatedPositionMs(now: now), targetMs: targetMs,
                    continuous: !trackChanged && posWasPlaying && anchor?.rate == rate
                        && (lastSeekAt.map { now.timeIntervalSince($0) >= Self.seekSettleWindow } ?? true))
                anchor = ProgressAnchor(
                    durationMs: Int(duration * 1000),
                    progressMs: targetMs - correction,
                    rate: rate,
                    progressTs: nil,
                    baseAgeMs: 0,
                    fetchedAt: now,
                    fresh: true, correctionMs: correction
                )
            }
        } else {
            if let anchor {

                pauseShownMs = anchor.extrapolatedPositionMs(now: now)
                pauseAnchorWasFrozenByEvent = anchor.rate == 0
                self.anchor = nil
            }

            if key != posTrackingKey, posReportedBiasSecs != 0 { setReportedBias(0, anchorElapsed: nil) }

            let frozenRaw = snapshot.elapsedTime ?? 0
            if let prev = posPausedRawSecs, abs(frozenRaw - prev) > Self.seekJumpToleranceSecs,
               posReportedBiasSecs != 0 {
                setReportedBias(0, anchorElapsed: nil)
            }
            posPausedRawSecs = frozenRaw
        }

        let newDurationMs: Int? = {
            if let d = snapshot.duration, d > 0 { return Int(d * 1000) }
            return nil
        }()
        if newDurationMs != currentDurationMs { currentDurationMs = newDurationMs }

        let newPausedPositionMs: Int? = {
            guard !playing else { return nil }

            let reported = max(0, (snapshot.elapsedTime ?? 0) - posReportedBiasSecs)
            if let target = lastSeekTargetSecs, let prev = lastSeekPrevSecs, let at = lastSeekAt,
               Self.shouldRejectStalePositionAfterSeek(
                   reported: reported, target: target, previous: prev, elapsedSinceSeek: now.timeIntervalSince(at)
               ) {
                return pausedPositionMs ?? Int(target * 1000)
            }
            return Int(reported * 1000)
        }()
        if newPausedPositionMs != pausedPositionMs { pausedPositionMs = newPausedPositionMs }
        if let shown = pauseShownMs, let paused = newPausedPositionMs {

            logger.notice("pause transition: shown=\(Double(shown) / 1000, format: .fixed(precision: 3)) frozenRaw=\(snapshot.elapsedTime ?? -1, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3)) paused=\(Double(paused) / 1000, format: .fixed(precision: 3)) delta=\(Double(paused - shown) / 1000, format: .fixed(precision: 3)) frozenByEvent=\(pauseAnchorWasFrozenByEvent) errEMA=\(self.posErrEMA, format: .fixed(precision: 3))")
        }

        posTrackingKey = key
        posWasPlaying = playing
        posPrevWall = now
        publishPositionBiasIfChanged(snapshot: snapshot, isSpotifyNative: isSpotifyNative, now: now)

        posPrevDurationSecs = snapshot.duration ?? 0
        posPrevTierCleanExtrapolated =
            Self.positionSourceTier(forBundleID: snapshot.bundleIdentifier) == .cleanExtrapolated
        if playing, posPausedRawSecs != nil { posPausedRawSecs = nil }
        if anchor == nil {

            stopFastTimer()
            resolveLinesForPausedPosition()
        } else if syncEngine.hasContent {
            ensureFastTimerRunning()
            fastTick()
        } else {

            fastTick()
            stopFastTimer()
        }
    }

    public func forceReloadLyricsForCurrentTrack() {

        EnrichCacheReader.reloadNow()
        lastEnrichMTime = EnrichCacheReader.decodedContentVersion
        reloadCurrentLyrics()

        if anchor != nil, syncEngine.hasContent { ensureFastTimerRunning() }
        fastTick()
    }

    private var lastSeekTargetSecs: Double?
    private var lastSeekPrevSecs: Double?
    private var lastSeekAt: Date?
    public nonisolated static let seekSettleWindow: TimeInterval = 1.2

    public nonisolated static func shouldRejectStalePositionAfterSeek(
        reported: Double, target: Double, previous: Double, elapsedSinceSeek: TimeInterval
    ) -> Bool {
        guard elapsedSinceSeek >= 0, elapsedSinceSeek < seekSettleWindow else { return false }
        return abs(reported - previous) < abs(reported - target)
    }

    public func seek(toMs targetMs: Int) {
        let clampedMs = max(0, min(targetMs, currentDurationMs ?? targetMs))
        let seconds = Double(clampedMs) / 1000

        let resolvedIsAppleMusic = lastSnapshot?.bundleIdentifier == PlaybackPlayer.appleMusic.bundleIdentifier
        MusicPlaybackController.seek(toSeconds: seconds, preferAppleScript: resolvedIsAppleMusic)

        let now = Date()

        lastSeekPrevSecs = trackPosSeconds
        lastSeekTargetSecs = seconds
        lastSeekAt = now

        pollGeneration += 1
        trackPosSeconds = seconds
        posPrevWall = now
        posErrEMA = 0

        setReportedBias(0, anchorElapsed: nil)
        if let existing = anchor {
            anchor = ProgressAnchor(
                durationMs: existing.durationMs,
                progressMs: clampedMs,
                rate: existing.rate,
                progressTs: nil,
                baseAgeMs: 0,
                fetchedAt: now,
                fresh: true
            )
        } else if currentDurationMs != nil {

            pausedPositionMs = clampedMs
        }

        fastTick()
    }

    @discardableResult
    public func nudgeLyricsOffset(by deltaMs: Int) -> Int {
        guard lastSnapshot != nil else { return trackLyricsOffsetMs }

        let radioKey = currentRadioOffsetKey
        if !radioKey.isEmpty {
            LyricsOffsetStore.shared.nudgeRadio(by: deltaMs, forKey: radioKey)
        } else {
            LyricsOffsetStore.shared.nudge(by: deltaMs, forKey: currentOffsetKey, pinKey: currentPinKey)
        }
        applyOffsets()
        return trackLyricsOffsetMs
    }

    public func resetLyricsOffset() {
        guard lastSnapshot != nil else { return }
        let radioKey = currentRadioOffsetKey
        if !radioKey.isEmpty {
            LyricsOffsetStore.shared.setRadioOffset(0, forKey: radioKey)
        } else {
            LyricsOffsetStore.shared.reset(forKey: currentOffsetKey, pinKey: currentPinKey)
        }
        applyOffsets()
    }

    public func setGlobalLyricsOffset(_ ms: Int) {
        LyricsOffsetStore.shared.setGlobalOffset(ms)
        guard lastSnapshot != nil else { return }
        applyOffsets()
    }

    public func setPlayerLyricsOffset(_ ms: Int, forBundleID bundleID: String) {
        LyricsOffsetStore.shared.setPlayerOffset(ms, forBundleID: bundleID)
        guard lastSnapshot?.bundleIdentifier == bundleID else { return }
        applyOffsets()
    }

    private func applyOffsets() {
        let track = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey)

        LyricsOffsetStore.shared.syncPinToOffset(forKey: currentOffsetKey, pinKey: currentPinKey)

        let radioKey = currentRadioOffsetKey
        let effective = LyricsOffsetStore.shared.effectiveOffset(
            forKey: currentOffsetKey, bundleID: lastSnapshot?.bundleIdentifier, radioKey: radioKey
        )
        syncEngine.offsetMs = effective

        let effectiveWithLRC = effective + syncEngine.lrcOffsetMs

        if currentLyricsOffsetMs != effectiveWithLRC { currentLyricsOffsetMs = effectiveWithLRC }

        let shown = radioKey.isEmpty ? track : LyricsOffsetStore.shared.radioOffset(forKey: radioKey)
        if trackLyricsOffsetMs != shown { trackLyricsOffsetMs = shown }
    }

    public func refreshOffsetFromStore() {
        guard lastSnapshot != nil else { return }
        applyOffsets()
    }

    private var currentOffsetKey = ""

    private var currentPinKey = ""

    private var currentStationHash: String?

    private var currentRadioOffsetKey: String {
        guard lastSnapshot?.isRadio == true, let hash = currentStationHash else { return "" }
        return LyricsOffsetStore.radioKey(stationHash: hash, trackKey: currentOffsetKey)
    }

    private var lastEnrichMTime: Date?

    @Published public private(set) var enrichContentVersion: Date?

    private struct LyricsReloadSnapshot: Equatable {
        let trackKey: String
        let lyrics, lyricsTr, lyricsRoma, lyricsYRC: String
        let instrumental, resolved, searchIncomplete: Bool
        let variant: ChineseVariant
        let romanizationScripts: RomanizationScripts
        let isCantonese: Bool

        let plainLyrics: String
    }
    private var lastReloadSnapshot: LyricsReloadSnapshot?

    private func reloadCurrentLyrics() {
        guard let snapshot = lastSnapshot else { return }
        let found = EnrichCacheReader.lookup(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            album: snapshot.album ?? ""
        )

        let raw = found?.lyrics ?? ""
        if !sawChineseLyrics, ChineseVariant.affects(raw) {
            sawChineseLyrics = true
        }

        currentLyricsSupportsChineseVariant = Self.supportsChineseVariant(
            lyrics: raw,
            translation: found?.lyricsTr ?? "",
            translationVisible: showsTranslation)

        let reloadSnapshot = LyricsReloadSnapshot(
            trackKey: "\(snapshot.artist ?? "")|\(snapshot.title ?? "")|\(snapshot.album ?? "")",
            lyrics: raw,
            lyricsTr: found?.lyricsTr ?? "",
            lyricsRoma: found?.lyricsRoma ?? "",
            lyricsYRC: found?.lyricsYRC ?? "",
            instrumental: found?.instrumental ?? false,
            resolved: found?.resolved ?? false,
            searchIncomplete: found?.searchIncomplete ?? false,
            variant: chineseVariant,
            romanizationScripts: romanizationScripts,
            isCantonese: found?.isCantonese ?? false,
            plainLyrics: found?.plainLyrics ?? "")
        if reloadSnapshot == lastReloadSnapshot {
            logger.debug("lyrics reload skipped: content unchanged (mtime-only churn)")
            return
        }
        lastReloadSnapshot = reloadSnapshot

        let variant = chineseVariant

        let rawYRC = found?.lyricsYRC ?? ""
        let japaneseSong = Romanizer.looksJapaneseSong(raw.isEmpty ? rawYRC : raw)

        syncEngine.load(
            lyrics: variant.converted(JapaneseKanjiRepair.repair(raw, japaneseSong: japaneseSong)),
            lyricsTr: variant.converted(found?.lyricsTr ?? ""),
            lyricsRoma: found?.lyricsRoma ?? "",
            lyricsYRC: variant.converted(JapaneseKanjiRepair.repair(rawYRC, japaneseSong: japaneseSong)),

            trackTitle: snapshot.title ?? "",
            trackArtist: snapshot.artist ?? "",
            romanizationScripts: romanizationScripts,
            songIsCantonese: found?.isCantonese ?? false
        )
        currentOffsetKey = LyricsOffsetStore.trackKey(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            lyrics: found?.lyrics ?? "",
            lyricsYRC: found?.lyricsYRC ?? ""
        )

        currentPinKey = EnrichCacheKeys.normalizedKey(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            album: snapshot.album ?? ""
        )
        applyOffsets()
        settledThresholdIndex = nil

        let newHasContent = syncEngine.hasContent
        if newHasContent != hasLyricsContent { hasLyricsContent = newHasContent }
        let newInstrumental = found?.instrumental ?? false
        if newInstrumental != isCurrentTrackInstrumental { isCurrentTrackInstrumental = newInstrumental }

        let newNoLyrics = (found?.resolved ?? false) && !newHasContent && !newInstrumental
            && !(found?.searchIncomplete ?? false)
        if newNoLyrics != currentTrackHasNoLyrics { currentTrackHasNoLyrics = newNoLyrics }

        let newPlainLyrics = newHasContent ? "" : (found?.plainLyrics ?? "")
        if newPlainLyrics != currentTrackPlainLyrics { currentTrackPlainLyrics = newPlainLyrics }

        let newAllLines = syncEngine.allLines(idPrefix: currentOffsetKey)
        if newAllLines != allLines { allLines = newAllLines }

        let newMarkers = syncEngine.gapMarkers()
        if newMarkers != lyricsGapMarkers { lyricsGapMarkers = newMarkers }
        logger.debug("lyrics reloaded: hasContent=\(self.syncEngine.hasContent) found=\(found != nil)")
    }

    private static let artworkStaleTimeout: TimeInterval = 3
    private var artworkStaleTimeoutTask: Task<Void, Never>?

    private func scheduleArtworkStaleTimeout(forKey key: String) {
        artworkStaleTimeoutTask?.cancel()
        artworkStaleTimeoutTask = nil
        guard artworkData != nil else { return }
        artworkStaleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.artworkStaleTimeout))
            guard !Task.isCancelled, let self, self.lastKey == key else { return }
            logger.debug("artwork stale timeout: clearing previous cover after \(Self.artworkStaleTimeout)s")
            self.artworkData = nil
            self.artworkAverageHex = nil
            self.artworkStaleTimeoutTask = nil
        }
    }

    private static let artworkRetryDelays: [TimeInterval] = [0.3, 0.6, 1.2]

    private static let artworkConfirmDelay: TimeInterval = 3

    public nonisolated static func artworkKeyMatches(_ payloadKey: String, _ expectedKey: String) -> Bool {
        payloadKey.compare(expectedKey, options: [.caseInsensitive]) == .orderedSame
    }

    private func fetchArtworkForCurrentTrack(expectedKey: String) {
        Task {

            func attempt() async -> (data: Data?, payloadKey: String?) {
                await Task.detached { () -> (Data?, String?) in
                    guard let result = MediaControlClient.fetchArtwork() else { return (nil, nil) }
                    return (result.data, result.trackKey)
                }.value
            }
            func hexFor(_ data: Data?) async -> String? {
                guard let data else { return nil }
                return await Task.detached { Self.computeAverageHex(from: data) }.value
            }

            func isFinal(_ data: Data?, _ payloadKey: String?) -> Bool {
                guard data != nil, let payloadKey else { return false }
                return Self.artworkKeyMatches(payloadKey, expectedKey)
            }
            var (data, payloadKey) = await attempt()

            var round = 0
            while !isFinal(data, payloadKey), round < Self.artworkRetryDelays.count {
                guard expectedKey == self.lastKey else { return }
                self.scheduleArtworkStaleTimeout(forKey: expectedKey)
                try? await Task.sleep(for: .seconds(Self.artworkRetryDelays[round]))
                guard expectedKey == self.lastKey else { return }
                (data, payloadKey) = await attempt()
                round += 1
            }
            guard expectedKey == self.lastKey else { return }
            if let payloadKey, data != nil, !Self.artworkKeyMatches(payloadKey, expectedKey) {
                logger.info("artwork payload key mismatch after retries: payload=\(payloadKey, privacy: .public) expected=\(expectedKey, privacy: .public), dropping")
                data = nil
            }

            self.artworkStaleTimeoutTask?.cancel()
            self.artworkStaleTimeoutTask = nil

            let averageHex = await hexFor(data)
            guard expectedKey == self.lastKey else { return }
            self.artworkData = data
            self.artworkAverageHex = averageHex
            self.noteRadioStationArtwork(data, forKey: expectedKey)
            logger.debug("artwork fetched: bytes=\(data?.count ?? 0) retries=\(round) average=\(averageHex ?? "nil")")

            try? await Task.sleep(for: .seconds(Self.artworkConfirmDelay))
            guard expectedKey == self.lastKey else { return }
            let confirm = await attempt()
            guard expectedKey == self.lastKey else { return }
            guard let confirmData = confirm.data, let confirmKey = confirm.payloadKey,
                  Self.artworkKeyMatches(confirmKey, expectedKey),
                  confirmData != self.artworkData else { return }

            let confirmHex = await hexFor(confirmData)
            guard expectedKey == self.lastKey else { return }
            logger.debug("artwork confirm pass replaced cover: bytes=\(confirmData.count)")
            self.artworkData = confirmData
            self.artworkAverageHex = confirmHex
            self.noteRadioStationArtwork(confirmData, forKey: expectedKey)
        }
    }

    nonisolated private static func computeAverageHex(from data: Data) -> String? {
        guard let ciImage = CIImage(data: data) else { return nil }
        return computeAverageHex(ciImage: ciImage)
    }

    public nonisolated static func computeAverageHex(cgImage: CGImage) -> String? {
        computeAverageHex(ciImage: CIImage(cgImage: cgImage))
    }

    nonisolated private static let averageHexContext =
        CIContext(options: [.workingColorSpace: NSNull()])

    nonisolated private static func computeAverageHex(ciImage: CIImage) -> String? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }

        let context = averageHexContext
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return String(
            format: "#%02X%02X%02XFF", Int(bitmap[0]), Int(bitmap[1]), Int(bitmap[2]))
    }

    nonisolated public static func brightenedAccent(
        r: Double, g: Double, b: Double, floor: Double = 0.62
    ) -> (r: Double, g: Double, b: Double) {

        if r < 0.03, g < 0.03, b < 0.03 { return (0.72, 0.72, 0.72) }

        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let brightness = maxC
        let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
        guard brightness < floor else { return (r, g, b) }

        let ratio = brightness / floor
        return hsbToRGB(
            hue: hueOf(r: r, g: g, b: b, maxC: maxC, minC: minC),
            saturation: saturation * ratio,
            brightness: floor)
    }

    nonisolated public static func accentForDarkBackdrop(
        r: Double, g: Double, b: Double, lumaFloor: Double = 0.62
    ) -> (r: Double, g: Double, b: Double) {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard luma < lumaFloor, luma < 1 else { return (r, g, b) }

        let t = min(1, max(0, (lumaFloor - luma) / (1 - luma)))
        return (r + t * (1 - r), g + t * (1 - g), b + t * (1 - b))
    }

    nonisolated public static let notchCoverArtOverlayOpacity: Double = 0.45

    nonisolated public static func accentForCoverArtBackground(
        r: Double, g: Double, b: Double,
        rawR: Double, rawG: Double, rawB: Double,
        minContrast: Double = 4.5
    ) -> (r: Double, g: Double, b: Double) {
        let dim = 1 - notchCoverArtOverlayOpacity
        return accentAgainstStroke(
            r: r, g: g, b: b,
            strokeR: rawR * dim, strokeG: rawG * dim, strokeB: rawB * dim,
            minContrast: minContrast)
    }

    nonisolated public static func accentAgainstStroke(
        r: Double, g: Double, b: Double,
        strokeR: Double, strokeG: Double, strokeB: Double,
        minContrast: Double = 3.0
    ) -> (r: Double, g: Double, b: Double) {

        var (r, g, b) = (r, g, b)
        if r < 0.03, g < 0.03, b < 0.03 {
            let mean = (r + g + b) / 3
            (r, g, b) = (mean, mean, mean)
        }

        let strokeLum = relativeLuminance(r: strokeR, g: strokeG, b: strokeB)
        let ownLum = relativeLuminance(r: r, g: g, b: b)

        if contrastRatio(strokeLum, ownLum) >= minContrast { return (r, g, b) }

        let upper = (strokeLum + 0.05) * minContrast - 0.05
        let lower = (strokeLum + 0.05) / minContrast - 0.05

        let canGoUp = upper <= 1.0
        let canGoDown = lower >= 0.0
        let preferUp = ownLum >= strokeLum
        if preferUp, canGoUp {
            return blendToLuminance(r: r, g: g, b: b, target: upper, towardWhite: true)
        }
        if !preferUp, canGoDown {
            return blendToLuminance(r: r, g: g, b: b, target: lower, towardWhite: false)
        }

        let closeEnoughFloor = 3.0
        let closeEnoughRatio = 0.80
        if preferUp, !canGoUp {
            let clamped = contrastRatio(strokeLum, 1)
            if clamped >= closeEnoughFloor, clamped >= minContrast * closeEnoughRatio {
                return blendToLuminance(r: r, g: g, b: b, target: 1.0, towardWhite: true)
            }
        }
        if !preferUp, !canGoDown {
            let clamped = contrastRatio(strokeLum, 0)
            if clamped >= closeEnoughFloor, clamped >= minContrast * closeEnoughRatio {
                return blendToLuminance(r: r, g: g, b: b, target: 0.0, towardWhite: false)
            }
        }

        if canGoUp {
            return blendToLuminance(r: r, g: g, b: b, target: upper, towardWhite: true)
        }
        if canGoDown {
            return blendToLuminance(r: r, g: g, b: b, target: lower, towardWhite: false)
        }

        return contrastRatio(strokeLum, 0) >= contrastRatio(strokeLum, 1)
            ? (0, 0, 0) : (1, 1, 1)
    }

    nonisolated public static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            let c = min(1, max(0, c))
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    nonisolated public static func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        let hi = max(l1, l2), lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    nonisolated private static func blendToLuminance(
        r: Double, g: Double, b: Double, target: Double, towardWhite: Bool
    ) -> (r: Double, g: Double, b: Double) {
        func at(_ t: Double) -> (Double, Double, Double) {
            towardWhite
                ? (r + t * (1 - r), g + t * (1 - g), b + t * (1 - b))
                : (r * (1 - t), g * (1 - t), b * (1 - t))
        }
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 24 {
            let mid = (lo + hi) / 2
            let c = at(mid)
            let lum = relativeLuminance(r: c.0, g: c.1, b: c.2)

            if towardWhite ? (lum < target) : (lum > target) { lo = mid } else { hi = mid }
        }
        let c = at(hi)
        return (c.0, c.1, c.2)
    }

    nonisolated private static func hueOf(
        r: Double, g: Double, b: Double, maxC: Double, minC: Double
    ) -> Double {
        let delta = maxC - minC
        guard delta > 0 else { return 0 }
        let h: Double
        switch maxC {
        case r: h = (g - b) / delta + (g < b ? 6 : 0)
        case g: h = (b - r) / delta + 2
        default: h = (r - g) / delta + 4
        }
        return h / 6
    }

    nonisolated private static func hsbToRGB(
        hue: Double, saturation: Double, brightness: Double
    ) -> (r: Double, g: Double, b: Double) {
        guard saturation > 0 else { return (brightness, brightness, brightness) }
        let sector = (hue - hue.rounded(.down)) * 6
        let i = Int(sector)
        let f = sector - Double(i)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch i % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}
