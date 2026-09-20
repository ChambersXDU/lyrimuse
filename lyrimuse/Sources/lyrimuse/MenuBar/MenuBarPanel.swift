import AppKit
import SwiftUI
import Combine
import LyrimuseCore

@MainActor
private final class PanelPlayback: ObservableObject {

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var currentLine: SyncedLyricLine?

    @Published private(set) var compactLine: SyncedLyricLine?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false

    @Published private(set) var isRadioTalkBreak = false
    @Published private(set) var radioStationName: String?
    @Published private(set) var currentLineFillSettled = true
    @Published private(set) var artworkImage: NSImage?

    @Published private(set) var highResArtworkImage: NSImage?
    @Published private(set) var highResArtworkThumbnail: NSImage?

    var displayArtworkImage: NSImage? { highResArtworkThumbnail ?? highResArtworkImage ?? artworkImage }
    @Published private(set) var anchor: ProgressAnchor?
    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?
    @Published private(set) var trackLyricsOffsetMs = 0

    @Published private(set) var classicOverlayEnabled = false
    @Published private(set) var showLyricsInMenuBar = false
    @Published private(set) var lyricsOffsetStepMs = 200
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$currentLine.removeDuplicates().sink { [weak self] in self?.currentLine = $0 },

            Publishers.CombineLatest(p.$compactLine, s.$menuBarLyricsKaraoke)
                .map { line, karaoke in karaoke ? line : line?.lineLevel }
                .removeDuplicates()
                .sink { [weak self] in self?.compactLine = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$isRadioTalkBreak.removeDuplicates().sink { [weak self] in self?.isRadioTalkBreak = $0 },
            p.$radioStationName.removeDuplicates().sink { [weak self] in self?.radioStationName = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },

            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
            p.$highResArtworkThumbnail.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkThumbnail = $0 },
            p.$anchor.sink { [weak self] in self?.anchor = $0 },
            p.$pausedPositionMs.removeDuplicates().sink { [weak self] in self?.pausedPositionMs = $0 },
            p.$currentDurationMs.removeDuplicates().sink { [weak self] in self?.currentDurationMs = $0 },
            p.$trackLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.trackLyricsOffsetMs = $0 },
            s.$classicOverlayEnabled.removeDuplicates().sink { [weak self] in self?.classicOverlayEnabled = $0 },
            s.$showLyricsInMenuBar.removeDuplicates().sink { [weak self] in self?.showLyricsInMenuBar = $0 },
            s.$lyricsOffsetStepMs.removeDuplicates().sink { [weak self] in self?.lyricsOffsetStepMs = $0 },
        ]
    }
}

@MainActor
final class MenuBarPanelController {
    private var popover: NSPopover?
    private var closeObserver: NSObjectProtocol?

    private var outsideClickMonitor: Any?

    private var resignActiveObserver: NSObjectProtocol?

    private var spaceChangeObserver: NSObjectProtocol?

    var onVisibilityChange: ((Bool) -> Void)?

    func toggle(relativeTo button: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let pop = NSPopover()
        pop.behavior = .transient

        pop.animates = false
        let content = MenuBarPanelView(close: { [weak pop] in pop?.performClose(nil) })
        pop.contentViewController = FirstMouseHostingController(rootView: content)
        popover = pop
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: pop, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.teardownDismissWatchers()
                self.onVisibilityChange?(false)

                self.popover = nil
                if let closeObserver = self.closeObserver {
                    NotificationCenter.default.removeObserver(closeObserver)
                    self.closeObserver = nil
                }
            }
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak pop] _ in
            Task { @MainActor in pop?.performClose(nil) }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak pop] _ in
            Task { @MainActor in pop?.performClose(nil) }
        }

        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak pop] _ in
            Task { @MainActor in pop?.performClose(nil) }
        }
        onVisibilityChange?(true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        pop.contentViewController?.view.window?.collectionBehavior
            .formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    private func teardownDismissWatchers() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        resignActiveObserver = nil
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        }
        spaceChangeObserver = nil
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }
}

private struct MenuBarPanelView: View {

    @StateObject private var playback = PanelPlayback()
    let close: () -> Void

    @State private var quickTarget: LyricsSurface?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 9) {
            nowPlayingCard

            if let quickTarget {
                PanelQuickSettings(
                    surface: quickTarget,
                    toggle: toggleAction(for: quickTarget),
                    back: { setQuickTarget(nil) },
                    close: close)
            } else {
                knobGrid
                footer
            }
        }
        .padding(10)
        .frame(width: 336)

    }

    private func setQuickTarget(_ surface: LyricsSurface?) {
        quickTarget = surface
    }

    private func toggleAction(for surface: LyricsSurface) -> () -> Void {
        switch surface {
        case .overlay:
            return {
                LyricsOverlayWindowController.shared.setVisible(!AppSettings.shared.classicOverlayEnabled)
            }
        case .menuBar:
            return {

                close()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    AppSettings.shared.showLyricsInMenuBar.toggle()
                }
            }
        }
    }

    private var knobGrid: some View {
        VStack(spacing: 9) {

            HStack(spacing: 9) {
                surfaceTile(.overlay)
                surfaceTile(.menuBar)
            }
            HStack(spacing: 9) {
                knobTile(symbol: "music.note.list", title: L10n.t("歌词管理"), on: false) {
                    close()
                    AppActions.shared.openLyricsManager?()
                }
            }
        }
    }

    private func surfaceTile(_ surface: LyricsSurface) -> some View {
        knobTile(symbol: surface.symbolName, title: surface.panelTitle,
                 on: surface.isEnabled, quick: surface,
                 action: toggleAction(for: surface))
    }

    private var displayTitle: String {
        if playback.isCurrentTrackAdBreak { return L10n.t("广告中") }

        if playback.isRadioTalkBreak, let station = playback.radioStationName, !station.isEmpty {
            return station
        }

        return playback.title
    }

    private var displayArtist: String {
        playback.isCurrentTrackAdBreak ? "" : playback.artist
    }

    private var displayAlbum: String {
        playback.isCurrentTrackAdBreak ? "" : playback.album
    }

    private var isIdleNoTrack: Bool {
        playback.title.isEmpty && playback.artist.isEmpty && !playback.isCurrentTrackAdBreak
    }

    private var trackHeader: some View {
        HStack(alignment: .top, spacing: 9) {

            coverView
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Text(displayArtist)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !displayAlbum.isEmpty {
                    Text(displayAlbum)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            if let icon = PlaybackCoordinator.shared.resolvedPlayerIcon {
                Button {
                    PlaybackCoordinator.shared.openResolvedPlayerApp()
                    close()
                } label: {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(PlaybackCoordinator.shared.resolvedPlayerDisplayName ?? "")
            }
    }
    }

    private var nowPlayingCard: some View {
        VStack(spacing: 8) {

            if !isIdleNoTrack {
                trackHeader
                lyricLine
            }

            PanelProgressSection(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                trackLyricsOffsetMs: playback.trackLyricsOffsetMs,
                lyricsOffsetStepMs: playback.lyricsOffsetStepMs)
            HStack(spacing: 28) {
                controlButton("backward.fill", size: 13) { MusicPlaybackController.previousTrack() }
                controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill", size: 18) {

                    PlaybackCoordinator.shared.userTogglePlayPause()
                }
                controlButton("forward.fill", size: 13) { MusicPlaybackController.nextTrack() }
            }
        }
        .padding(10)
        .background(Color(nsColor: .quaternarySystemFill),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var lyricLine: some View {

        MarqueeText(id: playback.compactLine?.plainText ?? "") {
            lyricContent
        }
        .font(.system(size: 11.5, weight: .medium))

        .frame(height: 16)
    }

    @ViewBuilder private var lyricContent: some View {

        switch LyricsLineDisplay.resolve(

            hasWordTiming: !(playback.compactLine?.words ?? []).isEmpty,
            hasCurrentLine: playback.compactLine != nil,
            isAdBreak: playback.isCurrentTrackAdBreak,
            isRadioTalk: playback.isRadioTalkBreak,
            isInstrumental: playback.isCurrentTrackInstrumental,
            hasNoLyrics: playback.currentTrackHasNoLyrics,
            networkDown: playback.collectorNetworkDown,
            hasLyricsContent: playback.hasLyricsContent,
            isPlaying: playback.isPlayingNow
        ) {
        case .words:
            karaokeLine(playback.compactLine?.words ?? [])
        case .plain:

            Text(playback.compactLine?.plainText ?? "").foregroundStyle(.primary).lineLimit(1)
        case .adBreak:

            Text("")
        case .radioTalk:
            statusText(L10n.t("口白"))
        case .instrumental:
            statusText(L10n.t("纯音乐"))
        case .noLyrics:
            statusText(L10n.t("暂无歌词"))
        case .networkDown:
            statusText(L10n.t("网络连接失败"))
        case .searching:
            statusText(L10n.t("搜索歌词中…"))
        case .idle:
            Text("")
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text).foregroundStyle(.tertiary).lineLimit(1)
    }

    private func karaokeLine(_ words: [SyncedLyricWord]) -> some View {

        TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                paused: !playback.isPlayingNow || playback.currentLineFillSettled)) { context in

            let ms = (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: context.date)
                ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
                + PlaybackCoordinator.shared.currentLyricsOffsetMs

            let palette = WordKaraokeGradient.palette(fg: .primary)
            HStack(spacing: 0) {
                ForEach(words.indices, id: \.self) { i in
                    let fraction = WordKaraokeGradient.fillFraction(for: words[i], atMs: ms)
                    Text(words[i].text)
                        .foregroundStyle(palette.style(
                            left: fraction - WordKaraokeGradient.wordEdgeSoftenBand,
                            right: fraction + WordKaraokeGradient.wordEdgeSoftenBand))
                }
            }
            .lineLimit(1)

            .transaction { $0.animation = nil }
        }
    }

    @ViewBuilder private var coverView: some View {

        if playback.isCurrentTrackAdBreak {

            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [.blue.opacity(0.55), .purple.opacity(0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "megaphone.fill").foregroundStyle(.white.opacity(0.85)))
        } else if let image = playback.displayArtworkImage {

            let scale = max(1, displayScale)
            Group {
                if let bitmap = ArtworkThumbnailCache.bitmap(for: image, pixelSide: Int((44 * scale).rounded())) {
                    Image(decorative: bitmap, scale: scale)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [.blue.opacity(0.55), .purple.opacity(0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.85)))
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat,
                               action: @escaping () -> Void) -> some View {

        ChipButton(cornerRadius: 13, action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 26)
        }
    }

    private func knobTile(symbol: String, title: String, subtitle: String? = nil, on: Bool,
                          quick: LyricsSurface? = nil,
                          action: @escaping () -> Void) -> some View {
        KnobTile(symbol: symbol, title: title, subtitle: subtitle, on: on,
                 action: action,

                 openQuick: quick.map { surface in { setQuickTarget(surface) } })
    }

    private struct KnobTile: View {
        let symbol: String
        let title: String
        let subtitle: String?
        let on: Bool
        let action: () -> Void

        let openQuick: (() -> Void)?

        @State private var hovering = false
        @State private var pressing = false

        var body: some View {
            content
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: fillColor))
                )
                .overlay {

                    TileMouseRouter(
                        onPrimary: action,
                        onSecondary: { (openQuick ?? action)() },
                        onPressingChange: { pressing = $0 },
                        onHoverChange: { hovering = $0 },
                        toolTip: openQuick == nil ? nil : L10n.t("长按或右键打开设置"))
                }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
        }

        private var fillColor: NSColor {
            if pressing { return .secondarySystemFill }
            return hovering ? .tertiarySystemFill : .quaternarySystemFill
        }

        private var content: some View {

            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(on ? AnyShapeStyle(Color.accentColor)
                                         : AnyShapeStyle(Color(nsColor: .quaternarySystemFill)))
                    )
                VStack(spacing: 1) {

                    Text(title).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let subtitle {
                        Text(subtitle).font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)

            .frame(height: 78)
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("gearshape", L10n.t("设置…")) {
                close()
                AppActions.shared.openSettings?()
            }
            versionFooterItem
        }
    }

    @ViewBuilder private var versionFooterItem: some View {
        footerItem(
            title: String(format: L10n.t("版本 %@"),
                          Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"),
            tint: .secondary, help: L10n.t("关于 Lyrimuse"),
            icon: { Image(systemName: "info.circle").font(.system(size: 10.5)) }
        ) {
            close()

            AppActions.shared.requestSettings(.tab(.about))
            AppActions.shared.openSettings?()
        }
    }

    private func footerButton(_ symbol: String, _ title: String,
                              action: @escaping () -> Void) -> some View {
        footerItem(title: title, tint: .secondary, help: nil,
                   icon: { Image(systemName: symbol).font(.system(size: 10.5)) },
                   action: action)
    }

    private func footerItem<Icon: View>(title: String, tint: Color, help: String?,

                                        @ViewBuilder icon: @escaping () -> Icon,
                                        action: @escaping () -> Void) -> some View {

        ChipButton(cornerRadius: 6, pressScale: 0.97, action: action) {
            HStack(spacing: 4) {
                icon()
                Text(title)
                    .font(.system(size: 10.5))

                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .modifier(OptionalHelp(text: help))
    }
}

private struct ChipButton<Label: View>: View {
    var cornerRadius: CGFloat = 7
    var pressScale: CGFloat = 0.92
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) { label().contentShape(Rectangle()) }
            .buttonStyle(ChipStyle(cornerRadius: cornerRadius, hovering: hovering,
                                   pressScale: pressScale))

            .onHover { hovering = $0 }
    }
}

private struct ChipStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let hovering: Bool
    let pressScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        let level: Double = pressed ? 0.14 : (hovering ? 0.07 : 0)
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(level))
            )

            .scaleEffect(pressed ? pressScale : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.65),
                       value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

private struct PanelProgressSection: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    let trackLyricsOffsetMs: Int
    let lyricsOffsetStepMs: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @GestureState private var scrubFraction: Double?

    @State private var hoveringScrubber = false

    @ViewBuilder var body: some View {
        if let anchor, anchor.durationMs > 0 {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let current = scrubFraction.map { Int($0 * Double(anchor.durationMs)) }
                    ?? anchor.extrapolatedPositionMs(now: context.date)
                progressBar(currentMs: current, durationMs: anchor.durationMs)
            }
        } else if let paused = pausedPositionMs,
                  let duration = durationMs, duration > 0 {
            let current = scrubFraction.map { Int($0 * Double(duration)) } ?? paused
            progressBar(currentMs: current, durationMs: duration)
        }
    }

    private func progressBar(currentMs: Int, durationMs: Int) -> some View {
        let fraction = min(max(Double(currentMs) / Double(durationMs), 0), 1)
        return VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .quaternarySystemFill).opacity(0.9))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * fraction))
                }

                .frame(height: scrubberHeight)
                .frame(maxHeight: .infinity)

                .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7),
                           value: scrubberHeight)
                .contentShape(Rectangle())
                .onHover { hoveringScrubber = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($scrubFraction) { value, state, _ in

                            if state == nil {
                                NSHapticFeedbackManager.defaultPerformer.perform(
                                    .alignment, performanceTime: .now)
                            }
                            state = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { value in
                            let f = min(max(value.location.x / geo.size.width, 0), 1)
                            PlaybackCoordinator.shared.seek(toMs: Int(f * Double(durationMs)))
                        }
                )
            }
            .frame(height: 14)
            HStack {
                Text(Self.mmss(currentMs))
                Spacer()
                offsetControls
                Spacer()
                Text("-" + Self.mmss(max(0, durationMs - currentMs)))
            }
            .font(.system(size: 9.5).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    private var offsetControls: some View {
        HStack(spacing: 3) {

            offsetButton("minus", help: nudgeHelp(L10n.t("延后"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: -lyricsOffsetStepMs)
            }

            Text(offsetText)
                .foregroundStyle(trackLyricsOffsetMs != 0 ? .secondary : .tertiary)
                .frame(width: 64)

                .modifier(TapToReset(enabled: trackLyricsOffsetMs != 0) {
                    PlaybackCoordinator.shared.resetLyricsOffset()
                })
            offsetButton("plus", help: nudgeHelp(L10n.t("提前"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: lyricsOffsetStepMs)
            }
        }
    }

    private var offsetText: String {
        "\(L10n.t("歌词")) \(AppSettings.signedSeconds(ms: trackLyricsOffsetMs))s"
    }

    private func nudgeHelp(_ verb: String) -> String {
        "\(verb) \(AppSettings.formattedSeconds(ms: lyricsOffsetStepMs))\(L10n.t("秒"))"
    }

    private func offsetButton(_ symbol: String, help: String,
                              action: @escaping () -> Void) -> some View {

        ChipButton(cornerRadius: 4, pressScale: 0.88, action: action) {
            Image(systemName: symbol)

                .font(.system(size: 10, weight: .semibold))

                .foregroundStyle(.secondary)
                .frame(width: 16, height: 14)
        }
        .help(help)
    }

    private struct TapToReset: ViewModifier {
        let enabled: Bool
        let action: () -> Void

        func body(content: Content) -> some View {
            content
                .contentShape(Rectangle())
                .onTapGesture { if enabled { action() } }
                .modifier(OptionalHelp(text: enabled ? L10n.t("点击归零") : nil))
        }
    }

    private var scrubberHeight: CGFloat {
        if scrubFraction != nil { return 7 }
        return hoveringScrubber ? 6 : 4
    }

    private static func mmss(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
