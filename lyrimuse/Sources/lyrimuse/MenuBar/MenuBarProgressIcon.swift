import AppKit
import LyrimuseCore

@MainActor
enum MenuBarProgressIcon {

    static let gap: CGFloat = 5

    static func reservedWidth(for style: MenuBarIconStyle?) -> CGFloat {
        guard let style else { return 0 }
        return MenuBarIconStyle.cachedImage(for: style).size.width + gap
    }

    static func size(of style: MenuBarIconStyle) -> CGSize {
        MenuBarIconStyle.cachedImage(for: style).size
    }

    struct Prepared {
        let cg: CGImage

        let scale: CGFloat
        let size: CGSize
    }

    static func tinted(style: MenuBarIconStyle, color: NSColor, scale: CGFloat) -> Prepared? {
        let image = MenuBarIconStyle.cachedImage(for: style)
        let size = image.size
        let pxW = Int((size.width * scale).rounded())
        let pxH = Int((size.height * scale).rounded())
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
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        return Prepared(cg: cg, scale: scale, size: size)
    }
}
