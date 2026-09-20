import AppKit
import Combine
import LyrimuseCore

@MainActor
enum NotchMirrorManager {

    private static var mirrors: [String: NotchLyricsWindowController] = [:]
    private static var cancellables = Set<AnyCancellable>()
    private static var screenObserver: NSObjectProtocol?
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true

        let settings = AppSettings.shared

        settings.$notchAllScreens
            .combineLatest(settings.$notchOverlayEnabled)
            .sink { allScreens, notchEnabled in
                MainActor.assumeIsolated {
                    refresh(enabled: allScreens && notchEnabled, notchEnabled: notchEnabled)
                }
            }
            .store(in: &cancellables)

        settings.$notchHideWhenNotPlaying
            .combineLatest(settings.$notchHideDuringScreenCapture, settings.$notchContentWidth,
                           settings.$notchExpandedContentWidth)
            .sink { hide, capture, width, expandedWidth in
                MainActor.assumeIsolated {
                    syncAll(hideWhenNotPlaying: hide, hideDuringCapture: capture,
                            contentWidth: width, expandedContentWidth: expandedWidth)
                }
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let s = AppSettings.shared
                refresh(enabled: s.notchAllScreens && s.notchOverlayEnabled)
            }
        }
    }

    static func refresh(enabled: Bool, notchEnabled: Bool? = nil) {
        guard enabled else {
            teardownAll()
            return
        }

        let primaryID = NotchLyricsWindowController.targetScreen().flatMap(ScreenIdentity.id(of:))
        var wanted = Set<String>()
        for screen in NSScreen.screens {
            guard let id = ScreenIdentity.id(of: screen), id != primaryID else { continue }
            wanted.insert(id)
        }

        for (id, mirror) in mirrors where !wanted.contains(id) {
            mirror.teardown()
            mirrors[id] = nil
        }
        for id in wanted where mirrors[id] == nil {

            mirrors[id] = NotchLyricsWindowController(pinnedScreenID: id)
        }
        syncAll(notchEnabled: notchEnabled)
    }

    private static func syncAll(
        notchEnabled: Bool? = nil,
        hideWhenNotPlaying: Bool? = nil,
        hideDuringCapture: Bool? = nil,
        contentWidth: CGFloat? = nil,
        expandedContentWidth: CGFloat? = nil
    ) {
        for mirror in mirrors.values {
            mirror.syncStateFromSettings(
                notchEnabled: notchEnabled,
                hideWhenNotPlaying: hideWhenNotPlaying,
                hideDuringCapture: hideDuringCapture,
                contentWidth: contentWidth,
                expandedContentWidth: expandedContentWidth)
        }
    }

    private static func teardownAll() {
        for mirror in mirrors.values { mirror.teardown() }
        mirrors.removeAll()
    }
}
