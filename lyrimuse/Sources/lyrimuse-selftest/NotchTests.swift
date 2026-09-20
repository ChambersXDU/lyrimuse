import LyrimuseCore
import Foundation

@MainActor
func runNotchTests() {

    do {
        typealias M = NotchExpandedMetrics
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true), 76)
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true),
                    M.maxHeight())
        expectEqual(M.height(hasLyricPreview: false, hasScrubber: true), 59)
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: false), 52)
        expectEqual(M.height(hasLyricPreview: false, hasScrubber: false), 35)

        expectEqual(M.height(hasLyricPreview: false, hasScrubber: false) >= 32, true)

        expectEqual(M.height(hasLyricPreview: true, hasScrubber: false)
                    > M.height(hasLyricPreview: false, hasScrubber: false), true)
    }

    do {
        typealias M = NotchExpandedMetrics

        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: false, showsArtist: false, showsAlbum: false), 0)
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: false, showsAlbum: false),
                    M.trackInfoTitleLineHeight)
        expectEqual(M.trackInfoHeight(showsArtwork: true, showsTitle: false, showsArtist: false, showsAlbum: false),
                    M.trackInfoArtworkSide)

        let threeLines = M.trackInfoTitleLineHeight + M.trackInfoArtistLineHeight + M.trackInfoAlbumLineHeight
            + 2 * M.trackInfoLineSpacing
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: true, showsAlbum: true),
                    threeLines)

        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: true, showsAlbum: false)
                    > M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: false, showsAlbum: false),
                    true)

        expectEqual(M.trackInfoHeight(showsArtwork: true, showsTitle: true, showsArtist: true, showsAlbum: true),
                    max(M.trackInfoArtworkSide, threeLines))
        expectEqual(M.trackInfoHeight(showsArtwork: true, showsTitle: false, showsArtist: false, showsAlbum: false)
                    <= M.trackInfoHeight(showsArtwork: true, showsTitle: true, showsArtist: true, showsAlbum: true),
                    true)

        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: false, showsArtist: false, showsAlbum: false,
                                      showsActions: true),
                    M.trackInfoActionsHeight)
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: true, showsAlbum: true,
                                      showsActions: true),
                    threeLines)
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: false, showsArtist: false, showsAlbum: true,
                                      showsActions: true),
                    max(M.trackInfoAlbumLineHeight, M.trackInfoActionsHeight))
        expectEqual(M.trackInfoActionsHeight, 22)

        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true, trackInfoHeight: 0), 76)

        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true, trackInfoHeight: threeLines),
                    76 + threeLines + M.trackInfoTopSpacing + M.trackInfoSpacing)

        expectEqual(M.maxHeight(hasLyricPreviewPossible: true, trackInfoHeight: 0), 76)
        expectEqual(M.maxHeight(hasLyricPreviewPossible: false, trackInfoHeight: 0),
                    M.height(hasLyricPreview: false, hasScrubber: true, trackInfoHeight: 0))
        expectEqual(M.maxHeight(hasLyricPreviewPossible: false, trackInfoHeight: 0), 59)
        expectEqual(M.maxHeight(hasLyricPreviewPossible: true, trackInfoHeight: threeLines),
                    M.height(hasLyricPreview: true, hasScrubber: true, trackInfoHeight: threeLines))

        expectEqual(M.maxHeight(trackInfoHeight: threeLines) > M.maxHeight(trackInfoHeight: 0), true)
    }

    do {
        typealias M = NotchExpandedMetrics

        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true), 76)
        expectEqual(M.height(hasLyricPreview: false, hasScrubber: false), 35)

        expectEqual(M.height(hasLyricPreview: false, hasScrubber: false, hasControls: false), 0)
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true, hasControls: false),
                    76 - M.controlsBlock)

        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true, hasControls: false)
                    < M.height(hasLyricPreview: true, hasScrubber: true, hasControls: true), true)

        expectEqual(M.maxHeight(hasControlsPossible: false),
                    M.height(hasLyricPreview: true, hasScrubber: true, hasControls: false))
        expectEqual(M.maxHeight(hasControlsPossible: false) < M.maxHeight(hasControlsPossible: true), true)
    }

    do {
        typealias M = NotchExpandedMetrics
        let roomiestFloor = NotchLyricRowMetrics.rowHeight
            + M.maxHeight(hasLyricPreviewPossible: false, hasControlsPossible: false, trackInfoHeight: 0)
        expectEqual(M.idlePanelHeight <= roomiestFloor, true)

        expectEqual(M.idlePanelHeight,
                    M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: true, showsAlbum: false,
                                      showsActions: true) + M.trackInfoTopSpacing + M.idlePanelBottomSpacing)
        expectEqual(M.idlePanelBottomSpacing > M.trackInfoSpacing, true)
    }

    do {
        func w(_ text: String, _ start: Int, _ dur: Int) -> SyncedLyricWord {
            SyncedLyricWord(text: text, startMs: start, durationMs: dur)
        }
        let words = [w("a", 1000, 400), w("b", 1400, 400), w("c", 2400, 300)]
        let amp: (Int) -> Double = { VocalEnvelope.amplitude(atMs: $0, words: words) }
        let boost = VocalEnvelope.onsetBoost
        let floor = VocalEnvelope.gapFloor

        expectEqual(VocalEnvelope.amplitude(atMs: 1200, words: []), VocalEnvelope.idleAmplitude)
        expectEqual(amp(1000), 1 + boost)
        let tau = Int(VocalEnvelope.attackMs)
        expectEqual(abs(amp(1000 + tau) - (1 + boost * exp(-1))) < 1e-9, true)
        expectEqual(amp(1000 + 3 * tau) < 1.02, true)
        expectEqual(amp(1000 + 3 * tau) >= 1, true)
        expectEqual(amp(1400), 1 + boost)

        let g0 = amp(1800), g1 = amp(1900), g2 = amp(2100), g3 = amp(2399)
        expectEqual(abs(g0 - 1) < 1e-9, true)
        expectEqual(g0 > g1 && g1 > g2 && g2 > g3, true)
        expectEqual(g3 > floor && g3 < floor + 0.05, true)
        let rt = Int(VocalEnvelope.releaseMs)
        expectEqual(abs(amp(1800 + rt) - (floor + (1 - floor) * exp(-1))) < 1e-9, true)
        expectEqual(amp(500), floor)
        expectEqual(amp(2900) < 1 && amp(2900) > floor, true)
        expectEqual(VocalEnvelope.releaseMs <= 300, true)
        expectEqual(VocalEnvelope.attackMs < VocalEnvelope.releaseMs, true)
    }

    do {
        let c = EqualizerBarCurve.contrast
        expectEqual(c(0), 0)
        expectEqual(c(1), 1)
        expectEqual(c(0.5), 0.5)
        expectEqual(c(0.25) < 0.25, true)
        expectEqual(c(0.75) > 0.75, true)
        expectEqual(abs(c(0.25) + c(0.75) - 1) < 1e-12, true)
        let samples = stride(from: 0.0, through: 1.0, by: 0.01).map(c)
        expectEqual(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, true)
        expectEqual(c(-0.3), 0)
        expectEqual(c(1.7), 1)
        expectEqual(EqualizerBarCurve.level(unit: 0.5, amplitude: 0.6), 0.3)
        expectEqual(EqualizerBarCurve.level(unit: 0.9, amplitude: 1.25), 1)
        expectEqual(EqualizerBarCurve.level(unit: 0.9, amplitude: 0), 0)
    }

    do {
        expectEqual(NotchReveal.startWidthFraction(notchWidth: 180, cardWidth: 360), 0.5)
        expectEqual(NotchReveal.startWidthFraction(notchWidth: 0, cardWidth: 360), 0.12)
        expectEqual(NotchReveal.startWidthFraction(notchWidth: 400, cardWidth: 360), 0.9)
        expectEqual(NotchReveal.startWidthFraction(notchWidth: 180, cardWidth: 0), 1)
        expectEqual(abs(NotchReveal.startHeightFraction(topRowHeight: 32, cardHeight: 76) - 32.0 / 76.0) < 1e-9, true)
        expectEqual(NotchReveal.startHeightFraction(topRowHeight: 32, cardHeight: 32), 0.9)
        expectEqual(NotchReveal.startHeightFraction(topRowHeight: 32, cardHeight: 0), 1)
        expectEqual(NotchReveal.heightDelay < NotchReveal.contentDelay, true)
        expectEqual(abs(NotchReveal.totalDuration - 0.30) < 1e-9, true)
        expectEqual(NotchReveal.totalDuration < 0.4, true)
    }

    do {
        typealias B = NotchWidthBounds
        expectEqual(B.expandedWidth(steady: 360, expandedSetting: 460), 460)
        expectEqual(B.expandedWidth(steady: 420, expandedSetting: 360), 420)
        expectEqual(B.expandedWidth(steady: 360, expandedSetting: 360), 360)
        expectEqual(B.normalized(steady: 400, expanded: 360) == (400, 400), true)
        expectEqual(B.normalized(steady: 300, expanded: 360) == (300, 360), true)
        expectEqual(B.normalized(steady: 360, expanded: 300) == (360, 360), true)

        typealias D = NotchWidthRangeDrag
        expectEqual(D.thumb(pressX: 40, steadyX: 30, expandedX: 120, dx: 0), .steady)
        expectEqual(D.thumb(pressX: 110, steadyX: 30, expandedX: 120, dx: -5), .expanded)
        expectEqual(D.thumb(pressX: 80, steadyX: 80, expandedX: 80, dx: 0), nil)
        expectEqual(D.thumb(pressX: 80, steadyX: 80, expandedX: 80, dx: 3), .expanded)
        expectEqual(D.thumb(pressX: 80, steadyX: 80, expandedX: 80, dx: -3), .steady)
        expectEqual(D.dragging(.steady, to: 300, steady: 360, expanded: 460) == (300, 460), true)
        expectEqual(D.dragging(.steady, to: 480, steady: 360, expanded: 460) == (460, 460), true)
        expectEqual(D.dragging(.expanded, to: 500, steady: 360, expanded: 460) == (360, 500), true)
        expectEqual(D.dragging(.expanded, to: 340, steady: 360, expanded: 460) == (360, 360), true)
    }

    do {
        expectEqual(LyricSecondaryLine.allCases.map(\.rawValue), ["off", "nextLine", "translation", "romanization"])
        expectEqual(LyricSecondaryLine.off.showsSecondaryRow, false)
        expectEqual(LyricSecondaryLine.allCases.filter(\.showsSecondaryRow).count, 3)
        expectEqual(LyricSecondaryLine.allCases.filter(\.hidesExpandedNextLinePreview), [.nextLine])
        for secondary in LyricSecondaryLine.allCases {
            expectEqual(LyricSecondaryLine.expandedNextLinePreviewVisible(userToggle: false, secondary: secondary), false)
            expectEqual(LyricSecondaryLine.expandedNextLinePreviewVisible(userToggle: true, secondary: secondary),
                        secondary != .nextLine)
        }
        typealias R = NotchLyricRowMetrics
        expectEqual(R.rowHeight, 44)
        expectEqual(R.twoLineStackHeight, 31)
        expectEqual(R.twoLineStackHeight <= R.rowHeight, true)
        expectEqual((R.rowHeight - R.twoLineStackHeight) / 2 >= 4, true)

        expectEqual(R.mainLineHeight(fontSize: R.defaultMainFontSize), 15)
        expectEqual(R.mainLineHeight, 15)
        expectEqual(R.secondaryLineHeight, 13)
        expectEqual(R.secondaryFontSize, 11)
        expectEqual(R.mainFontSizeRange.contains(R.defaultMainFontSize), true)
        expectEqual(R.mainFontSizeRange.lowerBound < R.defaultMainFontSize, true)
        let maxStack = R.twoLineStackHeight(fontSize: R.mainFontSizeRange.upperBound)
        expectEqual(maxStack <= R.rowHeight, true)
        expectEqual((R.rowHeight - maxStack) / 2 >= 4, true)
        expectEqual(R.clampedMainFontSize(99), R.mainFontSizeRange.upperBound)
        expectEqual(R.clampedMainFontSize(1), R.mainFontSizeRange.lowerBound)
        expectEqual(R.mainLineHeight(fontSize: 99), R.mainLineHeight(fontSize: R.mainFontSizeRange.upperBound))
        expectEqual(R.lineHeight(fontSize: 16.6), 19)
        expectEqual(OverlayFontWeight.semibold.lighter(by: OverlayFontWeight.notchSecondarySteps), .medium)
    }

    do {
        typealias H = NotchHoverHit
        let steady = (w: CGFloat(257), h: CGFloat(77))
        expectEqual(H.isInside(point: CGPoint(x: 127, y: 40), cardWidth: steady.w, cardHeight: steady.h),
                    true)
        expectEqual(H.isInside(point: CGPoint(x: 127, y: 76), cardWidth: steady.w, cardHeight: steady.h),
                    true)

        for p in [CGPoint(x: 11, y: 140), CGPoint(x: 177, y: 145),
                  CGPoint(x: 120, y: 176), CGPoint(x: 124, y: 177)] {
            expectEqual(H.isInside(point: p, cardWidth: steady.w, cardHeight: steady.h),
                        false)
        }
        expectEqual(H.isInside(point: CGPoint(x: 300, y: 40), cardWidth: steady.w, cardHeight: steady.h),
                    false)
        expectEqual(H.isInside(point: CGPoint(x: -1, y: 40), cardWidth: steady.w, cardHeight: steady.h),
                    false)

        for p in [CGPoint(x: 120, y: 176), CGPoint(x: 124, y: 177)] {
            expectEqual(H.isInside(point: p, cardWidth: 482, cardHeight: 191),
                        true)
        }
    }

    do {
        typealias S = YouTubeMusicAdSkipper
        let skipJS = S.skipJS
        for js in [skipJS, S.verifyJS] {
            expectEqual(js.contains("\""), false)
            expectEqual(js.contains("\\"), false)
        }
        for marker in ["ad-showing", "'SKIPPABLE|'", "'NOTYET|'", "'NOTFOUND'", ".ytp-ad-skip-button-modern", ".ytp-skip-ad-button",
                       "getBoundingClientRect", "/[0-9]+/", ".ytp-ad-simple-ad-badge"] {
            expectEqual(skipJS.contains(marker), true)
        }
        for marker in ["ad-showing", "'STILL|'", "'CLEAR'", "'NOTFOUND'", ".ytp-ad-simple-ad-badge"] {
            expectEqual(S.verifyJS.contains(marker), true)
        }

        for forbidden in ["click()", "dispatchEvent", "currentTime =", "onAdUxClicked"] {
            expectEqual(skipJS.contains(forbidden), false)
        }
        expectEqual(S.verifyJS.contains("currentTime ="), false)

        for prefix in AccessibilitySkipPress.skipButtonClassPrefixes {
            expectEqual(skipJS.contains("." + prefix), true)
        }
        expectEqual(AccessibilitySkipPress.matchesSkipClass(["ytp-ad-skip-button-modern", "ytp-button", "ytp-ad-skip-button-icon-delhi"]), true)
        expectEqual(AccessibilitySkipPress.matchesSkipClass(["ytp-skip-ad-button"]), true)
        expectEqual(AccessibilitySkipPress.matchesSkipClass(["ytp-ad-skip-button"]), true)
        for wrapper in [["ytp-ad-skip-button-slot"], ["ytp-ad-skip-button-container", "ytp-ad-skip-button-container-detached"],
                        ["ytp-ad-text", "ytp-ad-skip-button-text"], ["ytp-skip-ad-button__text"], ["style-scope", "yt-icon-button"], []] {
            expectEqual(AccessibilitySkipPress.matchesSkipClass(wrapper), false)
        }
        expectEqual(AccessibilitySkipPress.matchesSkipTitle("跳过"), true)
        expectEqual(AccessibilitySkipPress.matchesSkipTitle(" Skip "), true)
        expectEqual(AccessibilitySkipPress.matchesSkipTitle("跳过广告设置"), false)

        expectEqual(S.skippability(from: .skippable(desc: "BUTTON.ytp-ad-skip-button-modern", badge: "赞助商广告 1/2 ·", videoTime: 6)),
                    .ready)
        expectEqual(S.skippability(from: .notYet(seconds: 5)), .after(seconds: 5))

        expectEqual(S.skippability(from: .notYet(seconds: nil)), .never)
        expectEqual(S.skippability(from: .notFound), .notInAd)

        expectEqual(S.showsSkipButton(.ready), true)
        expectEqual(S.showsSkipButton(.after(seconds: 3)), false)
        expectEqual(S.showsSkipButton(.never), false)
        expectEqual(S.showsSkipButton(.notInAd), false)

        expectEqual(S.showsSkipButton(nil), true)

        expectEqual(S.gateRetryDelay(after: .after(seconds: 5)), 5.4)
        expectEqual(S.gateRetryDelay(after: .after(seconds: 0)), 1.4)
        expectEqual(S.gateRetryDelay(after: .after(seconds: 999)), 20.4)
        expectEqual(S.gateRetryDelay(after: .ready), YouTubeMusicAdProbe.adRefreshInterval)
        expectEqual(S.gateRetryDelay(after: .never), YouTubeMusicAdProbe.adRefreshInterval)

        expectEqual(S.gateRetryDelay(after: .never, round: 0), S.fastStartDelay)
        expectEqual(S.gateRetryDelay(after: .never, round: S.fastStartRounds - 1), S.fastStartDelay)
        expectEqual(S.gateRetryDelay(after: .never, round: S.fastStartRounds), YouTubeMusicAdProbe.adRefreshInterval)
        expectEqual(S.fastStartDelay * Double(S.fastStartRounds) < YouTubeMusicAdProbe.adRefreshInterval, true)
        expectEqual(S.gateRetryDelay(after: .after(seconds: 5), round: 0), 5.4)
        expectEqual(S.gateMaxRounds >= 6, true)
        expectEqual(AccessibilitySkipPress.matchesSkipTitle("播放"), false)
        expectEqual(S.verifyDelay >= 0.3 && S.verifyDelay <= 2, true)
        expectEqual(S.parseClick("SKIPPABLE|BUTTON.ytp-ad-skip-button-modern|赞助商广告 1/2 ·|8"),
                    .skippable(desc: "BUTTON.ytp-ad-skip-button-modern", badge: "赞助商广告 1/2 ·", videoTime: 8))
        expectEqual(S.parseClick("SKIPPABLE|x"), nil)
        expectEqual(S.parseClick("SKIPPED|BUTTON.x|b|8"), nil)
        expectEqual(S.parseClick("NOTYET|3"), .notYet(seconds: 3))
        expectEqual(S.parseClick("\"NOTYET|\"\n"), .notYet(seconds: nil))
        expectEqual(S.parseClick("NOTFOUND"), .notFound)
        expectEqual(S.parseClick("garbage"), nil)
        expectEqual(S.parseClick(""), nil)
        expectEqual(S.parseVerify("STILL|赞助商广告 2/2 ·|0"), .still(badge: "赞助商广告 2/2 ·", videoTime: 0))
        expectEqual(S.parseVerify("CLEAR"), .clear)
        expectEqual(S.parseVerify("NOTFOUND"), .notFound)
        expectEqual(S.parseVerify("STILL"), nil)

        let clicked = S.ClickResult.skippable(desc: "b", badge: "赞助商广告 1/2 ·", videoTime: 9)
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .clear), true)
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .notFound), true)
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .still(badge: "赞助商广告 1/2 ·", videoTime: 10)), false)
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .still(badge: "赞助商广告 2/2 ·", videoTime: 10)), true)
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .still(badge: "赞助商广告 1/2 ·", videoTime: 0)), false)
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .still(badge: "", videoTime: -1)), false)
        expectEqual(S.adAdvanced(afterClick: .notFound, verify: .still(badge: "x", videoTime: 0)), false)
        let script = BrowserTabProbeScript.build(
            bundleID: "com.google.Chrome", family: .chromium,
            hostMarker: YouTubeMusicAdProbe.hostMarker, js: skipJS,
            eventTimeoutSeconds: YouTubeMusicAdProbe.eventTimeoutSeconds)
        expectEqual(script.contains("music.youtube.com"), true)
        expectEqual(script.contains("with timeout of"), true)

        expectEqual(S.isYouTubeMusicAd(artist: "selftest-artist-\(UUID().uuidString)", title: "selftest"), false)

        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/UI")
        let view = (try? String(contentsOfFile: ui.appendingPathComponent("NotchLyricsView.swift").path,
                                encoding: .utf8)) ?? ""
        let stage = (try? String(contentsOfFile: ui.appendingPathComponent("NotchEditorStage.swift").path,
                                 encoding: .utf8)) ?? ""
        expectEqual(view.isEmpty, false)
        expectEqual(view.contains("var isAdBreakNow: Bool { get }"), true)
        expectEqual(view.contains("hasTrack && !isAdBreakNow"), true)
        expectEqual(view.contains("if playback.isCurrentTrackAdBreak {\n                    adStatusColumn"), true)
        expectEqual(view.contains("showsLyricsOffsetControls: playback.showsLyricsOffsetControls && !playback.isCurrentTrackAdBreak"),
                    true)
        expectEqual(view.contains("YouTubeMusicAdSkipper.isYouTubeMusicAd(artist: artist, title: title)"), true)
        expectEqual(view.contains("&& adSkipAvailable"), true)

        expectEqual(view.contains("@Published private(set) var adSkipAvailable"), true)
        expectEqual(view.contains("YouTubeMusicAdSkipper.probeSkippability(reportedBundleID: bundleID)"), true)

        expectEqual(view.contains(".onChange(of: controller.isAdBreakNow) { _, on in playback.syncAdSkipGate(adBreak: on) }"), true)
        expectEqual(view.contains("self?.syncAdSkipGate"), false)
        expectEqual(view.contains(".onAppear { playback.syncAdSkipGate(adBreak: controller.isAdBreakNow) }"), true)

        expectEqual(view.contains("playback.canSkipAd && !controller.isExpanded && !controller.showsLyrics"), true)
        if let earStart = view.range(of: "private func adBreakEarIcon"),
           let earEnd = view.range(of: "private var showsAdSkipHint") {
            let ear = String(view[earStart.lowerBound ..< earEnd.lowerBound])
            expectEqual(ear.contains("megaphone.fill"), true)
            expectEqual(ear.contains("forward.end.fill"), true)
            expectEqual(ear.contains("accessibilityHidden(!hint)"), true)
        } else {
            expectEqual(true, false)
        }
        expectEqual(view.contains("guard !skipAdInFlight else { return }"), true)
        expectEqual(view.contains("case .needsAccessibility?:") && view.contains("AccessibilitySkipPress.promptForTrust()"), true)
        expectEqual(view.contains("case .tabNotFrontmost?:"), true)
        expectEqual(view.contains(".disabled(playback.skipAdInFlight)"), true)
        expectEqual(stage.contains("var isAdBreakNow: Bool { false }"), true)

        expectEqual(view.contains("controller.isCollapsed || isIdleNoTrack || controller.isAdBreakNow"), true)

        expectEqual(view.contains("} else if controller.isAdBreakNow {"), true)
        expectEqual(view.contains("earShowsNothing"), false)
        expectEqual(view.contains("adBreakEarIcon(alignment: .leading)"), true)
        expectEqual(view.contains("Image(systemName: \"megaphone.fill\")"), true)

        expectEqual(view.contains("adBreakArtworkTile(side:"), true)
        expectEqual(view.contains("controller.isAdBreakNow || (playback.highResArtworkImage ?? playback.artworkImage) != nil"),
                    true)
        let window = (try? String(contentsOfFile: ui.appendingPathComponent("LyricsWindowView.swift").path,
                                  encoding: .utf8)) ?? ""
        let panel = (try? String(contentsOfFile: ui.deletingLastPathComponent()
                                    .appendingPathComponent("MenuBar/MenuBarPanel.swift").path,
                                 encoding: .utf8)) ?? ""
        expectEqual(window.isEmpty, false)
        expectEqual(panel.isEmpty, false)
        expectEqual(window.contains("if playback.isCurrentTrackAdBreak {") && window.contains("megaphone.fill"),
                    true)
        expectEqual(panel.contains("if playback.isCurrentTrackAdBreak {") && panel.contains("megaphone.fill"),
                    true)

        expectEqual(view.contains("adSlotText\n                    .font(playback.mainDetailFont)\n                adCountdown"), true)
        expectEqual(view.contains("if let slot = playback.currentAdSlot {"), true)
    }
}
