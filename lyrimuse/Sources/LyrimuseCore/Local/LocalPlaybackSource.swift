import Foundation
import Combine
import CoreImage
import CoreGraphics
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "local")

@MainActor
public final class LocalPlaybackSource: ObservableObject {
    public static let shared = LocalPlaybackSource()

    @Published public private(set) var title = ""
    @Published public private(set) var artist = ""
    @Published public private(set) var album = ""
    @Published public private(set) var isPlayingNow = false
    @Published public private(set) var currentLine: SyncedLyricLine?
    @Published public private(set) var nextLineText: String?
    @Published public private(set) var nextLineSide: LyricDuet.Side?
    @Published public private(set) var currentLineIndex: Int?
    @Published public private(set) var scrollLineIndex: Int?
    @Published public private(set) var compactLine: SyncedLyricLine?
    @Published public private(set) var compactShowsPlaceholder = false
    @Published public private(set) var compactDwellMs: Int?
    @Published public private(set) var compactLeadInMs: Int?
    @Published public private(set) var allLines: [MenuBarLyricLine] = []
    @Published public private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published public private(set) var currentGapIndex: Int?
    @Published public private(set) var currentLineFillSettled = true
    @Published public private(set) var hasLyricsContent = false
    @Published public private(set) var isCurrentTrackInstrumental = false
    @Published public private(set) var currentTrackHasNoLyrics = false
    @Published public private(set) var currentTrackPlainLyrics = ""
    @Published public private(set) var networkDown = false
    @Published public private(set) var isCurrentTrackAdBreak = false
    @Published public private(set) var currentLyricsOffsetMs = 0
    @Published public private(set) var trackLyricsOffsetMs = 0
    @Published public private(set) var artworkData: Data?
    @Published public private(set) var artworkAverageHex: String?
    @Published public private(set) var pausedPositionMs: Int?
    @Published public private(set) var currentDurationMs: Int?
    public var onTrackChanged: ((String, String, String, Double) -> Void)?
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

    @Published public private(set) var anchor: ProgressAnchor?
    @Published public private(set) var cacheContentVersion: Date?

    private let syncEngine = LyricsSyncEngine()
    private var lastSnapshot: AppleMusicPlaybackSnapshot?
    private var lastKey = ""
    private var currentOffsetKey = ""
    private var currentPinKey = ""
    private var lastCacheVersion: Date?
    private var lastReloadSnapshot: LyricsReloadSnapshot?
    private var fastTimer: Timer?
    private var playerInfoObserver: NSObjectProtocol?
    private var screenLocked = false
    private var needsRealtimeLyricsUpdates = false
    private var pollGeneration = 0
    private var settledThresholdIndex: Int?
    private var settledThresholdMs = 0
    private var lastSeekTargetSecs: Double?
    private var lastSeekPrevSecs: Double?
    private var lastSeekAt: Date?

    public var lastResolvedBundleID: String? {
        lastSnapshot == nil ? nil : MusicPlaybackController.appleMusicBundleIdentifier
    }

    public func setNetworkDown(_ value: Bool) {
        networkDown = value
    }

    public func setNeedsRealtimeLyricsUpdates(_ needs: Bool) {
        needsRealtimeLyricsUpdates = needs
        if needs {
            ensureFastTimerRunning()
        } else {
            stopFastTimer()
        }
    }

    private nonisolated static func shouldRunFastTimer(
        isPlaying: Bool, hasContent: Bool, screenLocked: Bool, needsRealtimeLyricsUpdates: Bool
    ) -> Bool {
        isPlaying && hasContent && !screenLocked && needsRealtimeLyricsUpdates
    }

    private nonisolated static func supportsChineseVariant(
        lyrics: String, translation: String, translationVisible: Bool
    ) -> Bool {
        ChineseVariant.affects(lyrics) || (translationVisible && ChineseVariant.affects(translation))
    }

    public func start() {
        guard playerInfoObserver == nil else { return }
        playerInfoObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    public func stop() {
        fastTimer?.invalidate(); fastTimer = nil
        if let observer = playerInfoObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        playerInfoObserver = nil
    }

    public func setScreenLocked(_ locked: Bool) {
        screenLocked = locked
        if locked { fastTimer?.invalidate(); fastTimer = nil }
        else if anchor != nil { ensureFastTimerRunning(); fastTick() }
    }

    private func poll() {
        pollGeneration += 1
        let generation = pollGeneration
        Task {
            let snapshot = await Task.detached(priority: .utility) { MusicPlaybackController.fetchSnapshot() }.value
            guard generation == pollGeneration else { return }
            guard let snapshot else {
                clearIfStopped()
                return
            }
            apply(snapshot)
        }
    }

    private func apply(_ snapshot: AppleMusicPlaybackSnapshot) {
        let trackChanged = snapshot.trackKey != lastKey
        if trackChanged { networkDown = false }
        lastSnapshot = snapshot
        title = snapshot.title ?? ""
        artist = snapshot.artist ?? ""
        album = snapshot.album ?? ""
        isPlayingNow = snapshot.playing == true
        currentDurationMs = snapshot.duration.flatMap { $0 > 0 ? Int($0 * 1000) : nil }

        let version = EnrichCacheReader.contentVersion
        if cacheContentVersion != version { cacheContentVersion = version }
        if trackChanged || version != lastCacheVersion {
            lastKey = snapshot.trackKey
            lastCacheVersion = version
            reloadCurrentLyrics()
            if trackChanged, let onTrackChanged, !(snapshot.title ?? "").isEmpty, !(snapshot.artist ?? "").isEmpty {
                onTrackChanged(snapshot.artist ?? "", snapshot.title ?? "", snapshot.album ?? "", snapshot.duration ?? 0)
            }
        }

        let now = Date()
        if isPlayingNow, let duration = currentDurationMs {
            let progress = max(0, min(duration, Int((snapshot.elapsedTime ?? 0) * 1000)))
            anchor = ProgressAnchor(
                durationMs: duration, progressMs: progress, rate: max(0, snapshot.playbackRate ?? 1),
                progressTs: nil, baseAgeMs: 0, fetchedAt: now, fresh: true)
            pausedPositionMs = nil
            ensureFastTimerRunning()
        } else {
            let paused = max(0, Int((snapshot.elapsedTime ?? 0) * 1000))
            pausedPositionMs = paused
            anchor = nil
            stopFastTimer()
        }
        applyOffsets()
        fastTick()
    }

    private func clearIfStopped() {
        guard !title.isEmpty || isPlayingNow else { return }
        title = ""; artist = ""; album = ""; isPlayingNow = false
        currentDurationMs = nil; pausedPositionMs = nil; anchor = nil
        clearLineDisplay(); artworkData = nil; artworkAverageHex = nil
        hasLyricsContent = false; currentTrackPlainLyrics = ""
        isCurrentTrackInstrumental = false; currentTrackHasNoLyrics = false
        lastSnapshot = nil; lastKey = ""; lastReloadSnapshot = nil
        stopFastTimer()
    }

    private func ensureFastTimerRunning() {
        guard Self.shouldRunFastTimer(
            isPlaying: isPlayingNow,
            hasContent: syncEngine.hasContent,
            screenLocked: screenLocked,
            needsRealtimeLyricsUpdates: needsRealtimeLyricsUpdates
        ) else {
            stopFastTimer()
            return
        }
        guard fastTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fastTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fastTimer = timer
    }

    private func stopFastTimer() { fastTimer?.invalidate(); fastTimer = nil }

    private func clearLineDisplay() {
        currentLine = nil; nextLineText = nil; nextLineSide = nil
        currentLineIndex = nil; scrollLineIndex = nil; compactLine = nil
        compactShowsPlaceholder = false; compactDwellMs = nil; compactLeadInMs = nil
        currentGapIndex = nil; currentLineFillSettled = true; settledThresholdIndex = nil
    }

    private func fastTick() {
        guard let position = anchor?.extrapolatedPositionMs() ?? pausedPositionMs else {
            clearLineDisplay(); return
        }
        guard syncEngine.hasContent else { clearLineDisplay(); return }
        let result = syncEngine.tickQuery(atMs: position, trackEndMs: currentDurationMs)
        currentLine = result.line
        compactLine = result.compactLine
        compactShowsPlaceholder = result.compactPlaceholder
        compactDwellMs = result.compactDwellMs
        compactLeadInMs = result.compactLeadInMs
        nextLineText = result.nextText
        nextLineSide = result.nextSide
        currentLineIndex = result.index
        scrollLineIndex = result.scrollIndex
        currentGapIndex = result.gapIndex
        updateLineFillSettled(line: result.line, index: result.index, atRawMs: position)
    }

    private func updateLineFillSettled(line: SyncedLyricLine?, index: Int?, atRawMs: Int) {
        let settled: Bool
        if let words = line?.words, let index {
            if settledThresholdIndex != index {
                settledThresholdIndex = index
                settledThresholdMs = KaraokeFill.lineFillSettledMs(words: words, groups: line?.wordGroups)
            }
            settled = atRawMs + syncEngine.effectiveOffsetMs >= settledThresholdMs
        } else {
            settledThresholdIndex = nil
            settled = true
        }
        currentLineFillSettled = settled
    }

    public func forceReloadLyricsForCurrentTrack() {
        lastCacheVersion = EnrichCacheReader.contentVersion
        reloadCurrentLyrics()
        ensureFastTimerRunning()
        fastTick()
    }

    public func seek(toMs targetMs: Int) {
        let target = max(0, min(targetMs, currentDurationMs ?? targetMs))
        MusicPlaybackController.seek(toSeconds: Double(target) / 1000)
        lastSeekPrevSecs = anchor.map { Double($0.extrapolatedPositionMs()) / 1000 } ?? pausedPositionMs.map { Double($0) / 1000 }
        lastSeekTargetSecs = Double(target) / 1000
        lastSeekAt = Date()
        pausedPositionMs = target
        if let current = anchor {
            anchor = ProgressAnchor(durationMs: current.durationMs, progressMs: target, rate: current.rate,
                                    progressTs: nil, baseAgeMs: 0, fetchedAt: Date(), fresh: true)
        }
        fastTick()
    }

    @discardableResult
    public func nudgeLyricsOffset(by deltaMs: Int) -> Int {
        guard lastSnapshot != nil else { return trackLyricsOffsetMs }
        LyricsOffsetStore.shared.nudge(by: deltaMs, forKey: currentOffsetKey, pinKey: currentPinKey)
        applyOffsets()
        return trackLyricsOffsetMs
    }

    public func resetLyricsOffset() {
        guard lastSnapshot != nil else { return }
        LyricsOffsetStore.shared.reset(forKey: currentOffsetKey, pinKey: currentPinKey)
        applyOffsets()
    }

    public func setGlobalLyricsOffset(_ ms: Int) {
        LyricsOffsetStore.shared.setGlobalOffset(ms)
        if lastSnapshot != nil { applyOffsets() }
    }

    public func refreshOffsetFromStore() {
        if lastSnapshot != nil { applyOffsets() }
    }

    private func applyOffsets() {
        let global = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey)
        LyricsOffsetStore.shared.syncPinToOffset(forKey: currentOffsetKey, pinKey: currentPinKey)
        let effective = LyricsOffsetStore.shared.effectiveOffset(
            forKey: currentOffsetKey, bundleID: lastResolvedBundleID)
        syncEngine.offsetMs = effective
        currentLyricsOffsetMs = effective + syncEngine.lrcOffsetMs
        trackLyricsOffsetMs = global
    }

    private struct LyricsReloadSnapshot: Equatable {
        let trackKey: String
        let lyrics, lyricsTr, lyricsRoma, lyricsYRC: String
        let instrumental, resolved, searchIncomplete: Bool
        let variant: ChineseVariant
        let romanizationScripts: RomanizationScripts
        let plainLyrics: String
    }

    private func reloadCurrentLyrics() {
        guard let snapshot = lastSnapshot else { return }
        let found = EnrichCacheReader.lookup(artist: snapshot.artist ?? "", title: snapshot.title ?? "", album: snapshot.album ?? "")
        let raw = found?.lyrics ?? ""
        if !sawChineseLyrics, ChineseVariant.affects(raw) { sawChineseLyrics = true }
        currentLyricsSupportsChineseVariant = Self.supportsChineseVariant(
            lyrics: raw, translation: found?.lyricsTr ?? "", translationVisible: showsTranslation)
        let reload = LyricsReloadSnapshot(
            trackKey: snapshot.trackKey,
            lyrics: raw, lyricsTr: found?.lyricsTr ?? "", lyricsRoma: found?.lyricsRoma ?? "", lyricsYRC: found?.lyricsYRC ?? "",
            instrumental: found?.instrumental ?? false, resolved: found?.resolved ?? false,
            searchIncomplete: found?.searchIncomplete ?? false, variant: chineseVariant,
            romanizationScripts: romanizationScripts,
            plainLyrics: found?.plainLyrics ?? "")
        guard reload != lastReloadSnapshot else { return }
        lastReloadSnapshot = reload
        let japaneseSong = Romanizer.looksJapaneseSong(raw.isEmpty ? reload.lyricsYRC : raw)
        syncEngine.load(
            lyrics: chineseVariant.converted(JapaneseKanjiRepair.repair(raw, japaneseSong: japaneseSong)),
            lyricsTr: chineseVariant.converted(found?.lyricsTr ?? ""),
            lyricsRoma: found?.lyricsRoma ?? "",
            lyricsYRC: chineseVariant.converted(JapaneseKanjiRepair.repair(reload.lyricsYRC, japaneseSong: japaneseSong)),
            trackTitle: snapshot.title ?? "", trackArtist: snapshot.artist ?? "",
            romanizationScripts: romanizationScripts)
        currentOffsetKey = LyricsOffsetStore.trackKey(artist: snapshot.artist ?? "", title: snapshot.title ?? "",
                                                       lyrics: raw, lyricsYRC: reload.lyricsYRC)
        currentPinKey = EnrichCacheKeys.normalizedKey(artist: snapshot.artist ?? "", title: snapshot.title ?? "", album: snapshot.album ?? "")
        applyOffsets()
        allLines = syncEngine.allLines(idPrefix: currentOffsetKey)
        lyricsGapMarkers = syncEngine.gapMarkers()
        hasLyricsContent = syncEngine.hasContent
        isCurrentTrackInstrumental = reload.instrumental
        currentTrackHasNoLyrics = reload.resolved && !hasLyricsContent && !reload.instrumental && !reload.searchIncomplete
        currentTrackPlainLyrics = hasLyricsContent ? "" : reload.plainLyrics
    }

    public nonisolated static func computeAverageHex(cgImage: CGImage) -> String? {
        computeAverageHex(ciImage: CIImage(cgImage: cgImage))
    }

    private nonisolated static func computeAverageHex(ciImage: CIImage) -> String? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return String(format: "#%02X%02X%02XFF", bytes[0], bytes[1], bytes[2])
    }

    nonisolated public static func brightenedAccent(
        r: Double, g: Double, b: Double, floor: Double = 0.62
    ) -> (r: Double, g: Double, b: Double) {
        if r < 0.03, g < 0.03, b < 0.03 { return (0.72, 0.72, 0.72) }
        let maxColor = max(r, max(g, b)), minColor = min(r, min(g, b))
        guard maxColor < floor else { return (r, g, b) }
        let saturation = maxColor <= 0 ? 0 : (maxColor - minColor) / maxColor
        return hsbToRGB(hue: hueOf(r: r, g: g, b: b, maxC: maxColor, minC: minColor),
                        saturation: saturation * maxColor / floor, brightness: floor)
    }

    nonisolated public static func accentAgainstStroke(
        r: Double, g: Double, b: Double, strokeR: Double, strokeG: Double, strokeB: Double,
        minContrast: Double = 3
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

    private nonisolated static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linear(_ value: Double) -> Double {
            let value = min(1, max(0, value))
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private nonisolated static func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        let high = max(l1, l2), low = min(l1, l2)
        return (high + 0.05) / (low + 0.05)
    }

    nonisolated private static func blendToLuminance(
        r: Double, g: Double, b: Double, target: Double, towardWhite: Bool
    ) -> (r: Double, g: Double, b: Double) {
        func at(_ t: Double) -> (Double, Double, Double) {
            towardWhite ? (r + t * (1 - r), g + t * (1 - g), b + t * (1 - b)) : (r * (1 - t), g * (1 - t), b * (1 - t))
        }
        var low = 0.0, high = 1.0
        for _ in 0 ..< 24 {
            let mid = (low + high) / 2
            let c = at(mid)
            if towardWhite ? relativeLuminance(r: c.0, g: c.1, b: c.2) < target : relativeLuminance(r: c.0, g: c.1, b: c.2) > target {
                low = mid
            } else { high = mid }
        }
        return at(high)
    }

    nonisolated private static func hueOf(r: Double, g: Double, b: Double, maxC: Double, minC: Double) -> Double {
        let delta = maxC - minC
        guard delta > 0 else { return 0 }
        let hue: Double
        switch maxC {
        case r: hue = (g - b) / delta + (g < b ? 6 : 0)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        return hue / 6
    }

    nonisolated private static func hsbToRGB(hue: Double, saturation: Double, brightness: Double) -> (r: Double, g: Double, b: Double) {
        guard saturation > 0 else { return (brightness, brightness, brightness) }
        let sector = (hue - floor(hue)) * 6
        let index = Int(sector), fraction = sector - Double(index)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch index % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}
