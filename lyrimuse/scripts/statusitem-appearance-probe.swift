#!/usr/bin/env swift

import AppKit

final class Probe: NSObject, NSApplicationDelegate {
    var item: NSStatusItem?
    var last = ""
    var t0 = Date()
    var timer: Timer?
    var hover: HoverProbe?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.appearance = nil
        print("NSApp.effectiveAppearance = \(NSApp.effectiveAppearance.name.rawValue)")
        let item = NSStatusBar.system.statusItem(withLength: 1)
        self.item = item
        t0 = Date()
        let h = HoverProbe(t0: t0)
        hover = h
        if let b = item.button {
            h.frame = b.bounds
            h.autoresizingMask = [.width, .height]
            b.addSubview(h)
        }
        sample("immediately after create+addSubview")
        timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in self?.sample(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.timer?.invalidate()
            if let it = self?.item { NSStatusBar.system.removeStatusItem(it) }
            self?.item = nil
            print("removed; exiting")
            NSApp.terminate(nil)
        }
    }

    func sample(_ label: String?) {
        guard let b = item?.button else { print("no button"); return }
        let win = b.window
        let desc = "window=\(win == nil ? "nil" : "yes") visible=\(win?.isVisible ?? false) " +
            "winFrame=\(win.map { NSStringFromRect($0.frame) } ?? "-") " +
            "winAppearance=\(win?.appearance?.name.rawValue ?? "nil") winEff=\(win?.effectiveAppearance.name.rawValue ?? "-") " +
            "buttonEff=\(b.effectiveAppearance.name.rawValue) hoverEff=\(hover?.effectiveAppearance.name.rawValue ?? "-") " +
            "hoverWindow=\(hover?.window == nil ? "nil" : "yes")"
        if desc != last || label != nil {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[\(ms)ms] \(label.map { $0 + ": " } ?? "")\(desc)")
            last = desc
        }
    }
}

final class HoverProbe: NSView {
    let t0: Date
    init(t0: Date) { self.t0 = t0; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[\(ms)ms] hover.viewDidChangeEffectiveAppearance → \(effectiveAppearance.name.rawValue) window=\(window == nil ? "nil" : "yes")")
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[\(ms)ms] hover.viewDidMoveToWindow window=\(window == nil ? "nil" : "yes") eff=\(effectiveAppearance.name.rawValue)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = Probe()
app.delegate = d
app.run()
