import AppKit
import QuartzCore

@MainActor
final class MenuBarLiveIconView: NSView {
    private static let animationKey = "lyrimuse.liveicon"

    private var currentStyle: MenuBarIconStyle?
    private var highlighted = false

    private let imageView = NSImageView()
    private var equalizerBars: [CALayer] = []

    private let movingPart = CALayer()

    private let staticPart = CALayer()

    private var pressKeys: [CALayer] = []

    private let classicLinesHost = CALayer()
    private var classicLineBars: [CALayer] = []
    private let classicLinesMask = CALayer()

    static let equalizerGlyphSize = NSSize(width: 12, height: 13.5)
    private static let barWidth: CGFloat = equalizerGlyphSize.width * 0.22
    private static let barGap: CGFloat = (equalizerGlyphSize.width - barWidth * 3) / 2
    private static let barPhases: [Double] = [0.0, 2.1, 4.2]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        imageView.imageScaling = .scaleNone
        imageView.isHidden = true

        imageView.wantsLayer = true
        imageView.layer?.allowsEdgeAntialiasing = true
        addSubview(imageView)
        for _ in 0 ..< 3 {
            equalizerBars.append(Self.roundedBar(width: Self.barWidth))
        }
        equalizerBars.forEach {
            $0.isHidden = true
            layer?.addSublayer($0)
        }
        for _ in 0 ..< 4 {
            let key = CALayer()
            key.cornerRadius = 1.0
            key.opacity = 0
            pressKeys.append(key)
        }
        for _ in 0 ..< 3 {
            let bar = CALayer()

            bar.anchorPoint = CGPoint(x: 1, y: 0.5)
            bar.cornerRadius = 0.95
            classicLineBars.append(bar)
            classicLinesHost.addSublayer(bar)
        }
        classicLinesHost.mask = classicLinesMask

        for l in [movingPart, classicLinesHost, staticPart] + pressKeys {
            l.isHidden = true
            layer?.addSublayer(l)
        }
        applyColor()
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不使用") }

    private static func roundedBar(width: CGFloat) -> CALayer {
        let bar = CALayer()
        bar.anchorPoint = .zero
        bar.cornerRadius = width / 2
        return bar
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func present(style: MenuBarIconStyle) {
        isHidden = false
        guard style != currentStyle else { return }
        teardown()
        currentStyle = style
        switch style {
        case .equalizer: buildEqualizer()
        case .waveform: buildWaveform()
        case .metronome: buildMetronome()
        case .pianokeys: buildPianoKeys()
        case .tuningfork: buildVibrate()
        case .disc: buildDisc()
        case .vinyl: buildVinyl()
        case .classic: buildClassicStretch()
        default: buildSway(style)
        }
        needsLayout = true
    }

    func clear() {
        guard currentStyle != nil || !isHidden else { return }
        teardown()
        currentStyle = nil
        isHidden = true
    }

    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        applyColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private var lastBitmapScale: CGFloat = 0

    private func setTinted(_ target: CALayer, _ image: NSImage) {
        let scale = menuBarBitmapScale
        target.contentsScale = scale
        target.contents = tintedContents(image, scale: scale)
        lastBitmapScale = scale
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        retintIfScaleChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        retintIfScaleChanged()
    }

    private func retintIfScaleChanged() {
        guard currentStyle != nil, lastBitmapScale != 0, lastBitmapScale != menuBarBitmapScale else { return }
        if currentStyle == .classic {
            setTinted(classicLinesMask, MenuBarIconStyle.classicLinesMaskArtwork())
        }
        applyColor()
    }

    private func teardown() {
        imageView.removeAllSymbolEffects()
        imageView.layer?.removeAnimation(forKey: Self.animationKey)
        imageView.image = nil
        imageView.isHidden = true
        for bar in equalizerBars + [movingPart, staticPart, classicLinesHost] + pressKeys + classicLineBars {
            bar.removeAnimation(forKey: Self.animationKey)
            bar.isHidden = true
        }

        movingPart.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    private func buildEqualizer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in equalizerBars.enumerated() {
            bar.isHidden = false
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth,
                                height: Self.equalizerGlyphSize.height * 0.5)
            bar.add(Self.sampledAnimation(keyPath: "bounds.size.height", duration: 1.2) { t in

                let a = 2 * Double.pi * t
                let raw = 0.55 + 0.30 * sin(a + Self.barPhases[i]) + 0.12 * sin(2 * a + Self.barPhases[i] * 1.7)
                return Self.equalizerGlyphSize.height * CGFloat(min(0.97, max(0.20, raw)))
            }, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }

    private func buildWaveform() {
        imageView.isHidden = false
        imageView.image = MenuBarIconStyle.cachedImage(for: .waveform)
        applyColor()

        if #available(macOS 15.0, *) {
            imageView.addSymbolEffect(.variableColor.iterative, options: .repeat(.continuous))
        } else {
            imageView.addSymbolEffect(.variableColor.iterative, options: .repeating)
        }
    }

    private func buildSway(_ style: MenuBarIconStyle) {
        imageView.isHidden = false
        imageView.image = MenuBarIconStyle.cachedImage(for: style)
        applyColor()

        imageView.layer?.add(
            Self.sampledAnimation(keyPath: "transform.rotation.z", duration: 1.6) { t in
                CGFloat(sin(2 * Double.pi * t) * 0.09)
            }, forKey: Self.animationKey)
    }

    private func buildMetronome() {
        staticPart.isHidden = false
        movingPart.isHidden = false
        staticPart.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.metronomeCanvas)
        let needleSize = MenuBarIconStyle.metronomeNeedleSize
        let pivot = MenuBarIconStyle.metronomeNeedlePivotInImage
        movingPart.bounds = CGRect(origin: .zero, size: needleSize)
        movingPart.anchorPoint = CGPoint(x: pivot.x / needleSize.width,
                                         y: pivot.y / needleSize.height)
        applyColor()
        movingPart.add(Self.sampledAnimation(keyPath: "transform.rotation.z", duration: 1.1) { t in
            CGFloat(sin(2 * Double.pi * t) * 0.30)
        }, forKey: Self.animationKey)
    }

    private func buildPianoKeys() {
        staticPart.isHidden = false
        staticPart.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.pianoCanvas)
        applyColor()
        let order: [Int] = [0, 2, 1, 3]
        let period = 1.8
        for (slot, keyIndex) in order.enumerated() {
            let key = pressKeys[keyIndex]
            key.isHidden = false
            key.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.pianoPressRects[keyIndex].size)

            let s0 = Double(slot) * 0.25
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0, 0, 1, 1, 0, 0]
            animation.keyTimes = [0, NSNumber(value: s0), NSNumber(value: s0 + 0.04),
                                  NSNumber(value: s0 + 0.16), NSNumber(value: s0 + 0.23), 1]
            animation.duration = period
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            key.add(animation, forKey: Self.animationKey)
        }
    }

    private func buildVibrate() {
        imageView.isHidden = false
        imageView.image = MenuBarIconStyle.cachedImage(for: .tuningfork)
        applyColor()
        imageView.layer?.add(
            Self.sampledAnimation(keyPath: "transform.translation.x", duration: 0.18) { t in
                CGFloat(sin(2 * Double.pi * t) * 0.6)
            }, forKey: Self.animationKey)
    }

    private func buildDisc() {
        movingPart.isHidden = false
        movingPart.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.cachedImage(for: .disc).size)
        applyColor()
        movingPart.add(Self.spinAnimation(secondsPerTurn: 4.0), forKey: Self.animationKey)
    }

    private func buildVinyl() {
        movingPart.isHidden = false
        staticPart.isHidden = false
        movingPart.bounds = CGRect(x: 0, y: 0, width: MenuBarIconStyle.vinylDiscSide,
                                   height: MenuBarIconStyle.vinylDiscSide)
        staticPart.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.vinylCanvas)
        applyColor()
        movingPart.add(Self.spinAnimation(secondsPerTurn: 3.2), forKey: Self.animationKey)
    }

    private func buildClassicStretch() {
        staticPart.isHidden = false
        staticPart.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.classicCanvas)
        classicLinesHost.isHidden = false
        classicLinesHost.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.classicCanvas)
        if classicLinesMask.contents == nil {

            classicLinesMask.frame = classicLinesHost.bounds
            setTinted(classicLinesMask, MenuBarIconStyle.classicLinesMaskArtwork())
        }
        applyColor()
        for (i, bar) in classicLineBars.enumerated() {
            let line = MenuBarIconStyle.classicLines[i]
            bar.isHidden = false
            bar.bounds = CGRect(x: 0, y: 0, width: line.w, height: MenuBarIconStyle.classicLineHeight)

            bar.position = CGPoint(x: MenuBarIconStyle.classicLineRightEdge, y: line.y)
            let phase = Double(i) * 1.03
            bar.add(Self.sampledAnimation(keyPath: "bounds.size.width", duration: 1.4) { t in
                line.w * CGFloat(0.86 + 0.14 * sin(2 * Double.pi * t + phase))
            }, forKey: Self.animationKey)
        }
    }

    private static func spinAnimation(secondsPerTurn: TimeInterval) -> CABasicAnimation {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0

        spin.toValue = -2 * Double.pi
        spin.duration = secondsPerTurn
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        return spin
    }

    private static func sampledAnimation(
        keyPath: String, duration: TimeInterval, curve: (Double) -> CGFloat
    ) -> CAKeyframeAnimation {
        let samples = 48
        let animation = CAKeyframeAnimation(keyPath: keyPath)

        animation.values = (0 ... samples).map { curve(Double($0 % samples) / Double(samples)) }
        animation.keyTimes = (0 ... samples).map { NSNumber(value: Double($0) / Double(samples)) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch currentStyle {
        case .equalizer:
            let x0 = ((bounds.width - Self.equalizerGlyphSize.width) / 2).rounded()
            let y0 = ((bounds.height - Self.equalizerGlyphSize.height) / 2).rounded()
            for (i, bar) in equalizerBars.enumerated() {

                bar.position = CGPoint(x: x0 + CGFloat(i) * (Self.barWidth + Self.barGap), y: y0)
            }
        case .vinyl:
            let canvas = MenuBarIconStyle.vinylCanvas
            let x0 = ((bounds.width - canvas.width) / 2).rounded()
            let y0 = ((bounds.height - canvas.height) / 2).rounded()

            staticPart.position = CGPoint(x: x0 + canvas.width / 2, y: y0 + canvas.height / 2)
            movingPart.position = CGPoint(x: x0 + MenuBarIconStyle.vinylDiscCenter.x,
                                          y: y0 + MenuBarIconStyle.vinylDiscCenter.y)
        case .disc:
            movingPart.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        case .metronome:
            let canvas = MenuBarIconStyle.metronomeCanvas
            let x0 = ((bounds.width - canvas.width) / 2).rounded()
            let y0 = ((bounds.height - canvas.height) / 2).rounded()
            staticPart.position = CGPoint(x: x0 + canvas.width / 2, y: y0 + canvas.height / 2)

            movingPart.position = CGPoint(x: x0 + MenuBarIconStyle.metronomePivot.x,
                                          y: y0 + MenuBarIconStyle.metronomePivot.y)
        case .pianokeys:
            let canvas = MenuBarIconStyle.pianoCanvas
            let x0 = ((bounds.width - canvas.width) / 2).rounded()
            let y0 = ((bounds.height - canvas.height) / 2).rounded()
            staticPart.position = CGPoint(x: x0 + canvas.width / 2, y: y0 + canvas.height / 2)
            for (i, rect) in MenuBarIconStyle.pianoPressRects.enumerated() {
                pressKeys[i].position = CGPoint(x: x0 + rect.midX, y: y0 + rect.midY)
            }
        case .classic:
            let canvas = MenuBarIconStyle.classicCanvas
            let x0 = ((bounds.width - canvas.width) / 2).rounded()
            let y0 = ((bounds.height - canvas.height) / 2).rounded()
            let center = CGPoint(x: x0 + canvas.width / 2, y: y0 + canvas.height / 2)
            staticPart.position = center
            classicLinesHost.position = center
        default:
            if let image = imageView.image {
                imageView.frame = NSRect(
                    x: ((bounds.width - image.size.width) / 2).rounded(),
                    y: ((bounds.height - image.size.height) / 2).rounded(),
                    width: image.size.width, height: image.size.height)
            }
        }
        CATransaction.commit()
    }

    private var tintColor: NSColor {
        highlighted ? .selectedMenuItemTextColor : .labelColor
    }

    private func applyColor() {

        var solid = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            solid = self.tintColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        equalizerBars.forEach { $0.backgroundColor = solid }

        switch currentStyle {
        case .vinyl:
            setTinted(movingPart, MenuBarIconStyle.vinylDiscArtwork())
            setTinted(staticPart, MenuBarIconStyle.vinylArmArtwork())
        case .disc:
            setTinted(movingPart, MenuBarIconStyle.discArtwork())
        case .metronome:
            setTinted(movingPart, MenuBarIconStyle.metronomeNeedleArtwork())
            setTinted(staticPart, MenuBarIconStyle.metronomeBodyArtwork())
        case .pianokeys:
            setTinted(staticPart, MenuBarIconStyle.pianoKeysArtwork())
            pressKeys.forEach { $0.backgroundColor = solid }
        case .classic:
            setTinted(staticPart, MenuBarIconStyle.classicNoteArtwork())
            classicLineBars.forEach { $0.backgroundColor = solid }
        default:
            break
        }
        CATransaction.commit()
        imageView.contentTintColor = tintColor
    }

    private func tintedContents(_ image: NSImage, scale: CGFloat) -> CGImage? {
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        effectiveAppearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: image.size))
            self.tintColor.set()
            NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
