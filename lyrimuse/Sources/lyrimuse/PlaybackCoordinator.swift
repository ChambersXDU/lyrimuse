import AppKit
import Foundation
import Combine
import LyrimuseCore
import SwiftUI
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "coordinator")

@MainActor
final class PlaybackCoordinator: ObservableObject {
    static let shared = PlaybackCoordinator()

    @Published private(set) var title: String = ""
    @Published private(set) var artist: String = ""
    @Published private(set) var album: String = ""
    @Published private(set) var isPlayingNow: Bool = false

    @Published private(set) var isPlayingSmoothed: Bool = false

    private static let stopGracePeriod: TimeInterval = 0.25
    private var stopGraceWork: DispatchWorkItem?

    private var optimisticReconcileWork: DispatchWorkItem?
    @Published private(set) var currentLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?

    @Published private(set) var nextLineSide: LyricDuet.Side?
    @Published private(set) var hasLyricsContent: Bool = false

    @Published private(set) var isCurrentTrackInstrumental: Bool = false
    @Published private(set) var currentTrackHasNoLyrics: Bool = false

    @Published private(set) var currentTrackPlainLyrics: String = ""

    @Published private(set) var collectorNetworkDown: Bool = false

    @Published private(set) var isCurrentTrackAdBreak: Bool = false

    @Published private(set) var isRadioTalkBreak: Bool = false

    @Published private(set) var radioStationName: String?
    @Published private(set) var radioStationImage: NSImage?

    @Published private(set) var currentAdSlot: YouTubeMusicAdProbe.AdSlot? = nil
    @Published private(set) var anchor: ProgressAnchor?

    @Published private(set) var currentLineIndex: Int?

    @Published private(set) var scrollLineIndex: Int?

    @Published private(set) var compactLine: SyncedLyricLine?
    @Published private(set) var compactShowsPlaceholder: Bool = false
    @Published private(set) var compactDwellMs: Int?

    @Published private(set) var compactLeadInMs: Int?
    @Published private(set) var allLines: [MenuBarLyricLine] = []

    @Published private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published private(set) var currentGapIndex: Int?

    @Published private(set) var currentLineFillSettled: Bool = true

    @Published private(set) var artworkData: Data?

    @Published private(set) var artworkImage: NSImage?

    @Published private(set) var highResArtworkImage: NSImage?

    @Published private(set) var highResArtworkThumbnail: NSImage?

    @Published private(set) var highResAverageHex: String?

    @Published private(set) var motionCoverFile: URL?
    private var motionCoverTask: Task<Void, Never>?

    @Published private(set) var artworkAccentColor: Color?

    @Published private(set) var currentLyricsOffsetMs: Int = 0

    @Published private(set) var trackLyricsOffsetMs: Int = 0

    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?

    var compactDwellSeconds: Double? {
        if let ms = compactDwellMs, ms > 50 { return Double(ms) / 1000 }

        return currentLineDwellSeconds
    }

    var compactLeadInSeconds: Double {
        guard let ms = compactLeadInMs, ms > 0 else { return 0 }
        return Double(ms) / 1000
    }

    var currentLineDwellSeconds: Double? {
        guard let index = currentLineIndex, allLines.indices.contains(index) else { return nil }
        let startMs = allLines[index].timeMs
        let endMs: Int
        if allLines.indices.contains(index + 1) {
            endMs = allLines[index + 1].timeMs
        } else if let duration = currentDurationMs, duration > startMs {

            endMs = duration
        } else {
            return nil
        }
        let seconds = Double(endMs - startMs) / 1000

        return seconds > 0.05 ? seconds : nil
    }

    private var cancellables: [AnyCancellable] = []
    private var started = false

    private init() {}

    func refreshLyricsForCurrentTrack() {
        LocalPlaybackSource.shared.forceReloadLyricsForCurrentTrack()
    }

    func seek(toMs targetMs: Int) {
        LocalPlaybackSource.shared.seek(toMs: targetMs)
    }

    var resolvedPlayerDescription: String {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return "none (no snapshot yet)" }
        if let known = PlaybackPlayer.allCases.first(where: { $0.bundleIdentifier == id }) {
            return "\(known.rawValue) (\(id))"
        }
        return "unknown (\(id))"
    }

    var resolvedPlayerDisplayName: String? {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return nil }
        if let platformID = resolvedWebPlatformID,
           let platform = BrowserPositionProbe.supportedPlatforms.first(where: { $0.id == platformID }) {
            return platform.displayName
        }
        return PlaybackPlayer.allCases.first { $0 != .auto && $0.bundleIdentifier == id }?.displayName
    }

    var resolvedWebPlatformID: String? {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return nil }
        return BrowserPositionProbe.shared.playingPlatformID(forBundleID: id)
    }

    var resolvedPlayerIcon: NSImage? {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else { return nil }
        if let platformID = resolvedWebPlatformID, let icon = WebPlatformIcon.image(platformID) {
            return icon
        }
        return AppIconResolver.icon(forBundleID: id)
    }

    func openResolvedPlayerApp() {
        guard let id = LocalPlaybackSource.shared.lastResolvedBundleID else {
            logger.notice("openResolvedPlayerApp: no resolved player")
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            logger.notice("openResolvedPlayerApp: no app for \(id, privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                logger.notice("openResolvedPlayerApp: \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            } else {
                logger.notice("openResolvedPlayerApp: activated \(id, privacy: .public)")
            }
        }
    }

    @discardableResult
    func nudgeLyricsOffset(by deltaMs: Int) -> Int {
        LocalPlaybackSource.shared.nudgeLyricsOffset(by: deltaMs)
    }

    func resetLyricsOffset() {
        LocalPlaybackSource.shared.resetLyricsOffset()
    }

    func refreshLyricsOffsetForCurrentTrack() {
        LocalPlaybackSource.shared.refreshOffsetFromStore()
    }

    var globalLyricsOffsetMs: Int { LyricsOffsetStore.shared.globalOffsetMs }

    func setGlobalLyricsOffset(_ ms: Int) {
        LocalPlaybackSource.shared.setGlobalLyricsOffset(ms)
    }

    func playerLyricsOffsetMs(forBundleID bundleID: String) -> Int {
        LyricsOffsetStore.shared.playerOffset(forBundleID: bundleID)
    }

    func setPlayerLyricsOffset(_ ms: Int, forBundleID bundleID: String) {
        LocalPlaybackSource.shared.setPlayerLyricsOffset(ms, forBundleID: bundleID)
    }

    var resolvedPlayerBundleID: String? { LocalPlaybackSource.shared.lastResolvedBundleID }

    @Published private(set) var isFavorited: Bool?

    @Published private(set) var playbackMode: MusicPlaybackController.MusicPlaybackMode?

    private var favoritedActionSeq = 0
    private var playbackModeActionSeq = 0
    private var volumeActionSeq = 0

    @Published private(set) var soundVolume: Int?

    private var volumeWriteInFlight = false
    private var pendingVolumeTarget: Int?

    private var volumeBeforeMute: Int?

    private var isAppleMusicPlayingNow: Bool {
        LocalPlaybackSource.shared.lastResolvedBundleID == PlaybackPlayer.appleMusic.bundleIdentifier
    }

    private var currentPlayer: PlaybackPlayer? {
        let bundleID = LocalPlaybackSource.shared.lastResolvedBundleID
        return PlaybackPlayer.allCases.first { $0 != .auto && $0.bundleIdentifier == bundleID }
    }

    private var extendedControlPlayer: PlaybackPlayer? {
        guard let player = currentPlayer,
              MusicPlaybackController.supportsExtendedControls(player) else { return nil }
        return player
    }

    private func extendedControlPlayerForBackgroundRefresh() -> PlaybackPlayer? {
        guard let player = extendedControlPlayer else { return nil }
        if player == .appleMusic,
           !MusicAutomationPermission.check(askIfNeeded: false).isAuthorized { return nil }
        return player
    }

    func refreshExtendedControls() {
        let includeFavorited = isAppleMusicPlayingNow
            && MusicAutomationPermission.check(askIfNeeded: false).isAuthorized
        guard let player = extendedControlPlayerForBackgroundRefresh() else {
            if isFavorited != nil { isFavorited = nil }
            if playbackMode != nil { playbackMode = nil }
            if soundVolume != nil { soundVolume = nil }
            return
        }
        let favSeq = favoritedActionSeq
        let modeSeq = playbackModeActionSeq
        let volSeq = volumeActionSeq
        Task.detached(priority: .utility) {
            let state = MusicPlaybackController.extendedControlsState(
                for: player, includeFavorited: includeFavorited && player == .appleMusic)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.favoritedActionSeq == favSeq {
                    let value = includeFavorited ? state.favorited : nil
                    if self.isFavorited != value { self.isFavorited = value }
                }
                if self.playbackModeActionSeq == modeSeq, self.playbackMode != state.mode {
                    self.playbackMode = state.mode
                }
                if self.volumeActionSeq == volSeq, self.soundVolume != state.volume {
                    self.soundVolume = state.volume
                }
            }
        }
    }

    func refreshFavorited() {
        guard isAppleMusicPlayingNow,
              MusicAutomationPermission.check(askIfNeeded: false).isAuthorized else {
            if isFavorited != nil { isFavorited = nil }
            return
        }
        let seq = favoritedActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.favoritedState()
            await MainActor.run { [weak self] in
                guard let self, self.favoritedActionSeq == seq else { return }
                guard self.isFavorited != value else { return }
                self.isFavorited = value
            }
        }
    }

    func refreshPlaybackMode() {
        guard let player = extendedControlPlayerForBackgroundRefresh() else {
            if playbackMode != nil { playbackMode = nil }
            return
        }
        let seq = playbackModeActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.playbackMode(for: player)
            await MainActor.run { [weak self] in
                guard let self, self.playbackModeActionSeq == seq else { return }
                guard self.playbackMode != value else { return }
                self.playbackMode = value
            }
        }
    }

    func refreshVolume() {
        guard let player = extendedControlPlayerForBackgroundRefresh() else {
            if soundVolume != nil { soundVolume = nil }
            return
        }
        let seq = volumeActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.soundVolume(for: player)
            await MainActor.run { [weak self] in
                guard let self, self.volumeActionSeq == seq else { return }
                guard self.soundVolume != value else { return }
                self.soundVolume = value
            }
        }
    }

    func setVolume(_ value: Int) {
        guard let player = extendedControlPlayer else { return }
        let target = min(100, max(0, value))

        if soundVolume != target { soundVolume = target }
        volumeActionSeq &+= 1

        pendingVolumeTarget = target
        pumpVolumeWrite(for: player)
    }

    private func pumpVolumeWrite(for player: PlaybackPlayer) {
        guard !volumeWriteInFlight, let target = pendingVolumeTarget else { return }
        pendingVolumeTarget = nil
        volumeWriteInFlight = true
        Task.detached(priority: .userInitiated) {

            let ok: Bool
            if player == .appleMusic,
               await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                ok = false
            } else {
                ok = MusicPlaybackController.setSoundVolume(target, for: player)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.volumeWriteInFlight = false
                if self.pendingVolumeTarget != nil {

                    self.pumpVolumeWrite(for: player)
                } else if !ok {

                    self.refreshVolume()
                }
            }
        }
    }

    func toggleMute() {
        guard let current = soundVolume else { return }
        if current > 0 {
            volumeBeforeMute = current
            setVolume(0)
        } else {
            setVolume(volumeBeforeMute ?? 50)
            volumeBeforeMute = nil
        }
    }

    func cyclePlaybackMode() {
        guard let player = extendedControlPlayer else { return }

        let target = (playbackMode ?? .list)
            .next(allowsRepeatOne: MusicPlaybackController.supportsRepeatOne(player))
        setPlaybackMode(target)
    }

    var playbackModeSupportsRepeatOne: Bool {
        guard let player = extendedControlPlayer else { return false }
        return MusicPlaybackController.supportsRepeatOne(player)
    }

    func setPlaybackMode(_ target: MusicPlaybackController.MusicPlaybackMode) {
        guard let player = extendedControlPlayer else { return }

        let resolved: MusicPlaybackController.MusicPlaybackMode =
            ((target == .repeatOne || target == .repeatAll)
                && !MusicPlaybackController.supportsRepeatOne(player))
            ? .list : target
        playbackMode = resolved
        playbackModeActionSeq &+= 1
        Task.detached(priority: .userInitiated) {
            if player == .appleMusic,
               await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
                return
            }
            let wrote = MusicPlaybackController.setPlaybackMode(resolved, for: player)

            guard !wrote else { return }
            await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
        }
    }

    func toggleFavorited() {
        guard isAppleMusicPlayingNow else { return }
        let target = !(isFavorited ?? false)
        isFavorited = target
        favoritedActionSeq &+= 1
        Task.detached(priority: .userInitiated) {

            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run { [weak self] in self?.refreshFavorited() }
                return
            }

            guard !MusicPlaybackController.setFavorited(target) else { return }
            await MainActor.run { [weak self] in self?.refreshFavorited() }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let s = LocalPlaybackSource.shared

        let settings = AppSettings.shared
        s.start()

        s.$title.assign(to: &$title)
        s.$artist.assign(to: &$artist)
        s.$album.assign(to: &$album)
        s.$isPlayingNow.assign(to: &$isPlayingNow)
        s.$nextLineText.assign(to: &$nextLineText)
        s.$nextLineSide.assign(to: &$nextLineSide)
        s.$anchor.assign(to: &$anchor)
        s.$hasLyricsContent.assign(to: &$hasLyricsContent)
        s.$isCurrentTrackInstrumental.assign(to: &$isCurrentTrackInstrumental)
        s.$currentTrackHasNoLyrics.assign(to: &$currentTrackHasNoLyrics)
        s.$currentTrackPlainLyrics.assign(to: &$currentTrackPlainLyrics)
        s.$collectorNetworkDown.assign(to: &$collectorNetworkDown)
        s.$isCurrentTrackAdBreak.assign(to: &$isCurrentTrackAdBreak)
        s.$isRadioTalkBreak.assign(to: &$isRadioTalkBreak)
        s.$radioStationName.assign(to: &$radioStationName)

        s.$radioStationArtwork
            .map { $0.flatMap { NSImage(data: $0) } }
            .assign(to: &$radioStationImage)
        s.$currentAdSlot.assign(to: &$currentAdSlot)
        s.$currentLineIndex.assign(to: &$currentLineIndex)
        s.$scrollLineIndex.assign(to: &$scrollLineIndex)
        s.$compactLine.assign(to: &$compactLine)
        s.$compactShowsPlaceholder.assign(to: &$compactShowsPlaceholder)
        s.$compactDwellMs.assign(to: &$compactDwellMs)
        s.$compactLeadInMs.assign(to: &$compactLeadInMs)
        s.$allLines.assign(to: &$allLines)
        s.$lyricsGapMarkers.assign(to: &$lyricsGapMarkers)
        s.$currentGapIndex.assign(to: &$currentGapIndex)
        s.$currentLineFillSettled.assign(to: &$currentLineFillSettled)
        s.$artworkData.assign(to: &$artworkData)

        s.$artworkData
            .map { $0.flatMap { NSImage(data: $0) } }
            .assign(to: &$artworkImage)

        Publishers.CombineLatest4(
            s.$artworkAverageHex,
            $highResAverageHex,
            settings.$textStrokeEnabled,
            settings.$textStrokeColorHex
        )
        .map { systemHex, highResHex, strokeOn, strokeHex -> Color? in
            guard let hex = highResHex ?? systemHex,
                  let ns = NSColor(hexStringWithAlpha: hex) else { return nil }

            let (r, g, b) = (ns.redComponent, ns.greenComponent, ns.blueComponent)

            guard strokeOn,
                  let stroke = NSColor(hexStringWithAlpha: strokeHex),
                  stroke.alphaComponent >= 0.5
            else {
                let lifted = LocalPlaybackSource.brightenedAccent(r: r, g: g, b: b)
                return Color(.sRGB, red: lifted.r, green: lifted.g, blue: lifted.b)
            }
            let fitted = LocalPlaybackSource.accentAgainstStroke(
                r: r, g: g, b: b,
                strokeR: stroke.redComponent,
                strokeG: stroke.greenComponent,
                strokeB: stroke.blueComponent)
            return Color(.sRGB, red: fitted.r, green: fitted.g, blue: fitted.b)
        }

        .removeDuplicates()
        .assign(to: &$artworkAccentColor)

        s.$currentLyricsOffsetMs.assign(to: &$currentLyricsOffsetMs)
        s.$trackLyricsOffsetMs.assign(to: &$trackLyricsOffsetMs)
        s.$pausedPositionMs.assign(to: &$pausedPositionMs)
        s.$currentDurationMs.assign(to: &$currentDurationMs)

        cancellables = [

            s.$title.combineLatest(s.$artist)
                .map { "\($0)|\($1)" }
                .removeDuplicates()
                .sink { [weak self] _ in

                    self?.refreshExtendedControls()
                },
            s.$isPlayingNow.sink { [weak self] playing in self?.updateSmoothedPlaying(playing) },
            s.$currentLine.sink { [weak self] line in
                logger.debug("coordinator currentLine updated: hasLine=\(line != nil) hasWords=\(line?.words != nil) hasMainText=\(line?.mainText != nil)")
                self?.currentLine = line
            },

            Publishers.CombineLatest4(s.$title, s.$artist, s.$album, s.$artworkData)
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _, _, _, _ in
                    self?.refreshHighResCover()

                    self?.refreshMotionCover()
                },

            s.$enrichContentVersion
                .dropFirst()
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refreshHighResCover(onlyIfMissing: true)

                    self?.refreshMotionCover(onlyIfMissing: true)
                },

            settings.$motionCoverEnabled
                .dropFirst()
                .sink { [weak self] _ in self?.refreshMotionCover() },
            NotificationCenter.default.publisher(for: NSNotification.Name.NSProcessInfoPowerStateDidChange)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshMotionCover() },

            Publishers.CombineLatest(s.$spotifyArtworkURL, s.$artworkData)
                .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
                .sink { [weak self] url, _ in self?.refreshSpotifyOriginalCover(url) },

        ]
    }

    private static let lowResArtworkThreshold = 300

    private var highResCoverTask: Task<Void, Never>?

    private var spotifyCoverTask: Task<Void, Never>?

    private var spotifyCoverAppliedURL: URL?

    private func refreshHighResCover(onlyIfMissing: Bool = false) {
        if onlyIfMissing, highResArtworkImage != nil { return }
        highResCoverTask?.cancel()
        highResCoverTask = nil

        let s = LocalPlaybackSource.shared
        let (title, artist, album) = (s.title, s.artist, s.album)

        func clearHighRes() {
            if highResArtworkImage != nil { highResArtworkImage = nil }
            if highResArtworkThumbnail != nil { highResArtworkThumbnail = nil }
            if highResAverageHex != nil { highResAverageHex = nil }
        }
        guard !title.isEmpty else {
            clearHighRes()
            return
        }
        let systemSize = Self.pixelSize(of: s.artworkData)
        let systemPixels = systemSize.width

        guard let reason = CoverArtReplacementGate.reason(width: systemSize.width, height: systemSize.height,
                                                          lowResThreshold: Self.lowResArtworkThreshold) else {
            clearHighRes()
            return
        }

        guard let cached = EnrichCacheReader.albumMatchedCoverURL(artist: artist, title: title, album: album) else {

            logger.debug("highres: no cached cover yet for \(title, privacy: .public) (system=\(systemSize.width, privacy: .public)x\(systemSize.height, privacy: .public)px, reason=\(String(describing: reason), privacy: .public))")
            clearHighRes()
            return
        }
        let url = EnrichCacheReader.nativeSizedCoverURL(cached)

        clearHighRes()
        highResCoverTask = Task { [weak self] in

            guard let image = await ImageMemoryCache.shared.load(url, variant: .original),
                  !Task.isCancelled else { return }

            guard LocalPlaybackSource.shared.title == title else { return }

            guard CoverArtReplacementGate.accepts(candidateWidth: image.pixelWidth,
                                                  candidateHeight: image.pixelHeight,
                                                  systemWidth: systemPixels, reason: reason) else { return }

            var hex: String?
            var thumbnail: NSImage?
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {

                (hex, thumbnail) = await Task.detached {
                    (LocalPlaybackSource.computeAverageHex(cgImage: cg),
                     Self.downscaledThumbnail(cg, maxPixel: 256))
                }.value
            }
            guard !Task.isCancelled, LocalPlaybackSource.shared.title == title else { return }
            logger.debug("highres: swapped in \(image.pixelWidth, privacy: .public)px for \(title, privacy: .public) (system=\(systemSize.width, privacy: .public)x\(systemSize.height, privacy: .public)px, reason=\(String(describing: reason), privacy: .public))")
            self?.highResArtworkImage = image
            self?.highResArtworkThumbnail = thumbnail
            self?.highResAverageHex = hex
        }
    }

    private func refreshMotionCover(onlyIfMissing: Bool = false) {
        if onlyIfMissing, motionCoverFile != nil { return }
        motionCoverTask?.cancel()
        motionCoverTask = nil
        let s = LocalPlaybackSource.shared
        let (title, artist, album) = (s.title, s.artist, s.album)
        func clear() {
            if motionCoverFile != nil { motionCoverFile = nil }
        }
        guard !title.isEmpty else {
            clear()
            return
        }

        guard AppSettings.shared.motionCoverEnabled,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            clear()
            return
        }
        guard let found = EnrichCacheReader.albumMatchedMotionCover(artist: artist, title: title, album: album) else {
            clear()
            return
        }
        if let hit = MotionCoverStore.shared.cachedFile(master: found.master) {
            if motionCoverFile != hit { motionCoverFile = hit }
            return
        }
        clear()
        motionCoverTask = Task { [weak self] in
            let file = await MotionCoverStore.shared.prepare(master: found.master)
            guard let file, !Task.isCancelled else { return }

            guard LocalPlaybackSource.shared.title == title else { return }
            self?.motionCoverFile = file
        }
    }

    private func refreshSpotifyOriginalCover(_ url: URL?) {
        spotifyCoverTask?.cancel()
        spotifyCoverTask = nil
        guard let url else {
            spotifyCoverAppliedURL = nil
            return
        }
        if spotifyCoverAppliedURL == url, highResArtworkImage != nil { return }
        let s = LocalPlaybackSource.shared
        let title = s.title
        guard !title.isEmpty, s.spotifyArtworkURL == url else { return }

        let systemWidth = artworkImage?.pixelWidth ?? 0
        let candidates = SpotifyArtworkURL.downloadCandidates(for: url)
        spotifyCoverTask = Task { [weak self] in
            var loaded: NSImage?
            for candidate in candidates {
                if Task.isCancelled { return }

                if let image = await ImageMemoryCache.shared.load(candidate, variant: .original) {
                    loaded = image
                    break
                }
            }
            guard !Task.isCancelled else { return }
            guard let image = loaded else {
                logger.notice("spotify original cover: no candidate loaded for \(title, privacy: .public)")
                return
            }

            guard LocalPlaybackSource.shared.title == title, LocalPlaybackSource.shared.spotifyArtworkURL == url else { return }

            let width = image.pixelWidth
            guard width > systemWidth else {
                logger.notice("spotify original cover: \(width, privacy: .public)px is not larger than system \(systemWidth, privacy: .public)px, keeping system cover")
                return
            }
            var hex: String?
            var thumbnail: NSImage?
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                (hex, thumbnail) = await Task.detached {
                    (LocalPlaybackSource.computeAverageHex(cgImage: cg),
                     Self.downscaledThumbnail(cg, maxPixel: 256))
                }.value
            }
            guard !Task.isCancelled, LocalPlaybackSource.shared.title == title else { return }
            logger.notice("spotify original cover: swapped in \(width, privacy: .public)px for \(title, privacy: .public) (system=\(systemWidth, privacy: .public)px)")
            self?.highResArtworkImage = image
            self?.highResArtworkThumbnail = thumbnail
            self?.highResAverageHex = hex
            self?.spotifyCoverAppliedURL = url
        }
    }

    nonisolated private static func downscaledThumbnail(_ cg: CGImage, maxPixel: Int) -> NSImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let longest = max(w, h)
        guard longest > maxPixel else {
            return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        }
        let scale = CGFloat(maxPixel) / CGFloat(longest)
        let tw = max(1, Int((CGFloat(w) * scale).rounded()))
        let th = max(1, Int((CGFloat(h) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: tw, height: th))
    }

    private static func pixelSize(of data: Data?) -> (width: Int, height: Int) {
        guard let data,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return (0, 0) }
        return (w, h)
    }

    var displayForegroundColor: Color {
        let settings = AppSettings.shared
        if settings.followsCoverArt, let accent = artworkAccentColor {
            return accent
        }
        return settings.foregroundColor
    }

    func userTogglePlayPause() {
        MusicPlaybackController.playPause()
        stopGraceWork?.cancel()
        stopGraceWork = nil
        isPlayingSmoothed = !isPlayingNow
        optimisticReconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.optimisticReconcileWork = nil
            if self.isPlayingSmoothed != self.isPlayingNow, self.stopGraceWork == nil {
                self.isPlayingSmoothed = self.isPlayingNow
            }
        }
        optimisticReconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func updateSmoothedPlaying(_ playing: Bool) {
        stopGraceWork?.cancel()
        stopGraceWork = nil
        if playing {
            if !isPlayingSmoothed { isPlayingSmoothed = true }
            return
        }

        guard isPlayingSmoothed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopGraceWork = nil

            if !self.isPlayingNow { self.isPlayingSmoothed = false }
        }
        stopGraceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopGracePeriod, execute: work)
    }
}
