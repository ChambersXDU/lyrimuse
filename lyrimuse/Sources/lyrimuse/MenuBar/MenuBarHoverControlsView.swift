import AppKit
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "menubar-hover")

@MainActor
final class MenuBarHoverControlsView: NSView {

    var onHoverChange: ((Bool) -> Void)?

    private var engaged = false

    private var highlighted = false

    private var isPlaying = false

    private var hoveredControl: MenuBarTransportControl?

    private var slot: CGRect?

    private weak var trackingHost: NSView?
    private var installedArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不使用") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func installTracking(on host: NSView) {
        if let old = installedArea, let oldHost = trackingHost {
            oldHost.removeTrackingArea(old)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        host.addTrackingArea(area)
        trackingHost = host
        installedArea = area

        MenuBarAppearanceStore.shared.observe(host)
    }

    func setEngaged(_ on: Bool) {
        guard on != engaged else { return }
        engaged = on
        if !on { hoveredControl = nil }
        isHidden = !on
        needsDisplay = true
    }

    var isEngaged: Bool { engaged }

    func setPlaying(_ on: Bool) {
        guard on != isPlaying else { return }
        isPlaying = on
        if engaged { needsDisplay = true }
    }

    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        if engaged { needsDisplay = true }
    }

    func setSlot(_ rect: CGRect?) {
        guard rect != slot else { return }
        slot = rect
        if engaged { needsDisplay = true }
    }

    private var slotRect: CGRect { slot ?? bounds }

    var controlRects: [MenuBarTransportControl: CGRect]? {
        MenuBarHoverControls.layout(in: slotRect)
    }

    func control(at point: CGPoint) -> MenuBarTransportControl? {
        guard engaged, let rects = controlRects else { return nil }
        return MenuBarHoverControls.control(at: point, in: rects)
    }

    var fitsControls: Bool { MenuBarHoverControls.layout(in: slotRect) != nil }

    override func mouseEntered(with event: NSEvent) {
        updateHovered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredControl != nil {
            hoveredControl = nil
            if engaged { needsDisplay = true }
        }
        onHoverChange?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHovered(with: event)
    }

    private func updateHovered(with event: NSEvent) {
        guard engaged, let window else { return }

        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let next = controlRects.flatMap { MenuBarHoverControls.control(at: point, in: $0) }
        guard next != hoveredControl else { return }
        hoveredControl = next
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        if engaged { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()

        MenuBarAppearanceStore.shared.hostAppearanceDidChange()
        if engaged { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard engaged, let rects = MenuBarHoverControls.layout(in: slotRect) else { return }

        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor

            for control in MenuBarTransportControl.allCases {
                guard let hit = rects[control],
                      let glyph = Self.glyph(for: control, playing: isPlaying) else { continue }
                glyph.image.draw(in: glyph.box(centeredIn: hit))
                tint.set()
                glyph.box(centeredIn: hit).fill(using: .sourceAtop)
            }

            if let hovered = hoveredControl, let hit = rects[hovered] {
                let base = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
                base.withAlphaComponent(0.15).set()
                NSBezierPath(roundedRect: hit.insetBy(dx: 1, dy: 3), xRadius: 4, yRadius: 4)
                    .fill(using: .destinationOver)
            }
        }
    }

    private struct Glyph {
        let image: NSImage
        let ink: CGRect

        func box(centeredIn hit: CGRect) -> CGRect {
            CGRect(x: Self.roundedToHalf(hit.midX - ink.midX),
                   y: Self.roundedToHalf(hit.midY - ink.midY),
                   width: image.size.width, height: image.size.height)
        }

        private static func roundedToHalf(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
    }

    private static var glyphCache: [String: Glyph] = [:]

    private static func glyph(for control: MenuBarTransportControl, playing: Bool) -> Glyph? {
        let name: String
        switch control {
        case .previous: name = "backward.fill"
        case .playPause: name = playing ? "pause.fill" : "play.fill"
        case .next: name = "forward.fill"
        }
        if let cached = glyphCache[name] { return cached }
        let config = NSImage.SymbolConfiguration(
            pointSize: MenuBarHoverControls.glyphPointSize, weight: .medium)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            logger.error("SF Symbol not found: \(name, privacy: .public)")
            return nil
        }

        let glyph = Glyph(image: image,
                          ink: inkRect(of: image) ?? CGRect(origin: .zero, size: image.size))
        glyphCache[name] = glyph
        return glyph
    }

    private static func inkRect(of image: NSImage) -> CGRect? {
        let size = image.size
        let scale: CGFloat = 2
        let pxW = Int((size.width * scale).rounded()), pxH = Int((size.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        var minX = pxW, maxX = -1, minY = pxH, maxY = -1
        for x in 0..<pxW {
            for y in 0..<pxH {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0, maxY >= 0 else { return nil }

        let x0 = CGFloat(minX) / scale, x1 = CGFloat(maxX + 1) / scale
        let yTop = CGFloat(minY) / scale, yBottom = CGFloat(maxY + 1) / scale
        return CGRect(x: x0, y: size.height - yBottom, width: x1 - x0, height: yBottom - yTop)
    }
}

private extension NSBezierPath {

    func fill(using operation: NSCompositingOperation) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = operation
        fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
