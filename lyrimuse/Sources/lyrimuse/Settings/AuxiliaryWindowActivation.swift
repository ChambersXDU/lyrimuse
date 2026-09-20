import AppKit

@MainActor
enum AuxiliaryWindowActivation {
    private static var openCount = 0

    static var hasAnyOpen: Bool { openCount > 0 }

    static func windowDidAppear() {
        openCount += 1
        guard !AppSettings.shared.showInDock else { return }
        NSApp.setActivationPolicy(.regular)
    }

    static func windowDidDisappear() {
        openCount = max(0, openCount - 1)
        guard openCount == 0, !AppSettings.shared.showInDock else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    struct BringForwardResult {

        var restored = 0

        var fronted = 0

        var alreadyFront = false

        var foundNone: Bool { restored == 0 && fronted == 0 }
    }

    @discardableResult
    static func bringOpenWindowsForward() -> BringForwardResult {
        var result = BringForwardResult()
        let open = NSApp.windows.filter { isAuxiliaryRegularWindow($0) && ($0.isVisible || $0.isMiniaturized) }
        guard !open.isEmpty else { return result }

        let frontVisible = NSApp.orderedWindows.first { w in open.contains(w) && w.isVisible }
            ?? open.first { $0.isVisible }
        let minimized = open.filter(\.isMiniaturized)

        if !minimized.isEmpty {
            for w in minimized { w.deminiaturize(nil) }
            result.restored = minimized.count
            minimized.last?.makeKeyAndOrderFront(nil)
        } else if let target = frontVisible {

            result.alreadyFront = target.isKeyWindow && target.isOnActiveSpace
            target.makeKeyAndOrderFront(nil)
            result.fronted = 1
        }
        return result
    }

    private static func isAuxiliaryRegularWindow(_ w: NSWindow) -> Bool {
        !(w is NSPanel) && w.styleMask.contains(.titled) && w.canBecomeMain
    }
}
