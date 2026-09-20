import AppKit

enum ThemeSwatch {
    static let defaultSize = NSSize(width: 28, height: 12)

    static func image(
        foregroundHex: String, backgroundHex: String, strokeEnabled: Bool, strokeHex: String,
        size: NSSize = defaultSize
    ) -> NSImage {

        let foreground = NSColor(hexStringWithAlpha: foregroundHex) ?? .white
        let background = NSColor(hexStringWithAlpha: backgroundHex) ?? .clear
        let stroke = NSColor(hexStringWithAlpha: strokeHex) ?? .black
        let image = NSImage(size: size, flipped: false) { rect in
            let radius: CGFloat = 2
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()

            let cell: CGFloat = 3
            var row = 0
            var y = rect.minY
            while y < rect.maxY {
                var col = 0
                var x = rect.minX
                while x < rect.maxX {
                    NSColor(white: (row + col) % 2 == 0 ? 0.94 : 0.76, alpha: 1).setFill()
                    NSRect(x: x, y: y, width: cell, height: cell).fill()
                    x += cell; col += 1
                }
                y += cell; row += 1
            }

            let bandWidth = rect.width / 3
            func band(_ index: Int) -> NSRect {
                NSRect(x: rect.minX + bandWidth * CGFloat(index), y: rect.minY, width: bandWidth, height: rect.height)
            }
            foreground.setFill(); band(0).fill()
            background.setFill(); band(1).fill()
            if strokeEnabled {
                stroke.setFill(); band(2).fill()
            } else {

                let hatchRect = band(2)
                NSColor(white: 0.9, alpha: 1).setFill(); hatchRect.fill()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: hatchRect).addClip()
                NSColor(white: 0.55, alpha: 1).setStroke()
                let hatch = NSBezierPath()
                hatch.lineWidth = 1
                var x = hatchRect.minX - hatchRect.height
                while x < hatchRect.maxX {
                    hatch.move(to: NSPoint(x: x, y: hatchRect.minY))
                    hatch.line(to: NSPoint(x: x + hatchRect.height, y: hatchRect.maxY))
                    x += 3
                }
                hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }

            NSColor.separatorColor.setStroke()
            for index in 1..<3 {
                let x = rect.minX + bandWidth * CGFloat(index)
                let line = NSBezierPath()
                line.lineWidth = 0.5
                line.move(to: NSPoint(x: x, y: rect.minY))
                line.line(to: NSPoint(x: x, y: rect.maxY))
                line.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            border.lineWidth = 0.5
            border.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
