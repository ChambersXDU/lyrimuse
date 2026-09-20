import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarAppearanceStore: ObservableObject {
    static let shared = MenuBarAppearanceStore()

    @Published private(set) var isDark: Bool = NSApp?.effectiveAppearance
        .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

    private weak var host: NSView?
    private var pendingSettle: DispatchWorkItem?

    nonisolated static let settleDelay: TimeInterval = 0.4

    private nonisolated static let maxSettleRetries = 5

    private init() {}

    func observe(_ view: NSView) {
        host = view
        scheduleSettle()
    }

    func hostAppearanceDidChange() {
        scheduleSettle()
    }

    private func scheduleSettle(retriesLeft: Int = maxSettleRetries) {
        pendingSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle(retriesLeft: retriesLeft) }
        pendingSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func settle(retriesLeft: Int) {
        pendingSettle = nil
        guard let host else { return }
        guard Self.isLaidOut(host.window) else {
            if retriesLeft > 0 { scheduleSettle(retriesLeft: retriesLeft - 1) }
            return
        }
        let dark = host.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != isDark else { return }
        isDark = dark
    }

    static func isLaidOut(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.frame.height > 0
    }

    var appearance: NSAppearance {
        NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }

    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

extension NSColor {

    func resolved(in appearance: NSAppearance) -> NSColor {
        var out = self
        appearance.performAsCurrentDrawingAppearance {
            out = usingColorSpace(.sRGB) ?? self
        }
        return out
    }
}
