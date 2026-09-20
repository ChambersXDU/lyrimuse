import AppKit

enum MenuBarIconStyle: String, CaseIterable, Codable, Hashable, Identifiable {

    case classic
    case note
    case noteList
    case quarternotes
    case waveform

    case equalizer
    case mic

    case metronome

    case pianokeys

    case tuningfork

    case disc

    case vinyl

    var id: String { rawValue }

    static let `default`: MenuBarIconStyle = .classic

    var displayName: String {
        switch self {
        case .note: return L10n.t("音符")
        case .noteList: return L10n.t("歌词列表")
        case .quarternotes: return L10n.t("三连音符")
        case .waveform: return L10n.t("声波")
        case .equalizer: return L10n.t("跳动音条")
        case .mic: return L10n.t("麦克风")
        case .metronome: return L10n.t("节拍器")
        case .pianokeys: return L10n.t("钢琴键")
        case .tuningfork: return L10n.t("音叉")
        case .disc: return L10n.t("光盘")
        case .vinyl: return L10n.t("黑胶唱片")
        case .classic: return L10n.t("经典")
        }
    }

    private static let pointSize: CGFloat = 15

    @MainActor
    static func cachedImage(for style: MenuBarIconStyle) -> NSImage {
        if let hit = cache[style] { return hit }
        let built = style.makeImage()
        cache[style] = built
        return built
    }

    @MainActor private static var cache: [MenuBarIconStyle: NSImage] = [:]

    func makeImage() -> NSImage {
        let image: NSImage? = {
            switch self {
            case .note: return Self.symbol("music.note")
            case .noteList: return Self.symbol("music.note.list")
            case .quarternotes: return Self.symbol("music.quarternote.3")
            case .waveform: return Self.symbol("waveform")

            case .equalizer: return Self.equalizerImage(heights: [0.55, 0.85, 0.40])
            case .mic: return Self.symbol("music.mic")
            case .metronome: return Self.metronomeArtwork()
            case .pianokeys: return Self.pianoKeysArtwork()
            case .tuningfork: return Self.symbol("tuningfork")
            case .disc: return Self.discArtwork()
            case .vinyl: return Self.vinylArtwork()
            case .classic: return Self.classicArtwork()
            }
        }()
        let result = image ?? NSImage(size: NSSize(width: 16, height: 16))
        result.isTemplate = true
        return result
    }

    static let classicCanvas = NSSize(width: 20.5, height: 14)

    static let classicLines: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
        (9.2, 10.9, 7.4), (5.7, 7.8, 10.5), (2.2, 7.8, 10.5),
    ]
    static let classicLineHeight: CGFloat = 1.9
    static let classicLineRightEdge: CGFloat = 18.3

    private static func classicNote(expand: CGFloat) {
        guard let ctx = NSGraphicsContext.current else { return }

        ctx.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: 3.3, yBy: 3.0)
        t.rotate(byRadians: -0.32)
        t.concat()
        NSBezierPath(ovalIn: NSRect(x: -3.0 - expand, y: -2.15 - expand,
                                    width: 6.0 + expand * 2, height: 4.3 + expand * 2)).fill()
        ctx.restoreGraphicsState()

        NSBezierPath(rect: NSRect(x: 5.35 - expand, y: 3.0 - expand,
                                  width: 1.55 + expand * 2, height: 10.3 + expand * 2)).fill()

        ctx.saveGraphicsState()
        let f = NSAffineTransform()
        f.translateX(by: 6.9, yBy: 12.6)
        f.rotate(byRadians: -0.55)
        f.concat()
        NSBezierPath(roundedRect: NSRect(x: -0.4 - expand, y: -0.8 - expand,
                                         width: 3.4 + expand * 2, height: 1.65 + expand * 2),
                     xRadius: 0.8 + expand, yRadius: 0.8 + expand).fill()
        ctx.restoreGraphicsState()
    }

    static func classicNoteArtwork() -> NSImage {
        let image = NSImage(size: classicCanvas, flipped: false) { _ in
            NSColor.black.setFill()
            classicNote(expand: 0)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func classicLinesMaskArtwork() -> NSImage {
        NSImage(size: classicCanvas, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current else { return true }
            NSColor.black.setFill()
            rect.fill()
            ctx.compositingOperation = .destinationOut
            classicNote(expand: 1.1)
            ctx.compositingOperation = .sourceOver
            return true
        }
    }

    private static func classicArtwork() -> NSImage? {
        NSImage(size: classicCanvas, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return true }
            NSColor.black.setFill()

            for l in classicLines {
                NSBezierPath(roundedRect: NSRect(x: l.x, y: l.y - classicLineHeight / 2,
                                                 width: l.w, height: classicLineHeight),
                             xRadius: 0.6, yRadius: 0.6).fill()
            }

            ctx.compositingOperation = .destinationOut
            classicNote(expand: 1.1)

            ctx.compositingOperation = .sourceOver
            classicNote(expand: 0)
            return true
        }
    }

    private static func symbol(_ name: String, pointSize: CGFloat = MenuBarIconStyle.pointSize) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    static let metronomeCanvas = NSSize(width: 14, height: 15)

    static let metronomePivot = NSPoint(x: 7, y: 2.0)
    static let metronomeNeedleSize = NSSize(width: 6, height: 11)

    static let metronomeNeedlePivotInImage = NSPoint(x: 3, y: 0.6)

    static func metronomeBodyArtwork() -> NSImage {
        let image = NSImage(size: metronomeCanvas, flipped: false) { _ in
            NSColor.black.setStroke()
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 1.4, y: 0.7))
            body.line(to: NSPoint(x: 5.1, y: 14.3))
            body.line(to: NSPoint(x: 8.9, y: 14.3))
            body.line(to: NSPoint(x: 12.6, y: 0.7))
            body.close()
            body.lineWidth = 1.2
            body.lineJoinStyle = .round
            body.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func metronomeNeedleArtwork() -> NSImage {
        let image = NSImage(size: metronomeNeedleSize, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let needle = NSBezierPath()
            needle.move(to: metronomeNeedlePivotInImage)
            needle.line(to: NSPoint(x: metronomeNeedlePivotInImage.x, y: 10.4))
            needle.lineWidth = 1.1
            needle.lineCapStyle = .round
            needle.stroke()

            NSBezierPath(roundedRect: NSRect(x: metronomeNeedlePivotInImage.x - 1.2, y: 6.8,
                                             width: 2.4, height: 1.7),
                         xRadius: 0.6, yRadius: 0.6).fill()

            NSBezierPath(ovalIn: NSRect(x: metronomeNeedlePivotInImage.x - 0.9,
                                        y: metronomeNeedlePivotInImage.y - 0.9,
                                        width: 1.8, height: 1.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func metronomeArtwork() -> NSImage {
        let image = NSImage(size: metronomeCanvas, flipped: false) { _ in
            metronomeBodyArtwork().draw(in: NSRect(origin: .zero, size: metronomeCanvas))
            guard let ctx = NSGraphicsContext.current else { return true }
            ctx.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: metronomePivot.x, yBy: metronomePivot.y)
            t.rotate(byRadians: 0.22)
            t.translateX(by: -metronomePivot.x, yBy: -metronomePivot.y)
            t.concat()
            metronomeNeedleArtwork().draw(
                in: NSRect(x: metronomePivot.x - metronomeNeedlePivotInImage.x,
                           y: metronomePivot.y - metronomeNeedlePivotInImage.y,
                           width: metronomeNeedleSize.width, height: metronomeNeedleSize.height))
            ctx.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }

    static let pianoCanvas = NSSize(width: 16, height: 12.5)

    static let pianoPressRects: [NSRect] = {
        let edges: [CGFloat] = [0.6, 4.45, 8.3, 12.15, 15.4]
        return (0 ..< 4).map { i in
            NSRect(x: edges[i] + 0.9, y: 1.4,
                   width: edges[i + 1] - edges[i] - 1.8, height: 4.1)
        }
    }()

    static func pianoKeysArtwork() -> NSImage {
        let image = NSImage(size: pianoCanvas, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6),
                                     xRadius: 2.2, yRadius: 2.2)
            frame.lineWidth = 1.2
            frame.stroke()
            for x in [4.45, 8.3, 12.15] as [CGFloat] {

                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: x, y: 0.6))
                divider.line(to: NSPoint(x: x, y: 6.8))
                divider.lineWidth = 0.8
                divider.stroke()

                NSBezierPath(roundedRect: NSRect(x: x - 1.2, y: 6.8, width: 2.4, height: 5.1),
                             xRadius: 0.7, yRadius: 0.7).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func discArtwork() -> NSImage {

        let s: CGFloat = 15.5
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            NSColor.black.setStroke()
            let c = s / 2
            let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            edge.lineWidth = 1.2
            edge.stroke()
            let hole = NSBezierPath(ovalIn: NSRect(x: c - 2.5, y: c - 2.5, width: 5.0, height: 5.0))
            hole.lineWidth = 1.0
            hole.stroke()

            for angle in [CGFloat.pi * 0.32, CGFloat.pi * 1.32] {
                let sheen = NSBezierPath()
                sheen.move(to: NSPoint(x: c + cos(angle) * 3.5, y: c + sin(angle) * 3.5))
                sheen.line(to: NSPoint(x: c + cos(angle) * 6.0, y: c + sin(angle) * 6.0))
                sheen.lineWidth = 1.5
                sheen.lineCapStyle = .round
                sheen.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static let vinylCanvas = NSSize(width: 16.6, height: 15)
    static let vinylDiscSide: CGFloat = 14.4

    static let vinylDiscCenter = NSPoint(x: 7.2, y: 7.4)

    static func vinylDiscArtwork() -> NSImage {
        let s = vinylDiscSide
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let full = rect.insetBy(dx: 0.6, dy: 0.6)
            let rim = NSBezierPath(ovalIn: full)
            rim.lineWidth = 1.2
            rim.stroke()
            let groove = NSBezierPath(ovalIn: full.insetBy(dx: 2.4, dy: 2.4))
            groove.lineWidth = 0.75
            groove.stroke()

            NSBezierPath(ovalIn: full.insetBy(dx: 4.4, dy: 4.4)).fill()

            let c = s / 2
            let r = s / 2 - 1.7
            let a = CGFloat.pi * 0.28
            NSBezierPath(ovalIn: NSRect(x: c + cos(a) * r - 0.85, y: c + sin(a) * r - 0.85,
                                        width: 1.7, height: 1.7)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func vinylArmArtwork() -> NSImage {
        let image = NSImage(size: vinylCanvas, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let pivot = NSPoint(x: 14.5, y: 12.9)
            let arm = NSBezierPath()
            arm.move(to: pivot)
            arm.line(to: NSPoint(x: 10.7, y: 8.0))
            arm.lineWidth = 1.35
            arm.lineCapStyle = .round
            arm.stroke()
            NSBezierPath(ovalIn: NSRect(x: pivot.x - 1.4, y: pivot.y - 1.4,
                                        width: 2.8, height: 2.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func vinylArtwork() -> NSImage {
        NSImage(size: vinylCanvas, flipped: false) { _ in
            vinylDiscArtwork().draw(in: NSRect(x: vinylDiscCenter.x - vinylDiscSide / 2,
                                               y: vinylDiscCenter.y - vinylDiscSide / 2,
                                               width: vinylDiscSide, height: vinylDiscSide))
            vinylArmArtwork().draw(in: NSRect(origin: .zero, size: vinylCanvas))
            return true
        }
    }

    private static func equalizerImage(heights: [CGFloat]) -> NSImage {
        let canvas = NSSize(width: pointSize * 0.80, height: pointSize * 0.90)
        let barWidth = canvas.width * 0.22
        let gap = (canvas.width - barWidth * CGFloat(heights.count)) / CGFloat(heights.count - 1)
        return NSImage(size: canvas, flipped: false) { _ in
            NSColor.black.setFill()
            for (i, ratio) in heights.enumerated() {
                let h = max(barWidth, canvas.height * ratio)
                let box = NSRect(x: CGFloat(i) * (barWidth + gap), y: 0,
                                 width: barWidth, height: h)
                NSBezierPath(roundedRect: box,
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
    }

}
