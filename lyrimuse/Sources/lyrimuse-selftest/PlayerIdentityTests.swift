import LyrimuseCore
import Foundation

@MainActor
func runPlayerIdentityTests() {
    do {
        func snapshot(_ bundle: String, playing: Bool) -> MediaControlSnapshot {
            let data = try! JSONSerialization.data(withJSONObject: [
                "bundleIdentifier": bundle, "title": "Song", "artist": "Artist", "playing": playing])
            return try! JSONDecoder().decode(MediaControlSnapshot.self, from: data)
        }
        let music = snapshot("com.apple.Music", playing: true)
        let paused = snapshot("com.apple.Music", playing: false)
        let browser = snapshot("com.google.Chrome", playing: true)
        let spotify = snapshot("com.spotify.client", playing: true)
        let select = MediaControlClient.selectMusicSnapshot
        let full = MediaControlStreamWatcher.digest(
            line: Data(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.google.Chrome"}}"#.utf8),
            merged: [:], arrivedAt: Date())
        let diff = MediaControlStreamWatcher.digest(
            line: Data(#"{"type":"data","diff":true,"payload":{"playing":false}}"#.utf8),
            merged: full.merged, arrivedAt: Date())
        expectEqual(diff.merged["bundleIdentifier"] as? String, "com.google.Chrome",
                    "视频暂停的增量事件保留来源，不能误冻 Apple Music")
        let cleared = MediaControlStreamWatcher.digest(
            line: Data(#"{"type":"data","diff":false,"payload":{}}"#.utf8),
            merged: diff.merged, arrivedAt: Date())
        expectEqual(cleared.merged["bundleIdentifier"] as? String, nil, "清空系统媒体状态时不沿用旧事件来源")
        expectEqual(select(nil, [.auto], { music })?.bundleIdentifier, "com.apple.Music",
                    "视频抢占系统焦点但不被接纳时，自动识别仍读取 Apple Music")
        expectEqual(select(nil, [.auto], { paused })?.playing, false,
                    "看完视频后仍保留暂停的 Apple Music，允许继续播放")
        expectEqual(select(browser, [.auto], { music })?.bundleIdentifier, "com.apple.Music",
                    "Apple Music 正在播放时优先于浏览器媒体")
        expectEqual(select(browser, [.auto], { paused })?.bundleIdentifier, "com.google.Chrome",
                    "Apple Music 暂停时仍支持已接纳的网页音乐")
        var queried = false
        expectEqual(select(spotify, [.auto], { queried = true; return music })?.bundleIdentifier,
                    "com.spotify.client", "已识别的其他原生播放器不被 Apple Music 抢走")
        expectEqual(queried, false, "原生播放器无需额外查询 Apple Music")
        expectEqual(select(nil, [.spotify], { queried = true; return music }) == nil, true,
                    "未选择 Apple Music 时不启用兜底")
        expectEqual(queried, false, "显式排除 Apple Music 时不发 AppleEvent")
        let target = MusicPlaybackController.controlTargetBundleID
        expectEqual(target([.auto], "com.apple.Music", [:]), "com.apple.Music", "自动模式按钮精确控制显示中的 Apple Music")
        expectEqual(target([.appleMusic, .spotify], "com.apple.Music", [:]), "com.apple.Music", "多选模式同样按实际播放器控制")
        expectEqual(target([.appleMusic], "com.google.Chrome", [:]), "com.apple.Music", "Apple Music 单选不受网页残留焦点影响")
        expectEqual(target([.auto], "com.google.Chrome", [:]), nil, "未接纳的视频绝不成为控制目标")
        expectEqual(target([.auto], nil, [:]), nil, "无播放对象时不发系统全局命令")
        expectEqual(target([.auto], "com.spotify.client", [:]), "com.spotify.client", "Spotify 使用自己的控制目标")
        expectEqual(LocalPlaybackSource.shouldFreezeForPlayerEvent(currentBundleID: "com.apple.Music",
            eventBundleID: "com.google.Chrome"), false, "网页开始或暂停不能冻结 Apple Music 歌词时钟")
        expectEqual(LocalPlaybackSource.shouldFreezeForPlayerEvent(currentBundleID: "com.apple.Music",
            eventBundleID: "com.apple.Music"), true, "Apple Music 自己的暂停仍立即冻结时钟")
    }


    do {
        typealias L = LocalPlaybackSource
        expectEqual(L.positionSourceTier(forBundleID: "com.apple.Music") == .precise, true)
        expectEqual(L.positionSourceTier(forBundleID: "com.spotify.client") == .cleanExtrapolated, true)
        expectEqual(L.positionSourceTier(forBundleID: "com.tencent.QQMusicMac") == .noisyFloored, true)
        expectEqual(L.positionSourceTier(forBundleID: "com.netease.163music") == .noisyFloored, true)

        expectEqual(L.positionSourceTier(forBundleID: "com.kugou.mac.Music") == .cleanExtrapolated, true)
        expectEqual(L.shouldRatchetForward(reported: 10, predicted: 5, tier: .cleanExtrapolated), false)

        expectEqual(L.positionSourceTier(forBundleID: nil) == .cleanExtrapolated, true)
        expectEqual(L.positionSourceTier(forBundleID: "company.thebrowser.Browser") == .cleanExtrapolated,
                    true)
        expectEqual(L.shouldRatchetForward(reported: 10, predicted: 5,
                                           tier: L.positionSourceTier(forBundleID: "company.thebrowser.Browser")),
                    false)
    }

    do {
        typealias Mode = MusicPlaybackController.MusicPlaybackMode

        expectEqual(Mode.list.next(allowsRepeatOne: true), .shuffle)
        expectEqual(Mode.shuffle.next(allowsRepeatOne: true), .repeatOne)
        expectEqual(Mode.repeatOne.next(allowsRepeatOne: true), .list)

        expectEqual(Mode.repeatAll.next(allowsRepeatOne: true), .repeatOne)
        expectEqual(Mode.repeatAll.next(allowsRepeatOne: false), .list)

        expectEqual(Mode.list.next(allowsRepeatOne: false), .shuffle)
        expectEqual(Mode.shuffle.next(allowsRepeatOne: false), .list)

        expectEqual(Mode.repeatOne.next(allowsRepeatOne: false), .list)

        for allows in [true, false] {
            for start in Mode.allCases {
                var cur = start
                var seen: [Mode] = []
                for _ in 0..<4 { cur = cur.next(allowsRepeatOne: allows); seen.append(cur) }
                let startIsUnreachable = (!allows && start == .repeatOne) || start == .repeatAll
                if !startIsUnreachable {
                    expectEqual(seen.contains(start), true)
                }
                if !allows {
                    expectEqual(seen.contains(.repeatOne), false)
                }
            }
        }

        expectEqual(MusicPlaybackController.supportsRepeatOne(.appleMusic), true)
        expectEqual(MusicPlaybackController.supportsRepeatOne(.spotify), false)
        expectEqual(MusicPlaybackController.supportsExtendedControls(.appleMusic), true)
        expectEqual(MusicPlaybackController.supportsExtendedControls(.spotify), true)
        expectEqual(MusicPlaybackController.supportsExtendedControls(.qqMusic), false)
        expectEqual(MusicPlaybackController.supportsExtendedControls(.netease), false)
        expectEqual(MusicPlaybackController.supportsExtendedControls(.kugou), false)
        expectEqual(MusicPlaybackController.supportsRepeatOne(.kugou), false)
    }

    do {
        typealias T = TrustedPlayers
        let trusted = ["com.foobar.mac": "Foobar2000", "com.some.player": ""]

        for player in PlaybackPlayer.allCases where player != .auto {
            expectEqual(T.isAccepted(player.bundleIdentifier, trusted: [:]), true)
        }

        expectEqual(T.isAccepted("com.foobar.mac", trusted: trusted), true)
        expectEqual(T.isAccepted("com.some.player", trusted: trusted), true)

        expectEqual(T.isAccepted("com.apple.Safari", trusted: trusted), false)
        expectEqual(T.isAccepted("", trusted: trusted), false)
        expectEqual(T.isAccepted(nil, trusted: trusted), false)

        expectEqual(T.isAccepted(PlaybackPlayer.auto.bundleIdentifier, trusted: [:]), false)
    }

    do {
        typealias P = BrowserAutomationPermission
        expectEqual(P.safariStatus(fromPrefValue: nil), P.Status.unknown)
        expectEqual(P.safariStatus(fromPrefValue: true as CFPropertyList), P.Status.enabled)
        expectEqual(P.safariStatus(fromPrefValue: false as CFPropertyList), P.Status.disabled)

        expectEqual(P.safariStatus(fromPrefValue: NSNumber(value: 1) as CFPropertyList), P.Status.enabled)
        expectEqual(P.safariStatus(fromPrefValue: NSNumber(value: 0) as CFPropertyList), P.Status.disabled)
    }

    do {
        typealias T = TrustedPlayers
        let arc = "company.thebrowser.Browser"
        let trusted = [arc: "Arc"]

        expectEqual(T.notASong(bundleID: arc, artist: "", album: "", trusted: trusted), true)
        expectEqual(T.notASong(bundleID: arc, artist: "Dream in reality", album: "", trusted: trusted), true)
        expectEqual(T.notASong(bundleID: arc, artist: "", album: "某专辑", trusted: trusted), true)
        expectEqual(T.notASong(bundleID: arc, artist: nil, album: nil, trusted: trusted), true)
        expectEqual(T.notASong(bundleID: arc, artist: "  ", album: "某专辑", trusted: trusted), true)

        for sample in [("周杰伦", "七里香"), ("方大同", "Soulboy"), ("卢广仲", "100种生活")] {
            expectEqual(T.notASong(bundleID: arc, artist: sample.0, album: sample.1, trusted: trusted), false)
        }

        for player in PlaybackPlayer.allCases where player != .auto {
            expectEqual(T.notASong(bundleID: player.bundleIdentifier, artist: "", album: "", trusted: trusted),
                        false)
        }

        expectEqual(T.notASong(bundleID: "com.apple.Safari", artist: "", album: "", trusted: trusted), false)

        let safariTrusted = ["com.apple.Safari": "Safari"]
        let webkitGPU = "com.apple.WebKit.GPU"
        expectEqual(T.notASong(bundleID: webkitGPU, artist: "某频道", album: "", trusted: safariTrusted), true)
        expectEqual(T.notASong(bundleID: webkitGPU, artist: "王力宏", album: "十八般武藝", trusted: safariTrusted), false)
        expectEqual(T.notASong(bundleID: webkitGPU, artist: "", album: "", trusted: trusted), false)
    }

    do {
        let expected: [PlaybackPlayer: (raw: String, bundle: String)] = [
            .appleMusic: ("apple_music", "com.apple.Music"),
            .qqMusic: ("qq_music", "com.tencent.QQMusicMac"),
            .netease: ("netease_music", "com.netease.163music"),
            .kugou: ("kugou_music", "com.kugou.mac.Music"),
            .spotify: ("spotify", "com.spotify.client"),
        ]
        for (player, want) in expected {
            expectEqual(player.rawValue, want.raw)
            expectEqual(player.bundleIdentifier, want.bundle)
            expectEqual(PlaybackPlayer(rawValue: want.raw) == player, true)
        }

        expectEqual(PlaybackPlayer.auto.bundleIdentifier, "")

        expectEqual(PlaybackPlayer.allCases.count, expected.count + 1)

        let bundles = PlaybackPlayer.allCases.filter { $0 != .auto }.map(\.bundleIdentifier)
        expectEqual(Set(bundles).count, bundles.count)
    }

    do {
        expectEqual(Set<PlaybackPlayer>([.auto]).soleExplicitPlayer, nil)
        expectEqual(Set<PlaybackPlayer>([.appleMusic]).soleExplicitPlayer, .appleMusic)
        expectEqual(Set<PlaybackPlayer>([.appleMusic, .auto]).soleExplicitPlayer, .appleMusic)
        expectEqual(Set<PlaybackPlayer>([.appleMusic, .qqMusic]).soleExplicitPlayer, nil)
        expectEqual(Set<PlaybackPlayer>([.appleMusic, .qqMusic, .auto]).soleExplicitPlayer, nil)
        expectEqual(Set<PlaybackPlayer>([]).soleExplicitPlayer, nil)
    }

    do {
        typealias P = YouTubeMusicAdProbe

        expectEqual(P.gate(artist: "Michael Jackson", verdict: .song), .acceptAsSong)
        expectEqual(P.gate(artist: "KAO Hong Kong", verdict: .ad), .acceptAsAd)
        expectEqual(P.gate(artist: "KAO Hong Kong", verdict: nil), .reject)

        expectEqual(P.gate(artist: "", verdict: .song), .reject)
        expectEqual(P.gate(artist: "   ", verdict: .ad), .reject)
        expectEqual(P.gate(artist: nil, verdict: nil), .reject)

        expectEqual(P.showsAdBadge(verdict: .ad), true)
        expectEqual(P.showsAdBadge(verdict: .song), false)
        expectEqual(P.showsAdBadge(verdict: nil), false)

        expectEqual(P.refreshInterval(for: .ad), P.adRefreshInterval)
        expectEqual(P.adRefreshInterval <= 5, true)
        expectEqual(P.refreshInterval(for: .song), P.songRefreshInterval)
        expectEqual(P.refreshInterval(for: .ad) < P.refreshInterval(for: .song), true)

        for verdict in [P.Verdict.ad, P.Verdict.song] {
            expectEqual(P.refreshInterval(for: verdict) < P.verdictMaxAge, true)
        }
        expectEqual(P.verdictMaxAge - P.songRefreshInterval >= 10, true)

        expectEqual(SpotifyWebAdProbe.refreshInterval < SpotifyWebAdProbe.verdictMaxAge, true)

        typealias S = LocalPlaybackSource
        expectEqual(S.nextAdBreakState(previous: false, isNewTrack: true, adByFields: true, pageVerdict: .ad), true)
        expectEqual(S.nextAdBreakState(previous: true, isNewTrack: true, adByFields: false, pageVerdict: nil), false)
        expectEqual(S.nextAdBreakState(previous: false, isNewTrack: false, adByFields: true, pageVerdict: .ad), true)
        expectEqual(S.nextAdBreakState(previous: true, isNewTrack: false, adByFields: false, pageVerdict: .song), false)
        expectEqual(S.nextAdBreakState(previous: true, isNewTrack: false, adByFields: false, pageVerdict: nil), true)
        expectEqual(S.nextAdBreakState(previous: false, isNewTrack: false, adByFields: false, pageVerdict: nil), false)
        expectEqual(S.nextAdBreakState(previous: true, isNewTrack: false, adByFields: false, pageVerdict: nil), true)

        expectEqual(S.adBreakByFields(isSpotifyNative: false, title: "Why You Wanna Treat Me So Bad?", artist: "王子",
                                      album: "", youTubeMusicVerdict: .song, spotifyWebVerdict: nil), false)
        expectEqual(S.adBreakByFields(isSpotifyNative: false, title: "Why You Wanna Treat Me So Bad?", artist: "王子",
                                      album: "", youTubeMusicVerdict: nil, spotifyWebVerdict: nil), false)
        expectEqual(S.adBreakByFields(isSpotifyNative: false, title: "Liese 全新登場", artist: "KAO Hong Kong",
                                      album: "", youTubeMusicVerdict: .ad, spotifyWebVerdict: nil), true)
        expectEqual(S.adBreakByFields(isSpotifyNative: false, title: "广告", artist: "", album: "",
                                      youTubeMusicVerdict: nil, spotifyWebVerdict: .ad), true)
        expectEqual(S.adBreakByFields(isSpotifyNative: false, title: "广告", artist: "", album: "",
                                      youTubeMusicVerdict: nil, spotifyWebVerdict: nil), false)
        expectEqual(S.adBreakByFields(isSpotifyNative: false, title: "三年二班", artist: "周杰伦", album: "葉惠美",
                                      youTubeMusicVerdict: nil, spotifyWebVerdict: .song), false)
        expectEqual(S.adBreakByFields(isSpotifyNative: true, title: "—", artist: "", album: "",
                                      youTubeMusicVerdict: nil, spotifyWebVerdict: nil), true)
        expectEqual(S.adBreakByFields(isSpotifyNative: true, title: "Now Streaming on Hulu.", artist: "Spotify", album: "",
                                      youTubeMusicVerdict: nil, spotifyWebVerdict: nil), true)
        expectEqual(S.adBreakByFields(isSpotifyNative: true, title: "七里香", artist: "周杰伦", album: "七里香",
                                      youTubeMusicVerdict: nil, spotifyWebVerdict: nil), false)
        expectEqual(S.adBreakByFields(isSpotifyNative: false, title: "某播客", artist: "某主播", album: "",
                                      youTubeMusicVerdict: nil, spotifyWebVerdict: nil), false)

        expectEqual(P.badgeVerdict(P.parse("1|1|1|")), .ad)
        expectEqual(P.badgeVerdict(P.parse("1|0|0|")), .ad)
        expectEqual(P.badgeVerdict(P.parse("0|1|0|")), .ad)
        expectEqual(P.badgeVerdict(P.parse("0|0|1|")), nil)
        expectEqual(P.badgeVerdict(P.parse("0|0|0||Prince")), .song)
        expectEqual(P.badgeVerdict(nil), nil)
        expectEqual(P.parse("0|0|1|")?.verdict, .ad)
        expectEqual(P.parse("0|0|1|")?.strongAd, false)
        expectEqual(P.parse("1|0|1|")?.strongAd, true)
        expectEqual(P.parse("0|1|1|")?.strongAd, true)
        expectEqual(P.parse("0|0|0|")?.strongAd, false)
        expectEqual(P.Reading(verdict: .song, strongAd: true, album: "").strongAd, false)

        expectEqual(S.nextAdBreakState(previous: false, isNewTrack: true, adByFields: false, pageVerdict: nil), false)
        expectEqual(S.adBreakByFields(isSpotifyNative: false, title: "It's Gonna Be Lonely", artist: "Prince", album: "Prince",
                                      youTubeMusicVerdict: P.badgeVerdict(P.parse("0|0|1|")), spotifyWebVerdict: nil), false)

        expectEqual(P.parse("1|1|1")?.verdict, .ad)
        expectEqual(P.parse("0|0|0")?.verdict, .song)

        expectEqual(P.parse("1|0|0")?.verdict, .ad)
        expectEqual(P.parse("0|1|0")?.verdict, .ad)
        expectEqual(P.parse("0|0|1")?.verdict, .ad)

        for raw in ["NOTFOUND", "", "   \n", "1|0", "1|x|0", "true|false|false"] {
            expectEqual(P.parse(raw), nil)
        }

        expectEqual(P.parse("\"1|1|1\"")?.verdict, .ad)
        expectEqual(P.parse("\"0|0|0\"\n")?.verdict, .song)

        expectEqual(P.parse("0|0|0||Already Gone")?.album, "Already Gone")
        expectEqual(P.parse("0|0|0||Already Gone")?.verdict, .song)
        expectEqual(P.parse("0|0|0||")?.album, "")
        expectEqual(P.parse("0|0|0")?.album, "")

        expectEqual(P.parse("0|0|0||A|B")?.album, "A|B")
        expectEqual(P.parse("1|0|0||0")?.album, "0")
        expectEqual(P.parse("0|0|0||  Already Gone  ")?.album, "Already Gone")
        expectEqual(P.parse("0|0|0||Already\nGone")?.album, "Already Gone")

        expectEqual(P.parse("1|1|0|1/2|")?.adSlot, .init(index: 1, total: 2))
        expectEqual(P.parse("1|1|0|2/2|")?.adSlot, .init(index: 2, total: 2))
        expectEqual(P.parse("1|1|0||")?.adSlot, nil)
        expectEqual(P.parse("1|1|0|abc|")?.adSlot, nil)

        expectEqual(P.parse("1|1|0|abc|")?.verdict, .ad)
        expectEqual(P.parse("1|1|0|abc|某专辑")?.album, "某专辑")
        expectEqual(P.parse("1|1|0|0/2|")?.adSlot, nil)
        expectEqual(P.parse("1|1|0|3/2|")?.adSlot, nil)
        expectEqual(P.parse("1|1|0|1/99|")?.adSlot, nil)

        expectEqual(P.parse("1|1|0|1/2|")?.adSlot?.total, 2)
        expectEqual(P.parse("1|1|0|1/2|")?.adSlot?.index, 1)
        expectEqual(P.parse("1|1|0|2/1|")?.adSlot, nil)

        let song = P.Reading(verdict: .song, strongAd: false, album: "Already Gone")
        expectEqual(P.albumPatch(reported: "", reading: song), "Already Gone")
        expectEqual(P.albumPatch(reported: nil, reading: song), "Already Gone")
        expectEqual(P.albumPatch(reported: "   ", reading: song), "Already Gone")

        expectEqual(P.albumPatch(reported: "The Essential Michael Jackson", reading: song), nil)

        expectEqual(P.albumPatch(reported: "", reading: P.Reading(verdict: .ad, strongAd: true, album: "Already Gone")),
                    nil)
        expectEqual(P.albumPatch(reported: "", reading: nil), nil)
        expectEqual(P.albumPatch(reported: "", reading: P.Reading(verdict: .song, strongAd: false, album: "  ")), nil)

        expectEqual(P.probeJS.contains("\""), false)

        expectEqual(P.probeJS.contains("\\"), false)

        for marker in ["ad-showing", "ytp-ad-badge", "YouTube Music", "NOTFOUND",
                       "slotEl", "new RegExp", "'|' + slot + '|'",

                       "[0-9]+:[0-9]+", "([0-9]+)[^0-9]{1,12}([0-9]+)"] {
            expectEqual(P.probeJS.contains(marker), true)
        }

        for family in [BrowserAutomationPermission.Family.chromium, .safari] {
            let s = P.buildAppleScript(bundleID: "com.google.Chrome", family: family)

            expectEqual(s.contains("tell application id \"com.google.Chrome\""), true)

            expectEqual(s.contains(P.hostMarker), true)

            expectEqual(s.components(separatedBy: "with timeout of").count - 1, 2)
            expectEqual(s.contains("return \"NOTFOUND\""), true)
        }

        let chromium = P.buildAppleScript(bundleID: "com.google.Chrome", family: .chromium)
        let safari = P.buildAppleScript(bundleID: "com.apple.Safari", family: .safari)
        expectEqual(chromium.contains("do JavaScript"), false)
        expectEqual(safari.contains("do JavaScript"), true)
        expectEqual(safari.contains("execute ("), false)

        let goSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lyrimuse-collector/ytmusicad.go")
        if let go = try? String(contentsOf: goSource, encoding: .utf8) {

            for marker in ["ad-showing", "ytp-ad-badge", "YouTube Music", "NOTFOUND",
                           "browse/MPREb", "ytmusic-player-bar", P.hostMarker] {
                expectEqual(go.contains(marker), true)
            }

            expectEqual(go.contains("ytmusicAdProbeEventTimeout = \(P.eventTimeoutSeconds)"), true)

            if let start = go.range(of: "const ytmusicAdProbeJS = "),
               let end = go.range(of: "\n\n", range: start.upperBound ..< go.endIndex) {
                let block = String(go[start.upperBound ..< end.lowerBound])

                let chunks = block.components(separatedBy: "`")
                let goJS = chunks.enumerated()
                    .filter { $0.offset % 2 == 1 }
                    .map(\.element)
                    .joined()
                expectEqual(goJS, P.probeJS)
            } else {
                expectEqual(true, false)
            }
        } else {
            expectEqual(true, false)
        }
    }

    do {
        typealias S = SpotifyWebAdProbe

        expectEqual(S.parse("1|1|1|1"), .ad)
        expectEqual(S.parse("0|0|0|0"), .song)
        expectEqual(S.parse("1|0|0|0"), .ad)
        expectEqual(S.parse("0|1|0|0"), .ad)
        expectEqual(S.parse("0|0|1|0"), .ad)
        expectEqual(S.parse("0|0|0|1"), .ad)

        for raw in ["NOTFOUND", "", "   \n", "1|0|0", "1|0|0|0|0", "1|x|0|0", "true|false|false|false"] {
            expectEqual(S.parse(raw), nil)
        }
        expectEqual(S.parse("\"1|1|1|1\""), .ad)
        expectEqual(S.parse("\"0|0|0|0\"\n"), .song)

        expectEqual(S.gate(verdict: .ad), .acceptAsAd)
        expectEqual(S.gate(verdict: .song), .reject)

        expectEqual(S.gate(verdict: nil), .reject)

        expectEqual(S.fieldShapeNeedsProbe(title: "广告", artist: ""), true)
        expectEqual(S.fieldShapeNeedsProbe(title: "广告", artist: "   "), true)
        expectEqual(S.fieldShapeNeedsProbe(title: "某首歌", artist: "周杰倫"), false)
        expectEqual(S.fieldShapeNeedsProbe(title: "", artist: ""), false)
        expectEqual(S.fieldShapeNeedsProbe(title: nil, artist: nil), false)

        expectEqual(S.probeJS.contains("\""), false)
        expectEqual(S.probeJS.contains("\\"), false)

        expectEqual(S.probeJS.contains("*="), false)
        for marker in ["now-playing-widget", "ad-controls", "context-item-info-ad-subtitle",
                       "ad-countdown-timer", "ad-link", "NOTFOUND"] {
            expectEqual(S.probeJS.contains(marker), true)
        }

        for family in [BrowserAutomationPermission.Family.chromium, .safari] {
            let s = S.buildAppleScript(bundleID: "com.apple.Safari", family: family)
            expectEqual(s.contains("tell application id \"com.apple.Safari\""), true)
            expectEqual(s.contains(S.hostMarker), true)
            expectEqual(s.components(separatedBy: "with timeout of").count - 1, 2)
            expectEqual(s.contains("return \"NOTFOUND\""), true)
        }

        func skeleton(_ script: String, host: String, js: String) -> String {
            script.replacingOccurrences(of: js, with: "<JS>")
                .replacingOccurrences(of: host, with: "<HOST>")
        }
        for family in [BrowserAutomationPermission.Family.chromium, .safari] {
            let yt = YouTubeMusicAdProbe.buildAppleScript(bundleID: "com.apple.Safari", family: family)
            let sp = S.buildAppleScript(bundleID: "com.apple.Safari", family: family)
            expectEqual(
                skeleton(yt, host: YouTubeMusicAdProbe.hostMarker, js: YouTubeMusicAdProbe.probeJS),
                skeleton(sp, host: S.hostMarker, js: S.probeJS))
        }
    }

    do {
        typealias A = UnknownPlayerAlert
        let now = Date()
        func offer(bundle: String = "com.google.Chrome", artist: String = "华晨宇",
                   album: String = "异类", age: TimeInterval = 0, auto: Bool = true,
                   accepted: Set<String> = []) -> Bool {
            A.shouldOffer(bundleID: bundle, artist: artist, album: album,
                          observedAt: now.addingTimeInterval(-age), isAutoDetect: auto, now: now,
                          isAccepted: { accepted.contains($0) })
        }

        expectEqual(offer(), true)

        expectEqual(offer(auto: false), false)

        expectEqual(offer(age: 14), true)
        expectEqual(offer(age: 16), false)
        expectEqual(A.freshWindow, 15)

        expectEqual(offer(album: ""), false)
        expectEqual(offer(artist: ""), false)
        expectEqual(offer(album: "   "), false)
        expectEqual(offer(artist: " \t "), false)

        expectEqual(offer(accepted: ["com.google.Chrome"]), false)
        expectEqual(offer(bundle: ""), false)
        expectEqual(offer(bundle: "  "), false)
        expectEqual(offer(age: -5), true)

        for player in PlaybackPlayer.allCases where player != .auto {
            expectEqual(A.shouldOffer(bundleID: player.bundleIdentifier, artist: "PRINCE",
                                      album: "Dirty Mind", observedAt: now, isAutoDetect: true,
                                      now: now,
                                      isAccepted: { TrustedPlayers.isAccepted($0, trusted: [:]) }),
                        false)
        }

        do {
            let webkit = "com.apple.WebKit.GPU"
            let safari = "com.apple.Safari"
            expectEqual(TrustedPlayers.isAccepted(webkit, trusted: [safari: "Safari"]), true)
            expectEqual(TrustedPlayers.isAccepted(webkit, trusted: [:]), false)
            expectEqual(TrustedPlayers.isAccepted(webkit, trusted: ["com.google.Chrome": "Chrome"]),
                        false)

            expectEqual(TrustedPlayers.isAccepted(safari, trusted: [webkit: ""]), false)
            expectEqual(TrustedPlayers.mediaProxyOwner(of: webkit), safari)
            expectEqual(TrustedPlayers.mediaProxyOwner(of: "com.google.Chrome"), nil)

            expectEqual(A.shouldOffer(bundleID: webkit, artist: "Musiq Soulchild",
                                      album: "Juslisen", observedAt: now, isAutoDetect: true,
                                      now: now,
                                      isAccepted: { TrustedPlayers.isAccepted($0, trusted: [safari: "Safari"]) }),
                        false)
            expectEqual(A.shouldOffer(bundleID: webkit, artist: "Musiq Soulchild",
                                      album: "Juslisen", observedAt: now, isAutoDetect: true,
                                      now: now,
                                      isAccepted: { TrustedPlayers.isAccepted($0, trusted: [:]) }),
                        true)

            expectEqual(TrustedPlayers.isTrusted("com.google.Chrome", trusted: ["com.google.Chrome": "Chrome"]),
                        true)
            expectEqual(TrustedPlayers.isTrusted("com.apple.Safari", trusted: [:]),
                        false)
            expectEqual(TrustedPlayers.isTrusted(PlaybackPlayer.qqMusic.bundleIdentifier, trusted: [:]),
                        false)
            expectEqual(TrustedPlayers.isTrusted(webkit, trusted: [safari: "Safari"]),
                        true)
            expectEqual(TrustedPlayers.isTrusted(nil, trusted: [safari: "Safari"]),
                        false)
            expectEqual(TrustedPlayers.isTrusted("", trusted: [safari: "Safari"]),
                        false)
        }

        expectEqual(TrustedPlayers.notASong(bundleID: "com.google.Chrome", artist: "华晨宇",
                                            album: "异类",
                                            trusted: ["com.google.Chrome": ""]),
                    false)

        expectEqual(offer(bundle: "company.thebrowser.Browser", artist: "Dream in reality",
                          album: ""), false)

        func announce(bundle: String = "com.google.Chrome", accepted: Set<String> = [],
                      hasName: Bool = true, stableFor: TimeInterval = 10, hits: Int = 5,
                      log: [String: A.AnnounceLog] = [:], at: Date = now) -> Bool {
            A.shouldAnnounce(bundleID: bundle, artist: "华晨宇", album: "异类", observedAt: at,
                             isAutoDetect: true, now: at,
                             isAccepted: { accepted.contains($0) },
                             hasDisplayName: hasName, stableFor: stableFor, stableHits: hits,
                             log: log)
        }
        expectEqual(announce(), true)

        expectEqual(announce(bundle: "com.apple.podcasts"), false)
        expectEqual(announce(bundle: "com.tencent.xinWeChat"), false)
        expectEqual(A.mutedForAnnounce.contains("com.apple.Safari"), false)

        expectEqual(A.shouldOffer(bundleID: "com.apple.podcasts", artist: "某节目", album: "某季",
                                  observedAt: now, isAutoDetect: true, now: now,
                                  isAccepted: { _ in false }),
                    true)

        expectEqual(announce(hasName: false), false)

        expectEqual(announce(stableFor: 5.9), false)
        expectEqual(announce(hits: 2), false)
        expectEqual(announce(stableFor: 6, hits: 3), true)
        expectEqual(A.stableWindow, 6)
        expectEqual(A.stableHitsNeeded, 3)

        let day = A.announceCooldown
        expectEqual(announce(log: ["com.google.Chrome": .init(count: 1, lastAt: now)]), false)
        expectEqual(announce(log: ["com.google.Chrome": .init(count: 1, lastAt: now - day)],
                             at: now), true)
        expectEqual(announce(log: ["com.google.Chrome": .init(count: 3, lastAt: now - day * 9)]),
                    false)
        expectEqual(A.maxAnnounces, 3)
        expectEqual(announce(log: ["com.other.app": .init(count: 3, lastAt: now)]), true)

        expectEqual(announce(accepted: ["com.google.Chrome"]), false)

        func qualifies(bundle: String = "com.google.Chrome", accepted: Set<String> = [],
                       hasName: Bool = true, stableFor: TimeInterval = 10, hits: Int = 5) -> Bool {
            A.qualifiesForAnnounce(bundleID: bundle, artist: "华晨宇", album: "异类", observedAt: now,
                                   isAutoDetect: true, now: now, isAccepted: { accepted.contains($0) },
                                   hasDisplayName: hasName, stableFor: stableFor, stableHits: hits)
        }
        expectEqual(qualifies(), true)
        expectEqual(qualifies(bundle: "com.apple.podcasts"), false)
        expectEqual(qualifies(hasName: false), false)
        expectEqual(qualifies(stableFor: 5.9), false)
        expectEqual(qualifies(hits: 2), false)
        expectEqual(qualifies(accepted: ["com.google.Chrome"]), false)

        expectEqual(announce(log: ["com.google.Chrome": .init(count: 3, lastAt: now)]), false)
        expectEqual(qualifies(), true)

        for (logged, expectedAnnounce) in [(false, true), (true, false)] {
            let log: [String: A.AnnounceLog] = logged ? ["com.google.Chrome": .init(count: 1, lastAt: now)] : [:]
            expectEqual(announce(log: log), qualifies() && expectedAnnounce)
        }
        expectEqual(announce(bundle: "com.apple.podcasts") || qualifies(bundle: "com.apple.podcasts"), false)

        expectEqual(A.nowPlayingDescription(artist: "热可可", title: "28. 对话行烟烟"), "热可可 - 28. 对话行烟烟")
        expectEqual(A.nowPlayingDescription(artist: "", title: "只有歌名"), "只有歌名")
        expectEqual(A.nowPlayingDescription(artist: "  ", title: " "), nil)
        expectEqual(A.nowPlayingDescription(artist: " 歌手 ", title: "歌名 "), "歌手 - 歌名")
    }

    do {
        let arc = "company.thebrowser.Browser"
        expectEqual(BrowserAutomationPermission.knownBrowserBundleIDs.contains(arc), false)
        expectEqual(BrowserAutomationPermission.family(forBundleID: arc), .chromium)

        for id in ["com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari"] {
            expectEqual(BrowserAutomationPermission.knownBrowserBundleIDs.contains(id), true)
        }

        expectEqual(BrowserAutomationPermission.family(forBundleID: "org.mozilla.firefox"), nil)
    }

    do {
        print("\n== 悬浮歌词字重阶梯 ==")

        let base = OverlayFontWeight.bold
        expectEqual(base.appKitWeight, 9)
        expectEqual(base.lighter(by: OverlayFontWeight.romanizationSteps).appKitWeight, 6)
        expectEqual(base.lighter(by: OverlayFontWeight.translationSteps).appKitWeight, 5)
        expectEqual(base.lighter(by: OverlayFontWeight.nextLinePreviewSteps).appKitWeight, 6)

        let current = OverlayFontWeight.semibold
        expectEqual(current.appKitWeight, 8)
        expectEqual(current.lighter(by: OverlayFontWeight.romanizationSteps).appKitWeight, 5)
        expectEqual(current.lighter(by: OverlayFontWeight.translationSteps).appKitWeight, 4)
        expectEqual(current.lighter(by: OverlayFontWeight.nextLinePreviewSteps).appKitWeight, 5)

        let ladder = OverlayFontWeight.allCases
        expectEqual(ladder.count >= 4, true)
        var strictlyIncreasing = true
        for i in 1..<ladder.count where ladder[i].appKitWeight <= ladder[i - 1].appKitWeight {
            strictlyIncreasing = false
        }
        expectEqual(strictlyIncreasing, true)
        expectEqual(ladder.first, .light)
        expectEqual(ladder.last, .heavy)

        expectEqual(OverlayFontWeight.light.lighter(by: 3), .light)
        expectEqual(OverlayFontWeight.regular.lighter(by: 9), .light)

        expectEqual(OverlayFontWeight.heavy.lighter(by: -5), .heavy)
        expectEqual(OverlayFontWeight.bold.lighter(by: 0), .bold)

        for weight in ladder {
            for steps in [OverlayFontWeight.romanizationSteps,
                          OverlayFontWeight.translationSteps,
                          OverlayFontWeight.nextLinePreviewSteps] {
                expectEqual(weight.lighter(by: steps).appKitWeight <= weight.appKitWeight, true)
            }
        }

        for weight in ladder {
            expectEqual(OverlayFontWeight(rawValue: weight.rawValue), weight)
        }
        expectEqual(OverlayFontWeight(rawValue: "ultraLight"), nil)
    }

    do {
        typealias PH = PlayerHealth
        expectEqual(PH.warnings(.init(appleMusicSelected: true, automationDenied: false,
                                      collectorServiceEnabled: true, collectorRunning: true)),
                    [])
        expectEqual(PH.warnings(.init(appleMusicSelected: true, automationDenied: true,
                                      collectorServiceEnabled: true, collectorRunning: true)),
                    [.automationDenied])
        expectEqual(PH.warnings(.init(appleMusicSelected: false, automationDenied: true,
                                      collectorServiceEnabled: true, collectorRunning: true)),
                    [])
        expectEqual(PH.warnings(.init(appleMusicSelected: false, automationDenied: false,
                                      collectorServiceEnabled: true, collectorRunning: false)),
                    [.collectorNotRunning])
        expectEqual(PH.warnings(.init(appleMusicSelected: false, automationDenied: false,
                                      collectorServiceEnabled: false, collectorRunning: false)),
                    [])
        expectEqual(PH.warnings(.init(appleMusicSelected: true, automationDenied: true,
                                      collectorServiceEnabled: true, collectorRunning: false)),
                    [.collectorNotRunning, .automationDenied])
    }

    do {
        typealias PL = PlayerLinkage
        let explicitAll = Set(PlaybackPlayer.allCases).subtracting([.auto])
        expectEqual(PL.candidates(selectedPlayers: [.auto]), explicitAll)
        expectEqual(PL.candidates(selectedPlayers: [.qqMusic, .kugou]), [.qqMusic, .kugou])
        expectEqual(PL.candidates(selectedPlayers: [.qqMusic, .auto]), explicitAll)
        expectEqual(PL.candidates(selectedPlayers: []), [])
        expectEqual(PL.effective([.spotify, .qqMusic], selectedPlayers: [.qqMusic]), [.qqMusic])
        expectEqual(PL.shouldQuit(terminatedBundleID: "com.apple.Music", boundBundleIDs: ["com.apple.Music"],
                                  runningBundleIDs: ["com.spotify.client"]), true)
        expectEqual(PL.shouldQuit(terminatedBundleID: "com.spotify.client", boundBundleIDs: ["com.apple.Music"],
                                  runningBundleIDs: []), false)
        expectEqual(PL.shouldQuit(terminatedBundleID: "com.apple.Music",
                                  boundBundleIDs: ["com.apple.Music", "com.spotify.client"],
                                  runningBundleIDs: ["com.spotify.client"]), false)
        expectEqual(PL.shouldQuit(terminatedBundleID: "com.apple.Music", boundBundleIDs: [], runningBundleIDs: []), false)
        expectEqual(PL.quitGraceSeconds, 5)
        expectEqual(PL.migratedLaunchSet(legacyEnabled: true, selectedPlayers: [.qqMusic], requiresSole: true), [.qqMusic])
        expectEqual(PL.migratedLaunchSet(legacyEnabled: true, selectedPlayers: [.qqMusic, .spotify], requiresSole: true), [])
        expectEqual(PL.migratedLaunchSet(legacyEnabled: true, selectedPlayers: [.auto], requiresSole: false), explicitAll)
        expectEqual(PL.migratedLaunchSet(legacyEnabled: false, selectedPlayers: [.auto], requiresSole: false), [])
    }
}
