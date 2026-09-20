import AppKit
import os

@MainActor
enum SpaceDiagnostics {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "spacediag")
    private static var started = false

    private static var fullScreenCapabilityWrites = 0

    static func noteFullScreenCapabilityWrite() {
        fullScreenCapabilityWrites += 1
    }

    private static var workspaceObservers: [NSObjectProtocol] = []
    private static var defaultObservers: [NSObjectProtocol] = []

    static func start() {
        guard !started else { return }
        started = true
        logger.notice("spacediag: probe started (temporary diagnostics, remove once the cause is found)")

        let ws = NSWorkspace.shared.notificationCenter
        let obsSpace = ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { report("Space 变了") }
        }

        let obsApp = ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .localizedName ?? "?"
            MainActor.assumeIsolated { report("别的 App 被激活: \(app)") }
        }
        workspaceObservers.append(contentsOf: [obsSpace, obsApp])

        let nc = NotificationCenter.default
        let appEvents: [(Notification.Name, String)] = [
            (NSApplication.didBecomeActiveNotification, "本 App 变活跃"),
            (NSApplication.didResignActiveNotification, "本 App 失去活跃"),
        ]
        for (name, label) in appEvents {
            let obs = nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    report(label)
                }
            }
            defaultObservers.append(obs)
        }

        let obsKey = nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let title = (note.object as? NSWindow)?.title ?? "(无标题)"
            MainActor.assumeIsolated { report("窗口成为 key: \(title)") }
        }
        defaultObservers.append(obsKey)
    }

    static func stop() {
        guard started else { return }
        started = false
        let ws = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            ws.removeObserver(token)
        }
        workspaceObservers.removeAll()
        let nc = NotificationCenter.default
        for token in defaultObservers {
            nc.removeObserver(token)
        }
        defaultObservers.removeAll()
        logger.notice("spacediag: probe stopped")
    }

    private static func report(_ reason: String) {
        let writes = fullScreenCapabilityWrites
        fullScreenCapabilityWrites = 0
        var parts: [String] = []
        for w in NSApp.windows where w.isVisible || w.isOnActiveSpace {
            let t = w.title.isEmpty ? "(无标题)" : w.title
            parts.append("[\(t) vis=\(w.isVisible ? 1 : 0) onActive=\(w.isOnActiveSpace ? 1 : 0) lvl=\(w.level.rawValue) cb=\(w.collectionBehavior.rawValue)]")
        }
        let dump = parts.joined(separator: " ")
        logger.notice("spacediag: \(reason, privacy: .public) | active=\(NSApp.isActive ? 1 : 0) | cb rewrites=\(writes, privacy: .public) | \(dump, privacy: .public)")
    }
}
