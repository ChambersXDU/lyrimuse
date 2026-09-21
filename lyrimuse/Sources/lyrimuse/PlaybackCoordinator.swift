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

    @Published private(set) var networkDown: Bool = false

    @Published private(set) var isCurrentTrackAdBreak: Bool = false

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

    var resolvedPlayerDisplayName: String? {
        LocalPlaybackSource.shared.lastResolvedBundleID == nil ? nil : "Apple Music"
    }

    var resolvedPlayerIcon: NSImage? {
        guard LocalPlaybackSource.shared.lastResolvedBundleID != nil else { return nil }
        return AppIconResolver.icon(forBundleID: MusicPlaybackController.appleMusicBundleIdentifier)
    }

    func openResolvedPlayerApp() {
        guard LocalPlaybackSource.shared.lastResolvedBundleID != nil else {
            logger.notice("openResolvedPlayerApp: no resolved player")
            return
        }
        let bundleID = MusicPlaybackController.appleMusicBundleIdentifier
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.notice("openResolvedPlayerApp: no app for \(bundleID, privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                logger.notice("openResolvedPlayerApp: \(bundleID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            } else {
                logger.notice("openResolvedPlayerApp: activated \(bundleID, privacy: .public)")
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

    func setGlobalLyricsOffset(_ ms: Int) {
        LocalPlaybackSource.shared.setGlobalLyricsOffset(ms)
    }

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
        LocalPlaybackSource.shared.lastResolvedBundleID == MusicPlaybackController.appleMusicBundleIdentifier
    }

    private var canRefreshAppleMusicControls: Bool {
        isAppleMusicPlayingNow && MusicAutomationPermission.check(askIfNeeded: false).isAuthorized
    }

    func refreshExtendedControls() {
        guard canRefreshAppleMusicControls else {
            if isFavorited != nil { isFavorited = nil }
            if playbackMode != nil { playbackMode = nil }
            if soundVolume != nil { soundVolume = nil }
            return
        }
        let favSeq = favoritedActionSeq
        let modeSeq = playbackModeActionSeq
        let volSeq = volumeActionSeq
        Task.detached(priority: .utility) {
            let state = MusicPlaybackController.extendedControlsState()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.favoritedActionSeq == favSeq {
                    let value = state.favorited
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
        guard canRefreshAppleMusicControls else {
            if playbackMode != nil { playbackMode = nil }
            return
        }
        let seq = playbackModeActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.playbackMode()
            await MainActor.run { [weak self] in
                guard let self, self.playbackModeActionSeq == seq else { return }
                guard self.playbackMode != value else { return }
                self.playbackMode = value
            }
        }
    }

    func refreshVolume() {
        guard canRefreshAppleMusicControls else {
            if soundVolume != nil { soundVolume = nil }
            return
        }
        let seq = volumeActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.soundVolume()
            await MainActor.run { [weak self] in
                guard let self, self.volumeActionSeq == seq else { return }
                guard self.soundVolume != value else { return }
                self.soundVolume = value
            }
        }
    }

    func setVolume(_ value: Int) {
        guard isAppleMusicPlayingNow else { return }
        let target = min(100, max(0, value))

        if soundVolume != target { soundVolume = target }
        volumeActionSeq &+= 1

        pendingVolumeTarget = target
        pumpVolumeWrite()
    }

    private func pumpVolumeWrite() {
        guard !volumeWriteInFlight, let target = pendingVolumeTarget else { return }
        pendingVolumeTarget = nil
        volumeWriteInFlight = true
        Task.detached(priority: .userInitiated) {

            let ok: Bool
            if await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                ok = false
            } else {
                ok = MusicPlaybackController.setSoundVolume(target)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.volumeWriteInFlight = false
                if self.pendingVolumeTarget != nil {

                    self.pumpVolumeWrite()
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
        guard isAppleMusicPlayingNow else { return }

        let target = (playbackMode ?? .list).next()
        setPlaybackMode(target)
    }

    var playbackModeSupportsRepeatOne: Bool {
        isAppleMusicPlayingNow
    }

    func setPlaybackMode(_ target: MusicPlaybackController.MusicPlaybackMode) {
        guard isAppleMusicPlayingNow else { return }
        playbackMode = target
        playbackModeActionSeq &+= 1
        Task.detached(priority: .userInitiated) {
            if await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
                return
            }
            let wrote = MusicPlaybackController.setPlaybackMode(target)

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
        s.$networkDown.assign(to: &$networkDown)
        s.$isCurrentTrackAdBreak.assign(to: &$isCurrentTrackAdBreak)
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

                },

            s.$cacheContentVersion
                .dropFirst()
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refreshHighResCover(onlyIfMissing: true)

                },

        ]
    }

    private static let lowResArtworkThreshold = 300

    private var highResCoverTask: Task<Void, Never>?

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
