import AppKit
import LyrimuseCore
import QuartzCore
import SwiftUI

@MainActor
final class MenuBarScrollingLabel: NSView {
    private static let scrollAnimationKey = "lyrimuse.marquee"
    private static let fillAnimationKey = "lyrimuse.karaoke-fill"
    private static let basePositionAnimationKey = "lyrimuse.karaoke-base-pos"
    private static let baseBoundsAnimationKey = "lyrimuse.karaoke-base-bounds"
    private static let iconFillAnimationKey = "lyrimuse.progress-fill"
    private static let iconBasePositionAnimationKey = "lyrimuse.progress-base-pos"
    private static let iconBaseBoundsAnimationKey = "lyrimuse.progress-base-bounds"

    private let clipLayer = CALayer()
    private let contentLayer = CALayer()
    private let baseClipLayer = CALayer()
    private let textLayer = CALayer()
    private let fillClipLayer = CALayer()
    private let fillTextLayer = CALayer()
    private let iconHostLayer = CALayer()
    private let iconBaseClipLayer = CALayer()
    private let iconBaseLayer = CALayer()
    private let iconFillClipLayer = CALayer()
    private let iconFillLayer = CALayer()
    private let secondaryClipLayer = CALayer()
    private let secondaryTextLayer = CALayer()

    private let secondaryFadeMask = CAGradientLayer()

    struct IconBadge: Equatable {
        let style: MenuBarIconStyle

        let position: MenuBarLyricsIconPosition
    }

    private struct Plan: Equatable {
        var text: String
        var windowWidth: CGFloat

        var alignment: LyricsRestingAlignment

        var fontWeight: OverlayFontWeight

        var fontSize: CGFloat

        var pacing: MenuBarMarquee.ScrollPacing?

        var fillPath: [MenuBarMarquee.KaraokeFillPoint]?

        var followPath: [MenuBarMarquee.KaraokeFillPoint]?

        var icon: IconBadge?

        var secondaryText: String?

        var secondaryKind: LyricSecondaryLine
    }

    private var plan: Plan?
    private var prepared: MenuBarMarqueeRenderer.PreparedLine?

    private var preparedSecondary: MenuBarMarqueeRenderer.PreparedLine?
    private var highlighted = false

    private struct KaraokeClock {
        let baseMs: Int
        let rate: Double
        let playing: Bool
        let capturedAt: Date

        func positionMs(at date: Date = Date()) -> Int {
            guard playing, rate > 0 else { return baseMs }
            return baseMs + Int(date.timeIntervalSince(capturedAt) * 1000 * rate)
        }
    }

    private var karaokeClock: KaraokeClock?

    private struct ProgressClock {
        let baseMs: Int
        let durationMs: Int
        let rate: Double
        let playing: Bool
        let capturedAt: Date

        func positionMs(at date: Date = Date()) -> Int {
            guard playing, rate > 0 else { return baseMs }
            return baseMs + Int(date.timeIntervalSince(capturedAt) * 1000 * rate)
        }
    }

    private var progressClock: ProgressClock?

    private var preparedIcon: (base: MenuBarProgressIcon.Prepared,
                               fill: MenuBarProgressIcon.Prepared)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        clipLayer.masksToBounds = true

        layer?.masksToBounds = true

        clipLayer.anchorPoint = .zero
        contentLayer.anchorPoint = .zero
        baseClipLayer.anchorPoint = .zero
        textLayer.anchorPoint = .zero
        fillClipLayer.anchorPoint = .zero
        fillTextLayer.anchorPoint = .zero
        baseClipLayer.masksToBounds = true
        fillClipLayer.masksToBounds = true
        baseClipLayer.addSublayer(textLayer)
        contentLayer.addSublayer(baseClipLayer)
        fillClipLayer.addSublayer(fillTextLayer)
        contentLayer.addSublayer(fillClipLayer)
        clipLayer.addSublayer(contentLayer)
        layer?.addSublayer(clipLayer)

        for l in [iconHostLayer, iconBaseClipLayer, iconBaseLayer, iconFillClipLayer, iconFillLayer] {
            l.anchorPoint = .zero
        }
        iconBaseClipLayer.masksToBounds = true
        iconFillClipLayer.masksToBounds = true
        iconHostLayer.isHidden = true
        iconBaseClipLayer.addSublayer(iconBaseLayer)
        iconHostLayer.addSublayer(iconBaseClipLayer)
        iconFillClipLayer.addSublayer(iconFillLayer)
        iconHostLayer.addSublayer(iconFillClipLayer)
        layer?.addSublayer(iconHostLayer)

        for l in [secondaryClipLayer, secondaryTextLayer, secondaryFadeMask] { l.anchorPoint = .zero }
        secondaryClipLayer.masksToBounds = true
        secondaryClipLayer.isHidden = true
        secondaryClipLayer.addSublayer(secondaryTextLayer)
        layer?.addSublayer(secondaryClipLayer)

        secondaryFadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        secondaryFadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        secondaryFadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不使用") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func present(text: String, windowWidth: CGFloat, pacing: MenuBarMarquee.ScrollPacing?,
                 fillPath: [MenuBarMarquee.KaraokeFillPoint]? = nil,
                 followPath: [MenuBarMarquee.KaraokeFillPoint]? = nil,
                 icon: IconBadge? = nil,
                 secondaryText: String? = nil,
                 secondaryKind: LyricSecondaryLine = .off) {
        let next = Plan(text: text, windowWidth: windowWidth,
                        alignment: AppSettings.shared.menuBarLyricsAlignment,
                        fontWeight: AppSettings.shared.menuBarLyricsFontWeight,
                        fontSize: AppSettings.shared.menuBarLyricsFontSize,
                        pacing: pacing, fillPath: fillPath, followPath: followPath, icon: icon,
                        secondaryText: secondaryText, secondaryKind: secondaryKind)
        guard next != plan else {
            isHidden = false
            return
        }

        let bitmapsUnchanged = prepared != nil && plan?.text == next.text
            && (plan?.fillPath != nil) == (next.fillPath != nil)
            && plan?.icon == next.icon
            && plan?.fontWeight == next.fontWeight
            && plan?.fontSize == next.fontSize

            && plan?.secondaryText == next.secondaryText
            && plan?.secondaryKind == next.secondaryKind

        let scrollUnchanged = prepared != nil && (plan.map {
            $0.text == next.text && $0.windowWidth == next.windowWidth && $0.pacing == next.pacing
                && $0.followPath == next.followPath
                && $0.fontWeight == next.fontWeight && $0.fontSize == next.fontSize

                && $0.secondaryKind.showsSecondaryRow == next.secondaryKind.showsSecondaryRow
        } ?? false)
        plan = next
        isHidden = false
        if !bitmapsUnchanged { rebuildImage() }

        if !scrollUnchanged || contentLayer.animation(forKey: Self.scrollAnimationKey) == nil {
            restartAnimation()
        }

        applyKaraokeFill()

        applyProgressFill()
        needsLayout = true
    }

    func updateKaraokeClock(positionMs: Int?, rate: Double, playing: Bool, force: Bool = false) {
        guard let positionMs else {
            karaokeClock = nil
            applyKaraokeFill()
            applyFollowScroll()
            return
        }
        let next = KaraokeClock(baseMs: positionMs, rate: rate, playing: playing, capturedAt: Date())
        if !force, playing, let old = karaokeClock, old.playing, old.rate == rate,
           hasClockDrivenAnimation,
           abs(old.positionMs() - positionMs) < 250 {
            karaokeClock = next
            return
        }
        karaokeClock = next
        applyKaraokeFill()
        applyFollowScroll()
    }

    private var hasClockDrivenAnimation: Bool {
        fillClipLayer.animation(forKey: Self.fillAnimationKey) != nil
            || (plan?.followPath != nil
                && contentLayer.animation(forKey: Self.scrollAnimationKey) != nil)
    }

    func updateProgressClock(positionMs: Int?, durationMs: Int?, rate: Double, playing: Bool,
                             force: Bool = false) {
        guard let positionMs, let durationMs, durationMs > 0 else {
            progressClock = nil
            applyProgressFill()
            return
        }
        let next = ProgressClock(baseMs: positionMs, durationMs: durationMs, rate: rate,
                                 playing: playing, capturedAt: Date())
        if !force, playing, let old = progressClock, old.playing, old.rate == rate,
           old.durationMs == durationMs,
           iconFillClipLayer.animation(forKey: Self.iconFillAnimationKey) != nil,
           abs(old.positionMs() - positionMs) < 1000 {
            progressClock = next
            return
        }
        progressClock = next
        applyProgressFill()
    }

    func clear() {
        guard plan != nil || !isHidden else { return }
        plan = nil
        prepared = nil
        contentLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        fillClipLayer.removeAnimation(forKey: Self.fillAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.basePositionAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.baseBoundsAnimationKey)

        iconFillClipLayer.removeAnimation(forKey: Self.iconFillAnimationKey)
        iconBaseClipLayer.removeAnimation(forKey: Self.iconBasePositionAnimationKey)
        iconBaseClipLayer.removeAnimation(forKey: Self.iconBaseBoundsAnimationKey)
        preparedIcon = nil
        preparedSecondary = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contents = nil
        fillTextLayer.contents = nil
        fillClipLayer.isHidden = true
        secondaryTextLayer.contents = nil
        secondaryClipLayer.isHidden = true
        iconBaseLayer.contents = nil
        iconFillLayer.contents = nil
        iconHostLayer.isHidden = true
        CATransaction.commit()
        isHidden = true
    }

    func clearLyricsKeepingIcon() {
        guard plan != nil else { return }
        plan = nil
        prepared = nil
        contentLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        fillClipLayer.removeAnimation(forKey: Self.fillAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.basePositionAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.baseBoundsAnimationKey)
        preparedSecondary = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contents = nil
        fillTextLayer.contents = nil
        fillClipLayer.isHidden = true

        secondaryTextLayer.contents = nil
        secondaryClipLayer.isHidden = true
        CATransaction.commit()
    }

    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        rebuildImage()
        applyKaraokeFill()

        applyProgressFill()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildIfScaleChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildIfScaleChanged()
    }

    private func rebuildIfScaleChanged() {
        guard let prepared, prepared.scale != menuBarBitmapScale else { return }
        refreshColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildImage()
    }

    struct ContentGeometry {

        let lyrics: CGRect

        let secondary: CGRect?

        let icon: CGRect?
    }

    func contentGeometry() -> ContentGeometry? {
        guard let plan else { return nil }

        let twoRows = plan.secondaryKind.showsSecondaryRow
        let height = prepared?.pointHeight
            ?? (twoRows ? MenuBarMarqueeRenderer.boxHeight(for: MenuBarMarqueeRenderer.doubleRowMainFont)
                        : MenuBarMarqueeRenderer.lineHeight)
        let rows: MenuBarLyricRows.Layout? = twoRows ? MenuBarLyricRows.layout(
            mainHeight: height,
            secondaryHeight: preparedSecondary?.pointHeight
                ?? MenuBarMarqueeRenderer.boxHeight(for: MenuBarMarqueeRenderer.doubleRowSecondaryFont),
            buttonHeight: bounds.height) : nil

        let iconSize = plan.icon.map { MenuBarProgressIcon.size(of: $0.style) } ?? .zero
        let reserved = MenuBarProgressIcon.reservedWidth(for: plan.icon?.style)

        guard let slot = MenuBarHoverControls.lyricsSlot(
            buttonWidth: bounds.width, contentWidth: plan.windowWidth + reserved,
            reservedIconWidth: reserved, iconLeading: plan.icon?.position == .leading)
        else { return nil }
        let contentW = min(plan.windowWidth + reserved, bounds.width)
        let left = max(0, ((bounds.width - contentW) / 2).rounded())
        let clipW = slot.width
        let y = rows?.mainY ?? ((bounds.height - height) / 2).rounded()
        let lyricsX = slot.x
        let iconX: CGFloat
        switch plan.icon?.position {
        case .leading:
            iconX = left
        case .trailing:
            iconX = left + clipW + MenuBarProgressIcon.gap
        default:
            iconX = 0
        }
        return ContentGeometry(
            lyrics: CGRect(x: lyricsX, y: y, width: clipW, height: height),
            secondary: rows.map { CGRect(x: lyricsX, y: $0.secondaryY, width: clipW, height: $0.secondaryHeight) },

            icon: plan.icon == nil ? nil : CGRect(
                x: iconX, y: ((bounds.height - iconSize.height) / 2).rounded(),
                width: iconSize.width, height: iconSize.height))
    }

    var showsIconBadge: Bool { plan?.icon != nil }

    override func layout() {
        super.layout()
        guard let geometry = contentGeometry() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.frame = geometry.lyrics

        contentLayer.position = CGPoint(x: contentLayer.position.x, y: 0)
        if let secondary = geometry.secondary {
            secondaryClipLayer.frame = secondary
            secondaryClipLayer.isHidden = false
            placeSecondaryText()
        } else {
            secondaryClipLayer.isHidden = true
        }
        if let icon = geometry.icon { iconHostLayer.frame = icon }
        CATransaction.commit()
    }

    private func placeSecondaryText() {
        guard let plan, let built = preparedSecondary else {
            secondaryClipLayer.mask = nil
            return
        }
        let clipW = secondaryClipLayer.bounds.width
        let slack = clipW - built.textWidth
        let x: CGFloat
        if slack >= 0 {
            switch plan.alignment {

            case .leading, .automatic: x = 0
            case .center: x = (slack / 2).rounded()
            case .trailing: x = slack.rounded()
            }
            secondaryClipLayer.mask = nil
        } else {
            x = 0
            let fade = min(MenuBarLyricRows.tailFadeWidth, clipW)
            secondaryFadeMask.frame = secondaryClipLayer.bounds
            secondaryFadeMask.locations = [
                0, NSNumber(value: Double(clipW > 0 ? (clipW - fade) / clipW : 1)), 1,
            ]
            secondaryClipLayer.mask = secondaryFadeMask
        }
        secondaryTextLayer.position = CGPoint(x: x, y: 0)
    }

    static func textColor(hex: String, highlighted: Bool) -> NSColor {

        if highlighted { return .selectedMenuItemTextColor }
        guard !hex.isEmpty else { return .labelColor }
        return NSColor(Color(hexWithAlpha: hex, fallback: Color(nsColor: .labelColor)))
    }

    static func fillColor(hex: String, darkMenuBar: Bool) -> NSColor {
        if !hex.isEmpty {
            return NSColor(Color(hexWithAlpha: hex, fallback: Color(nsColor: .controlAccentColor)))
        }
        let accent = NSColor.controlAccentColor
        guard darkMenuBar else { return accent }
        return accent.blended(withFraction: 0.4, of: .white) ?? accent
    }

    private var tintColor: NSColor {
        Self.textColor(hex: AppSettings.shared.menuBarLyricsTextColorHex, highlighted: highlighted)
    }

    private var karaokeFillColor: NSColor {
        Self.fillColor(
            hex: AppSettings.shared.menuBarLyricsFillColorHex,
            darkMenuBar: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    func refreshColors() {
        rebuildImage()
        applyKaraokeFill()
        applyProgressFill()
    }

    private func rebuildImage() {
        guard let plan else { return }
        let color = tintColor

        let scale = menuBarBitmapScale
        var built: MenuBarMarqueeRenderer.PreparedLine?
        var fillBuilt: MenuBarMarqueeRenderer.PreparedLine?
        var secondaryBuilt: MenuBarMarqueeRenderer.PreparedLine?
        var iconBase: MenuBarProgressIcon.Prepared?
        var iconFill: MenuBarProgressIcon.Prepared?

        let twoRows = plan.secondaryKind.showsSecondaryRow
        let mainFont = MenuBarMarqueeRenderer.mainFont(for: plan.text, twoRows: twoRows)

        effectiveAppearance.performAsCurrentDrawingAppearance {
            built = MenuBarMarqueeRenderer.prepare(text: plan.text, color: color, scale: scale,
                                                   font: mainFont, exactBox: twoRows)
            if plan.fillPath != nil {
                fillBuilt = MenuBarMarqueeRenderer.prepare(text: plan.text, color: karaokeFillColor,
                                                           scale: scale, font: mainFont, exactBox: twoRows)
            }
            if twoRows, let secondary = plan.secondaryText {
                secondaryBuilt = MenuBarMarqueeRenderer.prepare(
                    text: secondary, color: color, scale: scale,
                    font: MenuBarMarqueeRenderer.doubleRowSecondaryFont, exactBox: true)
            }

            if let icon = plan.icon {
                iconBase = MenuBarProgressIcon.tinted(style: icon.style, color: color, scale: scale)
                iconFill = MenuBarProgressIcon.tinted(style: icon.style, color: karaokeFillColor,
                                                      scale: scale)
            }
        }
        guard let built else {

            isHidden = true
            return
        }
        prepared = built
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contents = built.cg
        textLayer.contentsScale = built.scale

        textLayer.bounds = CGRect(x: 0, y: 0, width: built.textWidth, height: built.pointHeight)
        if let fillBuilt {
            fillTextLayer.contents = fillBuilt.cg
            fillTextLayer.contentsScale = fillBuilt.scale
            fillTextLayer.bounds = CGRect(x: 0, y: 0, width: fillBuilt.textWidth,
                                          height: fillBuilt.pointHeight)

            fillClipLayer.bounds.size.height = fillBuilt.pointHeight
        } else {
            fillTextLayer.contents = nil
        }
        preparedSecondary = secondaryBuilt
        if let secondaryBuilt {
            secondaryTextLayer.contents = secondaryBuilt.cg
            secondaryTextLayer.contentsScale = secondaryBuilt.scale
            secondaryTextLayer.bounds = CGRect(x: 0, y: 0, width: secondaryBuilt.textWidth,
                                               height: secondaryBuilt.pointHeight)
            secondaryTextLayer.opacity = MenuBarLyricRows.secondaryOpacity(for: plan.secondaryKind)
        } else {
            secondaryTextLayer.contents = nil
        }

        if let iconBase, let iconFill {
            preparedIcon = (iconBase, iconFill)
            iconBaseLayer.contents = iconBase.cg
            iconBaseLayer.contentsScale = iconBase.scale
            iconBaseLayer.bounds = CGRect(origin: .zero, size: iconBase.size)
            iconFillLayer.contents = iconFill.cg
            iconFillLayer.contentsScale = iconFill.scale
            iconFillLayer.bounds = CGRect(origin: .zero, size: iconFill.size)

            iconFillClipLayer.bounds.size.width = iconFill.size.width
            iconHostLayer.isHidden = false
        } else {
            preparedIcon = nil
            iconBaseLayer.contents = nil
            iconFillLayer.contents = nil
            iconHostLayer.isHidden = true
        }
        CATransaction.commit()
        needsLayout = true
    }

    struct Representable: NSViewRepresentable {
        let text: String
        let windowWidth: CGFloat

        let pacing: MenuBarMarquee.ScrollPacing?

        let fillPath: [MenuBarMarquee.KaraokeFillPoint]?

        let followPath: [MenuBarMarquee.KaraokeFillPoint]?

        let karaokePositionMs: Int?
        let karaokeRate: Double
        let karaokePlaying: Bool

        let icon: IconBadge?

        let progressPositionMs: Int?
        let progressDurationMs: Int?

        let secondaryText: String?
        let secondaryKind: LyricSecondaryLine

        func makeNSView(context: Context) -> MenuBarScrollingLabel { MenuBarScrollingLabel() }

        func updateNSView(_ view: MenuBarScrollingLabel, context: Context) {

            view.appearance = MenuBarAppearanceStore.shared.appearance

            view.present(text: text, windowWidth: windowWidth, pacing: pacing, fillPath: fillPath,
                         followPath: followPath, icon: icon,
                         secondaryText: secondaryText, secondaryKind: secondaryKind)

            view.refreshColors()

            view.updateKaraokeClock(positionMs: karaokePositionMs, rate: karaokeRate,
                                    playing: karaokePlaying)
            view.updateProgressClock(positionMs: progressPositionMs,
                                     durationMs: progressDurationMs,
                                     rate: karaokeRate, playing: karaokePlaying)
        }
    }

    private func restartAnimation() {
        contentLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        guard let plan, let prepared else { return }
        let maxOffset = prepared.textWidth - plan.windowWidth

        if applyFollowScroll() { return }
        guard let pacing = plan.pacing,
              let frames = MenuBarMarquee.scrollKeyframes(
                maxOffset: maxOffset,
                pointsPerSecond: pacing.pointsPerSecond,
                headHoldSeconds: pacing.headHoldSeconds,
                tailHoldSeconds: pacing.tailHoldSeconds)
        else {

            let slack = max(0, -maxOffset)
            let alignedX: CGFloat
            switch plan.alignment {

            case .leading, .automatic: alignedX = 0
            case .center: alignedX = (slack / 2).rounded()
            case .trailing: alignedX = slack.rounded()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.position = CGPoint(x: alignedX, y: contentLayer.position.y)
            CATransaction.commit()
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "position.x")

        animation.values = frames.offsets.map { NSNumber(value: Double(-$0)) }
        animation.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
        animation.calculationMode = .linear
        animation.duration = frames.duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        contentLayer.add(animation, forKey: Self.scrollAnimationKey)
    }

    @discardableResult
    private func applyFollowScroll() -> Bool {
        guard let plan, let prepared, plan.pacing != nil, let reading = plan.followPath else {
            return false
        }
        let path = MenuBarMarquee.followScrollPath(
            reading: reading, windowWidth: plan.windowWidth, textWidth: prepared.textWidth)
        guard !path.isEmpty else { return false }
        contentLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        func rest(at offset: CGFloat) {
            contentLayer.position = CGPoint(x: -offset, y: contentLayer.position.y)
        }
        guard let clock = karaokeClock else {

            rest(at: 0)
            return true
        }
        let nowMs = clock.positionMs()
        if clock.playing, clock.rate > 0,
           let frames = MenuBarMarquee.followScrollKeyframes(path: path, nowMs: nowMs,
                                                             rate: clock.rate) {

            rest(at: frames.widths.last ?? 0)
            let animation = CAKeyframeAnimation(keyPath: "position.x")
            animation.values = frames.widths.map { NSNumber(value: Double(-$0)) }
            animation.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
            animation.calculationMode = .linear
            animation.duration = frames.duration
            animation.beginTime = contentLayer.convertTime(CACurrentMediaTime(), from: nil)
            animation.isRemovedOnCompletion = false
            animation.fillMode = .forwards
            contentLayer.add(animation, forKey: Self.scrollAnimationKey)
        } else {
            rest(at: MenuBarMarquee.followScrollOffset(atMs: nowMs, path: path))
        }
        return true
    }

    private func applyKaraokeFill() {
        fillClipLayer.removeAnimation(forKey: Self.fillAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.basePositionAnimationKey)
        baseClipLayer.removeAnimation(forKey: Self.baseBoundsAnimationKey)
        let textWidth = prepared?.textWidth ?? 0
        let height = prepared?.pointHeight ?? MenuBarMarqueeRenderer.lineHeight
        func baseRect(_ boundary: CGFloat) -> CGRect {
            CGRect(x: min(boundary, textWidth), y: 0,
                   width: max(0, textWidth - boundary), height: height)
        }
        func setBoundary(_ boundary: CGFloat) {
            fillClipLayer.bounds = CGRect(x: 0, y: 0, width: max(0, boundary), height: height)
            baseClipLayer.position = CGPoint(x: min(boundary, textWidth), y: 0)
            baseClipLayer.bounds = baseRect(boundary)
        }
        guard let plan, let path = plan.fillPath, !path.isEmpty,
              prepared != nil, !highlighted, let clock = karaokeClock else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillClipLayer.isHidden = true
            setBoundary(0)
            CATransaction.commit()
            return
        }
        let nowMs = clock.positionMs()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillClipLayer.isHidden = false
        if clock.playing, clock.rate > 0,
           let frames = MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: nowMs,
                                                            rate: clock.rate) {

            setBoundary(frames.widths.last ?? 0)
            let keyTimes = frames.keyTimes.map { NSNumber(value: $0) }

            let start = fillClipLayer.convertTime(CACurrentMediaTime(), from: nil)
            func install(_ keyPath: String, _ values: [Any], on layer: CALayer, key: String) {
                let animation = CAKeyframeAnimation(keyPath: keyPath)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.calculationMode = .linear
                animation.duration = frames.duration
                animation.beginTime = start
                animation.isRemovedOnCompletion = false
                animation.fillMode = .forwards
                layer.add(animation, forKey: key)
            }
            install("bounds.size.width",
                    frames.widths.map { NSNumber(value: Double($0)) },
                    on: fillClipLayer, key: Self.fillAnimationKey)
            install("position.x",
                    frames.widths.map { NSNumber(value: Double(min($0, textWidth))) },
                    on: baseClipLayer, key: Self.basePositionAnimationKey)
            install("bounds",
                    frames.widths.map { NSValue(rect: baseRect($0)) },
                    on: baseClipLayer, key: Self.baseBoundsAnimationKey)
        } else {

            setBoundary(MenuBarMarquee.karaokeFillX(atMs: nowMs, path: path))
        }
        CATransaction.commit()
    }

    private func applyProgressFill() {
        iconFillClipLayer.removeAnimation(forKey: Self.iconFillAnimationKey)
        iconBaseClipLayer.removeAnimation(forKey: Self.iconBasePositionAnimationKey)
        iconBaseClipLayer.removeAnimation(forKey: Self.iconBaseBoundsAnimationKey)
        guard let icon = preparedIcon else { return }
        let w = icon.base.size.width
        let h = icon.base.size.height
        func baseRect(_ boundary: CGFloat) -> CGRect {
            CGRect(x: 0, y: min(boundary, h), width: w, height: max(0, h - boundary))
        }
        func setBoundary(_ boundary: CGFloat) {
            iconFillClipLayer.bounds = CGRect(x: 0, y: 0, width: w, height: max(0, boundary))
            iconBaseClipLayer.position = CGPoint(x: 0, y: min(boundary, h))
            iconBaseClipLayer.bounds = baseRect(boundary)
        }

        guard !highlighted, let clock = progressClock, clock.durationMs > 0 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            iconFillClipLayer.isHidden = true
            setBoundary(0)
            CATransaction.commit()
            return
        }
        let nowMs = clock.positionMs()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconFillClipLayer.isHidden = false
        if let ramp = MenuBarMarquee.progressFillRamp(
            positionMs: nowMs, durationMs: clock.durationMs,
            rate: clock.playing ? clock.rate : 0, fullLength: h) {

            setBoundary(ramp.to)

            let start = iconFillClipLayer.convertTime(CACurrentMediaTime(), from: nil)
            func install(_ keyPath: String, from: Any, to: Any, on layer: CALayer, key: String) {
                let animation = CABasicAnimation(keyPath: keyPath)
                animation.fromValue = from
                animation.toValue = to
                animation.duration = ramp.duration
                animation.beginTime = start

                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                animation.isRemovedOnCompletion = false
                animation.fillMode = .forwards
                layer.add(animation, forKey: key)
            }
            install("bounds.size.height",
                    from: NSNumber(value: Double(ramp.from)),
                    to: NSNumber(value: Double(ramp.to)),
                    on: iconFillClipLayer, key: Self.iconFillAnimationKey)
            install("position.y",
                    from: NSNumber(value: Double(min(ramp.from, h))),
                    to: NSNumber(value: Double(min(ramp.to, h))),
                    on: iconBaseClipLayer, key: Self.iconBasePositionAnimationKey)
            install("bounds",
                    from: NSValue(rect: baseRect(ramp.from)),
                    to: NSValue(rect: baseRect(ramp.to)),
                    on: iconBaseClipLayer, key: Self.iconBaseBoundsAnimationKey)
        } else {

            setBoundary(MenuBarMarquee.progressFillLength(
                positionMs: nowMs, durationMs: clock.durationMs, fullLength: h))
        }
        CATransaction.commit()
    }
}
