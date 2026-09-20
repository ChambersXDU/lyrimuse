import AppKit
import SwiftUI

struct WindowDragHandle: NSViewRepresentable {
    final class DragCatcherView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> NSView { DragCatcherView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct WindowResizeEnabler: NSViewRepresentable {

    let minWidth: CGFloat
    let minHeight: CGFloat

    final class Probe: NSView {
        var minSize: NSSize = .zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            apply(to: window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.apply(to: window)
            }
        }

        private func apply(to window: NSWindow) {
            window.styleMask.insert(.resizable)
            guard minSize.width > 0, minSize.height > 0 else { return }
            window.contentMinSize = minSize

            let content = window.contentRect(forFrameRect: window.frame).size
            if content.width < minSize.width || content.height < minSize.height {
                window.setContentSize(NSSize(
                    width: max(content.width, minSize.width),
                    height: max(content.height, minSize.height)))
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = Probe()
        view.minSize = NSSize(width: minWidth, height: minHeight)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? Probe else { return }
        probe.minSize = NSSize(width: minWidth, height: minHeight)
        if let window = probe.window {
            window.contentMinSize = probe.minSize
        }
    }
}
