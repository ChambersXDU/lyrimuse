import LyrimuseCore
import Foundation

@MainActor
func runOverlayTests() {

    do {

        let rects: [OverlayControlID: CGRect] = [
            .previous: CGRect(x: 100, y: 200, width: 26, height: 26),
            .playPause: CGRect(x: 144, y: 198, width: 30, height: 30),
            .next: CGRect(x: 192, y: 200, width: 26, height: 26),
            .favorite: CGRect(x: 236, y: 200, width: 26, height: 26),
            .lock: CGRect(x: 299, y: 200, width: 26, height: 26),
        ]
        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 113, y: 213), in: rects), .previous)
        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 159, y: 213), in: rects), .playPause)
        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 311, y: 213), in: rects), .lock)

        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 135, y: 213), in: rects) == nil, true)

        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 400, y: 300), in: rects) == nil, true)

        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 113, y: 213), in: [:]) == nil, true)
    }

    do {

        let overlapping: [OverlayControlID: CGRect] = [
            .previous: CGRect(x: 0, y: 0, width: 100, height: 100),
            .next: CGRect(x: 10, y: 10, width: 20, height: 20),
        ]
        var results = Set<OverlayControlID?>()
        for _ in 1...50 {
            results.insert(OverlayControlHitTest.control(at: CGPoint(x: 15, y: 15), in: overlapping))
        }
        expectEqual(results.count, 1)
        expectEqual(results.first ?? nil, .next)
    }

    do {
        let rects: [OverlayControlID: CGRect] = [
            .playPause: CGRect(x: 144, y: 198, width: 30, height: 30),
            .unlockPill: CGRect(x: 240, y: 198, width: 22, height: 22),
        ]
        let onPlay = CGPoint(x: 159, y: 213)
        let onUnlock = CGPoint(x: 251, y: 209)
        let H = OverlayControlHitTest.self

        expectEqual(H.hoveredControl(at: onPlay, in: rects, insideWindow: true, positionLocked: false),
                    .playPause)

        expectEqual(H.hoveredControl(at: onPlay, in: rects, insideWindow: false, positionLocked: false) == nil,
                    true)

        expectEqual(H.hoveredControl(at: onPlay, in: rects, insideWindow: true, positionLocked: true) == nil,
                    true)
        expectEqual(H.hoveredControl(at: onUnlock, in: rects, insideWindow: true, positionLocked: true),
                    .unlockPill)
        expectEqual(H.hoveredControl(at: onUnlock, in: rects, insideWindow: true, positionLocked: false),
                    .unlockPill)

        expectEqual(H.hoveredControl(at: CGPoint(x: 200, y: 213), in: rects,
                                     insideWindow: true, positionLocked: false) == nil,
                    true)
        expectEqual(H.hoveredControl(at: onPlay, in: [:], insideWindow: true, positionLocked: false) == nil,
                    true)
    }

    do {
        let H = OverlayControlHitTest.self

        let pill = CGRect(x: 400, y: 4, width: 216, height: 30)
        let buttons: [OverlayControlID: CGRect] = [
            .previous: CGRect(x: 410, y: 8, width: 22, height: 22),
            .playPause: CGRect(x: 440, y: 8, width: 22, height: 22),
        ]
        let lyrics = CGRect(x: 120, y: 62, width: 780, height: 46)

        let zone = H.chromeHoverZone(lyrics: lyrics, controlsPill: pill, controlRects: buttons) ?? .null
        expectEqual(zone.contains(CGPoint(x: 500, y: 80)), true)
        expectEqual(zone.contains(CGPoint(x: 450, y: 18)), true)

        expectEqual(zone.contains(CGPoint(x: 450, y: 48)), true)

        expectEqual(zone.contains(CGPoint(x: 20, y: 20)), false)
        expectEqual(zone.contains(CGPoint(x: 500, y: 160)), false)

        let unlock: [OverlayControlID: CGRect] = [.unlockPill: CGRect(x: 494, y: 8, width: 28, height: 22)]
        let locked = H.chromeHoverZone(lyrics: lyrics, controlsPill: nil, controlRects: unlock)
        expectEqual(locked?.contains(CGPoint(x: 508, y: 18)) ?? false, true)

        expectEqual(H.chromeHoverZone(lyrics: nil, controlsPill: nil, controlRects: [:]) == nil, true)

        let zeroed = H.chromeHoverZone(lyrics: lyrics, controlsPill: .zero, controlRects: [.lock: .zero])
        expectEqual(zeroed == lyrics, true)
        expectEqual(H.chromeHoverZone(lyrics: .zero, controlsPill: nil, controlRects: [:]) == nil, true)

        let repeated = (1...50).map {
            _ in H.chromeHoverZone(lyrics: lyrics, controlsPill: pill, controlRects: buttons) ?? .null
        }
        expectEqual(repeated.allSatisfy { $0 == zone }, true)
    }

    do {
        let L = LyricDuetLayout.self

        do {
            let i = L.insets(for: nil, availableWidth: 400, fontSize: 30)
            expectEqual(i.leading, 0)
            expectEqual(i.trailing, 0)
        }

        do {
            let i = L.insets(for: .leading, availableWidth: 400, fontSize: 200)
            expectEqual(i.leading, 30)
            expectEqual(i.trailing, 60)
        }
        do {
            let i = L.insets(for: .trailing, availableWidth: 400, fontSize: 200)
            expectEqual(i.leading, 60)
            expectEqual(i.trailing, 30)
        }

        do {
            let i = L.insets(for: .center, availableWidth: 400, fontSize: 200)
            expectEqual(i.leading, 60)
            expectEqual(i.trailing, 60)
        }

        do {
            let i = L.insets(for: .leading, availableWidth: 4000, fontSize: 30)
            expectEqual(i.trailing, 120)
            expectEqual(i.leading, 60)
        }

        do {
            let zeroWidth = L.insets(for: .leading, availableWidth: 0, fontSize: 30)
            expectEqual(zeroWidth.trailing, 0)
            expectEqual(zeroWidth.leading, 0)
            let negWidth = L.insets(for: .leading, availableWidth: -100, fontSize: 30)
            expectEqual(negWidth.trailing, 0)
            expectEqual(negWidth.leading, 0)
            let zeroFont = L.insets(for: .leading, availableWidth: 400, fontSize: 0)
            expectEqual(zeroFont.trailing, 0)
            expectEqual(zeroFont.leading, 0)
        }

        do {
            for (w, f) in [(400.0, 200.0), (4000.0, 30.0), (100.0, 12.0), (1200.0, 48.0)] {
                let i = L.insets(for: .leading, availableWidth: w, fontSize: f)
                expectEqual(i.trailing >= i.leading, true)
            }
        }
    }

    do {
        typealias O = OverlayDuetAlignmentOverride
        let D = LyricDuet.Side.self

        for real: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            expectEqual(O.automatic.effectiveAlignmentSide(realSide: real), real ?? .center)
            expectEqual(O.automatic.effectiveDecorationSide(realSide: real), real)
        }

        for real: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            expectEqual(O.center.effectiveAlignmentSide(realSide: real), .center)
            expectEqual(O.leading.effectiveAlignmentSide(realSide: real), .leading)
            expectEqual(O.trailing.effectiveAlignmentSide(realSide: real), .trailing)
        }

        for override in [O.center, O.leading, O.trailing] {
            for real: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
                expectEqual(override.effectiveDecorationSide(realSide: real), nil)
            }
        }
    }

    do {
        let G = OverlayCardGeometry.self
        let D = LyricDuet.Side.self

        let unit: CGFloat = 124

        let pad: CGFloat = 20

        expectEqual(G.cardInsets(for: nil, unit: unit).leading, 0)
        expectEqual(G.cardInsets(for: nil, unit: unit).trailing, 0)
        expectEqual(G.cardInsets(for: D.leading, unit: unit).leading, 0)
        expectEqual(G.cardInsets(for: D.leading, unit: unit).trailing, unit)
        expectEqual(G.cardInsets(for: D.trailing, unit: unit).leading, unit)
        expectEqual(G.cardInsets(for: D.trailing, unit: unit).trailing, 0)
        expectEqual(G.cardInsets(for: D.center, unit: unit).leading, unit)
        expectEqual(G.cardInsets(for: D.center, unit: unit).trailing, unit)

        for side: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            let card = G.cardInsets(for: side, unit: unit)
            let ctrl = G.controlsInsets(for: side, unit: unit, cardHorizontalPadding: pad)
            expectEqual(ctrl.leading - card.leading, pad)
            expectEqual(ctrl.trailing - card.trailing, pad)
        }

        for side: LyricDuet.Side? in [nil, D.center] {
            let ctrl = G.controlsInsets(for: side, unit: unit, cardHorizontalPadding: pad)
            expectEqual(ctrl.leading, ctrl.trailing)
        }

        for override in [OverlayDuetAlignmentOverride.center, .leading, .trailing] {
            for real: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
                let decoration = override.effectiveDecorationSide(realSide: real)
                let ctrl = G.controlsInsets(for: decoration, unit: unit, cardHorizontalPadding: pad)
                expectEqual(ctrl.leading, pad)
                expectEqual(ctrl.trailing, pad)
            }
        }
    }

    do {
        let G = OverlayCardGeometry.self
        let D = LyricDuet.Side.self
        let pad: CGFloat = 20
        let ref = G.duetStageReferenceWidth
        expectEqual(ref, 448)

        expectEqual(G.duetStageInset(availableWidth: 448, fontSize: 31), 0)
        expectEqual(G.duetStageInset(availableWidth: 300, fontSize: 31), 0)

        expectEqual(G.duetStageInset(availableWidth: 1360, fontSize: 31), 456)

        expectEqual(G.duetStageInset(availableWidth: 1360, fontSize: 48), (1360 - 576) / 2)

        expectEqual(G.duetStageInset(availableWidth: 500, fontSize: 48), 0)

        expectEqual(G.duetStageInset(availableWidth: 0, fontSize: 31), 0)
        expectEqual(G.duetStageInset(availableWidth: -100, fontSize: 31), 0)
        expectEqual(G.duetStageInset(availableWidth: 1360, fontSize: 0), 456)
        expectEqual(G.duetStageInset(availableWidth: 1360, fontSize: -5), 456)

        let unit = LyricDuetLayout.insets(for: .leading, availableWidth: 1360, fontSize: 31).trailing
        expectEqual(unit, 124)
        let stage = G.duetStageInset(availableWidth: 1360, fontSize: 31)

        expectEqual(G.cardInsets(for: D.leading, unit: unit, stageInset: stage).leading, stage)
        expectEqual(G.cardInsets(for: D.leading, unit: unit, stageInset: stage).trailing, unit)
        expectEqual(G.cardInsets(for: D.trailing, unit: unit, stageInset: stage).leading, unit)
        expectEqual(G.cardInsets(for: D.trailing, unit: unit, stageInset: stage).trailing, stage)
        expectEqual(G.cardInsets(for: D.center, unit: unit, stageInset: stage).leading, unit)
        expectEqual(G.cardInsets(for: D.center, unit: unit, stageInset: stage).trailing, unit)
        expectEqual(G.cardInsets(for: nil, unit: unit, stageInset: stage).leading, 0)
        expectEqual(G.cardInsets(for: nil, unit: unit, stageInset: stage).trailing, 0)
        expectEqual(G.cardInsets(for: D.leading, unit: unit, stageInset: -10).leading, 0)

        for side: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            let old = G.cardInsets(for: side, unit: unit)
            let new = G.cardInsets(for: side, unit: unit, stageInset: 0)
            expectEqual(old.leading, new.leading)
            expectEqual(old.trailing, new.trailing)
        }

        for side: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            let card = G.cardInsets(for: side, unit: unit, stageInset: stage)
            let ctrl = G.controlsInsets(for: side, unit: unit, stageInset: stage, cardHorizontalPadding: pad)
            expectEqual(ctrl.leading - card.leading, pad)
            expectEqual(ctrl.trailing - card.trailing, pad)
        }

        let leftStart = pad + G.cardInsets(for: D.leading, unit: unit, stageInset: stage).leading
        let rightEnd = 1400 - pad - G.cardInsets(for: D.trailing, unit: unit, stageInset: stage).trailing
        expectEqual(leftStart, 476)
        expectEqual(rightEnd, 924)
        expectEqual(rightEnd - leftStart, ref)
        expectEqual((leftStart + rightEnd) / 2, 700)
        let oldLeftStart = pad + G.cardInsets(for: D.leading, unit: unit).leading
        let oldRightEnd = 1400 - pad - G.cardInsets(for: D.trailing, unit: unit).trailing
        expectEqual(oldRightEnd - oldLeftStart, 1360)

        let leftWrapAt = 1400 - pad - G.cardInsets(for: D.leading, unit: unit, stageInset: stage).trailing
        expectEqual(leftWrapAt, 1256)
        expectEqual(leftWrapAt, 1400 - pad - G.cardInsets(for: D.leading, unit: unit).trailing)
    }

    do {
        let H = OverlayControlHitTest.self

        expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 10, y: 0, width: 30, height: 20), windowHeight: 100),
                    CGRect(x: 10, y: 80, width: 30, height: 20))
        expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 10, y: 80, width: 30, height: 20), windowHeight: 100),
                    CGRect(x: 10, y: 0, width: 30, height: 20))

        expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 7, y: 30, width: 13, height: 5), windowHeight: 60).minX,
                    7)
        expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 7, y: 30, width: 13, height: 5), windowHeight: 60).width,
                    13)

        do {
            let a = CGRect(x: 4, y: 12, width: 20, height: 8)
            let once = H.windowLocalRect(swiftUI: a, windowHeight: 50)
            expectEqual(H.windowLocalRect(swiftUI: once, windowHeight: 50), a)
        }
    }

    do {
        func sz(_ w: CGFloat, _ h: CGFloat = 10) -> CGSize { CGSize(width: w, height: h) }
        func rowIndices(_ rows: [WrapLayoutMath.Row]) -> [[Int]] { rows.map { $0.indices } }

        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(10), sz(10), sz(10)], maxWidth: 100, horizontalSpacing: 0)),
                    [[0, 1, 2]])

        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(60), sz(60), sz(60)], maxWidth: 100, horizontalSpacing: 0)),
                    [[0], [1], [2]])

        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(30), sz(30), sz(30)], maxWidth: 100, horizontalSpacing: 10)),
                    [[0, 1], [2]])

        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(500)], maxWidth: 100, horizontalSpacing: 0)),
                    [[0]])
        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(10), sz(500), sz(10)], maxWidth: 100, horizontalSpacing: 0)),
                    [[0], [1], [2]])

        expectEqual(WrapLayoutMath.rows(sizes: [], maxWidth: 100, horizontalSpacing: 0).count, 0)

        let twoRows = WrapLayoutMath.totalSize(
            sizes: [sz(60, 20), sz(60, 30)], maxWidth: 100, horizontalSpacing: 0, verticalSpacing: 5)
        expectEqual(twoRows, CGSize(width: 100, height: 55))

        func firstX(_ alignment: WrapLayoutMath.RowAlignment) -> CGFloat {
            WrapLayoutMath.placements(
                sizes: [sz(60)], bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
                horizontalSpacing: 0, verticalSpacing: 0, rowAlignment: alignment
            ).first?.origin.x ?? -1
        }
        expectEqual(firstX(.leading), 0)
        expectEqual(firstX(.center), 20)
        expectEqual(firstX(.trailing), 40)

        let offsetPlacement = WrapLayoutMath.placements(
            sizes: [sz(60)], bounds: CGRect(x: 7, y: 3, width: 100, height: 50),
            horizontalSpacing: 0, verticalSpacing: 0, rowAlignment: .leading).first
        expectEqual(offsetPlacement?.origin.x, 7)

        let vcenter = WrapLayoutMath.placements(
            sizes: [sz(10, 10), sz(10, 30)], bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            horizontalSpacing: 0, verticalSpacing: 0, rowAlignment: .leading)
        expectEqual(vcenter.first?.origin.y, 10)

        var orderOK = true, allPlaced = true, noLeftOverflow = true, noOverlap = true
        for count in 1...12 {
            var sizes: [CGSize] = []
            for i in 0..<count {
                let w: CGFloat = CGFloat(20 + (i * 13) % 70)
                let h: CGFloat = CGFloat(10 + (i * 7) % 20)
                sizes.append(sz(w, h))
            }
            for alignment in [WrapLayoutMath.RowAlignment.leading, .center, .trailing] {
                let bounds = CGRect(x: 5, y: 5, width: 120, height: 500)
                let ps = WrapLayoutMath.placements(
                    sizes: sizes, bounds: bounds, horizontalSpacing: 3, verticalSpacing: 2,
                    rowAlignment: alignment)
                if ps.count != sizes.count { allPlaced = false }
                let indices: [Int] = ps.map { $0.index }
                if indices != Array(0..<sizes.count) { orderOK = false }
                for p in ps where p.origin.x < bounds.minX - 1e-9 { noLeftOverflow = false }

                for a in 0..<ps.count {
                    for b in (a + 1)..<ps.count {
                        let ra = CGRect(origin: ps[a].origin, size: ps[a].size)
                        let rb = CGRect(origin: ps[b].origin, size: ps[b].size)
                        if ra.insetBy(dx: 1e-6, dy: 1e-6).intersects(rb.insetBy(dx: 1e-6, dy: 1e-6)) {
                            noOverlap = false
                        }
                    }
                }
            }
        }
        expectEqual(allPlaced, true)
        expectEqual(orderOK, true)
        expectEqual(noLeftOverflow, true)
        expectEqual(noOverlap, true)

        do {
            let bounds = CGRect(x: 0, y: 0, width: 200, height: 40)

            let one = WrapLayoutMath.rows(sizes: [sz(60, 20)], maxWidth: 200, horizontalSpacing: 0)
            expectEqual(
                WrapLayoutMath.contentBounds(rows: one, bounds: bounds, verticalSpacing: 2, rowAlignment: .leading),
                CGRect(x: 0, y: 0, width: 60, height: 20))
            expectEqual(
                WrapLayoutMath.contentBounds(rows: one, bounds: bounds, verticalSpacing: 2, rowAlignment: .center),
                CGRect(x: 70, y: 0, width: 60, height: 20))
            expectEqual(
                WrapLayoutMath.contentBounds(rows: one, bounds: bounds, verticalSpacing: 2, rowAlignment: .trailing),
                CGRect(x: 140, y: 0, width: 60, height: 20))

            let two = WrapLayoutMath.rows(sizes: [sz(120, 20), sz(120, 20)], maxWidth: 150, horizontalSpacing: 0)
            expectEqual(two.count, 2)
            expectEqual(
                WrapLayoutMath.contentBounds(rows: two, bounds: CGRect(x: 0, y: 0, width: 150, height: 50),
                                             verticalSpacing: 2, rowAlignment: .leading),
                CGRect(x: 0, y: 0, width: 120, height: 42))

            expectEqual(
                WrapLayoutMath.contentBounds(rows: one, bounds: CGRect(x: 30, y: 7, width: 200, height: 40),
                                             verticalSpacing: 2, rowAlignment: .leading),
                CGRect(x: 30, y: 7, width: 60, height: 20))

            expectEqual(
                WrapLayoutMath.contentBounds(rows: [], bounds: bounds, verticalSpacing: 2, rowAlignment: .center),
                .zero)

            let wide = WrapLayoutMath.rows(sizes: [sz(300, 20)], maxWidth: 200, horizontalSpacing: 0)
            expectEqual(
                WrapLayoutMath.contentBounds(rows: wide, bounds: bounds, verticalSpacing: 2, rowAlignment: .leading).width,
                200)
        }

    }

    do {
        let mainScreen = CGRect(x: 0, y: 0, width: 1470, height: 900)
        let secondScreen = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        let overlaySize = CGSize(width: 900, height: 166)

        let onMain = CGRect(origin: CGPoint(x: 285, y: 700), size: overlaySize)
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: onMain, screens: [mainScreen]) == nil, true)

        let onSecond = CGRect(origin: CGPoint(x: 1600, y: 100), size: overlaySize)
        expectEqual(
            OverlayPlacement.repositionIfOffscreen(frame: onSecond, screens: [mainScreen, secondScreen]) == nil, true)

        let rescued = OverlayPlacement.repositionIfOffscreen(frame: onSecond, screens: [mainScreen])
        expectEqual(rescued?.x, 570)
        expectEqual(rescued?.y, 100)

        let mostlyOff = CGRect(origin: CGPoint(x: 1270, y: 700), size: overlaySize)
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: mostlyOff, screens: [mainScreen]) == nil, true)

        let slivered = CGRect(origin: CGPoint(x: 1440, y: 700), size: overlaySize)
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: slivered, screens: [mainScreen]) != nil, true)

        let tooWide = CGRect(x: 3000, y: 100, width: 2000, height: 166)
        let clampedWide = OverlayPlacement.clamped(frame: tooWide, into: mainScreen)
        expectEqual(clampedWide.x, 0)

        let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let strayFrame = CGRect(x: -5000, y: 0, width: 900, height: 166)
        expectEqual(OverlayPlacement.clamped(frame: strayFrame, into: leftScreen).x, -1920)

        let tiny = CGRect(x: 10, y: 10, width: 20, height: 10)
        expectEqual(OverlayPlacement.isSufficientlyVisible(frame: tiny, screens: [mainScreen]), true)

        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: onMain, screens: []) == nil, true)

        let exactlyAtEdge = CGRect(origin: CGPoint(x: 570, y: 100), size: overlaySize)
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: exactlyAtEdge, screens: [mainScreen]) == nil, true)
    }

    do {
        let builtIn = CGRect(x: 0, y: 70, width: 1470, height: 853)
        let external = CGRect(x: -526, y: 956, width: 2560, height: 1440)
        let size = CGSize(width: 900, height: 120)

        let saved = CGRect(origin: CGPoint(x: 849, y: 1082), size: size)

        let kept = OverlayPlacement.restored(frame: saved, screens: [builtIn, external])
        expectEqual(kept.origin.x, 849)
        expectEqual(kept.origin.y, 1082)
        expectEqual(kept.wasRescued, false)

        let rescued = OverlayPlacement.restored(frame: saved, screens: [builtIn])
        expectEqual(rescued.origin.x, 570)
        expectEqual(rescued.origin.y, 803)
        expectEqual(rescued.wasRescued, true)

        let noScreens = OverlayPlacement.restored(frame: saved, screens: [])
        expectEqual(noScreens.origin.y, 1082)
        expectEqual(noScreens.wasRescued, false)

        let host = OverlayPlacement.hostVisibleFrame(of: saved, screens: [builtIn, external])
        expectEqual(host?.minY, 956)

        let straddling = CGRect(x: 0, y: 900, width: 200, height: 200)
        expectEqual(OverlayPlacement.hostVisibleFrame(of: straddling, screens: [builtIn, external])?.minY, 956)

        let nowhere = CGRect(x: 9000, y: 9000, width: 100, height: 100)
        expectEqual(OverlayPlacement.hostVisibleFrame(of: nowhere, screens: [builtIn, external]) == nil, true)
    }

    do {
        let screen = CGRect(x: 0, y: 70, width: 1470, height: 853)
        let size = CGSize(width: 488, height: 120)

        expectEqual(OverlayPlacementMode(rawValue: "free"), .free)
        expectEqual(OverlayPlacementMode(rawValue: "topCenter"), .topCenter)
        expectEqual(OverlayPlacementMode(rawValue: "bottomCenter"), .bottomCenter)
        expectEqual(OverlayPlacementMode.free.isPreset, false)
        expectEqual(OverlayPlacementMode.topCenter.isPreset, true)
        expectEqual(OverlayPlacementMode.bottomCenter.anchorsBottom, true)
        expectEqual(OverlayPlacementMode.topCenter.anchorsBottom, false)
        expectEqual(OverlayPlacementMode.free.anchorsBottom, false)
        expectEqual(OverlayPlacementMode.allCases.count, 3)

        expectEqual(OverlayPlacement.presetFrame(mode: .free, size: size, visibleFrame: screen) == nil, true)

        let top = OverlayPlacement.presetFrame(mode: .topCenter, size: size, visibleFrame: screen)
        expectEqual(top?.midX, 735)
        expectEqual(top?.maxY, 923 - OverlayPlacement.presetTopMargin)
        expectEqual(top?.size.height, 120)
        expectEqual(OverlayPlacement.presetTopMargin, 12)
        expectEqual(OverlayPlacement.presetTopMargin, OverlayPlacement.presetBottomMargin)

        let bottom = OverlayPlacement.presetFrame(mode: .bottomCenter, size: size, visibleFrame: screen)
        expectEqual(bottom?.midX, 735)
        expectEqual(bottom?.minY, 70 + OverlayPlacement.presetBottomMargin)
        expectEqual(bottom?.size.width, 488)

        let external = CGRect(x: -526, y: 956, width: 2560, height: 1440)
        let onExternal = OverlayPlacement.presetFrame(mode: .bottomCenter, size: size, visibleFrame: external)
        expectEqual(onExternal?.midX, external.midX)
        expectEqual(onExternal?.minY, 956 + 12)

        let topFrame = top!
        let grownDown = OverlayPlacement.grownFrame(
            current: topFrame, contentHeight: 150.4, minHeight: 120, anchorsBottom: false, visibleFrame: screen)
        expectEqual(grownDown.maxY, topFrame.maxY)
        expectEqual(grownDown.height, 151)
        expectEqual(grownDown.minX, topFrame.minX)

        expectEqual(OverlayPlacement.grownFrame(
            current: topFrame, contentHeight: 70, minHeight: 120, anchorsBottom: false, visibleFrame: screen).height,
            120)

        let tallDown = OverlayPlacement.grownFrame(
            current: topFrame, contentHeight: 2000, minHeight: 120, anchorsBottom: false, visibleFrame: screen)
        expectEqual(tallDown.minY, 70)
        expectEqual(tallDown.height, topFrame.maxY - 70)

        let flush = CGRect(x: 491, y: 70, width: 488, height: 120)
        let stuck = OverlayPlacement.grownFrame(
            current: flush, contentHeight: 150, minHeight: 120, anchorsBottom: false, visibleFrame: screen)
        expectEqual(stuck.height, 120)
        let bottomFrame = bottom!
        let stuckPreset = OverlayPlacement.grownFrame(
            current: bottomFrame, contentHeight: 150, minHeight: 120, anchorsBottom: false, visibleFrame: screen)
        expectEqual(stuckPreset.height, 132)
        let grownUp = OverlayPlacement.grownFrame(
            current: bottomFrame, contentHeight: 150, minHeight: 120, anchorsBottom: true, visibleFrame: screen)
        expectEqual(grownUp.minY, bottomFrame.minY)
        expectEqual(grownUp.height, 150)
        expectEqual(grownUp.maxY, bottomFrame.minY + 150)

        let tallUp = OverlayPlacement.grownFrame(
            current: bottomFrame, contentHeight: 2000, minHeight: 120, anchorsBottom: true, visibleFrame: screen)
        expectEqual(tallUp.maxY, 923)
        expectEqual(tallUp.height, 841)

        expectEqual(OverlayPlacement.grownFrame(
            current: bottomFrame, contentHeight: 2000, minHeight: 120, anchorsBottom: true, visibleFrame: nil).height,
            2000)

        typealias H = OverlayControlHitTest
        expectEqual(H.contentTopInset(anchorsBottom: false, windowHeight: 120, contentHeight: 70), 0)
        expectEqual(H.contentTopInset(anchorsBottom: true, windowHeight: 120, contentHeight: 70), 50)
        expectEqual(H.contentTopInset(anchorsBottom: true, windowHeight: 120, contentHeight: 150), -30)

        let btn = CGRect(x: 10, y: 0, width: 30, height: 20)
        let local = H.windowLocalRect(swiftUI: btn, windowHeight: 120, contentTopInset: 50)
        expectEqual(local.minY, 50)
        expectEqual(local.maxY, 70)
        expectEqual(local.minX, 10)

        expectEqual(H.windowLocalRect(swiftUI: btn, windowHeight: 120),
                    H.windowLocalRect(swiftUI: btn, windowHeight: 120, contentTopInset: 0))
    }

    do {
        func run(_ events: [TilePressState.Event]) -> [TilePressState.Action] {
            var state = TilePressState()
            return events.map { state.handle($0) }
        }

        expectEqual(run([.down, .up]), [.none, .primary])
        expectEqual(run([.down, .holdElapsed]), [.none, .secondary])
        expectEqual(run([.down, .holdElapsed, .up]), [.none, .secondary, .none])
        expectEqual(run([.secondaryClick]), [.secondary])
        expectEqual(run([.down, .secondaryClick, .up]), [.none, .secondary, .none])
        expectEqual(run([.down, .dragOutside, .up]), [.none, .none, .none])
        expectEqual(run([.down, .dragOutside, .holdElapsed]), [.none, .none, .none])
        expectEqual(run([.down, .dragOutside, .dragInside, .up]), [.none, .none, .none, .primary])
        expectEqual(run([.down, .up, .up]), [.none, .primary, .none])
        expectEqual(run([.down, .up, .down, .up]), [.none, .primary, .none, .primary])

        var visual = TilePressState()
        _ = visual.handle(.down)
        expectEqual(visual.isPressing, true)
        _ = visual.handle(.dragOutside)
        expectEqual(visual.isPressing, false)
        _ = visual.handle(.dragInside)
        expectEqual(visual.isPressing, true)
        _ = visual.handle(.holdElapsed)
        expectEqual(visual.isPressing, false)
    }

    do {
        typealias G = ProgressFillGeometry
        let w: CGFloat = 300

        expectEqual(G.visibleWidth(containerWidth: w, fraction: 0.5), 150)
        expectEqual(G.leadingOffset(containerWidth: w, fraction: 0.5), 150)
        expectEqual(G.visibleWidth(containerWidth: w, fraction: 1), 300)
        expectEqual(G.leadingOffset(containerWidth: w, fraction: 1), 0)

        expectEqual(G.visibleWidth(containerWidth: w, fraction: 0), G.minimumVisibleWidth)
        expectEqual(G.leadingOffset(containerWidth: w, fraction: 0), 296)

        expectEqual(G.visibleWidth(containerWidth: w, fraction: 0.022) > G.minimumVisibleWidth, true)

        expectEqual(G.visibleWidth(containerWidth: w, fraction: -1), G.minimumVisibleWidth)
        expectEqual(G.visibleWidth(containerWidth: w, fraction: 2), 300)

        expectEqual(G.visibleWidth(containerWidth: 2, fraction: 0), 2)
        expectEqual(G.leadingOffset(containerWidth: 2, fraction: 0), 0)
        expectEqual(G.visibleWidth(containerWidth: 0, fraction: 0.5), 0)
        expectEqual(G.leadingOffset(containerWidth: 0, fraction: 0.5), 0)

        var negatives = 0
        for wi in [0, 1, 2, 4, 8, 120, 300, 900] as [CGFloat] {
            for fi in [-0.5, 0, 0.001, 0.022, 0.5, 0.999, 1, 1.5] as [CGFloat] {
                if G.leadingOffset(containerWidth: wi, fraction: fi) < 0 { negatives += 1 }
            }
        }
        expectEqual(negatives, 0)
    }
}
