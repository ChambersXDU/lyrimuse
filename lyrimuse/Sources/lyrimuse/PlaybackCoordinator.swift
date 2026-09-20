import AppKit
import CoreImage
import Foundation
import Combine
import LyrimuseCore
import SwiftUI
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "coordinator")

final class WindowBackgroundLayers: Equatable {

    let base: NSImage

    let glows: [NSImage]

    struct GlowPose {
        let initialAngle: Double
        let spinDuration: Double
        let anchor: UnitPoint
        let scale: CGFloat
    }
    let poses: [GlowPose]

    let tintHue: Double
    let tintSaturation: Double
    let tintBrightness: Double

    init(base: NSImage, glows: [NSImage], poses: [GlowPose],
         tintHue: Double = 0, tintSaturation: Double = 0, tintBrightness: Double = 0) {
        self.base = base
        self.glows = glows
        self.poses = poses
        self.tintHue = tintHue
        self.tintSaturation = tintSaturation
        self.tintBrightness = tintBrightness
    }

    static func == (l: WindowBackgroundLayers, r: WindowBackgroundLayers) -> Bool { l === r }
}

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
    @Published private(set) var allLines: [LyricsWindowLine] = []

    @Published private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published private(set) var currentGapIndex: Int?

    @Published private(set) var currentLineFillSettled: Bool = true

    @Published private(set) var artworkData: Data?

    @Published private(set) var artworkImage: NSImage?

    @Published private(set) var highResArtworkImage: NSImage?

    @Published private(set) var highResArtworkThumbnail: NSImage?

    @Published private(set) var blurredArtworkImage: NSImage?

    @Published private(set) var windowBackgroundLayers: WindowBackgroundLayers?

    @Published private(set) var highResAverageHex: String?

    @Published private(set) var motionCoverFile: URL?
    private var motionCoverTask: Task<Void, Never>?

    @Published private(set) var artworkAccentColor: Color?

    @Published private(set) var notchAccentColor: Color?

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

        Publishers.CombineLatest3(s.$artworkAverageHex, $highResAverageHex, settings.$notchCardStyle)
            .map { systemHex, highResHex, cardStyle -> Color? in
                guard let hex = highResHex ?? systemHex,
                      let ns = NSColor(hexStringWithAlpha: hex) else { return nil }
                let rawR = ns.redComponent, rawG = ns.greenComponent, rawB = ns.blueComponent
                let base = LocalPlaybackSource.brightenedAccent(r: rawR, g: rawG, b: rawB)
                var lifted = LocalPlaybackSource.accentForDarkBackdrop(
                    r: base.r, g: base.g, b: base.b)
                if cardStyle == .coverArt {
                    lifted = LocalPlaybackSource.accentForCoverArtBackground(
                        r: lifted.r, g: lifted.g, b: lifted.b,
                        rawR: rawR, rawG: rawG, rawB: rawB)
                }
                return Color(.sRGB, red: lifted.r, green: lifted.g, blue: lifted.b)
            }
            .removeDuplicates()
            .assign(to: &$notchAccentColor)

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

            Publishers.CombineLatest($artworkImage, $highResArtworkImage)
                .map { system, high in high ?? system }

                .removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] source in self?.rebakeBlurredArtwork(from: source) },
        ]
    }

    private var blurBakeTask: Task<Void, Never>?

    private nonisolated static let blurBakeContext = CIContext()

    private func rebakeBlurredArtwork(from source: NSImage?) {
        blurBakeTask?.cancel()
        blurBakeTask = nil
        guard let source,
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            if blurredArtworkImage != nil { blurredArtworkImage = nil }
            if windowBackgroundLayers != nil { windowBackgroundLayers = nil }
            return
        }

        let s = LocalPlaybackSource.shared
        let seed = Self.stableSeed("\(s.artist)|\(s.title)")
        blurBakeTask = Task { [weak self] in

            let baked = await Task.detached(priority: .utility) {
                (notch: Self.bakeBackgroundBlur(cgImage: cg, targetWidth: 720, sigma: 40, saturation: nil),
                 window: Self.bakeWindowBackgroundLayers(cgImage: cg, seed: seed))
            }.value
            guard let self, !Task.isCancelled else { return }
            if let notch = baked.notch { self.blurredArtworkImage = notch }
            if let window = baked.window { self.windowBackgroundLayers = window }
        }
    }

    nonisolated private static func stableSeed(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    nonisolated private static func bakeWindowBackgroundLayers(cgImage: CGImage, seed: UInt64) -> WindowBackgroundLayers? {
        let W: CGFloat = 720
        let frame = CGRect(x: 0, y: 0, width: W, height: W)

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cgctx = CGContext(data: nil, width: 6, height: 6, bitsPerComponent: 8,
                                    bytesPerRow: 6 * 4, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        cgctx.interpolationQuality = .medium
        cgctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 6, height: 6))
        guard let data = cgctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: 36 * 4)

        var cellLuma = [Double](repeating: 0, count: 36)
        for i in 0..<36 {
            let o = i * 4
            cellLuma[i] = (0.299 * Double(px[o]) + 0.587 * Double(px[o + 1]) + 0.114 * Double(px[o + 2])) / 255
        }
        let meanLuma = cellLuma.reduce(0, +) / 36
        let homog = 0.55
        for i in 0..<36 {
            let f0 = meanLuma / max(0.02, cellLuma[i])
            let f = (1 - homog) + homog * min(3.5, max(0.4, f0))
            for ch in 0..<3 {
                px[i * 4 + ch] = UInt8(min(255, Double(px[i * 4 + ch]) * f))
            }
            px[i * 4 + 3] = 255
        }

        var cellSat = [Double](repeating: 0, count: 36)
        for i in 0..<36 {
            let o = i * 4
            let mx = Double(max(px[o], max(px[o + 1], px[o + 2])))
            let mn = Double(min(px[o], min(px[o + 1], px[o + 2])))
            cellSat[i] = mx > 0 ? (mx - mn) / mx : 0
        }

        func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
            let mx = Swift.max(r, g, b), mn = Swift.min(r, g, b), d = mx - mn
            var h = 0.0
            if d > 0 {
                if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
                h *= 60
                if h < 0 { h += 360 }
            }
            return (h, mx > 0 ? d / mx : 0, mx)
        }
        func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
            let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let i = Int(hh), f = hh - Double(i)
            let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
            switch i {
            case 0: return (v, t, p)
            case 1: return (q, v, p)
            case 2: return (p, v, t)
            case 3: return (p, q, v)
            case 4: return (t, p, v)
            default: return (v, p, q)
            }
        }

        let darkLumaFloor = 0.08
        var hueSin = 0.0, hueCos = 0.0
        for i in 0..<36 where cellSat[i] > 0.05 && cellLuma[i] > darkLumaFloor {
            let o = i * 4
            let (h, s, _) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
            hueSin += sin(h * .pi / 180) * s * s
            hueCos += cos(h * .pi / 180) * s * s
        }

        var hueCoherenceScale = 1.0
        if hueSin != 0 || hueCos != 0 {
            let hDom = atan2(hueSin, hueCos) * 180 / .pi

            var totalHueWeight = 0.0, offHueWeight = 0.0
            for i in 0..<36 where cellSat[i] > 0.05 && cellLuma[i] > darkLumaFloor {
                let o = i * 4
                let (h, s, _) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
                var d = h - hDom
                while d > 180 { d -= 360 }
                while d < -180 { d += 360 }
                totalHueWeight += s * s

                if abs(d) > 60 && abs(d) <= 120 { offHueWeight += s * s }
            }
            let offHueFraction = totalHueWeight > 0 ? offHueWeight / totalHueWeight : 0
            if totalHueWeight > 0 {
                let resultantMag = (hueSin * hueSin + hueCos * hueCos).squareRoot()
                let coherenceLinear = min(1, (resultantMag / totalHueWeight) / 0.4)
                hueCoherenceScale = coherenceLinear * coherenceLinear
            }
            if offHueFraction < 0.2 {
                for i in 0..<36 where cellSat[i] > 0.05 && cellLuma[i] > darkLumaFloor {
                    let o = i * 4
                    let (h, s, v) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
                    var d = h - hDom
                    while d > 180 { d -= 360 }
                    while d < -180 { d += 360 }

                    guard abs(d) > 60, abs(d) <= 120 else { continue }
                    let (r, g, b) = hsvToRGB(hDom + (d > 0 ? 60 : -60), s, v)
                    px[o] = UInt8(min(255, max(0, r * 255)))
                    px[o + 1] = UInt8(min(255, max(0, g * 255)))
                    px[o + 2] = UInt8(min(255, max(0, b * 255)))
                }
            }
        }

        let brightIdx = (0..<36).filter { cellLuma[$0] > darkLumaFloor }
        let satP75: Double
        if brightIdx.count >= 9 {
            let sats = brightIdx.map { cellSat[$0] }.sorted()
            satP75 = sats[min(sats.count - 1, Int(Double(sats.count) * 26.0 / 36.0))]
        } else {
            satP75 = cellSat.sorted()[26]
        }

        let satTarget = min(0.95, 1.029 * pow(satP75, 1.433)) * hueCoherenceScale
        for i in 0..<36 where cellSat[i] > 0.01 && cellSat[i] < satTarget && cellLuma[i] > darkLumaFloor {
            let target = satTarget
            let k = target / cellSat[i]
            let o = i * 4
            let mx = Double(max(px[o], max(px[o + 1], px[o + 2])))
            for ch in 0..<3 {
                let c = Double(px[o + ch])
                px[o + ch] = UInt8(min(255, max(0, mx - (mx - c) * k)))
            }
        }
        guard let fieldCG = cgctx.makeImage() else { return nil }

        func clamp(_ img: CIImage) -> CIImage {
            img.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
        }
        func render(_ img: CIImage) -> NSImage? {
            guard let out = blurBakeContext.createCGImage(img, from: frame) else { return nil }
            return NSImage(cgImage: out, size: NSSize(width: frame.width / 2, height: frame.height / 2))
        }

        let field = CIImage(cgImage: fieldCG)
            .transformed(by: CGAffineTransform(scaleX: W / 6, y: W / 6))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 35)
            .cropped(to: frame)

        var satMul = 0.85
        let fieldAvg = field.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: frame),
        ])
        if let avgCG = blurBakeContext.createCGImage(fieldAvg, from: CGRect(x: 0, y: 0, width: 1, height: 1)),
           let d = avgCG.dataProvider?.data as Data?, d.count >= 3 {
            let mx = Double(max(d[0], max(d[1], d[2])))
            let mn = Double(min(d[0], min(d[1], d[2])))
            let fieldS = mx > 0 ? (mx - mn) / mx : 0

            if fieldS > 0.02 {
                satMul = min(1.6 * max(0.4, hueCoherenceScale), max(0.35 * hueCoherenceScale, satTarget / fieldS))
            }
        }
        let vivified = field
            .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.4 * hueCoherenceScale])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: satMul])

        let baseImage = clamp(vivified
            .applyingFilter("CIExposureAdjust", parameters: ["inputEV": -0.15]))
        guard let base = render(baseImage) else { return nil }

        var tintHue: Double = 0
        var tintSat: Double = 0
        var tintBright: Double = 0
        let avg = baseImage.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: frame),
        ])
        if let avgCG = blurBakeContext.createCGImage(avg, from: CGRect(x: 0, y: 0, width: 1, height: 1)),
           let data = avgCG.dataProvider?.data as Data?, data.count >= 3 {
            let color = NSColor(
                red: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255,
                blue: CGFloat(data[2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            tintHue = Double(h)
            tintSat = Double(s)

            tintBright = Double(v) * 0.85
        }

        let brightest = (0..<36).max(by: { cellLuma[$0] < cellLuma[$1] }) ?? 14
        let bx = (Double(brightest % 6) + 0.5) / 6.0
        let by = 1.0 - (Double(brightest / 6) + 0.5) / 6.0
        guard let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: bx * frame.width, y: by * frame.height),
            "inputRadius0": frame.width * 0.08,
            "inputRadius1": frame.width * 0.7,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])?.outputImage?.cropped(to: frame) else { return nil }
        let glowImage = clamp(vivified.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame),
        ]))
        guard let glow = render(glowImage) else { return nil }

        var state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        let periods: [Double] = [55, 75, 95]
        var poses: [WindowBackgroundLayers.GlowPose] = []
        for i in 0..<3 {
            poses.append(WindowBackgroundLayers.GlowPose(
                initialAngle: (next() - 0.5) * 30,
                spinDuration: periods[i],
                anchor: UnitPoint(x: 0.4 + next() * 0.2, y: 0.4 + next() * 0.2),
                scale: 1.0 + next() * 0.25
            ))
        }
        return WindowBackgroundLayers(base: base, glows: [glow, glow, glow], poses: poses,
                                      tintHue: tintHue, tintSaturation: tintSat,
                                      tintBrightness: tintBright)
    }

    nonisolated private static func bakeBackgroundBlur(
        cgImage: CGImage, targetWidth: CGFloat, sigma: Double, saturation: Double?
    ) -> NSImage? {
        var image = CIImage(cgImage: cgImage)
        let scale = targetWidth / max(1, image.extent.width)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let saturation {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
        }
        let blurred = image.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: image.extent)
        guard let out = blurBakeContext.createCGImage(blurred, from: blurred.extent) else { return nil }

        return NSImage(cgImage: out, size: NSSize(width: blurred.extent.width / 2,
                                                  height: blurred.extent.height / 2))
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
