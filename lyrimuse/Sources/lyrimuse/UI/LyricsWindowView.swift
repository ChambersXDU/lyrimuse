import AppKit
import SwiftUI
import Combine
import CoreAudio
import LyrimuseCore

@MainActor
private final class WindowPlayback: ObservableObject {

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var isPlayingSmoothed = false
    @Published private(set) var currentLineIndex: Int?

    @Published private(set) var scrollLineIndex: Int?
    @Published private(set) var currentGapIndex: Int?
    @Published private(set) var allLines: [LyricsWindowLine] = []
    @Published private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published private(set) var currentLineFillSettled = true
    @Published private(set) var artworkData: Data?
    @Published private(set) var artworkImage: NSImage?

    @Published private(set) var isRadioTalkBreak = false
    @Published private(set) var radioStationName: String?
    @Published private(set) var radioStationImage: NSImage?
    @Published private(set) var highResArtworkImage: NSImage?

    @Published private(set) var motionCoverFile: URL?
    @Published private(set) var windowBackgroundLayers: WindowBackgroundLayers?
    @Published private(set) var anchor: ProgressAnchor?
    @Published private(set) var pausedPositionMs: Int?

    @Published private(set) var trackLyricsOffsetMs = 0
    @Published private(set) var currentDurationMs: Int?
    @Published private(set) var isFavorited: Bool?
    @Published private(set) var playbackMode: MusicPlaybackController.MusicPlaybackMode?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false

    @Published private(set) var currentTrackPlainLyrics = ""
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false

    @Published private(set) var showRomanization = true
    @Published private(set) var showTranslation = false
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$isPlayingSmoothed.removeDuplicates().sink { [weak self] in self?.isPlayingSmoothed = $0 },
            p.$currentLineIndex.removeDuplicates().sink { [weak self] in self?.currentLineIndex = $0 },
            p.$scrollLineIndex.removeDuplicates().sink { [weak self] in self?.scrollLineIndex = $0 },
            p.$currentGapIndex.removeDuplicates().sink { [weak self] in self?.currentGapIndex = $0 },
            p.$allLines.removeDuplicates().sink { [weak self] in self?.allLines = $0 },
            p.$lyricsGapMarkers.removeDuplicates().sink { [weak self] in self?.lyricsGapMarkers = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$artworkData.removeDuplicates().sink { [weak self] in self?.artworkData = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            p.$isRadioTalkBreak.removeDuplicates().sink { [weak self] in self?.isRadioTalkBreak = $0 },
            p.$radioStationName.removeDuplicates().sink { [weak self] in self?.radioStationName = $0 },
            p.$radioStationImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.radioStationImage = $0 },
            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
            p.$motionCoverFile.removeDuplicates()
                .sink { [weak self] in self?.motionCoverFile = $0 },
            p.$windowBackgroundLayers.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.windowBackgroundLayers = $0 },
            p.$anchor.sink { [weak self] in self?.anchor = $0 },
            p.$pausedPositionMs.removeDuplicates().sink { [weak self] in self?.pausedPositionMs = $0 },
            p.$trackLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.trackLyricsOffsetMs = $0 },
            p.$currentDurationMs.removeDuplicates().sink { [weak self] in self?.currentDurationMs = $0 },
            p.$isFavorited.removeDuplicates().sink { [weak self] in self?.isFavorited = $0 },
            p.$playbackMode.removeDuplicates().sink { [weak self] in self?.playbackMode = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$currentTrackPlainLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackPlainLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            s.$showRomanization.removeDuplicates().sink { [weak self] in self?.showRomanization = $0 },
            s.$showTranslation.removeDuplicates().sink { [weak self] in self?.showTranslation = $0 },
        ]
    }
}

@MainActor
private final class LyricsWindowController: ObservableObject {
    @Published private(set) var isActive = false

    @Published private(set) var isAlwaysOnTop = false

    @Published private(set) var isSurfaceVisible = true

    private weak var window: NSWindow?

    var isWindowVisible: Bool { window?.isVisible ?? false }
    private var savedFrame: NSRect?
    private var escapeMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var enterFullScreenObserver: NSObjectProtocol?
    private var exitFullScreenObserver: NSObjectProtocol?
    private var nativeFullScreenEscapeMonitor: Any?
    private var fullScreenCapabilityObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    private var persistFrameTask: Task<Void, Never>?

    private static let frameKey = "np:lyricsWindowFrame"
    private static let screenKey = "np:lyricsWindowScreenID"

    private func schedulePersistFrame() {
        persistFrameTask?.cancel()
        persistFrameTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistFrame()
        }
    }

    private func persistFrame() {
        guard let window, !isActive, !isNativeFullScreen else { return }

        guard window.isVisible else { return }
        let defaults = UserDefaults.standard
        defaults.set(NSStringFromRect(window.frame), forKey: Self.frameKey)

        if let screen = window.screen, let id = ScreenIdentity.id(of: screen) {
            defaults.set(id, forKey: Self.screenKey)
        } else {
            defaults.removeObject(forKey: Self.screenKey)
        }
    }

    @discardableResult
    private func restorePersistedFrame(_ window: NSWindow) -> Bool {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: Self.frameKey) else { return false }
        let saved = NSRectFromString(raw)
        guard saved.width > 0, saved.height > 0 else { return false }

        guard let id = defaults.string(forKey: Self.screenKey),
              let screen = ScreenIdentity.screen(withID: id) else { return false }

        let visible = screen.visibleFrame
        var frame = saved
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
        return true
    }

    private func addToWindowsMenu(_ window: NSWindow) {
        window.isExcludedFromWindowsMenu = false
        NSApp.addWindowsItem(window, title: window.title, filename: false)
    }

    private static func enforceFullScreenCapability(_ window: NSWindow) {
        var behavior = window.collectionBehavior
        guard behavior.contains(.fullScreenNone) || behavior.contains(.fullScreenAuxiliary)
            || !behavior.contains(.fullScreenPrimary) else { return }
        behavior.remove(.fullScreenNone)
        behavior.remove(.fullScreenAuxiliary)
        behavior.insert(.fullScreenPrimary)
        window.collectionBehavior = behavior

        SpaceDiagnostics.noteFullScreenCapabilityWrite()
    }

    private var trafficLightDefaultY: CGFloat?
    private var trafficLightDefaultXs: [NSWindow.ButtonType.RawValue: CGFloat] = [:]

    private static let trafficLightDownshift: CGFloat = 10

    private static let trafficLightCloseCenterX: CGFloat = 26

    private func enforceTrafficLightPosition(_ window: NSWindow) {
        guard !isNativeFullScreen else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        if trafficLightDefaultXs.isEmpty {
            for type in types {
                guard let button = window.standardWindowButton(type) else { continue }
                trafficLightDefaultXs[type.rawValue] = button.frame.origin.x
                if trafficLightDefaultY == nil { trafficLightDefaultY = button.frame.origin.y }
            }
        }
        guard let defaultY = trafficLightDefaultY,
              let closeButton = window.standardWindowButton(.closeButton),
              let closeDefaultX = trafficLightDefaultXs[NSWindow.ButtonType.closeButton.rawValue]
        else { return }

        let dx = (Self.trafficLightCloseCenterX - closeButton.frame.width / 2) - closeDefaultX

        let targetY = defaultY - Self.trafficLightDownshift
        for type in types {
            guard let button = window.standardWindowButton(type),
                  let defaultX = trafficLightDefaultXs[type.rawValue] else { continue }
            let targetX = defaultX + dx
            if abs(button.frame.origin.y - targetY) > 0.5 || abs(button.frame.origin.x - targetX) > 0.5 {
                button.setFrameOrigin(NSPoint(x: targetX, y: targetY))
            }
        }
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window

        Self.enforceFullScreenCapability(window)
        enforceTrafficLightPosition(window)
        addToWindowsMenu(window)

        restorePersistedFrame(window)
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }

        let persist: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePersistFrame() }
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main, using: persist)
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main, using: persist)

        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        isSurfaceVisible = window.isVisible ? window.occlusionState.contains(.visible) : true
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let win = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                let visible = win.occlusionState.contains(.visible)
                if self?.isSurfaceVisible != visible { self?.isSurfaceVisible = visible }
            }
        }
        if let fullScreenCapabilityObserver { NotificationCenter.default.removeObserver(fullScreenCapabilityObserver) }
        fullScreenCapabilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let win = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                Self.enforceFullScreenCapability(win)
                self?.enforceTrafficLightPosition(win)
            }
        }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.forceExit()

                if let win = note.object as? NSWindow { NSApp.removeWindowsItem(win) }
            }
        }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forceExit() }
        }

        if let enterFullScreenObserver { NotificationCenter.default.removeObserver(enterFullScreenObserver) }
        enterFullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isNativeFullScreen = true
                if self.nativeFullScreenEscapeMonitor == nil {
                    self.nativeFullScreenEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                        guard event.keyCode == 53,
                              let self, self.isNativeFullScreen,
                              self.window?.isKeyWindow == true else { return event }
                        self.window?.toggleFullScreen(nil)
                        return nil
                    }
                }
            }
        }
        if let exitFullScreenObserver { NotificationCenter.default.removeObserver(exitFullScreenObserver) }
        exitFullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isNativeFullScreen = false
                if let monitor = self.nativeFullScreenEscapeMonitor {
                    NSEvent.removeMonitor(monitor)
                    self.nativeFullScreenEscapeMonitor = nil
                }
            }
        }
    }

    func toggleAlwaysOnTop() {
        guard let window else { return }
        isAlwaysOnTop.toggle()
        window.level = isAlwaysOnTop ? .floating : .normal
    }

    @Published private(set) var isNativeFullScreen = false

    var isFullScreenActive: Bool { isActive || isNativeFullScreen }

    func toggle(reduceMotion: Bool) {

        if #available(macOS 15.0, *), let window {

            Self.enforceFullScreenCapability(window)
            window.toggleFullScreen(nil)
            return
        }
        if isActive {
            exit(animate: !reduceMotion)
        } else {
            enter(animate: !reduceMotion)
        }
    }

    private func enter(animate: Bool) {
        guard let window, let screen = window.screen ?? NSScreen.main, !isActive else { return }
        savedFrame = window.frame

        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        window.setFrame(screen.frame, display: true, animate: animate)
        isActive = true

        for delay in [0.05, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isActive, let window = self.window else { return }
                if window.frame != screen.frame {
                    window.setFrame(screen.frame, display: true)
                }
            }
        }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53, self?.window?.isKeyWindow == true else { return event }
            self?.exit(animate: true)
            return nil
        }
    }

    private func exit(animate: Bool) {
        guard let window, isActive else { return }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        NSApp.presentationOptions = []
        if let savedFrame {
            window.setFrame(savedFrame, display: true, animate: animate)
        }
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false

        savedFrame = nil
        isActive = false
    }

    private func forceExit() {
        guard isActive else { return }
        exit(animate: false)
    }

    deinit {
        persistFrameTask?.cancel()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let nativeFullScreenEscapeMonitor { NSEvent.removeMonitor(nativeFullScreenEscapeMonitor) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        if let enterFullScreenObserver { NotificationCenter.default.removeObserver(enterFullScreenObserver) }
        if let exitFullScreenObserver { NotificationCenter.default.removeObserver(exitFullScreenObserver) }
        if let fullScreenCapabilityObserver { NotificationCenter.default.removeObserver(fullScreenCapabilityObserver) }
    }
}

private struct LyricsWindowCapture: NSViewRepresentable {
    let controller: LyricsWindowController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                controller.attach(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            controller.attach(window)
        }
    }
}

struct LyricsWindowView: View {

    @StateObject private var playback = WindowPlayback()
    @StateObject private var windowController = LyricsWindowController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.displayScale) private var displayScale

    @State private var artworkWidth: CGFloat = 0

    @State private var hoveredLineID: String?

    @State private var showsMoreMenu = false

    @State private var showsInfoPanel = false

    @State private var showsChartsPanel = false

    @State private var moreAnchorRect: CGRect = .zero

    @State private var showsTranslationMenu = false

    @State private var showsLyricsPane = true

    @State private var showsListenHistory = false

    @StateObject private var scrollMetrics = LyricsScrollMetricsModel()

    @State private var scrollPendingWhileHidden = false

    @State private var idleBreath = false

    @State private var infoLyricsSource: String?

    @State private var lyricsSearchContext: LyricsSearchContext?

    private enum LibraryAddState: Equatable {
        case idle, alreadyInLibrary, adding, added, failed, removing, removeFailed
    }
    @State private var libraryAddState: LibraryAddState = .idle

    @State private var suggestLessApplied = false

    @State private var moreMenuStateGeneration = 0

    @State private var platformLinks: PlatformLinks?

    @State private var suggestLessUserToggled = false

    @State private var suggestLessSerialTask: Task<Void, Never>?

    @State private var showsOutputMenu = false
    @State private var isExternalOutput = false
    @Environment(\.colorScheme) private var colorScheme

    @State private var lyricsColumnWidth: CGFloat = 0

    @State private var lyricsViewportHeight: CGFloat = 0

    var body: some View {

        let _ = { if #available(macOS 14.1, *) { Self._logChanges() } }()
        return ScrollViewReader { scrollProxy in
            GeometryReader { geo in

                let showPlayerPane = geo.size.width >= 640

                let coverWidth = min(geo.size.width * 0.279, 460)

                let lyricsPaneVisible = showsLyricsPane || showsListenHistory || !showPlayerPane
                let paneLeading = lyricsPaneVisible
                    ? geo.size.width * 0.111

                    : (geo.size.width - coverWidth) / 2

                let isIdle = playback.title.isEmpty

                let idleWide = geo.size.width >= 860
                Group {
                if isIdle {

                    if idleWide {
                        IdleStandbyView(
                            player: idlePlayer,
                            onResume: { resumeFromIdle(player: idlePlayer) },
                            onOpenPlayer: { openIdlePlayerApp(idlePlayer) },
                            onOpenAlbum: { title, artist in
                                openCatalogPage(title: title, artist: artist, target: .album)
                            },
                            onOpenTrack: { title, artist in
                                openCatalogPage(title: title, artist: artist, target: .track)
                            })
                    } else {
                        idleWelcomeView
                            .offset(y: -geo.safeAreaInsets.top / 2)
                    }
                } else {
                HStack(spacing: 0) {
                    if showPlayerPane {
                        playerPane
                            .frame(width: coverWidth)
                            .padding(.leading, paneLeading)
                            .frame(maxHeight: .infinity)

                            .offset(y: -geo.safeAreaInsets.top / 2 - 2)
                    }
                    if lyricsPaneVisible {

                        Group {
                            if showsListenHistory {
                                listenHistoryPane(
                                    leading: showPlayerPane
                                        ? max(24, geo.size.width * 0.515 - (geo.size.width * 0.111 + coverWidth))
                                        : 44,
                                    trailing: max(32, geo.size.width * 0.06))
                            } else {
                                rightPane(
                                    leading: showPlayerPane
                                        ? max(24, geo.size.width * 0.515 - (geo.size.width * 0.111 + coverWidth))
                                        : 44,
                                    trailing: max(32, geo.size.width * 0.06))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 0).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                .background(
                    ZStack {
                        artworkBackground

                        IdleStandbyBackground(wide: idleWide)
                            .opacity(isIdle ? 1 : 0)
                    }
                    .animation(.easeInOut(duration: 0.45), value: isIdle)
                    .ignoresSafeArea())

                .overlay(alignment: .topTrailing) {

                    if !isIdle {
                        WindowVolumeCapsule(onArtwork: hasArtworkBackground,
                                            showsOutputMenu: $showsOutputMenu,
                                            isExternalOutput: isExternalOutput)
                        .padding(.trailing, 5)

                        .offset(y: 8)
                    }
                }
                .overlay(alignment: .topLeading) {

                    windowActionsCapsule()
                        .padding(.leading, 102)
                        .offset(y: -geo.safeAreaInsets.top + 8)
                }

                .overlayPreferenceValue(MoreMenuButtonBoundsKey.self) { anchor in
                    if let anchor {
                        let r = geo[anchor].integral
                        Color.clear
                            .allowsHitTesting(false)
                            .onAppear { moreAnchorRect = r }
                            .onChange(of: r) { _, v in moreAnchorRect = v }
                    }
                }
                .overlay {
                    if showsMoreMenu, moreAnchorRect != .zero {

                        ZStack(alignment: .bottomLeading) {

                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsMoreMenu = false }
                                }
                                .transition(.opacity)
                            moreMenuPanel
                                .fixedSize()
                                .padding(.leading, moreAnchorRect.maxX)
                                .padding(.bottom, max(8, geo.size.height - moreAnchorRect.minY + 8))

                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                        }
                    }
                }

                .overlay {
                    if showsInfoPanel, moreAnchorRect != .zero {

                        ZStack(alignment: .bottomLeading) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsInfoPanel = false }
                                }
                                .transition(.opacity)
                            trackInfoPanel
                                .fixedSize()
                                .padding(.leading, moreAnchorRect.maxX)
                                .padding(.bottom, max(8, geo.size.height - moreAnchorRect.minY + 8))
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                        }
                    }
                }

                .overlay {
                    if showsChartsPanel, moreAnchorRect != .zero {

                        ZStack(alignment: .bottomLeading) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsChartsPanel = false }
                                }
                                .transition(.opacity)
                            ChartsPanelView()
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 300)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                                .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
                                .padding(.leading, moreAnchorRect.maxX)
                                .padding(.bottom, max(8, geo.size.height - moreAnchorRect.minY + 8))
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                        }
                    }
                }

                .overlay(alignment: .bottomTrailing) {

                    HStack(spacing: 8.5) {
                        if !isIdle, playback.hasLyricsContent && (trackHasTranslation || trackHasRomanization)
                            && lyricsPaneVisible {
                            Button {
                                withAnimation(.easeOut(duration: 0.12)) { showsTranslationMenu.toggle() }
                            } label: {
                                translationButtonLabel
                            }
                            .buttonStyle(.plain)
                            .help(L10n.t("翻译与发音"))
                            .anchorPreference(key: TranslationMenuButtonBoundsKey.self, value: .bounds) { $0 }
                        }
                        if !isIdle { lyricsQueuePill(showPlayerPane: showPlayerPane) }
                    }
                    .padding(.trailing, 10)
                    .padding(.bottom, 11)
                }

                .overlayPreferenceValue(TranslationMenuButtonBoundsKey.self) { anchor in
                    if showsTranslationMenu, let anchor {
                        let r = geo[anchor]
                        ZStack(alignment: .bottomTrailing) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsTranslationMenu = false }
                                }
                                .transition(.opacity)
                            translationMenuPanel
                                .fixedSize()
                                .padding(.trailing, max(8, geo.size.width - r.maxX))
                                .padding(.bottom, max(8, geo.size.height - r.minY + 8))
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                        }
                    }
                }

                .overlayPreferenceValue(OutputMenuButtonBoundsKey.self) { anchor in
                    if showsOutputMenu, let anchor {
                        let r = geo[anchor]
                        let buttonBottom = r.maxY - geo.safeAreaInsets.top + 6
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.12)) { showsOutputMenu = false }
                                }
                                .transition(.opacity)
                            outputDevicePanel
                                .fixedSize()
                                .padding(.leading, max(8, r.minX - 16))
                                .padding(.top, max(8, buttonBottom + 8))
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                    }
                }
            }

            .sheet(item: $lyricsSearchContext) { ctx in
                LyricsSearchSheet(
                    artist: ctx.artist, title: ctx.title, album: ctx.album,
                    currentSource: ctx.currentSource, currentFingerprint: ctx.currentFingerprint,
                    durationSecs: ctx.durationSecs
                ) { candidate in

                    await EnrichCacheStore.shared.reload(onlyIfChanged: true)

                    let saved: Bool
                    if candidate.isPlainTextOnly {
                        saved = await EnrichCacheStore.shared.savePlainTextEdit(
                            key: ctx.key, plainLyrics: candidate.lyrics, source: candidate.source)
                    } else {

                        saved = await EnrichCacheStore.shared.saveEdit(
                            key: ctx.key,
                            lyrics: candidate.lyrics, tr: candidate.lyricsTr,
                            roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC,
                            source: candidate.source,
                            markManual: AppSettings.shared.manualPickLocksLyrics,
                            sourceChoice: "", fromManualPick: true)
                    }

                    PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()

                    return saved
                }
            }

            .onChange(of: playback.scrollLineIndex) {

                scrollToActiveLine(scrollProxy: scrollProxy, animated: windowController.isSurfaceVisible)
                if !windowController.isSurfaceVisible { scrollPendingWhileHidden = true }
            }
            .onChange(of: playback.currentGapIndex) {

                if let g = playback.currentGapIndex {
                    let visible = windowController.isSurfaceVisible
                    if !visible { scrollPendingWhileHidden = true }
                    if g == -1 {
                        DispatchQueue.main.async {
                            scrollToActiveLine(scrollProxy: scrollProxy, animated: visible)
                        }
                    } else if let id = gapRowID(g) {
                        if visible {
                            withAnimation(Self.lineTransition) {
                                scrollProxy.scrollTo(id, anchor: Self.activeLineAnchor)
                            }
                        } else {
                            scrollProxy.scrollTo(id, anchor: Self.activeLineAnchor)
                        }
                    }
                }
            }
            .onChange(of: playback.allLines) {

                DispatchQueue.main.async {
                    scrollToActiveLine(scrollProxy: scrollProxy, animated: false)
                }
            }
            .onChange(of: windowController.isSurfaceVisible) { _, visible in

                guard visible, scrollPendingWhileHidden else { return }
                scrollPendingWhileHidden = false
                DispatchQueue.main.async {
                    scrollToActiveLine(scrollProxy: scrollProxy, animated: false)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    scrollToActiveLine(scrollProxy: scrollProxy, animated: false)
                }
            }
        }

        .frame(minWidth: 520, idealWidth: 1020, minHeight: 480, idealHeight: 660)
        .background(LyricsWindowCapture(controller: windowController).frame(width: 0, height: 0))

        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }
        .onDisappear { AuxiliaryWindowActivation.windowDidDisappear() }

        .onAppear {
            PlaybackCoordinator.shared.refreshFavorited()
            PlaybackCoordinator.shared.refreshPlaybackMode()
            PlaybackCoordinator.shared.refreshVolume()
            isExternalOutput = AudioOutputDeviceManager.isExternalOutputActive()
        }

        .onChange(of: showsOutputMenu) {
            isExternalOutput = AudioOutputDeviceManager.isExternalOutputActive()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in

            guard windowController.isWindowVisible else { return }
            PlaybackCoordinator.shared.refreshFavorited()
            PlaybackCoordinator.shared.refreshPlaybackMode()
            PlaybackCoordinator.shared.refreshVolume()
        }
    }

    private var activeID: String? {
        guard let idx = playback.scrollLineIndex ?? playback.currentLineIndex,
              playback.allLines.indices.contains(idx) else { return nil }
        return playback.allLines[idx].id
    }

    private static let activeLineAnchor = UnitPoint(x: 0.5, y: 0.41)

    static let lineTransition: Animation = .smooth(duration: 0.45)

    private func scrollToActiveLine(scrollProxy: ScrollViewProxy, animated: Bool) {

        let target: (id: String, anchor: UnitPoint)?
        if let id = activeID {
            target = (id, Self.activeLineAnchor)
        } else if gapMarker(-1) != nil, let first = playback.allLines.first {
            target = (first.id, UnitPoint(x: 0.5, y: 0.52))
        } else {
            target = nil
        }
        guard let target else { return }
        if animated {
            withAnimation(Self.lineTransition) {
                scrollProxy.scrollTo(target.id, anchor: target.anchor)
            }
        } else {
            scrollProxy.scrollTo(target.id, anchor: target.anchor)
        }
    }

    private var lyricFontSize: CGFloat {
        let w = lyricsColumnWidth > 0 ? lyricsColumnWidth : 460
        let h = lyricsViewportHeight > 0 ? lyricsViewportHeight : 640
        return max(22, min(h * 0.0598, w * 0.0564))
    }

    private var duetInsetUnit: CGFloat {
        LyricDuetLayout.insets(
            for: .leading,
            availableWidth: lyricsColumnWidth,
            fontSize: lyricFontSize
        ).trailing
    }

    private var romaFontSize: CGFloat { lyricFontSize * 0.54 }
    private var translationFontSize: CGFloat { lyricFontSize * 0.61 }

    private var lyricLineSpacing: CGFloat { lyricFontSize * 0.98 }

    @ViewBuilder
    private func rightPane(leading: CGFloat, trailing: CGFloat) -> some View {
        if playback.isRadioTalkBreak {
            emptyState
        } else if playback.allLines.isEmpty {

            if !playback.currentTrackPlainLyrics.isEmpty {
                plainLyricsFallback(leading: leading, trailing: trailing)
            } else {
                emptyState
            }
        } else {
            ScrollView {

                VStack(alignment: .leading, spacing: lyricLineSpacing) {

                    if let intro = gapMarker(-1), let firstID = playback.allLines.first?.id {
                        gapDotsRow(intro, id: "\(firstID)-intro")
                    }
                    ForEach(Array(playback.allLines.enumerated()), id: \.element.id) { index, item in

                        LyricsLineRow(
                            item: item,
                            distance: distance(for: index),

                            isActive: item.id == activeID && playback.currentGapIndex == nil,
                            isHovered: hoveredLineID == item.id,

                            isPlaying: playback.isPlayingNow && windowController.isSurfaceVisible,

                            fillSettled: index == playback.currentLineIndex
                                && playback.currentLineFillSettled,
                            fontSize: lyricFontSize,
                            romaFontSize: romaFontSize,
                            translationFontSize: translationFontSize,
                            duetInsetUnit: duetInsetUnit,
                            onArtwork: hasArtworkBackground,
                            showRomanization: playback.showRomanization,
                            showTranslation: playback.showTranslation,
                            reduceMotion: reduceMotion,
                            displayScale: displayScale,
                            onHover: { inside in
                                if inside { hoveredLineID = item.id }
                                else if hoveredLineID == item.id { hoveredLineID = nil }
                            },
                            onTap: {

                                PlaybackCoordinator.shared.seek(toMs: max(0, item.timeMs - PlaybackCoordinator.shared.currentLyricsOffsetMs))
                            }
                        )
                        .equatable()
                        .id(item.id)

                        if let g = gapMarker(index) {
                            gapDotsRow(g, id: "\(item.id)-gap")
                        }
                    }
                }

                .animation(Self.lineTransition, value: playback.currentGapIndex)

                .padding(.top, max(88, lyricsViewportHeight * 0.395))
                .padding(.bottom, max(88, lyricsViewportHeight * 0.55))

                .padding(.leading, leading)
                .padding(.trailing, trailing)
                .frame(maxWidth: .infinity, alignment: .leading)

                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: LyricsScrollMetricsKey.self,
                            value: LyricsScrollMetricsValue(
                                offsetY: -g.frame(in: .named("lyricsScroll")).minY,
                                contentHeight: g.size.height))
                    }
                )
            }

            .scrollIndicators(.hidden)
            .coordinateSpace(name: "lyricsScroll")
            .onPreferenceChange(LyricsScrollMetricsKey.self) { [weak scrollMetrics] v in
                scrollMetrics?.update(offsetY: v.offsetY, contentHeight: v.contentHeight)
            }
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear {
                            lyricsColumnWidth = g.size.width
                            lyricsViewportHeight = g.size.height
                        }
                        .onChange(of: g.size.width) { _, w in lyricsColumnWidth = w }
                        .onChange(of: g.size.height) { _, h in lyricsViewportHeight = h }
                }
            )

            .mask(
                LinearGradient(
                    stops: [

                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.075),
                        .init(color: .black, location: 0.2),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )

            .overlay(alignment: .trailing) {
                LyricsScrollIndicator(metrics: scrollMetrics, onArtwork: hasArtworkBackground)
                    .frame(width: 12)

                    .padding(.trailing, 53)
                    .allowsHitTesting(false)
            }
        }
    }

    private var playerPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 20)
            artworkCard

            trackInfoRow
                .padding(.top, 19)

            WindowProgressSection(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                onArtwork: hasArtworkBackground,
                backgroundLayers: playback.windowBackgroundLayers,
                title: playback.title,
                artist: playback.artist)
                .padding(.top, 19)
            playbackControls
                .padding(.top, 17)
            Spacer(minLength: 20)
        }

    }

    private var artworkCard: some View {

        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {

                if playback.isCurrentTrackAdBreak {

                    ZStack {
                        Rectangle().fill(hasArtworkBackground ? Color.white.opacity(0.1) : Color.primary.opacity(0.06))
                        Image(systemName: "megaphone.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(secondaryTextColor)
                    }
                } else if let nsImage = radioTalkStation?.image ?? playback.highResArtworkImage ?? playback.artworkImage {
                    ZStack {

                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()

                        if !reduceMotion, let file = playback.motionCoverFile {
                            MotionCoverView(file: file, isPlaying: playback.isPlayingSmoothed)
                                .transition(.opacity)
                        }
                    }
                } else {
                    ZStack {
                        Rectangle().fill(hasArtworkBackground ? Color.white.opacity(0.1) : Color.primary.opacity(0.06))
                        Image(systemName: "music.note")
                            .font(.system(size: 44))
                            .foregroundStyle(secondaryTextColor)
                    }
                }
            }

            .animation(.easeInOut(duration: 0.5), value: playback.artworkData)

            .animation(.easeInOut(duration: 0.5), value: playback.highResArtworkImage)

            .animation(.easeInOut(duration: 0.5), value: playback.motionCoverFile)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(hasArtworkBackground ? 0.45 : 0.2), radius: 26, y: 12)

            .scaleEffect(playback.isPlayingSmoothed ? 1 : 0.732, anchor: .center)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72),
                       value: playback.isPlayingSmoothed)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { artworkWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in artworkWidth = w }
                }
            )
    }

    private var trackInfoRow: some View {

        HStack(alignment: .center, spacing: 12) {
            trackInfoTexts
            Spacer(minLength: 8)
            titleSideButtons
        }
    }

    private var trackInfoTexts: some View {

        VStack(alignment: .leading, spacing: -3) {

            MarqueeText(id: displayTitle) {
                Text(displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(primaryTextColor)
            }
            .frame(height: 22)
            MarqueeText(id: displayArtistAlbum) {
                Text(displayArtistAlbum)

                    .font(.system(size: 15.5))
                    .foregroundStyle(secondaryTextColor)
            }
            .frame(height: 22)
        }
    }

    private var titleSideButtons: some View {
        HStack(spacing: 8) {
            if let favorited = playback.isFavorited {
                Button {
                    PlaybackCoordinator.shared.toggleFavorited()
                } label: {
                    circleIcon(favorited ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .help(L10n.t(favorited ? "取消喜欢" : "喜欢"))
            }

            Button {
                withAnimation(.easeOut(duration: 0.12)) { showsMoreMenu.toggle() }
            } label: {
                circleIcon("ellipsis")
            }
            .buttonStyle(.plain)
            .anchorPreference(key: MoreMenuButtonBoundsKey.self, value: .bounds) { $0 }

            Button {
                AppActions.shared.openSettings?()
            } label: {
                circleIcon("gearshape")
            }
            .buttonStyle(.plain)
            .help(L10n.t("设置…"))
        }
    }

    private var isAppleMusicPlayer: Bool {
        PlaybackCoordinator.shared.resolvedPlayerBundleID == PlaybackPlayer.appleMusic.bundleIdentifier
    }

    private var moreMenuPanel: some View {
        let playerName = PlaybackCoordinator.shared.resolvedPlayerDisplayName
        let isAM = isAppleMusicPlayer
        return VStack(alignment: .leading, spacing: 2) {

            if isAM {
                addToLibraryRow
                MoreMenuRow(
                    title: L10n.t(suggestLessApplied ? "已减少推荐" : "减少推荐"),
                    trailingSystemImage: suggestLessApplied ? "checkmark" : nil
                ) {

                    suggestLessUserToggled = true
                    let newValue = !suggestLessApplied
                    suggestLessApplied = newValue

                    let previous = suggestLessSerialTask
                    suggestLessSerialTask = Task.detached(priority: .userInitiated) {
                        await previous?.value
                        guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else { return }
                        MusicPlaybackController.setDisliked(newValue)
                    }
                }
                menuDivider
                MoreMenuRow(title: L10n.t("前往专辑")) {
                    closeMoreMenu()
                    openCatalogPage(album: true)
                }
                MoreMenuRow(title: L10n.t("前往艺人")) {
                    closeMoreMenu()
                    openCatalogPage(album: false)
                }
            }

            if !platformMenuRows.isEmpty {
                ForEach(platformMenuRows) { row in

                    MoreMenuRow(title: row.title + " ↗") {
                        closeMoreMenu()
                        NSWorkspace.shared.open(row.url)
                    }
                }
                menuDivider
            }

            MoreMenuRow(title: String(format: L10n.t("在 %@ 中显示"), playerName ?? L10n.t("播放器"))) {
                closeMoreMenu()
                if isAM {
                    runAppleMusicMenuAction { MusicPlaybackController.revealCurrentTrack() }
                } else if PlaybackCoordinator.shared.resolvedPlayerBundleID == PlaybackPlayer.spotify.bundleIdentifier {
                    SpotifyReveal.revealCurrentTrack { PlaybackCoordinator.shared.openResolvedPlayerApp() }
                } else {
                    PlaybackCoordinator.shared.openResolvedPlayerApp()
                }
            }
            menuDivider
            MoreMenuRow(title: L10n.t("显示简介")) {
                closeMoreMenu()
                openInfoPanel()
            }

            if LastfmStatsService.shared.isConnected {
                MoreMenuRow(title: L10n.t("你的常听")) {
                    closeMoreMenu()
                    withAnimation(.easeOut(duration: 0.12)) { showsChartsPanel = true }
                }
            }
            if !playback.title.isEmpty {
                MoreMenuRow(title: L10n.t("搜索歌词…")) {
                    closeMoreMenu()
                    openLyricsSearch()
                }
            }

            lyricsOffsetRow
        }
        .padding(6)
        .frame(minWidth: 200, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
        .onAppear { refreshMoreMenuTrackState() }

        .onChange(of: moreMenuTrackIdentity) { _ in refreshMoreMenuTrackState() }
    }

    private struct PlatformMenuRow: Identifiable {
        let id: String
        let title: String
        let url: URL
    }

    private var platformMenuRows: [PlatformMenuRow] {
        guard !isAppleMusicPlayer, let links = platformLinks else { return [] }
        let bundleID = PlaybackCoordinator.shared.resolvedPlayerBundleID
        var out: [PlatformMenuRow] = []
        if bundleID == PlaybackPlayer.qqMusic.bundleIdentifier {
            if let u = links.qqSong { out.append(.init(id: "qq-song", title: L10n.t("QQ 音乐歌曲页"), url: u)) }
            if let u = links.qqAlbum { out.append(.init(id: "qq-album", title: L10n.t("QQ 音乐专辑页"), url: u)) }
            if let u = links.qqArtist { out.append(.init(id: "qq-artist", title: L10n.t("QQ 音乐歌手页"), url: u)) }
        } else if bundleID == PlaybackPlayer.netease.bundleIdentifier {

            if let u = links.neteaseSong { out.append(.init(id: "ne-song", title: L10n.t("网易云音乐歌曲页"), url: u)) }
        }
        return out
    }

    private var moreMenuTrackIdentity: String {
        "\(playback.title)|\(playback.artist)|\(playback.album)"
    }

    @ViewBuilder private var addToLibraryRow: some View {
        switch libraryAddState {
        case .idle:
            MoreMenuRow(title: L10n.t("添加到资料库")) { addCurrentTrackToLibraryFromMenu() }
        case .failed:
            MoreMenuRow(title: L10n.t("添加失败"), trailingSystemImage: "arrow.clockwise") {
                addCurrentTrackToLibraryFromMenu()
            }
        case .alreadyInLibrary:
            MoreMenuRow(title: L10n.t("从资料库删除")) { removeCurrentTrackFromLibraryFromMenu() }
        case .adding:
            MoreMenuRow(title: L10n.t("添加中…"), enabled: false) {}
        case .added:
            MoreMenuRow(title: L10n.t("已添加"), trailingSystemImage: "checkmark", enabled: false) {}
        case .removing:
            MoreMenuRow(title: L10n.t("删除中…"), enabled: false) {}
        case .removeFailed:
            MoreMenuRow(title: L10n.t("删除失败"), trailingSystemImage: "arrow.clockwise") {
                removeCurrentTrackFromLibraryFromMenu()
            }
        }
    }

    private func refreshMoreMenuTrackState() {
        moreMenuStateGeneration += 1
        let generation = moreMenuStateGeneration
        libraryAddState = .idle
        suggestLessApplied = false
        suggestLessUserToggled = false

        platformLinks = nil
        let linkArtist = playback.artist, linkTitle = playback.title, linkAlbum = playback.album
        if !linkTitle.isEmpty {
            platformLinks = EnrichCacheReader.platformLinks(
                artist: linkArtist, title: linkTitle, album: linkAlbum)
        }
        guard isAppleMusicPlayer else { return }
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: false) else { return }
            let inLibrary = MusicPlaybackController.currentTrackIsInLibrary()
            let disliked = MusicPlaybackController.currentTrackDisliked()
            await MainActor.run {

                guard generation == moreMenuStateGeneration else { return }

                if inLibrary == true, libraryAddState == .idle { libraryAddState = .alreadyInLibrary }

                if let disliked, !suggestLessUserToggled { suggestLessApplied = disliked }
            }
        }
    }

    private func addCurrentTrackToLibraryFromMenu() {
        libraryAddState = .adding
        let generation = moreMenuStateGeneration
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run {
                    if generation == moreMenuStateGeneration { libraryAddState = .failed }
                }
                return
            }
            let commandOK = MusicPlaybackController.addCurrentTrackToLibrary()
            let verified = MusicPlaybackController.currentTrackIsInLibrary()
            await MainActor.run {

                guard generation == moreMenuStateGeneration else { return }
                libraryAddState = (verified ?? commandOK) ? .added : .failed
            }
        }
    }

    private func removeCurrentTrackFromLibraryFromMenu() {
        libraryAddState = .removing
        let generation = moreMenuStateGeneration
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run {
                    if generation == moreMenuStateGeneration { libraryAddState = .removeFailed }
                }
                return
            }
            let commandOK = MusicPlaybackController.removeCurrentTrackFromLibrary()
            let verified = MusicPlaybackController.currentTrackIsInLibrary()
            await MainActor.run {
                guard generation == moreMenuStateGeneration else { return }
                let gone = verified.map { !$0 } ?? commandOK
                libraryAddState = gone ? .idle : .removeFailed
            }
        }
    }

    private var menuDivider: some View {
        Divider().overlay(Color.primary.opacity(0.12)).padding(.horizontal, 6).padding(.vertical, 2)
    }

    private func closeMoreMenu() {
        withAnimation(.easeOut(duration: 0.12)) { showsMoreMenu = false }
    }

    private func runAppleMusicMenuAction(_ action: @escaping @Sendable () -> Void) {
        Task.detached(priority: .userInitiated) {
            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else { return }
            action()
        }
    }

    private enum CatalogTarget { case album, artist, track }

    private func openCatalogPage(album: Bool) {
        openCatalogPage(title: playback.title, artist: playback.artist,
                        target: album ? .album : .artist)
    }

    private func openCatalogPage(title: String, artist: String, target: CatalogTarget) {
        guard !title.isEmpty || !artist.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
            guard let item = await MusicCatalogSearch.resolve(
                title: title, artist: artist, storefront: storefront) else { return }
            let https: String?
            switch target {
            case .album: https = item.collectionViewUrl ?? item.trackViewUrl
            case .artist: https = item.artistViewUrl
            case .track: https = item.trackViewUrl ?? item.collectionViewUrl
            }
            guard let url = MusicCatalogSearch.musicSchemeURL(https) else { return }

            await MusicAutomationPermission.ensureMusicAppRunning()
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }

    private func openInfoPanel() {
        let artist = playback.artist, title = playback.title, album = playback.album
        infoLyricsSource = EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)?.lyricsSource
        platformLinks = EnrichCacheReader.platformLinks(artist: artist, title: title, album: album)
        withAnimation(.easeOut(duration: 0.12)) { showsInfoPanel = true }
    }

    private func openLyricsSearch() {
        let p = PlaybackCoordinator.shared
        let artist = p.artist, title = p.title, album = p.album
        let durationSecs = Double(p.currentDurationMs ?? 0) / 1000
        let key = EnrichCacheReader.resolvedKey(artist: artist, title: title, album: album)
            ?? EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        let source = EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)?.lyricsSource

        let lyrics = EnrichCacheReader.lookup(artist: artist, title: title, album: album)?.lyrics ?? ""
        let fingerprint = lyrics.isEmpty ? nil : ManualPickLock.fingerprint(lyrics: lyrics)
        lyricsSearchContext = LyricsSearchContext(
            artist: artist, title: EnrichCacheKeys.normalizedTitle(title), album: album,
            key: key, currentSource: source, currentFingerprint: fingerprint, durationSecs: durationSecs)
    }

    private var lyricsOffsetRow: some View {
        let trackMs = playback.trackLyricsOffsetMs
        let stepMs = AppSettings.shared.lyricsOffsetStepMs
        let stepHelp = AppSettings.formattedSeconds(ms: stepMs) + L10n.t("秒")
        return HStack(spacing: 4) {
            Text(L10n.t("歌词时间轴"))
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            if trackMs != 0 {
                Text(AppSettings.signedSeconds(ms: trackMs) + "s")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)

            if trackMs != 0 {
                OffsetNudgeButton(symbol: "arrow.counterclockwise", help: L10n.t("重置")) {
                    PlaybackCoordinator.shared.resetLyricsOffset()
                }
            }
            OffsetNudgeButton(symbol: "minus", help: L10n.t("延后") + " " + stepHelp) {
                PlaybackCoordinator.shared.nudgeLyricsOffset(by: -stepMs)
            }
            OffsetNudgeButton(symbol: "plus", help: L10n.t("提前") + " " + stepHelp) {
                PlaybackCoordinator.shared.nudgeLyricsOffset(by: stepMs)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var trackHasTranslation: Bool {
        playback.allLines.contains { $0.line.translation != nil }
    }
    private var trackHasRomanization: Bool {
        playback.allLines.contains { $0.line.romanization != nil }
    }

    private var translationButtonLabel: some View {
        let active = playback.showTranslation && trackHasTranslation
        return Group {
            if active {
                Image(systemName: "translate")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .frame(width: 36, height: 36)

                    .background(Circle().fill(Color.white.opacity(0.84)))
            } else {
                Image(systemName: "translate")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(capsuleIconColor)
                    .frame(width: 36, height: 36)
                    .clearGlassCapsule(
                        rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
            }
        }
        .contentShape(Circle())
    }

    @ViewBuilder private func lyricsQueuePill(showPlayerPane: Bool) -> some View {
        let showsLyricsButton = showPlayerPane

        let showsLyricsActive = showsLyricsPane && !showsListenHistory
        if showsLyricsButton {
            HStack(spacing: 2) {
                pillSlotButton(icon: "quote.bubble.fill", active: showsLyricsActive,
                               help: L10n.t(showsLyricsActive ? "隐藏歌词" : "显示歌词")) {
                    withAnimation(.smooth(duration: 0.35)) {
                        if showsListenHistory {
                            showsListenHistory = false
                        } else {
                            showsLyricsPane.toggle()
                        }
                    }
                }
                pillSlotButton(icon: "list.bullet", active: showsListenHistory,
                               help: L10n.t("播放记录")) {
                    withAnimation(.smooth(duration: 0.35)) {
                        showsListenHistory = true
                        showsLyricsPane = true
                    }
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 36)
            .clearGlassCapsule(
                rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
        } else {

            pillSlotButton(icon: "list.bullet", active: showsListenHistory,
                           help: L10n.t(showsListenHistory ? "显示歌词" : "播放记录")) {
                withAnimation(.smooth(duration: 0.35)) { showsListenHistory.toggle() }
            }
            .frame(width: 36, height: 36)
            .clearGlassCapsule(
                rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
        }
    }

    private func pillSlotButton(icon: String, active: Bool, help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color.black.opacity(0.75))
                                        : AnyShapeStyle(capsuleIconColor))
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? Color.white.opacity(0.84) : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func listenHistoryPane(leading: CGFloat, trailing: CGFloat) -> some View {
        ListenHistoryPane(
            leading: leading, trailing: trailing,
            onArtwork: hasArtworkBackground, colorScheme: colorScheme,
            onOpenTrack: { title, artist in
                openCatalogPage(title: title, artist: artist, target: .track)
            })
    }

    private var translationMenuPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            MoreMenuRow(title: L10n.t(playback.showTranslation ? "隐藏翻译" : "显示翻译"),
                        enabled: trackHasTranslation) {
                withAnimation(.easeOut(duration: 0.12)) { showsTranslationMenu = false }
                AppSettings.shared.showTranslation.toggle()
            }
            MoreMenuRow(title: L10n.t(playback.showRomanization ? "隐藏发音" : "显示发音"),
                        enabled: trackHasRomanization) {
                withAnimation(.easeOut(duration: 0.12)) { showsTranslationMenu = false }
                AppSettings.shared.showRomanization.toggle()
            }
        }
        .padding(6)
        .frame(minWidth: 150, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
    }

    private var trackInfoPanel: some View {

        let lyricsKind: String = {
            if playback.hasLyricsContent {
                let wordSynced = playback.allLines.contains { $0.line.words != nil }
                var parts = [L10n.t(wordSynced ? "逐字歌词" : "逐行歌词")]
                if playback.allLines.contains(where: { $0.line.translation != nil }) {
                    parts.append(L10n.t("译文"))
                }
                if playback.allLines.contains(where: { $0.line.romanization != nil }) {
                    parts.append(L10n.t("罗马音"))
                }
                return parts.joined(separator: " · ")
            }
            if playback.isRadioTalkBreak { return L10n.t("口白") }
            if playback.isCurrentTrackInstrumental { return L10n.t("纯音乐") }
            if !playback.currentTrackPlainLyrics.isEmpty { return L10n.t("纯文本(无时间戳)") }
            return L10n.t("无歌词")
        }()
        let durationText: String? = playback.currentDurationMs.map { ms in
            let s = ms / 1000
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return VStack(alignment: .leading, spacing: 6) {
            InfoPanelRow(label: L10n.t("歌名"), value: playback.title, onArtwork: hasArtworkBackground)
            InfoPanelRow(label: L10n.t("歌手"), value: playback.artist, onArtwork: hasArtworkBackground)
            if !playback.album.isEmpty {
                InfoPanelRow(label: L10n.t("专辑"), value: playback.album, onArtwork: hasArtworkBackground)
            }
            if let durationText {
                InfoPanelRow(label: L10n.t("时长"), value: durationText, onArtwork: hasArtworkBackground)
            }
            if let player = PlaybackCoordinator.shared.resolvedPlayerDisplayName {
                InfoPanelRow(label: L10n.t("播放器"), value: player, onArtwork: hasArtworkBackground)
            }
            InfoPanelRow(label: L10n.t("歌词"), value: lyricsKind, onArtwork: hasArtworkBackground)
            if let source = infoLyricsSource, !source.isEmpty {
                InfoPanelRow(label: L10n.t("来源"), value: sourceDisplayName(source), onArtwork: hasArtworkBackground)
            }

            if let links = platformLinks,
               let link = links.songLink(forPlayerBundleID: PlaybackCoordinator.shared.resolvedPlayerBundleID,
                                         webPlatformID: PlaybackCoordinator.shared.resolvedWebPlatformID) {
                InfoPanelLinksRow(name: Self.platformDisplayName(link.platform), url: link.url,
                                  onArtwork: hasArtworkBackground)
            }

            InfoPanelListeningRows(title: playback.title, artist: playback.artist, onArtwork: hasArtworkBackground)
        }
        .padding(12)
        .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
    }

    private static func platformDisplayName(_ platform: PlatformLinks.Platform) -> String {
        switch platform {
        case .appleMusic: return L10n.t("Apple Music")
        case .qqMusic: return L10n.t("QQ 音乐")
        case .netease: return L10n.t("网易云音乐")
        case .spotify: return "Spotify"
        }
    }

    private var outputDevicePanel: some View {
        let devices = AudioOutputDeviceManager.outputDevices()
        let current = AudioOutputDeviceManager.defaultOutputDeviceID()
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(devices, id: \.id) { device in
                OutputDeviceRow(
                    title: device.name,
                    symbol: Self.deviceSymbol(device),
                    isCurrent: device.id == current
                ) {
                    AudioOutputDeviceManager.setDefaultOutput(device.id)
                    isExternalOutput = AudioOutputDeviceManager.isExternalOutputActive()
                    withAnimation(.easeOut(duration: 0.12)) { showsOutputMenu = false }
                }
            }
        }
        .padding(6)
        .frame(minWidth: 230, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.colorScheme, hasArtworkBackground ? .dark : colorScheme)
    }

    private static func deviceSymbol(_ device: AudioOutputDeviceManager.Device) -> String {
        let name = device.name.lowercased()
        switch device.kind {
        case .builtIn: return "laptopcomputer"
        case .airPlay: return "hifispeaker"
        case .display: return "display"
        case .bluetooth:
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            return "headphones"
        case .other: return "speaker.wave.2"
        }
    }

    private func circleIcon(_ name: String) -> some View {
        circleIconGlyph(name)
            .frame(width: 26, height: 26)
            .background(Circle().fill(circleIconFill))
            .contentShape(Circle())
    }

    private var circleIconFill: Color {
        hasArtworkBackground ? Color.white.opacity(0.16) : Color.primary.opacity(0.08)
    }

    private func circleIconGlyph(_ name: String) -> some View {
        Image(systemName: name)

            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(primaryTextColor.opacity(0.9))
    }

    private var artistAlbumText: String {
        playback.album.isEmpty ? playback.artist : "\(playback.artist) — \(playback.album)"
    }

    private var displayTitle: String {
        if playback.isCurrentTrackAdBreak { return L10n.t("广告中") }

        if let station = radioTalkStation { return station.name }
        return playback.title
    }

    private var radioTalkStation: (name: String, image: NSImage?)? {
        guard playback.isRadioTalkBreak, let name = playback.radioStationName, !name.isEmpty else { return nil }
        return (name, playback.radioStationImage)
    }

    private var displayArtistAlbum: String {
        playback.isCurrentTrackAdBreak ? "" : artistAlbumText
    }

    private var controlScale: CGFloat { artworkWidth > 0 ? artworkWidth : 300 }
    private func ctrl(_ ratio: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(hi, max(lo, controlScale * ratio))
    }

    private var playbackControls: some View {

        HStack(spacing: 0) {
            shuffleButton
            Spacer(minLength: 12)
            HStack(spacing: ctrl(0.116, 18, 48)) {
            Button {
                MusicPlaybackController.previousTrack()
            } label: {
                Image(systemName: "backward.fill").font(.system(size: ctrl(0.060, 13, 25)))
            }
            .help(L10n.t("上一首"))
            Button {

                PlaybackCoordinator.shared.userTogglePlayPause()
            } label: {

                Image(systemName: playback.isPlayingSmoothed ? "pause.fill" : "play.fill")
                    .font(.system(size: ctrl(0.079, 17, 33)))

                    .frame(width: ctrl(0.10, 22, 38))
            }
            .help(L10n.t("播放/暂停"))
            Button {
                MusicPlaybackController.nextTrack()
            } label: {
                Image(systemName: "forward.fill").font(.system(size: ctrl(0.060, 13, 25)))
            }
            .help(L10n.t("下一首"))
            }
            Spacer(minLength: 12)
            repeatButton
        }

        .buttonStyle(TransportButtonStyle(reduceMotion: reduceMotion))
        .foregroundStyle(primaryTextColor)
        .frame(maxWidth: .infinity)
    }

    private func windowActionsCapsule() -> some View {

        HStack(spacing: 14) {
            Button {
                windowController.toggleAlwaysOnTop()
            } label: {
                Image(systemName: windowController.isAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 17))
                    .frame(width: 18)
            }

            .help(
                (windowController.isAlwaysOnTop ? L10n.t("取消置顶") : L10n.t("置于最顶层"))
                    + " · " + L10n.t("这个状态只在本次打开这扇窗口期间有效，下次重新打开会恢复默认"))
            Button {
                windowController.toggle(reduceMotion: reduceMotion)
            } label: {
                Image(
                    systemName: windowController.isFullScreenActive
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .font(.system(size: 17))
                .frame(width: 18)
            }
            .help(L10n.t(windowController.isFullScreenActive ? "退出全屏" : "进入全屏"))
        }
        .buttonStyle(.plain)

        .foregroundStyle(capsuleIconColor)

        .frame(height: 22)
        .padding(.horizontal, 12)

        .padding(.vertical, 7)
        .clearGlassCapsule(
            rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
    }

    private var shuffleButton: some View {
        modeToggleButton(icon: "shuffle",
                         active: playback.playbackMode == .shuffle,
                         shown: playback.playbackMode != nil,
                         label: L10n.t("随机播放")) {
            PlaybackCoordinator.shared.setPlaybackMode(playback.playbackMode == .shuffle ? .list : .shuffle)
        }
    }

    private var repeatButton: some View {
        let mode = playback.playbackMode
        return modeToggleButton(
            icon: mode == .repeatOne ? "repeat.1" : "repeat",
            active: mode == .repeatOne || mode == .repeatAll,
            shown: mode != nil && PlaybackCoordinator.shared.playbackModeSupportsRepeatOne,
            label: L10n.t("循环播放")
        ) {
            let next: MusicPlaybackController.MusicPlaybackMode
            switch mode {
            case .repeatAll: next = .repeatOne
            case .repeatOne: next = .list
            default: next = .repeatAll
            }
            PlaybackCoordinator.shared.setPlaybackMode(next)
        }
    }

    private func modeToggleButton(icon: String, active: Bool, shown: Bool, label: String,
                                  action: @escaping () -> Void) -> some View {
        Group {
            if shown {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(.system(size: ctrl(0.043, 11, 18)))
                        .opacity(active ? 1 : 0.55)

                        .padding(.horizontal, 3)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                active
                                    ? (hasArtworkBackground
                                        ? Color.white.opacity(0.22) : Color.primary.opacity(0.12))
                                    : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .help(label)
            }
        }

        .frame(width: ctrl(0.043, 11, 18) + 8)
    }

    private var primaryTextColor: Color { hasArtworkBackground ? .white : .primary }

    private var capsuleIconColor: Color {
        hasArtworkBackground ? .white.opacity(0.9) : .primary.opacity(0.75)
    }

    private var secondaryTextColor: Color {
        guard hasArtworkBackground else { return .secondary }
        return amVibrantColor(layers: playback.windowBackgroundLayers,
                              satScale: 0.5, satCap: 0.45, brightness: 0.85,
                              fallback: .white.opacity(0.6),
                              minContrastToBackground: 0.25)
    }

    private static let maxVisualDistance = 4

    private func distance(for index: Int) -> Int? {

        guard let activeIdx = playback.scrollLineIndex ?? playback.currentLineIndex else { return nil }

        let gapPenalty = playback.currentGapIndex != nil ? 1 : 0
        return min(abs(index - activeIdx) + gapPenalty, Self.maxVisualDistance)
    }

    private var gapMarkersByIndex: [Int: LyricsGapMarker] {
        Dictionary(uniqueKeysWithValues: playback.lyricsGapMarkers.map { ($0.index, $0) })
    }

    private func gapMarker(_ index: Int) -> LyricsGapMarker? {
        gapMarkersByIndex[index]
    }

    private func gapRowID(_ index: Int) -> String? {
        if index == -1 { return playback.allLines.first.map { "\($0.id)-intro" } }
        guard playback.allLines.indices.contains(index) else { return nil }
        return "\(playback.allLines[index].id)-gap"
    }

    @ViewBuilder
    private func gapDotsRow(_ marker: LyricsGapMarker, id: String) -> some View {
        if playback.currentGapIndex == marker.index {

            TimelineView(.animation(paused: !playback.isPlayingNow
                                            || !windowController.isSurfaceVisible)) { context in

                let pos = (playback.anchor?.extrapolatedPositionMs()
                    ?? playback.pausedPositionMs ?? marker.startMs)
                    + PlaybackCoordinator.shared.currentLyricsOffsetMs
                let span = max(1, marker.endMs - marker.startMs)
                let progress = min(1, max(0, Double(pos - marker.startMs) / Double(span)))

                let breathePeriodMs = 7000.0
                let breathePhase = Double(pos).truncatingRemainder(dividingBy: breathePeriodMs) / breathePeriodMs
                let breatheRaised = pow(0.5 - 0.5 * cos(2 * .pi * breathePhase), 2)
                let breathe = reduceMotion ? 1 : 0.90 + 0.38 * breatheRaised
                HStack(spacing: lyricFontSize * 0.3) {
                    ForEach(0 ..< 3, id: \.self) { i in
                        Circle()
                            .fill(primaryTextColor)
                            .frame(width: lyricFontSize * 0.32, height: lyricFontSize * 0.32)

                            .opacity(0.22 + 0.78 * min(1, max(0, progress * 3 - Double(i))))
                            .scaleEffect(breathe)
                    }
                }
            }
            .frame(height: lyricFontSize * 0.5)
            .id(id)
            .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: .leading)))
        }
    }

    private var hasArtworkBackground: Bool { playback.artworkData != nil }

    @ViewBuilder
    private var artworkBackground: some View {

        if let layers = playback.windowBackgroundLayers {
            WindowAnimatedBackground(layers: layers)

                .id(ObjectIdentifier(layers))
                .overlay(Color.black.opacity(0.15))
                .clipped()

                .animation(.easeInOut(duration: 0.5), value: playback.windowBackgroundLayers)
        }
    }

    private var idlePlayer: PlaybackPlayer { IdlePlaybackActions.player }

    private var idleWelcomeView: some View {
        let player = idlePlayer
        let playerName = player.displayName
        let canResume = player == .appleMusic || player == .spotify
        return VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color.accentColor.opacity(0.12), .clear],
                        center: .center, startRadius: 8, endRadius: 90))
                    .frame(width: 180, height: 180)
                Image(systemName: "music.note")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .scaleEffect(idleBreath ? 1.05 : 0.96)
            .opacity(idleBreath ? 1 : 0.8)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                value: idleBreath)
            .onAppear { idleBreath = true }
            .onDisappear { idleBreath = false }
            Text(L10n.t("没有在播放"))
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 4)
            Text(String(format: L10n.t("在 %@ 播放任意歌曲，歌词会自动出现"), playerName))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            HStack(spacing: 10) {
                if canResume {
                    Button {
                        resumeFromIdle(player: player)
                    } label: {
                        Label(L10n.t("继续播放"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if canResume {
                    Button {
                        openIdlePlayerApp(player)
                    } label: {
                        Text(String(format: L10n.t("打开 %@"), playerName))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button {
                        openIdlePlayerApp(player)
                    } label: {
                        Text(String(format: L10n.t("打开 %@"), playerName))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.top, 20)

            IdleLastfmSection()
                .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resumeFromIdle(player: PlaybackPlayer) {
        IdlePlaybackActions.resume(player: player)
    }

    private func openIdlePlayerApp(_ player: PlaybackPlayer) {
        IdlePlaybackActions.openPlayerApp(player)
    }

    private var emptyStateSpec: (icon: String, text: String, offersSearch: Bool) {

        if playback.title.isEmpty { return ("music.note", L10n.t("没有在播放"), false) }
        if playback.isCurrentTrackAdBreak { return ("megaphone", L10n.t("广告中"), false) }

        if playback.isRadioTalkBreak { return ("dot.radiowaves.left.and.right", L10n.t("口白"), false) }
        if playback.isCurrentTrackInstrumental { return ("waveform", L10n.t("纯音乐"), false) }

        if playback.currentTrackHasNoLyrics { return ("text.badge.xmark", L10n.t("暂无歌词"), true) }

        if playback.collectorNetworkDown && !playback.hasLyricsContent {
            return ("wifi.slash", L10n.t("网络连接失败"), true)
        }
        if playback.isPlayingNow && !playback.hasLyricsContent { return ("magnifyingglass", L10n.t("搜索歌词中…"), false) }
        return ("text.quote", L10n.t("无歌词"), false)
    }

    @ViewBuilder
    private func plainLyricsFallback(leading: CGFloat, trailing: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(L10n.t("这份歌词没有时间戳,无法跟随播放高亮或自动滚动"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hasArtworkBackground ? .white.opacity(0.75) : Color.orange)
                Text(playback.currentTrackPlainLyrics)
                    .font(.system(size: lyricFontSize * 0.62))
                    .lineSpacing(lyricFontSize * 0.32)
                    .foregroundStyle(hasArtworkBackground ? .white.opacity(0.92) : Color.primary)
                    .textSelection(.enabled)
            }
            .padding(.top, 40)
            .padding(.bottom, 60)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var emptyState: some View {
        let spec = emptyStateSpec
        if hasArtworkBackground {

            VStack(spacing: 12) {
                Image(systemName: spec.icon).font(.system(size: 40))
                Text(spec.text).font(.system(size: 16, weight: .semibold))

                if spec.offersSearch {
                    Button {
                        openLyricsSearch()
                    } label: {
                        Label(L10n.t("搜索歌词…"), systemImage: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .clearGlassCapsule(rim: Color.white.opacity(0.28))
                    .padding(.top, 6)
                }
            }
            .foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {

            ContentUnavailableView {
                Label(spec.text, systemImage: spec.icon)
            } description: {
                EmptyView()
            } actions: {
                if spec.offersSearch {
                    Button(L10n.t("搜索歌词…")) { openLyricsSearch() }
                }
            }
        }
    }

}

private struct LyricsLineRow: View, Equatable {
    let item: LyricsWindowLine
    let distance: Int?
    let isActive: Bool
    let isHovered: Bool

    let isPlaying: Bool

    let fillSettled: Bool
    let fontSize: CGFloat
    let romaFontSize: CGFloat
    let translationFontSize: CGFloat

    let duetInsetUnit: CGFloat
    let onArtwork: Bool
    let showRomanization: Bool
    let showTranslation: Bool
    let reduceMotion: Bool
    let displayScale: CGFloat
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    nonisolated static func == (a: LyricsLineRow, b: LyricsLineRow) -> Bool {
        MainActor.assumeIsolated {

            a.item.id == b.item.id
                && a.distance == b.distance
                && a.isActive == b.isActive
                && a.isHovered == b.isHovered
                && a.isPlaying == b.isPlaying
                && a.fillSettled == b.fillSettled
                && a.fontSize == b.fontSize
                && a.romaFontSize == b.romaFontSize
                && a.translationFontSize == b.translationFontSize
                && a.duetInsetUnit == b.duetInsetUnit
                && a.onArtwork == b.onArtwork
                && a.showRomanization == b.showRomanization
                && a.showTranslation == b.showTranslation
                && a.reduceMotion == b.reduceMotion
                && a.displayScale == b.displayScale
        }
    }

    private var secondaryTextColor: Color { onArtwork ? .white.opacity(0.6) : .secondary }

    private var side: LyricDuet.Side { item.line.side ?? .leading }

    private var alignment: Alignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var textAlignment: TextAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var rowAlignment: WrapLayout.RowAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var duetInsets: (leading: CGFloat, trailing: CGFloat) {
        guard let s = item.line.side else { return (0, 0) }
        switch s {
        case .leading: return (0, duetInsetUnit)
        case .trailing: return (duetInsetUnit, 0)
        case .center: return (duetInsetUnit, duetInsetUnit)
        }
    }

    private var usesPerWordRomanization: Bool {
        showRomanization && item.line.wordGroups?.isEmpty == false
            && item.line.words != nil
    }

    private var lineOpacity: Double {
        guard let d = distance else { return 0.45 }
        if d == 0 { return 1 }
        return max(0.22, 0.42 - 0.10 * Double(max(0, d - 2)))
    }

    private var lineBlur: CGFloat {
        guard let d = distance else { return fontSize * 0.03 }
        if d == 0 { return 0 }
        return fontSize * 0.0148 * CGFloat(d + 1)
    }

    var body: some View {
        VStack(alignment: alignment.horizontal, spacing: 6) {
            mainText

            if showRomanization, !usesPerWordRomanization, let roma = item.line.romanization {
                Text(roma)
                    .font(.system(size: romaFontSize, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
            }
            if showTranslation, let tr = item.line.translation {
                Text(tr)
                    .font(.system(size: translationFontSize, weight: .semibold))
                    .foregroundStyle(secondaryTextColor)
            }
        }

        .multilineTextAlignment(textAlignment)

        .padding(.leading, duetInsets.leading)
        .padding(.trailing, duetInsets.trailing)
        .frame(maxWidth: .infinity, alignment: alignment)

        .animation(nil, value: distance)
        .animation(nil, value: isHovered)
        .opacity(isHovered ? 1 : lineOpacity)

        .animation(isActive ? nil : LyricsWindowView.lineTransition, value: distance)

        .blur(radius: (reduceMotion || isHovered) ? 0 : lineBlur)

        .animation(LyricsWindowView.lineTransition, value: distance)
        .animation(.easeOut(duration: 0.16), value: isHovered)

        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var mainText: some View {

        let base: Color = onArtwork ? .white : .primary

        if let words = item.line.words {
            KaraokeLineText(
                words: words,
                plainText: item.line.plainText ?? "",
                groups: usesPerWordRomanization ? item.line.wordGroups : nil,
                base: base,
                isActive: isActive,
                isPlaying: isPlaying,
                fillSettled: fillSettled,
                fontSize: fontSize,
                romaFontSize: romaFontSize,
                reduceMotion: reduceMotion,
                displayScale: displayScale,
                rowAlignment: rowAlignment
            )
        } else {
            Text(item.line.plainText ?? "")
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(base)
        }
    }
}

private struct KaraokeLineText: View {
    let words: [SyncedLyricWord]
    let plainText: String
    let groups: [SyncedLyricWordGroup]?
    let base: Color

    let isActive: Bool
    let isPlaying: Bool

    let fillSettled: Bool
    let fontSize: CGFloat
    let romaFontSize: CGFloat
    let reduceMotion: Bool
    let displayScale: CGFloat
    var rowAlignment: WrapLayout.RowAlignment = .leading

    private var lineLayoutKey: AnyHashable {
        AnyHashable(WindowLineKey(
            text: plainText,
            hasGroups: groups?.isEmpty == false,
            fontSize: fontSize,
            romaFontSize: romaFontSize))
    }

    private struct WindowLineKey: Hashable {
        let text: String
        let hasGroups: Bool
        let fontSize: CGFloat
        let romaFontSize: CGFloat
    }

    var body: some View {

        TimelineView(.animation(minimumInterval: Self.coarseInterval,
                                paused: !isActive || !isPlaying || fillSettled)) { coarse in
            lineContent(coarseDate: coarse.date, coarseMs: currentMs(at: coarse.date))
        }
    }

    private static let coarseInterval: Double = 0.25

    private func currentMs(at date: Date) -> Int {
        let coordinator = PlaybackCoordinator.shared
        return (coordinator.anchor?.extrapolatedPositionMs(now: date)
            ?? coordinator.pausedPositionMs ?? 0)
            + coordinator.currentLyricsOffsetMs
    }

    private func isLive(_ w: SyncedLyricWord, atMs ms: Int) -> Bool {
        guard isActive, !fillSettled else { return false }
        let margin = Int(Self.coarseInterval * 1000) + 80
        let end = w.startMs + max(1, w.durationMs) + Int(KaraokeWordText.riseWindowMs(for: w))
        return ms >= w.startMs - margin && ms <= end + margin
    }

    @ViewBuilder
    private func lineContent(coarseDate: Date, coarseMs: Int) -> some View {
        WrapLayout(rowAlignment: rowAlignment, contentKey: lineLayoutKey) {
            if let groups, !groups.isEmpty {

                ForEach(groups) { g in

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(g.words.indices, id: \.self) { i in
                                KaraokeWordText(word: g.words[i], base: base, isPlaying: isPlaying,
                                                isLive: isLive(g.words[i], atMs: coarseMs),
                                                staticDate: coarseDate,
                                                fontSize: fontSize, reduceMotion: reduceMotion,
                                                displayScale: displayScale,

                                                forceFilled: !isActive,
                                                lineSettled: fillSettled)
                            }
                        }
                        if let roma = g.romanization {

                            let romaWord = SyncedLyricWord(
                                text: roma, startMs: g.startMs,
                                durationMs: max(1, g.endMs - g.startMs))
                            KaraokeWordText(
                                word: romaWord,
                                base: base.opacity(0.75), isPlaying: isPlaying,
                                isLive: isLive(romaWord, atMs: coarseMs),
                                staticDate: coarseDate,
                                fontSize: romaFontSize, weight: .medium,
                                reduceMotion: reduceMotion, displayScale: displayScale,
                                rises: false,
                                forceFilled: !isActive,
                                lineSettled: fillSettled
                            )
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 2)
                        }
                    }
                }
            } else {
                ForEach(words.indices, id: \.self) { i in
                    KaraokeWordText(word: words[i], base: base, isPlaying: isPlaying,
                                    isLive: isLive(words[i], atMs: coarseMs), staticDate: coarseDate,
                                    fontSize: fontSize, reduceMotion: reduceMotion,
                                    displayScale: displayScale,

                                    forceFilled: !isActive,
                                    lineSettled: fillSettled)
                }
            }
        }
        .font(.system(size: fontSize, weight: .bold))
    }
}

private struct KaraokeWordText: View {
    let word: SyncedLyricWord
    let base: Color
    let isPlaying: Bool

    let isLive: Bool

    let staticDate: Date
    let fontSize: CGFloat
    var weight: Font.Weight = .bold
    let reduceMotion: Bool
    let displayScale: CGFloat
    var rises: Bool = true

    var forceFilled: Bool = false

    var lineSettled: Bool = false

    private static let settledFraction = 1 + KaraokeFill.wordEdgeSoftenBand

    static func riseWindowMs(for w: SyncedLyricWord) -> Double {
        min(max(1, Double(w.durationMs)), 1000)
    }

    private var riseAmplitude: CGFloat {
        let scale = max(1, displayScale)
        return (fontSize * 0.05 * scale).rounded() / scale
    }

    private func rise(atMs currentMs: Int) -> CGFloat {
        guard rises, !reduceMotion else { return 0 }
        let elapsed = Double(currentMs - word.startMs)
        guard elapsed > 0 else { return 0 }
        let p = min(1, elapsed / Self.riseWindowMs(for: word))
        return -sin(p * .pi / 2) * riseAmplitude
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: WordKaraokeGradient.windowRefreshInterval,
                                paused: !isPlaying || !isLive)) { context in

            let coordinator = PlaybackCoordinator.shared

            let date = isLive ? context.date : staticDate

            let currentMs = (coordinator.anchor?.extrapolatedPositionMs(now: date)
                ?? coordinator.pausedPositionMs ?? 0)
                + coordinator.currentLyricsOffsetMs
            let fraction = (forceFilled || lineSettled)
                ? Self.settledFraction
                : WordKaraokeGradient.fillFraction(for: word, atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand

            let lift: CGFloat = forceFilled ? 0
                : (lineSettled ? ((rises && !reduceMotion) ? -riseAmplitude : 0)
                               : rise(atMs: currentMs))
            Text(word.text)
                .font(.system(size: fontSize, weight: weight))

                .foregroundStyle(WordKaraokeGradient.palette(fg: base)
                    .style(left: fraction - band, right: fraction + band))

                .offset(y: lift)

                .transaction { t in
                    if t.animation != nil { t.animation = nil }
                }
        }
    }
}

private func amVibrantColor(layers: WindowBackgroundLayers?, satScale: Double, satCap: Double,
                            brightness: Double, fallback: Color,
                            minContrastToBackground: Double? = nil) -> Color {
    guard let layers, layers.tintSaturation > 0.01 else { return fallback }
    var v = brightness
    if let minC = minContrastToBackground {
        let bgV = layers.tintBrightness
        if bgV > 0, v - bgV < minC {
            if bgV <= 0.75 || layers.tintSaturation >= 0.5 {
                v = min(0.97, max(bgV + minC, brightness))
            } else {
                v = max(0.22, bgV - 0.32)
            }
        }
    }
    return Color(hue: layers.tintHue,
                 saturation: min(satCap, layers.tintSaturation * satScale),
                 brightness: v)
}

private struct WindowProgressSection: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    let onArtwork: Bool
    let backgroundLayers: WindowBackgroundLayers?

    let title: String
    let artist: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @GestureState private var scrubbingFraction: Double?

    @State private var scrubWidth: CGFloat = 0

    @State private var shownFraction: Double = 0
    @State private var progressPrimed = false

    private let scrubberHeight: CGFloat = 6

    @ViewBuilder
    var body: some View {
        if let anchor {

            TimelineView(.periodic(from: .now, by: 1)) { context in
                progressBar(
                    positionMs: anchor.extrapolatedPositionMs(now: context.date),
                    durationMs: anchor.durationMs,

                    advancePerSecondMs: 1000 * anchor.rate)
            }
        } else if let paused = pausedPositionMs, let duration = durationMs, duration > 0 {

            progressBar(positionMs: paused, durationMs: duration)
        } else {

            progressBar(positionMs: 0, durationMs: 0).hidden()
        }
    }

    private func progressBar(positionMs: Int, durationMs: Int, advancePerSecondMs: Double = 0) -> some View {

        let shownMs = scrubbingFraction.map { Int($0 * Double(durationMs)) } ?? positionMs
        let fraction = durationMs > 0 ? min(1, max(0, Double(shownMs) / Double(durationMs))) : 0
        return VStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(primaryTextColor.opacity(0.25))

                    Capsule().fill(onArtwork
                        ? amVibrantColor(layers: backgroundLayers, satScale: 0.5, satCap: 0.4,
                                         brightness: 0.92, fallback: .white.opacity(0.85))
                        : primaryTextColor.opacity(0.85))

                        .frame(width: g.size.width, height: scrubberHeight)
                        .offset(x: -ProgressFillGeometry.leadingOffset(
                            containerWidth: g.size.width, fraction: shownFraction))
                        .clipShape(Capsule())
                }
            }
            .frame(height: scrubberHeight)
            .onAppear {
                shownFraction = fraction

                DispatchQueue.main.async { progressPrimed = true }
            }
            .onChange(of: fraction) { _, f in
                let smooth = progressPrimed && !reduceMotion && scrubbingFraction == nil
                if smooth {

                    let step = durationMs > 0 ? advancePerSecondMs / Double(durationMs) : 0
                    withAnimation(.linear(duration: 1)) { shownFraction = min(1, max(0, f + step)) }
                } else {

                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { shownFraction = f }
                }
            }

            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .padding(.vertical, -9)

            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { scrubWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in scrubWidth = w }
                }
            )
            .gesture(

                DragGesture(minimumDistance: 0)
                    .updating($scrubbingFraction) { value, state, _ in
                        guard durationMs > 0, scrubWidth > 0 else { return }

                        if state == nil {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment, performanceTime: .now)
                        }
                        state = min(1, max(0, value.location.x / scrubWidth))
                    }
                    .onEnded { value in
                        guard durationMs > 0, scrubWidth > 0 else { return }
                        let f = min(1, max(0, value.location.x / scrubWidth))
                        PlaybackCoordinator.shared.seek(toMs: Int(f * Double(durationMs)))
                    }
            )
            HStack {
                Text(Self.formatTime(ms: shownMs))
                Spacer()

                Text(Self.formatTime(ms: durationMs))
            }
            .overlay {

                NowPlayingCountBadge(title: title, artist: artist, textColor: secondaryTextColor)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(secondaryTextColor)
        }
    }

    private static func formatTime(ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        return "\(totalSeconds / 60):" + String(format: "%02d", totalSeconds % 60)
    }

    private var primaryTextColor: Color { onArtwork ? .white : .primary }

    private var secondaryTextColor: Color {
        guard onArtwork else { return .secondary }
        return amVibrantColor(layers: backgroundLayers,
                              satScale: 0.62, satCap: 0.5, brightness: 0.68,
                              fallback: .white.opacity(0.6),
                              minContrastToBackground: 0.25)
    }
}

private struct WindowVolumeCapsule: View {
    let onArtwork: Bool

    @Binding var showsOutputMenu: Bool
    let isExternalOutput: Bool
    @StateObject private var model = Model()

    @MainActor
    private final class Model: ObservableObject {
        @Published private(set) var soundVolume: Int?
        private var sub: AnyCancellable?
        init() {
            sub = PlaybackCoordinator.shared.$soundVolume.removeDuplicates()
                .sink { [weak self] in self?.soundVolume = $0 }
        }
    }

    private var capsuleIconColor: Color {
        onArtwork ? .white.opacity(0.9) : .primary.opacity(0.75)
    }
    private var hasArtworkBackground: Bool { onArtwork }

    @ViewBuilder
    var body: some View {
        if let volume = model.soundVolume {

            HStack(spacing: 10) {

                Button {
                    withAnimation(.easeOut(duration: 0.12)) { showsOutputMenu.toggle() }
                } label: {
                    Image(systemName: "airplay.audio")

                        .font(.system(size: 17))
                        .frame(width: 22)
                        .foregroundStyle(
                            isExternalOutput
                                ? AnyShapeStyle(Color.red) : AnyShapeStyle(capsuleIconColor))
                }
                .buttonStyle(.plain)
                .help(L10n.t("音频输出"))
                .anchorPreference(key: OutputMenuButtonBoundsKey.self, value: .bounds) { $0 }
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: 18)

                volumeSlider(volume: volume)
                    .frame(width: 114, height: 22)
                Button {
                    PlaybackCoordinator.shared.toggleMute()
                } label: {
                    Image(systemName: volumeLevelIcon(volume))
                        .font(.system(size: 17))

                        .frame(width: 24, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(volume == 0 ? L10n.t("取消静音") : L10n.t("静音"))
            }
            .foregroundStyle(capsuleIconColor)
            .padding(.horizontal, 14)

            .padding(.vertical, 7)
            .clearGlassCapsule(

                rim: hasArtworkBackground ? Color.white.opacity(0.28) : Color.primary.opacity(0.10))
        }
    }

    private func volumeLevelIcon(_ v: Int) -> String {
        switch v {
        case 0: return "speaker.slash.fill"
        case 1...33: return "speaker.wave.1.fill"
        case 34...66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private func volumeSlider(volume: Int) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let f = min(1, max(0, Double(volume) / 100))

            let knob: CGFloat = 23
            let knobHeight: CGFloat = 14
            let travel = max(0, w - knob)
            ZStack(alignment: .leading) {

                Capsule()
                    .fill(onArtwork ? Color.white.opacity(0.20) : Color.primary.opacity(0.14))
                    .frame(height: 6)

                Capsule()
                    .fill(onArtwork ? Color.white.opacity(0.80) : Color.primary.opacity(0.55))
                    .frame(width: knob / 2 + travel * f, height: 6)
                Capsule()
                    .fill(Color.white)
                    .frame(width: knob, height: knobHeight)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: travel * f)
            }
            .frame(height: g.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(

                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard travel > 0 else { return }
                        let x = min(travel, max(0, value.location.x - knob / 2))
                        PlaybackCoordinator.shared.setVolume(Int((x / travel * 100).rounded()))
                    }
            )
        }
    }
}

private struct MoreMenuButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct OutputMenuButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct TranslationMenuButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct LyricsScrollMetricsValue: Equatable {
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
}
private struct LyricsScrollMetricsKey: PreferenceKey {
    static let defaultValue = LyricsScrollMetricsValue()
    static func reduce(value: inout LyricsScrollMetricsValue, nextValue: () -> LyricsScrollMetricsValue) {
        value = nextValue()
    }
}

@MainActor final class LyricsScrollMetricsModel: ObservableObject {
    @Published private(set) var offsetY: CGFloat = 0
    @Published private(set) var contentHeight: CGFloat = 0
    func update(offsetY: CGFloat, contentHeight: CGFloat) {
        if abs(offsetY - self.offsetY) > 0.5 { self.offsetY = offsetY }
        if abs(contentHeight - self.contentHeight) > 0.5 { self.contentHeight = contentHeight }
    }
}

private struct LyricsScrollIndicator: View {
    @ObservedObject var metrics: LyricsScrollMetricsModel
    let onArtwork: Bool

    var body: some View {
        GeometryReader { g in
            let viewH = g.size.height
            let topInset: CGFloat = 90
            let bottomInset: CGFloat = 40
            let trackH = viewH - topInset - bottomInset
            let content = metrics.contentHeight
            if content > viewH + 4, trackH > 80 {
                let thumbH = min(trackH, max(40, trackH * viewH / content))
                let maxScroll = content - viewH
                let f = maxScroll > 0 ? min(1, max(0, metrics.offsetY / maxScroll)) : 0
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Color.white.opacity(onArtwork ? 0.08 : 0.10))
                        .frame(width: 6, height: trackH)
                    Capsule()
                        .fill(Color.white.opacity(onArtwork ? 0.30 : 0.35))
                        .frame(width: 12, height: thumbH)
                        .offset(y: (trackH - thumbH) * f)
                }
                .frame(width: 12)
                .padding(.top, topInset)
            }
        }
    }
}

private struct ListenHistoryPane: View {
    let leading: CGFloat
    let trailing: CGFloat
    let onArtwork: Bool
    let colorScheme: ColorScheme
    let onOpenTrack: (String, String) -> Void

    @ObservedObject private var stats = LastfmStatsService.shared

    var body: some View {
        Group {

            if stats.isConnected {
                RecentListensPanel(onOpenTrack: onOpenTrack, showsCard: false, onArtwork: onArtwork)
            } else {
                PendingListensPanel(onOpenTrack: onOpenTrack, showsCard: false, onArtwork: onArtwork)
            }
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)

        .padding(.top, 52)
        .padding(.bottom, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, onArtwork ? .dark : colorScheme)
    }
}

private struct OutputDeviceRow: View {
    let title: String
    let symbol: String
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(width: 22)
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 16)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .opacity(isCurrent ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct OffsetNudgeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.16 : 0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct LyricsSearchContext: Identifiable {
    let artist: String
    let title: String
    let album: String

    let key: String
    let currentSource: String?

    let currentFingerprint: String?
    let durationSecs: Double

    var id: String { key }
}

private struct InfoPanelRow: View {
    let label: String
    let value: String
    var onArtwork: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(onArtwork ? Color.white.opacity(0.75) : Color.secondary)
                .shadow(color: onArtwork ? .black.opacity(0.5) : .clear, radius: 1.5)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct InfoPanelLinksRow: View {
    let name: String
    let url: URL
    var onArtwork: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L10n.t("网页"))
                .font(.system(size: 12))
                .foregroundStyle(onArtwork ? Color.white.opacity(0.75) : Color.secondary)
                .shadow(color: onArtwork ? .black.opacity(0.5) : .clear, radius: 1.5)
                .frame(width: 52, alignment: .leading)
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(name + " ↗")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }
}

private struct MoreMenuRow: View {
    let title: String

    var trailingSystemImage: String? = nil

    var enabled: Bool = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let icon = trailingSystemImage {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(enabled ? 1 : 0.55)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = enabled && $0 }
    }
}

private struct TransportButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.8 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : configuration.isPressed
                        ? .easeOut(duration: 0.1)
                        : .spring(response: 0.32, dampingFraction: 0.55),
                value: configuration.isPressed)
    }
}

private struct WindowAnimatedBackground: View {
    let layers: WindowBackgroundLayers
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(nsImage: layers.base)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                ForEach(layers.poses.indices, id: \.self) { i in
                    let pose = layers.poses[i]
                    Image(nsImage: layers.glows[i])
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(pose.scale)

                        .rotationEffect(
                            .degrees(pose.initialAngle + (spinning ? 12 : -12)),
                            anchor: pose.anchor
                        )
                        .animation(
                            spinning
                                ? .easeInOut(duration: pose.spinDuration).repeatForever(autoreverses: true)
                                : nil,
                            value: spinning
                        )
                        .opacity(0.25)
                        .blendMode(.lighten)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)

            .compositingGroup()
        }
        .onAppear { if !reduceMotion { spinning = true } }
    }
}

private struct NowPlayingCountBadge: View {
    let title: String
    let artist: String
    let textColor: Color
    @ObservedObject private var stats = LastfmStatsService.shared

    var body: some View {

        Group {
            if stats.isConnected, !title.isEmpty, let n = stats.nowPlayingCount {

                Button {
                    AppActions.shared.requestSettings(.account(.lastfm))
                    NSApp.activate(ignoringOtherApps: true)
                    AppActions.shared.openSettings?()
                } label: {
                    Text(String(format: L10n.t("收听次数：%@"), "\(n)"))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(textColor)
                }
                .buttonStyle(.plain)
                .help(L10n.t("在设置中查看 Last.fm"))
                .transition(.opacity)
            }
        }
        .onAppear { refresh() }
        .onChange(of: "\(artist)|\(title)") { refresh() }
    }

    private func refresh() {
        guard !title.isEmpty, LastfmStatsService.shared.isConnected else { return }
        LastfmStatsService.shared.refreshNowPlayingCount(title: title, artist: artist)
    }
}

private struct InfoPanelListeningRows: View {
    let title: String
    let artist: String
    var onArtwork: Bool = false
    @ObservedObject private var stats = LastfmStatsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if stats.isConnected {
                if let n = stats.nowPlayingCount {
                    InfoPanelRow(label: L10n.t("累计"),
                                 value: String(format: L10n.t("第 %@ 次听"), "\(n)"), onArtwork: onArtwork)
                }
                if let span = stats.nowPlayingSpan, span.total > 0 {
                    if let first = span.first {
                        InfoPanelRow(label: L10n.t("首次听"),
                                     value: first.formatted(date: .abbreviated, time: .omitted), onArtwork: onArtwork)
                    }
                    if let last = span.last {
                        InfoPanelRow(label: L10n.t("上次听"),
                                     value: last.formatted(.relative(presentation: .named)), onArtwork: onArtwork)
                    }
                }
            }
        }
        .onAppear { refresh() }

        .onChange(of: "\(artist)|\(title)") { refresh() }
    }

    private func refresh() {
        guard !title.isEmpty, stats.isConnected else { return }
        stats.refreshNowPlayingCount(title: title, artist: artist)
        stats.refreshNowPlayingSpan(title: title, artist: artist)
    }
}

private struct IdleLastfmSection: View {
    @ObservedObject private var stats = LastfmStatsService.shared

    private var weekValue: Int? {
        guard !stats.dailySyncing else { return stats.overview?.week }
        return IdleListeningStats.lastSevenDays(
            dailyCounts: stats.dailyCounts, today: Date(),
            todayCount: stats.overview?.today,
            dayKey: { LastfmStatsService.dayKey($0) })
    }

    var body: some View {
        if stats.isConnected {
            VStack(spacing: 12) {
                if let o = stats.overview, let week = weekValue {
                    Text(String(format: L10n.t("今天听了 %1$@ 首 · 本周 %2$@ 首"),
                                "\(o.today)", "\(week)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let day = stats.onThisDay, let top = day.top.first {
                    VStack(spacing: 3) {
                        Text(String(format: L10n.t("那年今日 · %1$@ 年前听了 %2$@ 首"),
                                    "\(day.yearsAgo)", "\(day.total)"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(String(format: L10n.t("循环最多：《%1$@》— %2$@（%3$@ 次）"),
                                    top.track.title, top.track.artist, "\(top.count)"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                MiniHeatmapStrip(dailyCounts: stats.dailyCounts)

                if case .syncing(_, let total) = stats.bootstrapState, total > 3 {
                    Text(L10n.t("首次同步历史中，稍候完整数据会自动出现"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 420)
            .task {

                var tick = 0
                while !Task.isCancelled {
                    stats.refreshBaseline()
                    stats.refreshOnThisDay()
                    if tick % 20 == 0 { stats.refreshDailyCounts() }
                    tick += 1
                    try? await Task.sleep(nanoseconds: 180_000_000_000)
                }
            }
        }
    }
}

private struct MiniHeatmapStrip: View {
    let dailyCounts: [String: Int]
    private static let weeks = 12

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        let thisMonday = cal.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        HStack(alignment: .top, spacing: 2) {
            ForEach(0..<Self.weeks, id: \.self) { w in
                let monday = cal.date(byAdding: .day, value: (w - Self.weeks + 1) * 7,
                                      to: thisMonday) ?? thisMonday
                VStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: d, to: monday) ?? monday
                        cell(for: day, future: day > today)
                    }
                }
            }
        }
        .help(L10n.t("近 12 周的收听热力（完整年历在设置的统计页）"))
    }

    private func cell(for day: Date, future: Bool) -> some View {
        let n = future ? 0 : (dailyCounts[LastfmStatsService.dayKey(day)] ?? 0)
        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(future ? Color.clear : Color.accentColor.opacity(intensity(for: n)))
            .frame(width: 7, height: 7)
    }

    private func intensity(for n: Int) -> Double {
        switch n {
        case 0: return 0.08
        case 1...2: return 0.3
        case 3...5: return 0.5
        case 6...9: return 0.72
        default: return 0.95
        }
    }
}

private struct ChartsPanelView: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    @State private var kind: LastfmStatsService.ChartKind = .tracks
    @State private var period: LastfmStatsService.Period = .week

    @AppStorage("settings:chartsPanelMinHeight") private var contentMinHeight: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("你的常听"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            Picker("", selection: $kind) {
                ForEach(LastfmStatsService.ChartKind.allCases) { k in
                    Text(k.displayName).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("", selection: $period) {
                ForEach(LastfmStatsService.Period.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            content
        }
        .padding(10)
        .onAppear { stats.refreshChart(kind: kind, period: period) }
        .onChange(of: kind) { _, k in stats.refreshChart(kind: k, period: period) }
        .onChange(of: period) { _, p in stats.refreshChart(kind: kind, period: p) }
    }

    private func growMinHeight(_ h: CGFloat) {
        if h > contentMinHeight { contentMinHeight = h }
    }

    private var reservedMinHeight: CGFloat? { contentMinHeight > 0 ? contentMinHeight : nil }

    @ViewBuilder
    private var content: some View {
        Group {
            if let entries = stats.chart(kind, period), !entries.isEmpty {

                VStack(spacing: 0) {
                    ForEach(entries.prefix(10)) { entry in
                        row(entry)
                    }
                }
                .frame(minHeight: reservedMinHeight, alignment: .top)
            } else if stats.chartLoading(kind, period) {

                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .frame(minHeight: reservedMinHeight, alignment: .center)
            } else if stats.chartFailed(kind, period) {
                Button(L10n.t("重试")) { stats.refreshChart(kind: kind, period: period) }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .frame(minHeight: reservedMinHeight, alignment: .center)
            } else {
                Text(L10n.t("暂无数据"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .frame(minHeight: reservedMinHeight, alignment: .center)
            }
        }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { growMinHeight(g.size.height) }
                    .onChange(of: g.size.height) { _, h in growMinHeight(h) }
            }
        )
    }

    private func row(_ entry: LastfmStatsService.ChartEntry) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 8) {
                Text("\(entry.rank)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(String(format: L10n.t("%@ 次"), "\(entry.playcount)"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("在 Apple Music 中打开"))
    }

    private func open(_ entry: LastfmStatsService.ChartEntry) {
        let kind = kind
        Task.detached(priority: .userInitiated) {
            let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
            let title: String
            let artist: String
            switch kind {
            case .tracks, .albums:
                title = entry.name
                artist = entry.detail
            case .artists:

                title = ""
                artist = entry.name
            }
            guard let item = await MusicCatalogSearch.resolve(
                title: title, artist: artist, storefront: storefront) else { return }
            let https: String?
            switch kind {
            case .tracks: https = item.trackViewUrl
            case .albums: https = item.collectionViewUrl ?? item.trackViewUrl
            case .artists: https = item.artistViewUrl
            }
            guard let url = MusicCatalogSearch.musicSchemeURL(https) else { return }

            await MusicAutomationPermission.ensureMusicAppRunning()
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }
}
