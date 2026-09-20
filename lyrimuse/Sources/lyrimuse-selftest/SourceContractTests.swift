import LyrimuseCore
import Foundation

@MainActor
func runSourceContractTests() {

    expectEqual(LyricsSurface.allCases.map(\.rawValue), ["overlay", "notch", "menuBar"])
    expectEqual(LyricsSurface.appearanceSectionStorageKey, "settings:appearanceSection")
    expectEqual(LyricsSurface.notch.appearanceSectionRawValue, "notch")
    expectEqual(LyricsSurface(rawValue: "menuBar"), .menuBar)
    expectEqual(LyricsSurface(rawValue: "other"), nil)

    do {

        func stringsPairs(_ path: String) -> [String: String]? {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            func unescape(_ s: Substring) -> String {
                s.replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\t", with: "\t")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            var pairs: [String: String] = [:]
            let pattern = #/^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/#
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                if let m = line.firstMatch(of: pattern) {
                    let key = unescape(m.1)

                    if pairs[key] != nil { return nil }
                    pairs[key] = unescape(m.2)
                }
            }
            return pairs
        }
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogPath = sourcesDir.deletingLastPathComponent()
            .appendingPathComponent("Localization/Localizable.xcstrings").path
        let resources = sourcesDir.appendingPathComponent("lyrimuse/Resources")

        struct CatalogPairs {
            var zh: [String: String] = [:]; var en: [String: String] = [:]; var hant: [String: String] = [:]

            var missingHant: [String] = []
        }
        func catalogPairs(_ path: String) -> CatalogPairs? {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["sourceLanguage"] as? String == "zh-Hans",
                  let strings = obj["strings"] as? [String: Any], !strings.isEmpty
            else { return nil }
            var out = CatalogPairs()
            for (key, raw) in strings {
                let localizations = (raw as? [String: Any])?["localizations"] as? [String: Any]
                func value(_ lang: String) -> String? {
                    (((localizations?[lang] as? [String: Any])?["stringUnit"]) as? [String: Any])?["value"] as? String
                }

                out.zh[key] = value("zh-Hans") ?? key
                if let hant = value("zh-Hant"), !hant.isEmpty {
                    out.hant[key] = hant
                } else {
                    out.missingHant.append(key)
                    out.hant[key] = out.zh[key]!
                }
                guard let en = value("en"), !en.isEmpty else { return nil }
                out.en[key] = en
            }
            return out
        }

        if let catalog = catalogPairs(catalogPath),
           let zhGen = stringsPairs(resources.appendingPathComponent("zh-hans.lproj/Localizable.strings").path),
           let hantGen = stringsPairs(resources.appendingPathComponent("zh-hant.lproj/Localizable.strings").path),
           let enGen = stringsPairs(resources.appendingPathComponent("en.lproj/Localizable.strings").path) {
            expectEqual(catalog.zh.isEmpty, false)
            expectEqual(catalog.missingHant.sorted(), [])

            func diff(_ a: [String: String], _ b: [String: String], _ tag: String) {
                expectEqual(Set(a.keys).subtracting(b.keys).sorted(), [])
                expectEqual(Set(b.keys).subtracting(a.keys).sorted(), [])
                let valueDiff = a.keys.filter { b[$0] != nil && a[$0] != b[$0] }.sorted()
                expectEqual(valueDiff, [])
            }
            diff(catalog.zh, zhGen, "zh-hans")
            diff(catalog.hant, hantGen, "zh-hant")
            diff(catalog.en, enGen, "en")

            expectEqual(UILanguage.resolve(preferred: "zh-Hans-CN"), "zh-hans")
            expectEqual(UILanguage.resolve(preferred: "zh"), "zh-hans")
            expectEqual(UILanguage.resolve(preferred: "zh-SG"), "zh-hans")
            expectEqual(UILanguage.resolve(preferred: "zh-Hant-TW"), "zh-hant")
            expectEqual(UILanguage.resolve(preferred: "zh-TW"), "zh-hant")
            expectEqual(UILanguage.resolve(preferred: "zh-HK"), "zh-hant")
            expectEqual(UILanguage.resolve(preferred: "zh-MO"), "zh-hant")
            expectEqual(UILanguage.resolve(preferred: "zh-Hans-HK"), "zh-hans")
            expectEqual(UILanguage.resolve(preferred: "zh-Hant-CN"), "zh-hant")
            expectEqual(UILanguage.resolve(preferred: "en-GB"), "en")
            expectEqual(UILanguage.resolve(preferred: "EN"), "en")
            expectEqual(UILanguage.resolve(preferred: "ja-JP"), "zh-hans")
            expectEqual(UILanguage.isTraditionalChineseTag("ja-JP"), false)

            let uiSources = sourcesDir.appendingPathComponent("lyrimuse")
            let callPattern = #/L10n\.t\(\s*"((?:[^"\\]|\\.)*)"\s*\)/#
            var literalKeys: Set<String> = []
            var scannedFiles = 0
            if let walker = FileManager.default.enumerator(atPath: uiSources.path) {
                for case let rel as String in walker where rel.hasSuffix(".swift") {
                    let path = uiSources.appendingPathComponent(rel).path
                    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                    scannedFiles += 1
                    for m in text.matches(of: callPattern) {
                        literalKeys.insert(
                            String(m.1)
                                .replacingOccurrences(of: "\\n", with: "\n")
                                .replacingOccurrences(of: "\\t", with: "\t")
                                .replacingOccurrences(of: "\\\"", with: "\"")
                                .replacingOccurrences(of: "\\\\", with: "\\"))
                    }
                }
            }

            expectEqual(scannedFiles > 0 && !literalKeys.isEmpty, true)
            expectEqual(literalKeys.subtracting(catalog.zh.keys).sorted(), [])
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let uiSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")

        func topLevelArguments(_ chars: [Character], openIndex: Int) -> String? {
            var depth = 0
            var collected: [Character] = []
            var i = openIndex
            let limit = min(chars.count, openIndex + 4000)
            while i < limit {
                let c = chars[i]
                if c == "(" {
                    depth += 1
                    if depth > 1 { collected.append(c) }
                } else if c == ")" {
                    depth -= 1
                    if depth == 0 { return String(collected) }
                    collected.append(c)
                } else if depth >= 1 {
                    if depth == 1 { collected.append(c) }
                }
                i += 1
            }
            return nil
        }

        let needle = Array("Slider(")
        var scannedFiles = 0
        var directCallSites = 0
        var offenders: [String] = []
        if let walker = FileManager.default.enumerator(atPath: uiSources.path) {
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard let text = try? String(contentsOfFile: uiSources.appendingPathComponent(rel).path,
                                             encoding: .utf8) else { continue }
                scannedFiles += 1
                let chars = Array(text)
                var i = 0
                while i + needle.count <= chars.count {
                    guard Array(chars[i ..< (i + needle.count)]) == needle else { i += 1; continue }

                    let prev: Character? = i > 0 ? chars[i - 1] : nil
                    let isDirectCall = prev.map { !($0.isLetter || $0.isNumber || $0 == "_") } ?? true
                    if isDirectCall {
                        directCallSites += 1
                        if let args = topLevelArguments(chars, openIndex: i + needle.count - 1),
                           args.contains("step:") {
                            offenders.append(rel)
                        }
                    }
                    i += needle.count
                }
            }
        }

        expectEqual(scannedFiles > 0 && directCallSites > 0, true)
        expectEqual(offenders.sorted(), [])
    }

    do {
        let uiSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")

        var offenders: [String] = []
        var scannedFiles = 0
        var readSites = 0
        if let walker = FileManager.default.enumerator(atPath: uiSources.path) {
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard let text = try? String(contentsOfFile: uiSources.appendingPathComponent(rel).path,
                                             encoding: .utf8) else { continue }
                scannedFiles += 1
                for (i, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(rawLine)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                    guard line.contains(".artworkImage") else { continue }

                    if line.contains("@Published") || line.contains("$artworkImage")
                        || line.contains("removeDuplicates") || line.contains(".sink")
                        || line.contains("\\.artworkImage") || line.contains("artworkImage = ") {
                        continue
                    }
                    readSites += 1

                    if line.contains("highResArtworkImage ?? ") || line.contains("displayArtworkImage") {
                        continue
                    }
                    offenders.append("\(rel):\(i + 1)")
                }
            }
        }

        expectEqual(scannedFiles > 0 && readSites > 0, true)
        expectEqual(offenders.sorted(), [])
    }

    do {
        let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let core = sourcesRoot.appendingPathComponent("LyrimuseCore/Local")
        let app = sourcesRoot.appendingPathComponent("lyrimuse")
        func code(_ url: URL) -> String? {
            guard let text = try? String(contentsOfFile: url.path, encoding: .utf8) else { return nil }
            return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        func count(_ text: String, _ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }
        if let lps = code(core.appendingPathComponent("LocalPlaybackSource.swift")) {
            expectEqual(count(lps, "verifySpotifyAdViaAppleScript(forKey:"), 1)
            expectEqual(count(lps, "spotifyNativeAdCheckForNewTrack(snapshot: snapshot)") >= 1, true)
            expectEqual(lps.contains("SpotifyNotificationHint(userInfo: note.userInfo)"), true)
            expectEqual(lps.contains("SpotifyPositionProbe.shared.setArtworkSink"), true)
            expectEqual(lps.contains("BrowserPositionProbe.shared.setArtworkSink"), true)
        } else {
            expectEqual(true, false)
        }
        if let web = code(core.appendingPathComponent("BrowserPositionProbe.swift")) {
            expectEqual(web.contains("img[data-testid=cover-art-image]"), true)
            expectEqual(web.contains("return parseReading(fromOsascriptOutput:"), true)
        } else {
            expectEqual(true, false)
        }
        if let probe = code(core.appendingPathComponent("SpotifyPositionProbe.swift")) {
            for needle in ["player position", "spotify url of current track", "artwork url of current track"] {
                expectEqual(probe.contains(needle), true)
            }
        } else {
            expectEqual(true, false)
        }

        if let mpc = code(core.appendingPathComponent("MusicPlaybackController.swift")) {
            expectEqual(count(mpc, "shuffling enabled") >= 2, true)
            expectEqual(count(mpc, "spotifyPlaybackMode(fromModePart") >= 3, true)
            expectEqual(mpc.contains("public static func spotifyCurrentTrackURI()"), true)
        } else {
            expectEqual(true, false)
        }
        if let reveal = code(app.appendingPathComponent("SpotifyReveal.swift")) {
            expectEqual(reveal.contains("MusicPlaybackController.spotifyCurrentTrackURI()"), true)
            expectEqual(reveal.contains("SpotifyURI.deepLink"), true)
            expectEqual(reveal.contains("withApplicationAt:"), true)
        } else {
            expectEqual(true, false)
        }
        if let lwv = code(app.appendingPathComponent("UI/LyricsWindowView.swift")) {
            expectEqual(lwv.contains("SpotifyReveal.revealCurrentTrack"), true)
        } else {
            expectEqual(true, false)
        }
        if let pc = code(app.appendingPathComponent("PlaybackCoordinator.swift")) {
            expectEqual(pc.contains("s.$spotifyArtworkURL"), true)
            expectEqual(count(pc, "refreshSpotifyOriginalCover(") >= 2, true)

            expectEqual(count(pc, "image.size.width"), 0)
            expectEqual(count(pc, ".pixelWidth") >= 3, true)
        } else {
            expectEqual(true, false)
        }
        if let cached = code(app.appendingPathComponent("UI/CachedImage.swift")) {
            expectEqual(cached.contains("image.pixelWidth * image.pixelHeight"), true)
            expectEqual(cached.contains("var pixelWidth: Int"), true)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let repo = sourcesRoot.deletingLastPathComponent().deletingLastPathComponent()
        func code(_ url: URL) -> String? {
            guard let text = try? String(contentsOfFile: url.path, encoding: .utf8) else { return nil }
            return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        func count(_ text: String, _ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }
        if let poller = code(repo.appendingPathComponent("lyrimuse-collector/poller.go")) {
            expectEqual(count(poller, "= lastfmExcluded(p.cur.Bundle)"), 2)
            expectEqual(count(poller, "s.lastfmExcluded") >= 1, true)
            expectEqual(count(poller, "!lastfmSkip") >= 1, true)
            expectEqual(count(poller, "!p.sess.lastfmExcluded") >= 1, true)
            expectEqual(count(poller, "historyExcluded"), 0)
        } else {
            expectEqual(true, false)
        }
        if let features = code(repo.appendingPathComponent("lyrimuse-collector/features.go")) {
            expectEqual(features.contains("json:\"lastfm_excluded_bundles,omitempty\""), true)
            expectEqual(features.contains("resolveLastfmExcludedBundles(f.LastfmExcludedBundles)"), true)
        } else {
            expectEqual(true, false)
        }
        if let store = code(sourcesRoot.appendingPathComponent("lyrimuse/Settings/FeatureSettingsStore.swift")) {
            expectEqual(store.contains("case lastfmExcludedBundles = \"lastfm_excluded_bundles\""), true)
            expectEqual(count(store, "lastfmExcludedBundles") >= 6, true)
        } else {
            expectEqual(true, false)
        }
        if let tab = code(sourcesRoot.appendingPathComponent("lyrimuse/AccountLinkingTab.swift")) {
            expectEqual(tab.contains("PlayerBundleChipsRow("), true)
            expectEqual(count(tab, "updateLastfmExclusion(") >= 1, true)

            expectEqual(tab.contains("builtIn + trusted"), true)
        } else {
            expectEqual(true, false)
        }

        do {
            let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            func text(_ rel: String) -> String? {
                try? String(contentsOfFile: repoRoot.appendingPathComponent(rel).path, encoding: .utf8)
            }
            if let mcc = text("lyrimuse/Sources/LyrimuseCore/Local/MediaControlClient.swift") {
                expectEqual(mcc.contains("radioStationHash"), true)
                expectEqual(mcc.contains("RadioTrackClock.advance("), true)

                expectEqual(mcc.contains("duration: isRadio ? nil"), false)
                expectEqual(mcc.contains("elapsedTime: radioPosition ?? elapsed"), true)
                expectEqual(mcc.contains("guard snapshot.isRadio != true else { return snapshot }"), true)

                expectEqual(mcc.contains("startedAt: Self.lastTrackChangeObserved(forKey: trackKey)"), true)

                expectEqual(mcc.contains("RadioClockFile.restorable("), true)
                expectEqual(mcc.contains("RadioClockFile.write(record)"), true)

                expectEqual(mcc.contains("if players == [.appleMusic] { return radioAwareAppleMusicSnapshot() }"), true)
                expectEqual(mcc.contains("snapshot.withRadio(position: position)"), true)
                expectEqual(mcc.contains("guard raw.bundleIdentifier == PlaybackPlayer.appleMusic.bundleIdentifier else { return nil }"), true)
            } else {
                expectEqual(true, false)
            }

            if let mcs = text("lyrimuse/Sources/LyrimuseCore/Local/MediaControlSnapshot.swift") {
                expectEqual(mcs.contains("elapsedTime: position, playing: playing"), true)
                expectEqual(mcs.contains("anchorElapsedTime: position, isRadio: true"), true)

                expectEqual(mcs.contains("album: album, duration: duration,"), true)
            } else {
                expectEqual(true, false)
            }
            if let lps = text("lyrimuse/Sources/LyrimuseCore/Local/LocalPlaybackSource.swift") {

                expectEqual(lps.contains("RadioTrackClock.passedTrackEnd("), true)
                expectEqual(lps.contains("if radioTrackFinished {"), true)

                expectEqual(lps.contains("RadioStationCardFile.stationName("), true)

                expectEqual(lps.contains("let finished = stationCardName != nil || RadioTrackClock.passedTrackEnd("), true)
                expectEqual(lps.contains("noteRadioStationArtwork(data, forKey: expectedKey)"), true)

                expectEqual(lps.contains("LyricsOffsetStore.shared.nudgeRadio(by: deltaMs, forKey: radioKey)"), true)
                expectEqual(lps.contains("radioKey: radioKey"), true)
            } else {
                expectEqual(true, false)
            }

            for (rel, _) in [("lyrimuse/Sources/lyrimuse/UI/NotchLyricsView.swift", "灵动岛"),
                                ("lyrimuse/Sources/lyrimuse/UI/LyricsOverlayView.swift", "桌面悬浮歌词"),
                                ("lyrimuse/Sources/lyrimuse/UI/LyricsWindowView.swift", "歌词窗口"),
                                ("lyrimuse/Sources/lyrimuse/MenuBar/MenuBarPanel.swift", "菜单栏面板")] {
                if let face_text = text(rel) {
                    expectEqual(face_text.contains("L10n.t(\"口白\")"), true)

                    if rel.hasSuffix("LyricsWindowView.swift") {
                        expectEqual(face_text.contains("if playback.isRadioTalkBreak { return (\"dot.radiowaves.left.and.right\""), true)
                        expectEqual(face_text.contains("if playback.isRadioTalkBreak {\n            emptyState"), true)
                    }
                } else {
                    expectEqual(true, false)
                }
            }
            if let watcher = text("lyrimuse/Sources/LyrimuseCore/Local/MediaControlStreamWatcher.swift") {
                expectEqual(watcher.contains("MediaControlClient.noteTrackChangeObserved(key: changed, at: at)"), true)
            } else {
                expectEqual(true, false)
            }
            if let enrich = text("lyrimuse-collector/enrich.go") {

                expectEqual(enrich.contains("if radioStationCard(radio, artist, title) {"), true)
            } else {
                expectEqual(true, false)
            }

            if let lps = text("lyrimuse/Sources/LyrimuseCore/Local/LocalPlaybackSource.swift") {
                expectEqual(lps.contains("EnrichCacheReader.trackDurationSecs("), true)
                expectEqual(lps.contains("rawSnapshot.withDuration(cached)"), true)
            } else {
                expectEqual(true, false)
            }
            if let sys2 = text("lyrimuse-collector/system.go") {
                expectEqual(sys2.contains("\"catalogDurationSecs\": catalogDuration"), true)
                expectEqual(sys2.contains("state[\"catalogDurationSecs\"] = d"), true)
            } else {
                expectEqual(true, false)
            }
            if let poller = text("lyrimuse-collector/poller.go") {
                expectEqual(poller.contains("applyRadioClock(&p.cur,"), true)
                expectEqual(poller.contains("if p.cur.Artist == \"\" {"), true)
                expectEqual(poller.contains("if lm.ArtistName == \"\" {"), true)
                expectEqual(poller.contains("if artistName == \"\" {"), true)

                expectEqual(poller.contains("playing, tracked, radio bool) bool {"), true)
                expectEqual(poller.contains("&& playing && tracked && !radio"), true)
                expectEqual(poller.contains("p.cur.Playing, p.isTracked(), p.cur.Radio)"), true)

                expectEqual(poller.contains("needsRadioDurationBackfill("), true)
            } else {
                expectEqual(true, false)
            }
            if let sys = text("lyrimuse-collector/system.go") {
                expectEqual(sys.contains("\"radioStationHash\": raw.RadioStationHash"), true)
                expectEqual(sys.contains("state[\"radioStationHash\"] = hash"), true)
            } else {
                expectEqual(true, false)
            }
            if let snap = text("lyrimuse-collector/snapshot.go") {
                expectEqual(snap.contains("str(\"radioStationHash\") != \"\""), true)
                expectEqual(snap.contains("duration = num(\"catalogDurationSecs\")"), true)
            } else {
                expectEqual(true, false)
            }
        }

        do {
            let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let store = try? String(contentsOfFile: repoRoot
                .appendingPathComponent("lyrimuse/Sources/lyrimuse/Settings/FeatureSettingsStore.swift").path, encoding: .utf8)
            let go = try? String(contentsOfFile: repoRoot
                .appendingPathComponent("lyrimuse-collector/lastfmexclude.go").path, encoding: .utf8)
            let goMain = try? String(contentsOfFile: repoRoot
                .appendingPathComponent("lyrimuse-collector/main.go").path, encoding: .utf8)
            expectEqual(CollectorRestartPolicy.hotReloadedKeys, ["lastfm_excluded_bundles"])
            for key in CollectorRestartPolicy.hotReloadedKeys.sorted() {
                expectEqual(store?.contains("= \"\(key)\"") ?? false, true)
                expectEqual(go?.contains("json:\"\(key)\"") ?? false, true)
            }

            expectEqual(goMain?.contains("setLastfmExcludePath(featureFlagsPath)") ?? false, true)
            for needle in ["os.Stat(lastfmExcludePath)", "ModTime().Equal(lastfmExcludeMTime)", "currentLastfmExcludedBundles()"] {
                expectEqual(go?.contains(needle) ?? false, true)
            }
            expectEqual(go?.contains("len(features.LastfmExcludedBundles) == 0") ?? false, false)

            expectEqual(store?.contains("CollectorRestartPolicy.needsRestart(changedKeys:") ?? false, true)
        }

        if let row = code(sourcesRoot.appendingPathComponent("lyrimuse/Settings/PlayerLinkageRow.swift")) {
            expectEqual(count(row, "ChipFlowGeometry.rows(") >= 2, true)
            expectEqual(row.contains("ChipFlowGeometry.size("), true)
        } else {
            expectEqual(true, false)
        }
        if let view = code(sourcesRoot.appendingPathComponent("lyrimuse/SettingsView.swift")) {
            expectEqual(count(view, "listenHistoryCard") + count(view, "historyExcludedBundles"), 0)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        if let notch = try? String(contentsOfFile: appSources.appendingPathComponent("UI/NotchLyricsView.swift").path,
                                   encoding: .utf8) {
            let code = notch.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            func count(_ needle: String) -> Int { code.components(separatedBy: needle).count - 1 }

            let hasAdRow = code.contains("adCountdown")
            expectEqual(count("playback.mainFont)") >= (hasAdRow ? 2 : 1), true)
            expectEqual(count("playback.secondaryFont)") >= 2, true)
            if hasAdRow {
                expectEqual(count("playback.mainDetailFont)") >= 1, true)
            }
            expectEqual(count("playback.mainLineHeight") >= 1, true)
            for needle in ["s.$notchMainFont", "s.$notchMainDetailFont", "s.$notchSecondaryFont", "s.$notchFontSize"] {
                expectEqual(code.contains(needle), true)
            }
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }

        if let notch = read("UI/NotchLyricsView.swift") {
            let code = notch.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            expectEqual(code.components(separatedBy: "playback.lyricsAlignment.swiftUIAlignment").count - 1, 0)
            for accessor in ["playback.mainLyricAlignment", "playback.secondaryLyricAlignment", "playback.nextLineAlignment"] {
                expectEqual(code.contains(accessor), true)
            }
            expectEqual(code.contains("resolved(duetSide: displayLine?.side)"), true)
            expectEqual(code.contains("resolved(duetSide: nextLineSide)"), true)
            expectEqual(code.contains("p.$nextLineSide"), true)
        } else {
            expectEqual(true, false)
        }

        if let stage = read("UI/NotchEditorStage.swift") {
            expectEqual(stage.contains("settings.notchLyricsAlignment = AppSettings.defaultNotchLyricsAlignment"),
                        true)
        } else {
            expectEqual(true, false)
        }

        var controlDefs: [String] = []
        if let walker = FileManager.default.enumerator(atPath: appSources.path) {
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard let text = read(rel) else { continue }
                for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix("struct "), line.contains("AlignmentSegmentedControl"),
                          line.contains(": View") else { continue }
                    controlDefs.append(rel)
                }
            }
        }
        expectEqual(controlDefs.sorted(),
                    ["UI/LyricsAlignmentSegmentedControl.swift", "UI/OverlayStyleSettingsRows.swift"])

        if let control = read("UI/LyricsAlignmentSegmentedControl.swift") {
            expectEqual(control.contains("LyricsRestingAlignment.allCases"), false)
        }
        if let stage = read("UI/MenuBarEditorStage.swift") {
            expectEqual(stage.contains("options: LyricsRestingAlignment.menuBarOptions"), true)
        }
        if let settings = read("SettingsView.swift") {
            expectEqual(settings.contains("options: LyricsRestingAlignment.notchOptions"), true)
        }
        if let panel = read("MenuBar/MenuBarPanelQuickSettings.swift") {
            expectEqual(panel.contains("options: LyricsRestingAlignment.menuBarOptions"), true)
            expectEqual(panel.contains("options: LyricsRestingAlignment.notchOptions"), true)
            expectEqual(panel.contains("ForEach(Value.allCases"), false)
        }
        if let label = read("MenuBar/MenuBarScrollingLabel.swift") {
            expectEqual(label.components(separatedBy: "case .leading, .automatic:").count - 1, 2)
        }
        if let app = read("Settings/AppSettings.swift") {
            expectEqual(app.contains("static var menuBarOptions: [LyricsRestingAlignment] { [.leading, .center, .trailing] }"), true)
            expectEqual(app.contains("case nil: return .leading"), true)
        }
    }

    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }
        if let notch = read("UI/NotchLyricsView.swift") {
            expectEqual(notch.components(separatedBy: "playback.compactLine").count - 1, 0)
            expectEqual(notch.contains("secondary.showsSecondaryRow ? current : compact"), true)
            expectEqual(notch.contains("playback.displayLine?.words"), true)
            expectEqual(notch.contains("alignment: playback.secondaryLyricAlignment"), true)
        } else {
            expectEqual(true, false)
        }
        let rule = "LyricSecondaryLine.expandedNextLinePreviewVisible("
        for rel in ["UI/NotchLyricsWindowController.swift", "UI/NotchEditorStage.swift"] {
            if let text = read(rel) {
                expectEqual(text.contains(rule), true)
            } else {
                expectEqual(true, false)
            }
        }
        if let stage = read("UI/NotchEditorStage.swift") {
            expectEqual(stage.contains("settings.notchSecondaryLine = AppSettings.defaultNotchSecondaryLine"), true)
        }
        if let settingsView = read("SettingsView.swift") {

            expectEqual(settingsView.contains("!settings.notchSecondaryLine.hidesExpandedNextLinePreview"), true)
        }
        if let stage = read("UI/NotchEditorStage.swift") {
            expectEqual(stage.contains("!settings.notchSecondaryLine.hidesExpandedNextLinePreview, settings.notchExpandedShowsNextLine"), true)
        }
    }

    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }
        if let item = read("MenuBar/MenuBarStatusItem.swift") {
            expectEqual(item.contains("secondaryKind.showsSecondaryRow ? coordinator.currentLine : coordinator.compactLine"), true)
            expectEqual(item.contains("widthMode: renderWidth > 0 ? .fixed : settings.menuBarLyricsWidthMode"), true)
            expectEqual(item.contains("MenuBarMarqueeRenderer.mainFont(for: text, twoRows: twoRows)"), true)
            expectEqual(item.components(separatedBy: "font: rowState.mainFont").count - 1 >= 3, true)
            expectEqual(item.contains("settings.$menuBarSecondaryLine.dropFirst()"), true)
        } else {
            expectEqual(true, false)
        }
        if let label = read("MenuBar/MenuBarScrollingLabel.swift") {
            expectEqual(label.contains("MenuBarLyricRows.layout("), true)
            expectEqual(label.contains("MenuBarLyricRows.secondaryOpacity(for:"), true)
            expectEqual(label.contains("secondaryKind.showsSecondaryRow == next.secondaryKind.showsSecondaryRow"), true)
        }
        if let preview = read("UI/SectionPreviewBars.swift") {
            expectEqual(preview.components(separatedBy: "secondaryKind: secondaryKind)").count - 1, 2)
            expectEqual(preview.contains("|| twoRows {"), true)
        }
        if let stage = read("UI/MenuBarEditorStage.swift") {
            expectEqual(stage.contains("settings.menuBarSecondaryLine = AppSettings.defaultMenuBarSecondaryLine"), true)

            expectEqual(stage.components(separatedBy: "if settings.menuBarSecondaryLine.showsSecondaryRow {").count - 1, 1)
            expectEqual(stage.components(separatedBy: "MenuBarFontRows()").count - 1, 2)
        }
        if let notch = read("UI/NotchLyricsView.swift") {
            expectEqual(notch.contains("secondary.secondaryText(currentLine: current, nextLineText: next)"), true)
        }
    }

    do {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = sources.appendingPathComponent("LyrimuseCore/Local/LocalPlaybackSource.swift").path
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            expectEqual(text.contains("lyrics: variant.converted(JapaneseKanjiRepair.repair(raw, japaneseSong: japaneseSong))"), true)
            expectEqual(text.contains("lyricsYRC: variant.converted(JapaneseKanjiRepair.repair(rawYRC, japaneseSong: japaneseSong))"), true)
            expectEqual(text.contains("lyricsTr: variant.converted(found?.lyricsTr ?? \"\")"), true)
            expectEqual(text.contains("Romanizer.looksJapaneseSong(raw.isEmpty ? rawYRC : raw)"), true)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }

        for rel in ["OnboardingView.swift", "SettingsView.swift"] {
            guard let text = read(rel) else {
                expectEqual(true, false)
                continue
            }
            let offenders = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .filter { $0.contains("features.players.insert") || $0.contains("features.players.remove")
                            || $0.contains("features.players = [") }
            expectEqual(offenders, [])
        }

        if let onboarding = read("OnboardingView.swift") {
            expectEqual(onboarding.contains("BrowserPairing.trustAndPair("), true)

            let offenders = onboarding.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { _, raw in
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && !line.hasPrefix("///")
                        && line.contains("browserPlatformPairs")
                }
                .map { "OnboardingView.swift:\($0.offset + 1)" }
            expectEqual(offenders, [])
        } else {
            expectEqual(true, false)
        }

        if let settings = read("SettingsView.swift") {
            for forwarded in ["BrowserPairing.trustAndPair(", "BrowserPairing.pair(",
                              "BrowserPairing.unpair(", "BrowserPairing.addableBrowsers(",
                              "BrowserPairing.rememberManualBrowser(",
                              "BrowserPairing.chooseFromApplications(",
                              "BrowserPairing.forgetManualBrowserIfUnpaired("] {
                expectEqual(settings.contains(forwarded), true)
            }
        } else {
            expectEqual(true, false)
        }

        var platformTables: [String] = []
        if let walker = FileManager.default.enumerator(atPath: appSources.path) {
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard let text = read(rel) else { continue }
                let hit = text.split(separator: "\n", omittingEmptySubsequences: false).contains { raw in
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && !line.hasPrefix("///")
                        && line.contains("case \"youtubeMusic\"")
                }
                if hit { platformTables.append(rel) }
            }
        }
        expectEqual(platformTables.sorted(), ["Settings/WebPlatformIcon.swift"])

        if let onboarding = read("OnboardingView.swift") {
            let unpairCalls = onboarding.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .filter { $0.contains("BrowserPairing.unpair(") }
                .count
            expectEqual(unpairCalls, 1)

            expectEqual(onboarding.contains("BrowserPairing.candidateBrowsers("), true)
            let splitGroups = onboarding.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .filter { $0.contains("BrowserPairing.addableBrowsers(")
                            || $0.contains("BrowserPairing.pairedBrowsers(") }
            expectEqual(splitGroups, [])
        } else {
            expectEqual(true, false)
        }

        if let onboarding = read("OnboardingView.swift") {
            let rawIndexing = onboarding.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { _, raw in
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && !line.hasPrefix("///")
                        && line.contains("steps[step]")
                }
                .map { "OnboardingView.swift:\($0.offset + 1)" }
            expectEqual(rawIndexing, [])
            expectEqual(onboarding.contains("private var currentStep: Step"), true)
            expectEqual(onboarding.contains(".onChange(of: steps.count)"), true)

            expectEqual(onboarding.contains("features.players.contains(.appleMusic) || features.players.contains(.auto)"), true)

            let lockLines = onboarding.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .filter { $0.contains("nextIsLocked") && $0.contains("automation") }
            expectEqual(lockLines, [])

            expectEqual(onboarding.contains("if collectorRunning {\n            settings.hasCompletedOnboarding = true"), true)

            expectEqual(onboarding.contains("private var readinessItems: [ReadinessItem]"), true)

            expectEqual(onboarding.contains("BrowserPairing.chooseFromApplications("), true)
        }

        if let statusItem = read("MenuBar/MenuBarStatusItem.swift") {
            let gate = statusItem.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .contains { $0.contains("AppSettings.shared.hasCompletedOnboarding") }
            expectEqual(gate, true)
        } else {
            expectEqual(true, false)
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let translateGoPath = repoRoot.appendingPathComponent("lyrimuse-collector/translate.go").path
        if let goSource = try? String(contentsOfFile: translateGoPath, encoding: .utf8) {

            let goSentinel = goSource
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("const lyricsTrSourceMachine") }
                .flatMap { line -> String? in
                    guard let open = line.firstIndex(of: "\""),
                          let close = line.lastIndex(of: "\""), open < close else { return nil }
                    return String(line[line.index(after: open)..<close])
                }
            expectEqual(goSentinel, LyricsTranslationSource.machineSentinel)
        } else {
            expectEqual(true, false)
        }

        let biasGoPath = repoRoot.appendingPathComponent("lyrimuse-collector/positionbias.go").path
        let biasMainPath = repoRoot.appendingPathComponent("lyrimuse-collector/main.go").path
        if let goSource = try? String(contentsOfFile: biasGoPath, encoding: .utf8),
           let mainSource = try? String(contentsOfFile: biasMainPath, encoding: .utf8) {
            for tag in ["\"artist\"", "\"title\"", "\"bundle_id\"", "\"anchor_elapsed\"", "\"bias_secs\"", "\"written_at_ms\""] {
                expectEqual(goSource.contains("json:\(tag)"), true)
            }
            let suffix = PositionBiasFile.fileName.replacingOccurrences(of: "lyrimuse", with: "")
            expectEqual(mainSource.contains("clientName+\"\(suffix)\""), true)
        } else {
            expectEqual(true, false)
        }

        let coreLyrics = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LyrimuseCore/Lyrics")
        func readCore(_ name: String) -> String? {
            try? String(contentsOfFile: coreLyrics.appendingPathComponent(name).path, encoding: .utf8)
        }
        if let engine = readCore("LyricsSyncEngine.swift") {
            expectEqual(engine.contains("Romanizer.lineReading("), true)
            let inlined = engine.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { _, raw in
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && !line.hasPrefix("///")
                        && line.contains("Romanizer.readingFromSegments(")
                }
                .map { "LyricsSyncEngine.swift:\($0.offset + 1)" }
            expectEqual(inlined, [])
        } else {
            expectEqual(true, false)
        }
        if let helper = try? String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lyrics-romanize/main.swift").path, encoding: .utf8) {
            expectEqual(helper.contains("LyricsRomanization.romanizeLRC("), true)
        } else {
            expectEqual(true, false)
        }
        if let romanization = readCore("LyricsRomanization.swift") {
            expectEqual(romanization.contains("Romanizer.lineReading("), true)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let docPath = repoRoot.appendingPathComponent("docs/features/08-lyrics-engine.md").path

        func chineseNumeral(_ s: String) -> Int? {
            let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                                            "六": 6, "七": 7, "八": 8, "九": 9]
            let chars = Array(s)
            guard !chars.isEmpty, chars.count <= 3 else { return nil }
            guard let tenIdx = chars.firstIndex(of: "十") else {
                guard chars.count == 1, let v = digits[chars[0]] else { return nil }
                return v
            }
            let high = chars[..<tenIdx], low = chars[(tenIdx + 1)...]
            var value = 0
            if high.isEmpty {
                value = 10
            } else if high.count == 1, let v = digits[high[high.startIndex]] {
                value = v * 10
            } else {
                return nil
            }
            if low.isEmpty { return value }
            guard low.count == 1, let v = digits[low[low.startIndex]] else { return nil }
            return value + v
        }

        func rounds(in text: String, prefix: String) -> [Int] {
            var out: [Int] = []
            var rest = Substring(text)
            while let hit = rest.range(of: prefix + "第") {
                let tail = rest[hit.upperBound...]
                if let close = tail.firstIndex(of: "轮"),
                   let v = chineseNumeral(String(tail[tail.startIndex..<close])) {
                    out.append(v)
                }
                rest = rest[hit.upperBound...]
            }
            return out
        }
        if let doc = try? String(contentsOfFile: docPath, encoding: .utf8) {

            let entryRounds: [Int] = doc.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { $0.hasPrefix("- **第") }
                .compactMap { rounds(in: $0, prefix: "").first }
            expectNotEqual(entryRounds.count, 0)
            let counters = rounds(in: doc, prefix: "至今补到")
            expectEqual(counters.count, 1)
            expectEqual(counters.first, entryRounds.max())
            let expectedRun = Array(stride(from: entryRounds.min() ?? 0, through: entryRounds.max() ?? 0, by: 1))
            expectEqual(entryRounds, expectedRun)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let en = LegalNoticeLinks.usageNoticeURL(language: "en")
        expectEqual(en.absoluteString, "https://github.com/Yudaotor/lyrimuse/blob/main/README.md#license-and-copyright")
        let hans = LegalNoticeLinks.usageNoticeURL(language: "zh-hans")
        expectEqual(hans.absoluteString,
                    "https://github.com/Yudaotor/lyrimuse/blob/main/README.zh-CN.md#%E8%AE%B8%E5%8F%AF%E4%B8%8E%E7%89%88%E6%9D%83%E8%AF%B4%E6%98%8E")
        expectEqual(LegalNoticeLinks.usageNoticeURL(language: "zh-hant"), hans)
        expectEqual(LegalNoticeLinks.usageNoticeURL(language: "system"), en)
        expectEqual(LegalNoticeLinks.thirdPartyLicensesOnGitHub.absoluteString,
                    "https://github.com/Yudaotor/lyrimuse/blob/main/THIRD_PARTY_LICENSES")

        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageDir.deletingLastPathComponent()
        func read(_ url: URL) -> String? { try? String(contentsOfFile: url.path, encoding: .utf8) }
        func codeLines(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
        }
        if let readme = read(repoRoot.appendingPathComponent("README.md")) {
            expectEqual(readme.contains("\n## License and Copyright\n"), true)
        } else {
            expectEqual(true, false)
        }
        if let readme = read(repoRoot.appendingPathComponent("README.zh-CN.md")) {
            expectEqual(readme.contains("\n## 许可与版权说明\n"), true)
        } else {
            expectEqual(true, false)
        }
        let appSources = packageDir.appendingPathComponent("Sources/lyrimuse")
        if let settings = read(appSources.appendingPathComponent("SettingsView.swift")) {
            let code = codeLines(settings)
            expectEqual(code.contains { $0.contains("LegalNotices.openUsageNotice()") }, true)
            expectEqual(code.contains { $0.contains("LegalNotices.openThirdPartyLicenses()") }, true)
            expectEqual(code.contains { $0.contains("README.zh-CN.md") || $0.contains("license-and-copyright") }, false)
        } else {
            expectEqual(true, false)
        }
        if let onboarding = read(appSources.appendingPathComponent("OnboardingView.swift")) {
            let code = codeLines(onboarding)
            expectEqual(code.contains { $0.contains("LegalNotices.openUsageNotice()") }, true)
            expectEqual(code.contains { $0.contains("README.zh-CN.md") || $0.contains("license-and-copyright") }, false)
        } else {
            expectEqual(true, false)
        }
        if let buildScript = read(packageDir.appendingPathComponent("build.sh")) {
            let copies = buildScript.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .contains { $0.hasPrefix("cp ") && $0.contains("THIRD_PARTY_LICENSES") && $0.contains("Contents/Resources") }
            expectEqual(copies, true)
        } else {
            expectEqual(true, false)
        }
        if let ci = read(repoRoot.appendingPathComponent(".github/workflows/ci.yml")) {
            expectEqual(ci.contains("scripts/check_third_party_licenses.py"), true)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ipcCalls = ["MusicAutomationPermission.check(", "BrowserAutomationPermission.status(",
                        "CollectorServiceManager.state", "CollectorServiceManager.isRunning"]
        let allow: [(file: String, funcs: Set<String>)] = [
            ("lyrimuse/SettingsView.swift", ["refreshBrowserLiveStatus", "refreshAutomationStatus", "refreshCollectorState"]),
            ("lyrimuse/Settings/PlayerHealthMonitor.swift", ["refresh"]),
        ]
        for entry in allow {
            let path = sourcesDir.appendingPathComponent(entry.file).path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                expectEqual(true, false)
                continue
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var offenders: [String] = []
            var checked = 0
            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                guard ipcCalls.contains(where: { line.contains($0) }) else { continue }
                checked += 1

                var funcName = "<无所属函数>"
                var funcLine = 0
                for j in stride(from: i, through: 0, by: -1) {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if let r = t.range(of: "func ") , !t.hasPrefix("//") {
                        let after = t[r.upperBound...]
                        funcName = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                        funcLine = j
                        break
                    }
                }
                let between = lines[funcLine...i].joined(separator: "\n")
                let inAllowedFunc = entry.funcs.contains(funcName)
                let detached = between.contains("Task.detached")
                if !(inAllowedFunc && detached) {
                    offenders.append("\(entry.file):\(i + 1) 在 \(funcName)()\(detached ? "" : "、且不在 Task.detached 里"): \(line.prefix(80))")
                }
            }
            expectEqual(checked > 0, true)
            expectEqual(offenders, [])
        }
    }

    do {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        func restoreDefaultsBody(_ relativePath: String) -> String? {
            let path = sourcesDir.appendingPathComponent(relativePath).path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let start = text.range(of: "static func restoreDefaults() {") else { return nil }
            var depth = 0
            var body = ""
            for ch in text[start.lowerBound...] {
                body.append(ch)
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            return body.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        let settingsPath = sourcesDir.appendingPathComponent("lyrimuse/Settings/AppSettings.swift").path
        if let settings = try? String(contentsOfFile: settingsPath, encoding: .utf8),
           let notchBody = restoreDefaultsBody("lyrimuse/UI/NotchEditorStage.swift"),
           let menuBarBody = restoreDefaultsBody("lyrimuse/UI/MenuBarEditorStage.swift") {
            var notchConsts: [String] = []
            var menuBarConsts: [String] = []
            for m in settings.matches(of: #/static let (default(?:Notch|MenuBar)\w+)/#) {
                let name = String(m.1)
                if name.hasPrefix("defaultNotch") { notchConsts.append(name) } else { menuBarConsts.append(name) }
            }

            expectEqual(notchConsts.isEmpty || menuBarConsts.isEmpty, false)

            let exempt: Set<String> = ["defaultNotchContentWidth", "defaultNotchExpandedContentWidth"]

            expectEqual(notchConsts.filter { !exempt.contains($0) && !notchBody.contains("AppSettings.\($0)") }.sorted(), [])
            expectEqual(menuBarConsts.filter { !exempt.contains($0) && !menuBarBody.contains("AppSettings.\($0)") }.sorted(), [])
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/Settings/AppSettings.swift").path
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let m = text.firstMatch(of: #/static let defaultOverlayFontWeight: OverlayFontWeight = \.(\w+)/#)
            expectEqual(m.map { String($0.1) }, "semibold")
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let drawers = [
            ("悬浮歌词", "lyrimuse/UI/OverlayAllSettingsDrawer.swift"),
            ("灵动岛", "lyrimuse/SettingsView.swift"),
            ("菜单栏", "lyrimuse/UI/MenuBarEditorStage.swift"),
        ]
        var missing: [String] = []
        var unreadable: [String] = []
        for (surface, rel) in drawers {
            let path = sourcesDir.appendingPathComponent(rel).path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                unreadable.append(surface)
                continue
            }

            let defined = text.contains("private var resetRow: some View")

            let mounted = text.contains("\n                resetRow\n")
            if !(defined && mounted) { missing.append("\(surface)(定义=\(defined) 装配=\(mounted))") }
        }
        expectEqual(unreadable, [])
        expectEqual(missing, [])
    }

    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        let glassAPIs = ["glassEffect(", "glassEffectID(", "glassEffectTransition(", "glassEffectUnion(",
                         "GlassEffectContainer(", ".glassProminent", "buttonStyle(.glass)"]
        let allowed: Set<String> = ["Settings/SettingsDesignSystem.swift", "UI/LyricsOverlayView.swift"]
        var offenders: [String] = []
        var filesUsingGlass: Set<String> = []
        var missingGate: [String] = []
        var scanned = 0
        if let files = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                let rel = url.path.replacingOccurrences(of: appSources.path + "/", with: "")
                var uses = false
                for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("//") { continue }
                    guard glassAPIs.contains(where: { line.contains($0) }) else { continue }
                    uses = true
                    if !allowed.contains(rel) { offenders.append("\(rel):\(index + 1)") }
                }
                if uses {
                    filesUsingGlass.insert(rel)
                    if !text.contains("#available(macOS 26.0, *)") { missingGate.append(rel) }
                }
            }
        }
        expectEqual(scanned > 50, true)
        expectEqual(offenders.sorted(), [])
        expectEqual(missingGate.sorted(), [])
        expectEqual(filesUsingGlass.contains("Settings/SettingsDesignSystem.swift"), true)
        if let designSystem = try? String(contentsOf: appSources.appendingPathComponent("Settings/SettingsDesignSystem.swift"), encoding: .utf8) {
            for entry in ["func settingsCardBackground(", "func settingsGlassButtons(", "func settingsProminentGlassButton(",
                          "func clearGlassCapsule(", "struct SettingsGlassContainer"] {
                expectEqual(designSystem.contains(entry), true)
            }
        } else {
            expectEqual(true, false)
        }

        if let loginItem = try? String(
            contentsOf: appSources.appendingPathComponent("Settings/LoginItemManager.swift"),
            encoding: .utf8) {
            let offenders = loginItem.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { _, raw in
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    guard !line.hasPrefix("//"), !line.hasPrefix("///") else { return false }
                    return line.contains("launchctl") || line.contains("Process()")
                }
                .map { "LoginItemManager.swift:\($0.offset + 1)" }
            expectEqual(offenders, [])
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appSources = packageDir.appendingPathComponent("Sources/lyrimuse")
        let repoRoot = packageDir.deletingLastPathComponent()
        func codeLines(_ text: String) -> [(Int, String)] {
            text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                return line.hasPrefix("//") ? nil : (index + 1, line)
            }
        }

        var offenders: [String] = []
        var scanned = 0
        if let files = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                let rel = url.path.replacingOccurrences(of: appSources.path + "/", with: "")
                if rel == "AppExit.swift" { continue }
                for (lineNo, line) in codeLines(text)
                where line.contains("NSApp.terminate(") || line.contains("NSApplication.shared.terminate(") {
                    offenders.append("\(rel):\(lineNo)")
                }
            }
        }
        expectEqual(scanned > 50, true)
        expectEqual(offenders.sorted(), [])
        if let appExit = try? String(contentsOf: appSources.appendingPathComponent("AppExit.swift"), encoding: .utf8) {
            expectEqual(appExit.contains("exiting reason="), true)
            expectEqual(appExit.contains("category: \"lifecycle\""), true)
        } else {
            expectEqual(true, false)
        }
        if let delegate = try? String(contentsOf: appSources.appendingPathComponent("AppDelegate.swift"), encoding: .utf8) {
            let code = codeLines(delegate).map(\.1)
            expectEqual(code.contains { $0.contains("AppExit.logTermination(") }, true)
            expectEqual(code.contains { $0.contains("AppExit.installSigtermHandler()") }, true)
            expectEqual(code.contains { $0.contains("NSLog(") }, false)
        } else {
            expectEqual(true, false)
        }

        if let mainGo = try? String(contentsOf: repoRoot.appendingPathComponent("lyrimuse-collector/main.go"), encoding: .utf8) {
            let bare = codeLines(mainGo).filter { $0.1.contains("log.Fatal") }.map { "main.go:\($0.0)" }
            expectEqual(bare, [])
            let exits = codeLines(mainGo).filter { $0.1.contains("os.Exit(") }
            expectEqual(exits.count, 1)
        } else {
            expectEqual(true, false)
        }
        if let exitReason = try? String(contentsOf: repoRoot.appendingPathComponent("lyrimuse-collector/exitreason.go"), encoding: .utf8) {
            expectEqual(exitReason.contains("\"exiting reason=%s\""), true)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageDir.deletingLastPathComponent()
        let swiftPath = packageDir.appendingPathComponent("Sources/lyrimuse/Settings/FeatureSettingsStore.swift").path
        let goPath = repoRoot.appendingPathComponent("lyrimuse-collector/features.go").path
        if let swift = try? String(contentsOfFile: swiftPath, encoding: .utf8),
           let go = try? String(contentsOfFile: goPath, encoding: .utf8) {
            var keys: [String] = []
            var inEnum = false
            for raw in swift.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("enum CodingKeys: String, CodingKey, CaseIterable {") { inEnum = true; continue }
                guard inEnum else { continue }
                if line == "}" { break }
                guard line.hasPrefix("case ") else { continue }
                let body = line.dropFirst(5)
                if let eq = body.range(of: " = \"") {
                    keys.append(String(body[eq.upperBound...].dropLast()))
                } else {
                    keys.append(String(body).trimmingCharacters(in: .whitespaces))
                }
            }
            expectEqual(keys.count > 10, true)
            let missing = keys.filter { !go.contains("json:\"\($0),omitempty\"") && !go.contains("json:\"\($0)\"") }
            expectEqual(missing, [])
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageDir.deletingLastPathComponent()
        func read(_ url: URL) -> String? { try? String(contentsOfFile: url.path, encoding: .utf8) }
        let enrichGo = read(repoRoot.appendingPathComponent("lyrimuse-collector/enrich.go"))
        let breakerGo = read(repoRoot.appendingPathComponent("lyrimuse-collector/sourcebreaker.go"))
        let reader = read(packageDir.appendingPathComponent("Sources/LyrimuseCore/Local/EnrichCacheReader.swift"))
        let source = read(packageDir.appendingPathComponent("Sources/LyrimuseCore/Local/LocalPlaybackSource.swift"))
        if let enrichGo, let breakerGo, let reader, let source {

            expectEqual(enrichGo.contains("if (len(e.LyricsSourcesSkipped) > 0 || len(e.LyricsSourcesFailed) > 0) && e.LyricsFillCount == 0 {"), true)
            expectEqual(enrichGo.contains("if !anyLyricSourceCooling(e.LyricsSourcesSkipped) && !anyLyricSourceCooling(e.LyricsSourcesFailed) {"), true)

            for (tag, codingKey) in [("lyrics_sources_skipped", "case lyricsSourcesSkipped = \"lyrics_sources_skipped\""),
                                     ("lyrics_sources_failed", "case lyricsSourcesFailed = \"lyrics_sources_failed\""),
                                     ("lyrics_fill_count", "case lyricsFillCount = \"lyrics_fill_count\"")] {
                expectEqual(enrichGo.contains("json:\"\(tag),omitempty\""), true)
                expectEqual(reader.contains(codingKey), true)
            }

            expectEqual(reader.contains("lyrics.isEmpty && (!sourcesSkipped.isEmpty || !sourcesFailed.isEmpty) && fillCount == 0"), true)
            expectEqual(source.contains("&& !(found?.searchIncomplete ?? false)"), true)

            expectEqual(breakerGo.contains("idx := st.trips"), true)

            let breakerCode = breakerGo.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }.joined(separator: "\n")
            expectEqual(breakerCode.contains("st.consecutive - lyricSourceBreakerTripAfter"), false)
        } else {
            expectEqual(true, false)
        }

        expectEqual(enrichLyricsSearchIncomplete(lyrics: "", sourcesSkipped: ["netease"], fillCount: 0), true)
        expectEqual(enrichLyricsSearchIncomplete(lyrics: "[00:00.00] a", sourcesSkipped: ["netease"], fillCount: 0), false)
        expectEqual(enrichLyricsSearchIncomplete(lyrics: "", sourcesSkipped: [], fillCount: 0), false)
        expectEqual(enrichLyricsSearchIncomplete(lyrics: "", sourcesSkipped: ["netease"], fillCount: 1), false)
    }

    do {
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageDir.deletingLastPathComponent()
        func read(_ url: URL) -> String? { try? String(contentsOfFile: url.path, encoding: .utf8) }
        let swiftEnum = read(packageDir.appendingPathComponent("Sources/lyrimuse/Settings/FeatureSettingsStore.swift"))
        let go = read(repoRoot.appendingPathComponent("lyrimuse-collector/enrich.go"))
        let sheet = read(packageDir.appendingPathComponent("Sources/lyrimuse/LyricsManager/LyricsSearchSheet.swift"))
        if let swiftEnum, let go, let sheet {

            var swiftNames: [String] = []
            var inEnum = false
            for raw in swiftEnum.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("public enum LyricsSource: String") { inEnum = true; continue }
                guard inEnum else { continue }
                if line == "}" { break }
                guard line.hasPrefix("case ") else { continue }
                swiftNames += line.dropFirst(5).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }

            var goNames: [String] = []
            if let start = go.range(of: "var lyricSourceNames = []string{"),
               let end = go[start.upperBound...].range(of: "}") {
                goNames = go[start.upperBound..<end.lowerBound].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            expectEqual(swiftNames.count >= 9, true)
            expectEqual(goNames.count >= 9, true)
            expectEqual(Set(swiftNames).count, swiftNames.count)
            expectEqual(Set(swiftNames), Set(goNames))

            expectEqual(sheet.contains("LyricsSource.allCases"), true)
            expectEqual(sheet.contains("[\"netease\""), false)

            func chineseNumber(_ s: Substring) -> Int? {
                let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
                let chars = Array(s)
                switch chars.count {
                case 1: return chars[0] == "十" ? 10 : digits[chars[0]]
                case 2 where chars[0] == "十": return digits[chars[1]].map { 10 + $0 }
                case 2 where chars[1] == "十": return digits[chars[0]].map { $0 * 10 }
                case 3 where chars[1] == "十":
                    if let a = digits[chars[0]], let b = digits[chars[2]] { return a * 10 + b }
                    return nil
                default: return nil
                }
            }
            let marker = "个源都没找到可用的候选\")"
            if let end = sheet.range(of: marker),
               let start = sheet[..<end.lowerBound].range(of: "L10n.t(\"", options: .backwards) {
                let numeral = sheet[start.upperBound..<end.lowerBound]
                expectEqual(chineseNumber(numeral), swiftNames.count)
            }

        } else {
            expectEqual(true, false)
        }
    }

    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }
        var callSites: [String] = []
        if let walker = FileManager.default.enumerator(atPath: appSources.path) {
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard rel != "LyricsManager/LyricsSearchSheet.swift", let text = read(rel) else { continue }
                let hit = text.split(separator: "\n").contains { raw in
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && line.contains("LyricsSearchSheet(")
                }
                if hit { callSites.append(rel) }
            }
        }
        expectEqual(callSites.sorted(),
                    ["LyricsManager/LyricsManagerView.swift", "LyricsManager/LyricsQuickSearchWindow.swift",
                     "UI/LyricsWindowView.swift"])
        for rel in callSites.sorted() {
            guard let text = read(rel) else { continue }
            for marker in ["isPlainTextOnly", "savePlainTextEdit(", "manualPickLocksLyrics", "fromManualPick: true", "currentFingerprint:"] {
                expectEqual(text.contains(marker), true)
            }
        }
    }

    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }
        if let settings = read("SettingsView.swift") {
            expectEqual(settings.contains("static let lastTabStorageKey = \"settings:lastTab\""), true)
            expectEqual(settings.contains("@AppStorage(SettingsTab.lastTabStorageKey)"), true)
            expectEqual(settings.contains(".tab(SettingsTab.restoredLastTab())"), true)
            expectEqual(settings.contains("if case .tab(let tab)? = item { lastTabRaw = tab.rawValue }"), true)
        } else {
            expectEqual(true, false)
        }
        if let portability = read("Settings/ConfigPortability.swift") {
            expectEqual(portability.contains("hasPrefix(\"settings:\")"), false)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }

        func body(of source: String, from marker: String) -> String? {
            guard let start = source.range(of: marker) else { return nil }
            let rest = source[start.lowerBound...]
            guard let end = rest.range(of: "\n    }\n") else { return nil }
            return String(rest[..<end.lowerBound])
        }
        for (file, marker) in [("MenuBar/MenuBarStatusItem.swift", "private func followReadingPath(for text: String)"),
                               ("UI/SectionPreviewBars.swift", "private var followReadingPath:")] {
            guard let source = read(file) else {
                expectEqual(true, false)
                continue
            }
            guard let fn = body(of: source, from: marker) else {
                expectEqual(true, false)
                continue
            }
            expectEqual(fn.contains("menuBarLyricsKaraoke"), false)
            expectEqual(fn.contains("MenuBarMarquee.followReadingPath("), true)
            expectEqual(source.contains("followPath: followReadingPath"), true)
        }
        if let label = read("MenuBar/MenuBarScrollingLabel.swift") {
            expectEqual(label.contains("$0.followPath == next.followPath"), true)
            expectEqual(label.contains("MenuBarMarquee.followScrollPath("), true)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let menuBarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/MenuBar")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: menuBarDir.path)) ?? [])
            .filter { $0.hasSuffix(".swift") }.sorted()
        expectEqual(files.isEmpty, false)
        var offenders: [String] = []
        let hardcoded = try? NSRegularExpression(pattern: #"contentsScale\s*=\s*[0-9]"#)
        for f in files {
            guard let src = try? String(contentsOfFile: menuBarDir.appendingPathComponent(f).path, encoding: .utf8) else { continue }
            if src.contains("NSScreen.main?.backingScaleFactor") { offenders.append("\(f): NSScreen.main 猜屏") }
            if let hardcoded,
               hardcoded.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)) != nil {
                offenders.append("\(f): contentsScale 写死数字")
            }
        }
        expectEqual(offenders, [])
        for f in ["MenuBarScrollingLabel.swift", "MenuBarLiveIconView.swift"] {
            let src = (try? String(contentsOfFile: menuBarDir.appendingPathComponent(f).path, encoding: .utf8)) ?? ""
            expectEqual(src.contains("override func viewDidChangeBackingProperties()"), true)
            expectEqual(src.contains("menuBarBitmapScale"), true)
        }
    }

    do {
        let menuBarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/MenuBar")
        let store = (try? String(contentsOfFile: menuBarDir.appendingPathComponent("MenuBarAppearance.swift").path,
                                 encoding: .utf8)) ?? ""
        expectEqual(store.isEmpty, false)
        expectEqual(store.contains("static let settleDelay: TimeInterval"), true)
        expectEqual(store.contains("func observe(_ view: NSView)"), true)
        expectEqual(store.contains("func hostAppearanceDidChange()"), true)
        expectEqual(store.contains("func update(from"), false)

        let writes = store.components(separatedBy: "\n").filter {
            $0.contains("isDark = ") && !$0.contains("@Published")
        }
        expectEqual(writes.count, 1)
        let hover = (try? String(contentsOfFile: menuBarDir.appendingPathComponent("MenuBarHoverControlsView.swift").path,
                                 encoding: .utf8)) ?? ""
        expectEqual(hover.contains("MenuBarAppearanceStore.shared.observe(host)"), true)
        expectEqual(hover.contains("MenuBarAppearanceStore.shared.hostAppearanceDidChange()"), true)
        expectEqual(hover.contains("effectiveAppearance.bestMatch"), false)
    }

    do {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func codeLines(_ rel: String) -> String {
            let src = (try? String(contentsOfFile: appDir.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""

            return src.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        for f in ["Settings/ConfigStore.swift", "Settings/FeatureSettingsStore.swift"] {
            let code = codeLines(f)
            expectEqual(code.isEmpty, false)
            expectEqual(code.contains("JSONConfigDocument.load(url:"), true)
            expectEqual(code.contains("document.save(fields:"), true)
            expectEqual(code.contains("Data(contentsOf:"), false)
            expectEqual(code.contains(".write(to:"), false)
            expectEqual(code.contains("writeSecurely(to:"), false)
            expectEqual(code.contains("var loadFailure: String?"), true)
            expectEqual(code.contains("catch ConfigFileSaveError.refusedCorruptFile"), true)
            expectEqual(code.contains("func discardCorruptFileAndSave()"), true)
        }
        let settingsView = codeLines("SettingsView.swift")
        expectEqual(settingsView.contains("ConfigFileDamageBanner()"), true)
        let banner = codeLines("Settings/ConfigFileDamageBanner.swift")
        expectEqual(banner.contains("discardCorruptFileAndSave()"), true)
        expectEqual(banner.contains("activateFileViewerSelecting"), true)
    }

    do {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func code(_ rel: String) -> String {
            (try? String(contentsOfFile: appDir.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
        }
        expectEqual(code("SettingsView.swift").contains("CollectorApplyStatusBar()"), true)
        let bar = code("Settings/CollectorApplyStatusBar.swift")
        expectEqual(bar.isEmpty, false)
        expectEqual(bar.contains(".isRestarting"), true)
        expectEqual(bar.contains(".pendingUntilServiceEnabled"), true)
        expectEqual(bar.contains(".lastError"), true)
        expectEqual(bar.contains("L10n.t(\"重试\")"), true)
        expectEqual(bar.contains("clearApplyStatus()"), true)
        let coordinator = code("Settings/CollectorRestartCoordinator.swift")
        expectEqual(coordinator.contains("@Published public private(set) var isRestarting"), true)
        expectEqual(coordinator.contains("isRestarting = !waiters.isEmpty"), true)
        for f in ["Settings/ConfigStore.swift", "Settings/FeatureSettingsStore.swift"] {
            let s = code(f)
            expectEqual(s.contains("var pendingUntilServiceEnabled"), true)
            expectEqual(s.contains("if !AppSettings.shared.collectorServiceEnabled {"), true)
            expectEqual(s.contains("func clearApplyStatus()"), true)
            expectEqual(s.contains("L10n.t(\"后台采集服务重启失败\")"), false)
        }
    }

    skillGuard: do {

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let skillsDir = repoRoot.appendingPathComponent(".claude/skills")

        guard FileManager.default.fileExists(atPath: skillsDir.path) else { break skillGuard }
        let expected = ["lyrimuse-lyrics-triage", "lyrimuse-release", "lyrimuse-verify-ui"]
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: skillsDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        expectEqual(found, expected)
        let linkPattern = try? NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
        let codePattern = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#)
        let pathPrefixes = ["lyrimuse/", "lyrimuse-collector/", "docs/", ".github/", ".claude/"]
        for name in expected {
            let file = skillsDir.appendingPathComponent("\(name)/SKILL.md")
            guard let src = try? String(contentsOfFile: file.path, encoding: .utf8) else {
                expectEqual(true, false)
                continue
            }
            let lineCount = src.split(separator: "\n", omittingEmptySubsequences: false).count
            expectEqual(lineCount <= 80, true)
            expectEqual(src.hasPrefix("---\nname: \(name)\n"), true)
            expectEqual(src.contains("\ndescription: "), true)
            expectEqual(src.contains("AGENTS.md"), true)
            let ns = src as NSString
            let whole = NSRange(location: 0, length: ns.length)
            var missing: [String] = []
            if let linkPattern {
                for m in linkPattern.matches(in: src, range: whole) {
                    var target = ns.substring(with: m.range(at: 1))
                    if target.hasPrefix("http") { continue }
                    if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
                    guard !target.isEmpty else { continue }
                    let url = file.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
                    if !FileManager.default.fileExists(atPath: url.path) { missing.append("link:" + target) }
                }
            }
            if let codePattern {
                for m in codePattern.matches(in: src, range: whole) {
                    let token = ns.substring(with: m.range(at: 1))
                    var first = token.split(separator: " ").first.map(String.init) ?? ""
                    if first.hasPrefix("./") { first.removeFirst(2) }
                    guard pathPrefixes.contains(where: { first.hasPrefix($0) }),
                          !first.contains("<"), !first.contains("*") else { continue }
                    if !FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(first).path) {
                        missing.append("path:" + first)
                    }
                }
            }
            expectEqual(missing, [])
        }
        let release = (try? String(contentsOfFile: skillsDir.appendingPathComponent("lyrimuse-release/SKILL.md").path,
                                   encoding: .utf8)) ?? ""
        expectEqual(release.contains("\ndisable-model-invocation: true\n"), true)
        let verify = (try? String(contentsOfFile: skillsDir.appendingPathComponent("lyrimuse-verify-ui/SKILL.md").path,
                                  encoding: .utf8)) ?? ""
        let verifyHead = verify.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
        expectEqual(verifyHead.contains("AppleScript"), true)
        for entry in ["AGENTS.md", "CLAUDE.md"] {
            let text = (try? String(contentsOfFile: repoRoot.appendingPathComponent(entry).path, encoding: .utf8)) ?? ""
            expectEqual(text.contains(".claude/skills/"), true)
        }
    }

    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func read(_ rel: String) -> String {
            (try? String(contentsOfFile: repoRoot.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
        }
        let yml = read(".github/workflows/release.yml")
        expectEqual(yml.isEmpty, false)
        expectEqual(yml.contains("prerelease: ${{ steps.version.outputs.is_prerelease == 'true' }}"), true)
        expectEqual(yml.contains("releases/latest/download/${ZIP_NAME}"), false)
        expectEqual(yml.contains("releases/latest/download/${INTEL_ZIP_NAME}"), false)
        expectEqual(yml.contains("releases/download/${TAG}/${ZIP_NAME}"), true)
        expectEqual(yml.contains("<sparkle:channel>beta</sparkle:channel>"), true)
        expectEqual(yml.contains("scripts/build-version.sh"), true)
        expectEqual(yml.contains("check_appcast.py appcast.xml --tag"), true)
        let buildSh = read("lyrimuse/build.sh")
        expectEqual(buildSh.contains("scripts/build-version.sh"), true)
        expectEqual(buildSh.contains("<key>CFBundleVersion</key>\n    <string>${BUILD_VERSION}</string>"), true)
        expectEqual(buildSh.contains("<key>CFBundleShortVersionString</key>\n    <string>${APP_VERSION}</string>"), true)
        let portability = read("lyrimuse/Sources/lyrimuse/Settings/ConfigPortability.swift")
        expectEqual(portability.contains("\"np:receiveBetaUpdates\""), true)
        let sparkle = read("lyrimuse/Sources/lyrimuse/Settings/SparkleUpdaterManager.swift")
        expectEqual(sparkle.contains("func feedURLString(for updater: SPUUpdater) -> String?"), true)
        expectEqual(sparkle.contains("func allowedChannels(for updater: SPUUpdater) -> Set<String>"), true)
        expectEqual(sparkle.contains("UpdateChannel.betaChannelName"), true)

        let checkTag = read(".github/scripts/check_release_tag.sh")
        expectEqual(checkTag.isEmpty, false)
        expectEqual(checkTag.contains("git cat-file -t"), true)
        expectEqual(checkTag.contains("split_release_notes.py"), true)
        expectEqual(checkTag.contains("scripts/build-version.sh"), true)
        expectEqual(checkTag.contains("${BODY//"), false)
        expectEqual(yml.contains("check_release_tag.sh"), true)
        let validateAt = yml.range(of: "- name: Validate release tag")?.lowerBound
        let setupGoAt = yml.range(of: "- name: Set up Go")?.lowerBound
        let buildAt = yml.range(of: "- name: Build + package release assets")?.lowerBound
        expectEqual(validateAt != nil && setupGoAt != nil && buildAt != nil, true)
        if let v = validateAt, let g = setupGoAt, let b = buildAt {
            expectEqual(v < g && v < b, true)
        }
        expectEqual(yml.contains("steps.changelog."), false)
        expectEqual(yml.components(separatedBy: "steps.tag.outputs.body").count - 1 >= 2, true)
        expectEqual(read("docs/releasing.md").contains("check_release_tag.sh"), true)

        let agentsDoc = read("AGENTS.md")
        if !agentsDoc.isEmpty {
            expectEqual(agentsDoc.contains("check_release_tag.sh"), true)
        }
    }

    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        func swiftFiles(under rel: String) -> [String] {
            let base = repoRoot.appendingPathComponent(rel).path
            guard let e = fm.enumerator(atPath: base) else { return [] }
            return e.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { base + "/" + $0 }.sorted()
        }
        func codeLines(_ path: String) -> [(Int, String)] {
            let src = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return src.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { i, line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { return nil }

                let code = String(line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                return (i + 1, code)
            }
        }
        var offenders: [String] = []
        for path in swiftFiles(under: "lyrimuse/Sources/LyrimuseCore") + swiftFiles(under: "lyrimuse/Sources/lyrimuse") {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            if name == "LyrimuseIdentity.swift" { continue }
            for (n, code) in codeLines(path) {
                if code.contains("L10n.t(") { continue }
                if code.contains(".config/lyrimuse") { offenders.append("\(name):\(n) .config/lyrimuse") }
                if code.contains("Library/Logs/lyrimuse") { offenders.append("\(name):\(n) Library/Logs/lyrimuse") }
                if code.contains("\"com.lyrimuse.collector") { offenders.append("\(name):\(n) collector label 字面量") }
                if code.contains("\"me.yudaotor.lyrimuse\""), !code.contains("subsystem"), !code.contains("DispatchQueue(label:") {
                    offenders.append("\(name):\(n) bundle id 字面量(只许 Logger subsystem / 队列名用)")
                }
                if code.contains("/Applications/Lyrimuse.app") { offenders.append("\(name):\(n) 安装路径字面量") }
            }
        }
        expectEqual(offenders, [])

        var goOffenders: [String] = []
        let goDir = repoRoot.appendingPathComponent("lyrimuse-collector").path
        for f in ((try? fm.contentsOfDirectory(atPath: goDir)) ?? []).filter({ $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") && $0 != "paths.go" }).sorted() {
            for (n, code) in codeLines(goDir + "/" + f) {
                if code.contains("\".config\", clientName") || code.contains(".config/lyrimuse\"") { goOffenders.append("\(f):\(n) 配置目录") }
                if code.contains("Library/Logs") { goOffenders.append("\(f):\(n) 日志路径") }
                if code.contains("os.UserHomeDir()") { goOffenders.append("\(f):\(n) 自己拿家目录拼路径(走 configDir())") }
            }
        }
        expectEqual(goOffenders, [])
        let pathsGo = (try? String(contentsOfFile: goDir + "/paths.go", encoding: .utf8)) ?? ""
        expectEqual(pathsGo.contains("LYRIMUSE_CONFIG_DIR") && pathsGo.contains("LYRIMUSE_LOG_FILE") && pathsGo.contains("LYRIMUSE_APP_BUNDLE_ID"), true)
        let companion = (try? String(contentsOfFile: goDir + "/companionlaunch.go", encoding: .utf8)) ?? ""
        expectEqual(companion.contains("\"-b\", appBundleID()"), true)

        var spawnOffenders: [String] = []
        for path in swiftFiles(under: "lyrimuse/Sources/lyrimuse") {
            let src = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            guard src.contains("Contents/Resources/collector") else { continue }

            let code = codeLines(path).map(\.1).joined(separator: "\n")
            let execs = code.components(separatedBy: ".executableURL = URL(fileURLWithPath:").count - 1
            let runners = code.components(separatedBy: "ProcessRunner.run(").count - 1
            let envs = code.components(separatedBy: "LyrimusePaths.collectorProcessEnvironment()").count - 1
            if execs + runners != envs {
                spawnOffenders.append("\(path.split(separator: "/").last ?? ""): spawn \(execs + runners) 处(executableURL \(execs) + ProcessRunner \(runners)), environment \(envs) 处")
            }
        }
        expectEqual(spawnOffenders, [])
        let csm = (try? String(contentsOfFile: repoRoot.appendingPathComponent("lyrimuse/Sources/lyrimuse/Settings/CollectorServiceManager.swift").path, encoding: .utf8)) ?? ""
        expectEqual(csm.contains("\"EnvironmentVariables\": LyrimusePaths.collectorEnvironment"), true)
    }

    do {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func code(_ rel: String) -> String {
            (try? String(contentsOfFile: appDir.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
        }
        let swatch = code("Settings/ColorThemeSwatch.swift")
        expectEqual(swatch.isEmpty, false)
        expectEqual(swatch.contains("NSImage(size: size, flipped: false)"), true)
        expectEqual(swatch.contains("NSColor.separatorColor"), true)
        expectEqual(swatch.contains("if strokeEnabled {"), true)
        expectEqual(code("Settings/ColorTheme.swift").contains("func swatchImage() -> NSImage"), true)
        let rows = code("UI/OverlayStyleSettingsRows.swift")

        func stripComments(_ src: String) -> String {
            src.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let rowsCode = stripComments(rows)
        expectEqual(rowsCode.components(separatedBy: "theme.swatchImage()").count - 1, 1)
        expectEqual(rowsCode.contains("Button(theme.name) { theme.apply(to: settings) }"), true)
        expectEqual(rowsCode.contains("Toggle(isOn: Binding("), false)

        expectEqual(rows.contains("guard !settings.followsCoverArt else { return noThemeInEffectPlaceholder }"), true)
        let quick = code("UI/OverlayQuickSettingsMenu.swift")
        expectEqual(quick.contains("let showsCheckmarks = !settings.followsCoverArt"), true)
    }

    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func read(_ rel: String) -> String {
            (try? String(contentsOfFile: repoRoot.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
        }
        let exporter = read("lyrimuse/Sources/lyrimuse/Settings/DiagnosticsExporter.swift")
        expectEqual(exporter.contains("== Recent Crash Reports"), true)
        expectEqual(exporter.contains("recentCrashReportLines().map { LogRedactor.redactAll($0, secrets: secrets) }"), true)
        expectEqual(exporter.contains("CrashReportSummary.parse("), true)
        expectEqual(exporter.contains("CrashReportSummary.select("), true)
        expectEqual(exporter.contains("belongsToApp("), true)
        let core = read("lyrimuse/Sources/LyrimuseCore/Diagnostics/CrashReportSummary.swift")
        expectEqual(core.isEmpty, false)
        expectEqual(core.contains("import AppKit"), false)
        expectEqual(core.contains("FileManager"), false)
        expectEqual(read("lyrimuse/Sources/lyrimuse-selftest/OpsDiagnosticsTests.swift").contains("CrashReportSummary.parse("), true)
    }

    do {
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageDir.deletingLastPathComponent()
        func read(_ rel: String) -> String {
            (try? String(contentsOfFile: repoRoot.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
        }

        func codeHits(_ src: String, _ needle: String) -> Int {
            src.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { acc, line in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return acc }
                let code = String(line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                return acc + (code.contains(needle) ? 1 : 0)
            }
        }
        let tab = read("lyrimuse/Sources/lyrimuse/AccountLinkingTab.swift")
        let svc = read("lyrimuse/Sources/lyrimuse/Settings/ScrobbleBackfillService.swift")
        if tab.isEmpty || svc.isEmpty {
            expectEqual(true, false)
        } else {
            let produced = codeHits(tab, "backfillRunResultText(")
            expectEqual(produced >= 3, true)
            expectEqual(codeHits(tab, "backfillResultRow") >= 2, true)
            expectEqual(svc.contains("var lastRunFailed"), true)
            expectEqual(codeHits(tab, "abortedReason") >= 1, true)
        }
    }

    do {
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageDir.deletingLastPathComponent()
        func read(_ rel: String) -> String {
            (try? String(contentsOfFile: repoRoot.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
        }

        func omitemptyKeys(_ go: String, _ name: String) -> [String] {
            guard let start = go.range(of: "\ntype \(name) struct {") else { return [] }
            let rest = go[start.upperBound...]
            guard let end = rest.range(of: "\n}") else { return [] }
            var keys: [String] = []
            for line in rest[..<end.lowerBound].split(separator: "\n") {
                guard let open = line.range(of: "json:\"") else { continue }
                let after = line[open.upperBound...]
                guard let close = after.range(of: "\"") else { continue }
                let parts = after[..<close.lowerBound].split(separator: ",").map(String.init)
                if parts.count > 1, parts.dropFirst().contains("omitempty"), let key = parts.first {
                    keys.append(key)
                }
            }
            return keys
        }

        func swiftStruct(_ swift: String, _ name: String) -> String? {
            guard let start = swift.range(of: "struct \(name):") else { return nil }
            var depth = 0
            var opened = false
            var out: [Substring] = []
            for line in swift[start.lowerBound...].split(separator: "\n", omittingEmptySubsequences: false) {
                out.append(line)
                depth += line.filter { $0 == "{" }.count
                depth -= line.filter { $0 == "}" }.count
                if line.contains("{") { opened = true }
                if opened, depth <= 0 { break }
            }
            return out.joined(separator: "\n")
        }

        func tolerant(_ body: String, _ key: String) -> Bool {
            for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }

                if line.contains("decodeIfPresent("), line.contains("forKey: .\(key))") { return true }
                if line.hasPrefix("var \(key):") || line.hasPrefix("let \(key):"), line.contains("?") { return true }
            }
            return false
        }
        let boundaries: [(go: String, goStruct: String, swift: String, swiftStruct: String)] = [
            ("lyrimuse-collector/backfill.go", "backfillOutcome",
             "lyrimuse/Sources/lyrimuse/Settings/ScrobbleBackfillService.swift", "Outcome"),
            ("lyrimuse-collector/backfill.go", "backfillItem",
             "lyrimuse/Sources/lyrimuse/Settings/ScrobbleBackfillService.swift", "Item"),
            ("lyrimuse-collector/searchcli.go", "searchLyricsPick",
             "lyrimuse/Sources/lyrimuse/LyricsManager/LyricsSearchService.swift", "Pick"),
        ]
        for b in boundaries {
            let go = read(b.go)
            guard !go.isEmpty, let body = swiftStruct(read(b.swift), b.swiftStruct) else {
                expectEqual(true, false)
                continue
            }
            let keys = omitemptyKeys(go, b.goStruct)
            expectEqual(keys.isEmpty, false)
            expectEqual(keys.filter { !tolerant(body, $0) }, [])
        }
    }

    do {
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageDir.deletingLastPathComponent()
        func hasCJK(_ s: Substring) -> Bool {
            s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        }

        func firstLiteral(_ line: String) -> Substring? {
            guard let open = line.range(of: "(\"") else { return nil }
            var i = open.upperBound
            var prev: Character = " "
            while i < line.endIndex {
                if line[i] == "\"" && prev != "\\" { return line[open.upperBound..<i] }
                prev = line[i]; i = line.index(after: i)
            }
            return nil
        }
        func files(under dir: URL, suffix: String) -> [(rel: String, text: String)] {
            var out: [(String, String)] = []
            if let walker = FileManager.default.enumerator(atPath: dir.path) {
                for case let rel as String in walker where rel.hasSuffix(suffix) {
                    if let text = try? String(contentsOfFile: dir.appendingPathComponent(rel).path, encoding: .utf8) {
                        out.append((rel, text))
                    }
                }
            }
            return out.sorted { $0.0 < $1.0 }
        }
        var offenders: [String] = []
        var subsystems: Set<String> = []
        let swiftLogCall = try? NSRegularExpression(pattern: #"logger\.(debug|info|notice|error|warning|fault|log)\(""#)
        for dir in ["Sources/lyrimuse", "Sources/LyrimuseCore"] {
            for (rel, text) in files(under: packageDir.appendingPathComponent(dir), suffix: ".swift") {
                for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(raw)
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("//") || line.contains("// log-style: allow") { continue }
                    if t.contains("NSLog(") || t.hasPrefix("print(") {
                        offenders.append("\(dir)/\(rel):\(n + 1) NSLog/print")
                    }
                    if let r = line.range(of: "Logger(subsystem: \"") {
                        let rest = line[r.upperBound...]
                        if let q = rest.firstIndex(of: "\"") { subsystems.insert(String(rest[..<q])) }
                    }
                    if let re = swiftLogCall,
                       re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                       let open = line.range(of: "(\""), let close = line.range(of: "\")", options: .backwards),
                       open.upperBound <= close.lowerBound, hasCJK(line[open.upperBound..<close.lowerBound]) {
                        offenders.append("\(dir)/\(rel):\(n + 1) CJK in log literal")
                    }
                }
            }
        }

        let goLogCall = try? NSRegularExpression(pattern: #"\b(?:log|slog)\.(Printf|Println|Print|Fatalf|Fatal|Debug|Info|Warn|Error)\(""#)
        for (rel, text) in files(under: repoRoot.appendingPathComponent("lyrimuse-collector"), suffix: ".go")
        where !rel.hasSuffix("_test.go") && !rel.contains("/") {
            for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(raw)
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || line.contains("// log-style: allow") { continue }
                if let re = goLogCall,
                   re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                   let lit = firstLiteral(line), hasCJK(lit) {
                    offenders.append("lyrimuse-collector/\(rel):\(n + 1) CJK in log literal")
                }
            }
        }
        expectEqual(offenders, [])
        expectEqual(subsystems, ["me.yudaotor.lyrimuse"])
    }
}
