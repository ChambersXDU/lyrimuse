import AppKit
import LyrimuseCore

@MainActor
enum MenuBarMarqueeRenderer {

    static var font: NSFont {
        let settings = AppSettings.shared
        return font(weight: settings.menuBarLyricsFontWeight, size: settings.menuBarLyricsFontSize)
    }

    static let fontSizeRange: ClosedRange<CGFloat> = 10...16

    static var systemPointSize: CGFloat { NSFont.menuBarFont(ofSize: 0).pointSize }

    static func font(weight: OverlayFontWeight, size: CGFloat) -> NSFont {
        let pointSize = size > 0
            ? min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
            : systemPointSize
        return font(weight: weight, pointSize: pointSize)
    }

    static func font(weight: OverlayFontWeight, pointSize: CGFloat) -> NSFont {

        guard weight != .regular else { return NSFont.menuBarFont(ofSize: pointSize) }
        return NSFont.systemFont(ofSize: pointSize, weight: weight.nsWeight)
    }

    static var doubleRowMainFont: NSFont {
        font(weight: AppSettings.shared.menuBarLyricsFontWeight, pointSize: MenuBarLyricRows.mainPointSize)
    }

    static var doubleRowSecondaryFont: NSFont {
        font(weight: AppSettings.shared.menuBarLyricsFontWeight, pointSize: MenuBarLyricRows.secondaryPointSize)
    }

    static func mainFont(for text: String, twoRows: Bool) -> NSFont {
        guard twoRows else { return font(for: text) }
        return text == placeholderGlyph
            ? NSFont.menuBarFont(ofSize: MenuBarLyricRows.mainPointSize) : doubleRowMainFont
    }

    static func boxHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender)
    }

    static let placeholderGlyph = "♪"

    static func font(for text: String) -> NSFont {
        let lineFont = font
        return text == placeholderGlyph ? NSFont.menuBarFont(ofSize: lineFont.pointSize) : lineFont
    }

    static func width(of text: String) -> CGFloat {
        width(of: text, font: font(for: text))
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    static var lineHeight: CGFloat {
        let f = font
        return ceil(f.ascender - f.descender) + 2
    }

    static func wordEndXs(for words: [SyncedLyricWord], font: NSFont? = nil) -> [CGFloat] {

        let lineFont = font ?? Self.font
        var prefix = ""
        return words.map { w in
            prefix += w.text
            return width(of: prefix, font: lineFont)
        }
    }

    static func truncate(_ text: String, toWidth limit: CGFloat) -> String {
        guard limit > 0 else { return "" }
        guard width(of: text) > limit else { return text }
        let ellipsis = "…"
        let ellipsisWidth = width(of: ellipsis)

        let chars = Array(text)
        var lo = 0
        var hi = chars.count
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if width(of: String(chars[0..<mid])) + ellipsisWidth > limit {
                hi = mid
            } else {
                lo = mid
            }
        }

        return lo == 0 ? ellipsis : String(chars[0..<lo]) + ellipsis
    }

    enum Presentation: Equatable {

        case text(String)

        case fixed(text: String, windowWidth: CGFloat, pacing: MenuBarMarquee.ScrollPacing?)
    }

    static func presentation(
        for text: String, windowWidth: CGFloat, dwellSeconds: Double?,
        leadInSeconds: Double, widthMode: MenuBarLyricsWidthMode, font: NSFont? = nil
    ) -> Presentation {
        guard windowWidth > 0 else { return .text(truncate(text, toWidth: windowWidth)) }
        let fullWidth = width(of: text, font: font ?? Self.font(for: text))

        guard fullWidth > windowWidth + 0.5 else {
            switch widthMode {
            case .adaptive:

                return .text(text)
            case .fixed:
                return .fixed(text: text, windowWidth: windowWidth, pacing: nil)
            }
        }

        let averageCharWidth = fullWidth / CGFloat(max(1, text.count))
        return .fixed(
            text: text,
            windowWidth: windowWidth,
            pacing: MenuBarMarquee.pacing(
                maxOffset: fullWidth - windowWidth,
                averageCharWidth: averageCharWidth,
                dwellSeconds: dwellSeconds,
                leadInSeconds: leadInSeconds))
    }

    struct PreparedLine {
        let cg: CGImage

        let scale: CGFloat

        let textWidth: CGFloat
        let pointHeight: CGFloat
        let text: String

        let color: NSColor
    }

    static func prepare(text: String, color: NSColor, scale: CGFloat,
                        font: NSFont? = nil, exactBox: Bool = false) -> PreparedLine? {
        guard !text.isEmpty else { return nil }
        let lineFont = font ?? Self.font(for: text)
        let box = exactBox ? boxHeight(for: lineFont) : ceil(lineFont.ascender - lineFont.descender) + 2
        let attributes: [NSAttributedString.Key: Any] = [.font: lineFont, .foregroundColor: color]
        let textWidth = ceil((text as NSString).size(withAttributes: attributes).width)

        let pxW = Int(textWidth * scale), pxH = Int(box * scale)
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(
                data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns

        (text as NSString).draw(at: NSPoint(x: 0, y: exactBox ? 0 : 1), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return PreparedLine(cg: cg, scale: scale, textWidth: textWidth,
                            pointHeight: box, text: text, color: color)
    }
}

extension NSView {

    var menuBarBitmapScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2
    }
}
