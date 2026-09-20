import LyrimuseCore
import Foundation

@MainActor
func runPlaybackPositionTests() {
    do {
        let start = Date(timeIntervalSince1970: 1_000_000)
        for correction in [-1000, -500, 500, 1000] {
            let anchor = ProgressAnchor(durationMs: 200_000, progressMs: 40_000, rate: 1,
                progressTs: nil, baseAgeMs: 0, fetchedAt: start, fresh: true, correctionMs: correction)
            var previous = 40_000
            for step in 0...200 {
                let position = anchor.extrapolatedPositionMs(now: start.addingTimeInterval(Double(step) / 20))
                expectEqual(position >= previous, true)
                previous = position
            }
            expectEqual(previous, 50_000 + correction)
            expectEqual(anchor.instantaneousRate(now: start), correction < 0 ? 0.8 : 1.2)
            expectEqual(anchor.instantaneousRate(now: start.addingTimeInterval(10)), 1)
        }
        expectEqual(ProgressAnchor.correctionForContinuousPlayback(displayedMs: 40_000,
            targetMs: 39_000, continuous: true), -1000)
        expectEqual(ProgressAnchor.correctionForContinuousPlayback(displayedMs: 40_000,
            targetMs: 39_000, continuous: false), 0)
        expectEqual(ProgressAnchor.correctionForContinuousPlayback(displayedMs: 40_000,
            targetMs: 10_000, continuous: true), 0)
        expectEqual(enrichLyricsSearchIncomplete(lyrics: "", sourcesSkipped: [], fillCount: 0,
            sourcesFailed: ["netease"]), true)
        expectEqual(enrichLyricsSearchIncomplete(lyrics: "", sourcesSkipped: [], fillCount: 1,
            sourcesFailed: ["netease"]), false)
        let legacy = try? JSONDecoder().decode(EnrichCacheEntry.self, from: Data("{\"lyrics\":\"line\"}".utf8))
        expectEqual(legacy?.lyrics, "line")
    }

    do {
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        let steady = MediaControlClient.ageCompensatedCachedElapsed(
            cachedElapsed: 100.0, cachedPlaying: true, cachedRate: 1, cachedAt: t0,
            freshElapsed: 101.9, freshPlaying: true, now: t0.addingTimeInterval(1.8)
        )
        expectEqual(steady.map { abs($0 - 101.8) < 0.001 }, true)

        let loopRestart = MediaControlClient.ageCompensatedCachedElapsed(
            cachedElapsed: 240.0, cachedPlaying: true, cachedRate: 1, cachedAt: t0,
            freshElapsed: 1.6, freshPlaying: true, now: t0.addingTimeInterval(1.8)
        )
        expectEqual(loopRestart == nil, true)

        let pausedCache = MediaControlClient.ageCompensatedCachedElapsed(
            cachedElapsed: 100.0, cachedPlaying: false, cachedRate: 0, cachedAt: t0,
            freshElapsed: 100.1, freshPlaying: true, now: t0.addingTimeInterval(1.8)
        )
        expectEqual(pausedCache == nil, true)

        let zeroRate = MediaControlClient.ageCompensatedCachedElapsed(
            cachedElapsed: 100.0, cachedPlaying: true, cachedRate: 0, cachedAt: t0,
            freshElapsed: 101.9, freshPlaying: true, now: t0.addingTimeInterval(1.8)
        )
        expectEqual(zeroRate.map { abs($0 - 101.8) < 0.001 }, true)
    }

    do {
        let ts = Date(timeIntervalSince1970: 1_000_000)

        let healthy = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 170.866, elapsedTimeNow: 176.21,
            playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(6.0))
        expectEqual(healthy.map { ($0 * 100).rounded() / 100 }, 176.21)

        let stalled = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 178.604, elapsedTimeNow: 178.604,
            playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(16.0))
        expectEqual(stalled.map { ($0 * 1000).rounded() / 1000 }, 194.604)

        let a = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 178.604, elapsedTimeNow: 178.604,
            playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(2))
        let b = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 178.604, elapsedTimeNow: 178.604,
            playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(15))
        expectEqual((a ?? 0) < (b ?? 0), true)

        let paused = MediaControlClient.livePositionSeconds(
            playing: false, elapsedTime: 104.948, elapsedTimeNow: 108.428,
            playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30))
        expectEqual(paused, 104.948)

        do {
            let ts = Date(timeIntervalSince1970: 1_000_000)
            func est(_ gap: Double) -> Double {
                MC.estimatedAnchorInstant(timestamp: ts, firstSeenAt: ts.addingTimeInterval(gap))
                    .timeIntervalSince(ts)
            }

            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            expectEqual(ms(est(0.10)), 0.05)
            expectEqual(ms(est(0.90)), 0.45)

            expectEqual(est(1.00), 0.5)
            expectEqual(est(5.00), 0.5)

            for gap in [0.01, 0.3, 0.7, 1.0, 2.0, 30.0] {
                let v = est(gap)
                expectEqual(v >= 0 && v <= 0.5, true)
            }

            expectEqual(MC.estimatedAnchorInstant(timestamp: ts, firstSeenAt: ts.addingTimeInterval(-3)),
                        ts)

            let frozen = MC.livePositionSeconds(
                playing: true, elapsedTime: 100, elapsedTimeNow: 130.0,
                playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30),
                lastPlayingPosition: nil, firstSeenAt: ts.addingTimeInterval(0.4))

            expectEqual(frozen.map { (($0) * 1000).rounded() / 1000 }, 129.8)

            let fresh = MC.livePositionSeconds(
                playing: true, elapsedTime: 100, elapsedTimeNow: 100.9,
                playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(0.9),
                lastPlayingPosition: nil, firstSeenAt: ts.addingTimeInterval(0.2))
            expectEqual(fresh, 100.9)

            let legacy = MC.livePositionSeconds(
                playing: true, elapsedTime: 100, elapsedTimeNow: 130.0,
                playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30))
            expectEqual(legacy, 130.0)
        }

        do {
            let ts = Date(timeIntervalSince1970: 1_000_000)
            let tsString = "1970-01-12T13:46:40Z"
            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            expectEqual(MC.parseTimestamp(tsString), ts)

            let tight = MC.AnchorSighting(at: ts.addingTimeInterval(0.585), tight: true)
            expectEqual(ms(MC.estimatedAnchorInstant(timestamp: ts, sighting: tight).timeIntervalSince(ts)), 0.56)

            let early = MC.AnchorSighting(at: ts.addingTimeInterval(0.010), tight: true)
            expectEqual(MC.estimatedAnchorInstant(timestamp: ts, sighting: early), ts)

            let late = MC.AnchorSighting(at: ts.addingTimeInterval(1.3), tight: true)
            expectEqual(ms(MC.estimatedAnchorInstant(timestamp: ts, sighting: late).timeIntervalSince(ts)), 0.999)

            let loose = MC.AnchorSighting(at: ts.addingTimeInterval(0.4), tight: false)
            expectEqual(MC.estimatedAnchorInstant(timestamp: ts, sighting: loose),
                        MC.estimatedAnchorInstant(timestamp: ts, firstSeenAt: ts.addingTimeInterval(0.4)))

            let resumed = MC.livePositionSeconds(
                playing: true, elapsedTime: 172.994, elapsedTimeNow: 172.994,
                playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(42.647),
                lastPlayingPosition: nil, sighting: tight)
            expectEqual(resumed.map(ms), 215.081)

            let noSighting = MC.livePositionSeconds(
                playing: true, elapsedTime: 172.994, elapsedTimeNow: 172.994,
                playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(42.647))
            expectEqual(noSighting.map(ms), 215.641)

            let looseResumed = MC.livePositionSeconds(
                playing: true, elapsedTime: 172.994, elapsedTimeNow: 172.994,
                playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(42.647),
                lastPlayingPosition: nil, sighting: loose)
            expectEqual(looseResumed.map(ms), 215.441)

            let staleTight = MC.livePositionSeconds(
                playing: true, elapsedTime: 100, elapsedTimeNow: 130.0,
                playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30),
                lastPlayingPosition: nil, sighting: tight)
            expectEqual(staleTight.map(ms), 129.44)

            let both = MC.livePositionSeconds(
                playing: true, elapsedTime: 100, elapsedTimeNow: 130.0,
                playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30),
                lastPlayingPosition: nil, firstSeenAt: ts.addingTimeInterval(0.4), sighting: tight)
            expectEqual(both.map(ms), 129.44)

            expectEqual(MC.anchorKey(artist: "方大同", title: "南音", elapsedTime: 172.994, timestamp: "2026-09-06T16:40:25Z"),
                        "方大同|南音|172.994|2026-09-06T16:40:25Z")
            expectEqual(MC.anchorKey(artist: nil, title: "x", elapsedTime: 0, timestamp: nil), "|x|0.000|-")

            let arrival = ts.addingTimeInterval(0.585)
            let full = Data(("{\"type\":\"data\",\"diff\":false,\"payload\":{\"bundleIdentifier\":\"com.spotify.client\","
                + "\"title\":\"南音\",\"artist\":\"方大同\",\"playing\":true,\"elapsedTime\":26.458,"
                + "\"timestamp\":\"\(tsString)\",\"duration\":215.853}}").utf8)
            let d1 = MediaControlStreamWatcher.digest(line: full, merged: [:], arrivedAt: arrival)
            expectEqual(d1.anchorKey, "方大同|南音|26.458|\(tsString)")
            expectEqual(d1.tight, true)
            expectEqual(d1.anchorAge.map(ms), 0.585)

            let diff = Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"elapsedTime\":162.05,\"timestamp\":\"\(tsString)\",\"playbackRate\":null}}".utf8)
            let d2 = MediaControlStreamWatcher.digest(line: diff, merged: d1.merged, arrivedAt: arrival)
            expectEqual(d2.anchorKey, "方大同|南音|162.050|\(tsString)")
            expectEqual(d2.merged["title"] as? String, "南音")

            let playingOnly = Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":false}}".utf8)
            expectEqual(MediaControlStreamWatcher.digest(line: playingOnly, merged: d1.merged, arrivedAt: arrival).anchorKey, nil)

            let stale = MediaControlStreamWatcher.digest(line: full, merged: [:], arrivedAt: ts.addingTimeInterval(30))
            expectEqual(stale.anchorKey != nil && stale.tight == false, true)

            let empty = MediaControlStreamWatcher.digest(
                line: Data("{\"type\":\"data\",\"diff\":false,\"payload\":{}}".utf8), merged: d1.merged, arrivedAt: arrival)
            expectEqual(empty.anchorKey == nil && empty.merged.isEmpty, true)
            expectEqual(MediaControlStreamWatcher.digest(line: Data("garbage".utf8), merged: d1.merged, arrivedAt: arrival).anchorKey, nil)
        }

        do {
            let ts = Date(timeIntervalSince1970: 1_000_000)
            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            let last = MC.PlayingAnchor(track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T09", instant: ts.addingTimeInterval(0.555))
            let later = ts.addingTimeInterval(34.5)

            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T43", duration: 268.92, now: later),
                        true)

            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|忘了美麗", elapsed: 44.2, timestamp: "T43", duration: 268.92, now: later),
                        false)

            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T09", duration: 268.92, now: later),
                        false)

            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|南音", elapsed: 10.477, timestamp: "T43", duration: 268.92, now: later),
                        false)

            let atStart = MC.PlayingAnchor(track: "x|y", elapsed: 0, timestamp: "T00", instant: ts)
            expectEqual(MC.isStaleAnchorRepublish(last: atStart, track: "x|y", elapsed: 0, timestamp: "T44", duration: 268.92, now: ts.addingTimeInterval(44)),
                        false)

            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T99", duration: 268.92, now: ts.addingTimeInterval(270)),
                        false)

            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T43", duration: nil, now: later),
                        true)
            expectEqual(MC.isStaleAnchorRepublish(last: nil, track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T43", duration: 268.92, now: later),
                        false)

            let kept = MC.livePositionSeconds(
                playing: true, elapsedTime: 10.477, elapsedTimeNow: 73.752,
                playbackRate: 1, timestamp: ts.addingTimeInterval(34), now: ts.addingTimeInterval(97.7),
                lastPlayingPosition: nil, sighting: MC.AnchorSighting(at: ts.addingTimeInterval(34.5), tight: true),
                republishedAnchorInstant: last.instant)
            expectEqual(kept.map(ms), ms(10.477 + 97.7 - 0.555))

            let keptNoRate = MC.livePositionSeconds(
                playing: true, elapsedTime: 10.477, elapsedTimeNow: 10.477,
                playbackRate: nil, timestamp: ts.addingTimeInterval(34), now: ts.addingTimeInterval(97.7),
                republishedAnchorInstant: last.instant)
            expectEqual(keptNoRate.map(ms), ms(10.477 + 97.7 - 0.555))

            let pausedKept = MC.livePositionSeconds(
                playing: false, elapsedTime: 44.0, elapsedTimeNow: 73.752,
                playbackRate: 1, timestamp: ts.addingTimeInterval(34), now: ts.addingTimeInterval(97.7),
                republishedAnchorInstant: last.instant)
            expectEqual(pausedKept, 44.0)
        }

        do {
            let t = Date(timeIntervalSince1970: 1_000_000)
            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            expectEqual(SpotifyPositionProbe.extrapolate(position: 3.2, capturedAt: t, now: t.addingTimeInterval(0.4), rate: 1).map(ms),
                        3.6)
            expectEqual(SpotifyPositionProbe.extrapolate(position: 3.2, capturedAt: t, now: t.addingTimeInterval(0.4), rate: 0).map(ms),
                        3.6)
            expectEqual(SpotifyPositionProbe.extrapolate(position: 3.2, capturedAt: t, now: t.addingTimeInterval(7), rate: 1),
                        nil)
            expectEqual(SpotifyPositionProbe.extrapolate(position: 3.2, capturedAt: t, now: t.addingTimeInterval(-1), rate: 1),
                        nil)
        }

        do {
            let gap = SpotifyPositionProbe.livenessGapSeconds
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 4.96, second: 4.96 + gap, wallGap: gap), true)
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 4.96, second: 4.96 + gap * 0.7, wallGap: gap), true)
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 0, second: 0, wallGap: gap), false)
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 4.96, second: 4.96 + gap * 0.3, wallGap: gap), false)
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 4.96, second: 2.0, wallGap: gap), false)
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 4.96, second: 30.0, wallGap: gap), false)
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 1, second: 2, wallGap: 0), false)
        }

        do {
            func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.5, residual: 0.07, hasPrior: false)), 0.57)
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.57, residual: 0.0, hasPrior: true)), 0.57)
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.57, residual: -0.46, hasPrior: true)), 0.34)
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.569, residual: 2.3, hasPrior: true)), 0.569)
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.5, residual: -1.8, hasPrior: false)), 0.5)
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.1, residual: -0.3, hasPrior: true)), -0.05)
            expectEqual(LocalPlaybackSource.probeLeadPrior(for: .bluetooth), 0.5)
            expectEqual(LocalPlaybackSource.probeLeadPrior(for: .builtIn), 0.1)
            expectEqual(LocalPlaybackSource.probeLeadPrior(for: .airPlay), 0)
            expectEqual(LocalPlaybackSource.probeLeadPrior(for: .other), 0)
        }

        do {
            let rec = PositionBiasRecord(artist: "Olivia Rodrigo", title: "vampire", bundleID: "com.spotify.client",
                                         anchorElapsed: 0, biasSecs: -1.957, writtenAtMs: 1_789_002_067_341)
            let encoded = (try? PositionBiasFile.encode(rec)).flatMap { String(data: $0, encoding: .utf8) }
            expectEqual(encoded,
                        #"{"anchor_elapsed":0,"artist":"Olivia Rodrigo","bias_secs":-1.957,"bundle_id":"com.spotify.client","title":"vampire","written_at_ms":1789002067341}"#)
            let cleared = PositionBiasRecord(artist: "Olivia Rodrigo", title: "vampire", bundleID: "com.spotify.client",
                                             anchorElapsed: nil, biasSecs: 0, writtenAtMs: 1)
            let clearedJSON = (try? PositionBiasFile.encode(cleared)).flatMap { String(data: $0, encoding: .utf8) } ?? ""

            expectEqual(clearedJSON.contains(#""anchor_elapsed""#), false)
            expectEqual(clearedJSON.contains(#""bias_secs":0"#), true)
            expectEqual(rec.sameContent(as: PositionBiasRecord(artist: "Olivia Rodrigo", title: "vampire", bundleID: "com.spotify.client",
                                                                anchorElapsed: 0, biasSecs: -1.957, writtenAtMs: 9)), true)
            expectEqual(rec.sameContent(as: cleared), false)
            expectEqual(PositionBiasFile.fileName, "lyrimuse-position-bias.json")
        }

        do {
            let ts = Date(timeIntervalSince1970: 1_000_000)
            let sampled = ts.addingTimeInterval(5.30)
            let pauseAt = ts.addingTimeInterval(7.05)
            let now = ts.addingTimeInterval(7.35)
            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

            let extrapolated = MC.pausedPositionSeconds(
                elapsedTime: 0, anchorTimestamp: ts, lastPlaying: (5.225, sampled), pauseObservedAt: pauseAt, now: now)
            expectEqual(extrapolated.map(ms), 6.975)

            let frozen = MC.pausedPositionSeconds(
                elapsedTime: 6.858, anchorTimestamp: ts.addingTimeInterval(7), lastPlaying: (5.225, sampled), pauseObservedAt: pauseAt, now: now)
            expectEqual(frozen, 6.858)

            let stalePause = MC.pausedPositionSeconds(
                elapsedTime: 0, anchorTimestamp: ts, lastPlaying: (5.225, sampled), pauseObservedAt: ts.addingTimeInterval(1), now: now)
            expectEqual(stalePause, 5.225)

            let noEvent = MC.pausedPositionSeconds(
                elapsedTime: 0, anchorTimestamp: ts, lastPlaying: (5.225, sampled), pauseObservedAt: nil, now: now)
            expectEqual(noEvent, 5.225)

            expectEqual(MC.pausedPositionSeconds(elapsedTime: 12, anchorTimestamp: ts, lastPlaying: nil, pauseObservedAt: pauseAt, now: now),
                        12)

            let justBefore = MC.pausedPositionSeconds(
                elapsedTime: 0, anchorTimestamp: ts, lastPlaying: (5.225, sampled), pauseObservedAt: sampled.addingTimeInterval(-0.2), now: now)
            expectEqual(justBefore, 5.225)

            let viaLive = MC.livePositionSeconds(
                playing: false, elapsedTime: 0, elapsedTimeNow: 999, playbackRate: 1, timestamp: ts, now: now,
                lastPlayingPosition: 5.225, lastPlayingSampledAt: sampled, pauseObservedAt: pauseAt)
            expectEqual(viaLive.map(ms), 6.975)
            let viaLiveLegacy = MC.livePositionSeconds(
                playing: false, elapsedTime: 0, elapsedTimeNow: 999, playbackRate: 1, timestamp: ts, now: now,
                lastPlayingPosition: 5.225)
            expectEqual(viaLiveLegacy, 5.225)

            let pausedLine = Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":false}}".utf8)
            expectEqual(MediaControlStreamWatcher.digest(line: pausedLine, merged: [:], arrivedAt: now).pausedAtArrival, true)
            let playingLine = Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":true}}".utf8)
            expectEqual(MediaControlStreamWatcher.digest(line: playingLine, merged: [:], arrivedAt: now).pausedAtArrival, false)
        }

        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 0), true)
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 0.0005), true)
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 152.673), false)
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 50.844), false)
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: nil), true)

        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 1.923, measuredAgainst: 1.923), true)
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 1.923, measuredAgainst: 0), false)
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 0, measuredAgainst: 0), true)
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 41.377, measuredAgainst: 0), false)
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: nil, measuredAgainst: 1.923), true)

        typealias MC = MediaControlClient

        expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: 187, lastPlayingPosition: 187),
                    187)

        expectEqual(MC.pausedPositionSeconds(elapsedTime: 12, anchorAge: 0.3, lastPlayingPosition: 100),
                    12)

        expectEqual(MC.pausedPositionSeconds(elapsedTime: 99, anchorAge: 30, lastPlayingPosition: 100),
                    99)

        expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: 999, lastPlayingPosition: nil),
                    0)
        expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: nil, lastPlayingPosition: 187),
                    0)

        expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: MC.staleAnchorAfter,
                                             lastPlayingPosition: 187),
                    0)
        expectEqual(MC.pausedPositionSeconds(elapsedTime: 100, anchorAge: 60,
                                             lastPlayingPosition: 100 + MC.frozenAnchorPauseDrop),
                    100)

        expectEqual(MC.livePositionSeconds(playing: false, elapsedTime: 104.948, elapsedTimeNow: 999,
                                           playbackRate: 1, timestamp: nil, now: Date()),
                    104.948)

        let zeroRate = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 10, elapsedTimeNow: 10,
            playbackRate: 0, timestamp: ts, now: ts.addingTimeInterval(5))
        expectEqual(zeroRate, 15)

        let backwards = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 50, elapsedTimeNow: 50,
            playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(-10))
        expectEqual(backwards, 50)
    }

    do {

        expectEqual(MediaControlClient.parseTimestamp("2026-08-18T08:51:46Z") != nil, true)
        expectEqual(MediaControlClient.parseTimestamp("2026-08-18T08:51:46.123Z") != nil, true)
        expectEqual(MediaControlClient.parseTimestamp(nil) == nil, true)
    }

    do {

        var ema = 0.0
        var snapped = false
        var rounds = 0
        for _ in 1...5 {
            rounds += 1
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: -1.2, tier: .precise)
            ema = newEMA
            if snap { snapped = true; break }
        }
        expectEqual(snapped, true)
        expectEqual(rounds <= 3, true)
    }

    do {

        var ema = 0.0
        var snapped = false
        for _ in 1...10 {
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: 0.205, tier: .precise)
            ema = newEMA
            if snap { snapped = true; break }
        }
        expectEqual(snapped, true)
    }

    do {

        var ema = 0.0
        var falseSnap = false
        for i in 1...50 {
            let err = i % 2 == 0 ? 0.06 : -0.06
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, tier: .precise)
            ema = newEMA
            if snap { falseSnap = true; break }
        }
        expectEqual(falseSnap, false)
    }

    do {

        var ema = 0.0
        var falseSnap = false
        for i in 1...50 {
            let err = i % 2 == 0 ? 1.5 : -1.5
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, tier: .noisyFloored)
            ema = newEMA
            if snap { falseSnap = true; break }
        }
        expectEqual(falseSnap, false)
    }

    do {

        var ema = 0.0
        var snapped = false
        for _ in 1...10 {
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: 1.5, tier: .noisyFloored)
            ema = newEMA
            if snap { snapped = true; break }
        }
        expectEqual(snapped, true)
    }

    do {

        var ema = 0.0
        var snapped = false
        var rounds = 0
        for _ in 1...5 {
            rounds += 1
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: -0.8, tier: .cleanExtrapolated)
            ema = newEMA
            if snap { snapped = true; break }
        }
        expectEqual(snapped, true)
        expectEqual(rounds <= 3, true)
    }

    do {

        let (ema1, snap1) = LocalPlaybackSource.servoDecision(errEMA: 0, error: -1.27, tier: .cleanExtrapolated)
        expectEqual(snap1, false)

        let (_, snap2) = LocalPlaybackSource.servoDecision(errEMA: ema1, error: -0.05, tier: .cleanExtrapolated)
        expectEqual(snap2, false)
    }

    do {

        var ema = 0.0
        var falseSnap = false
        for i in 1...50 {
            let err = i % 2 == 0 ? 0.05 : -0.05
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, tier: .cleanExtrapolated)
            ema = newEMA
            if snap { falseSnap = true; break }
        }
        expectEqual(falseSnap, false)
    }

    do {

        let corr = LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.048, overrun: -0.837)
        expectEqual(corr != nil, true)
        if let corr {
            expectEqual(abs(corr.seed - (-0.837)) < 1e-9, true)
            expectEqual(abs(corr.bias - 0.885) < 1e-9, true)
        }
    }

    do {

        let corr = LocalPlaybackSource.naturalAdvanceCorrection(reported: 1.5, overrun: 0.6)
        expectEqual(corr?.seed == 0.6 && corr?.bias == 0.9, true)
    }

    do {

        expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.3, overrun: -188) == nil, true)
        expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.3, overrun: 0.28) == nil, true)
        expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 30.3, overrun: -0.5) == nil, true)
        expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.1, overrun: 0.9) == nil, true)
    }

    do {

        let corr = LocalPlaybackSource.naturalAdvanceCorrection(reported: 3.2, overrun: 0.2)
        expectEqual(corr == nil, true)
    }

    do {
        typealias L = LocalPlaybackSource
        expectEqual(L.isFrozenReport(reportedAdvance: 0.0, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                    true)
        expectEqual(L.isFrozenReport(reportedAdvance: 2.0, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                    false)
        expectEqual(L.isFrozenReport(reportedAdvance: -8.0, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                    false)
        expectEqual(L.isFrozenReport(reportedAdvance: 8.2, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                    false)
        expectEqual(L.isFrozenReport(reportedAdvance: 0.02, gap: 0.3, rate: 1, tier: .cleanExtrapolated),
                    false)
        expectEqual(L.isFrozenReport(reportedAdvance: 0.0, gap: 2.0, rate: 1, tier: .noisyFloored),
                    false)

        let (_, snap) = L.servoDecision(errEMA: 0, error: -1.74, tier: .cleanExtrapolated)
        expectEqual(snap, false)
    }

    do {
        let f = LocalPlaybackSource.shouldRejectStalePositionAfterSeek

        expectEqual(f(30.2, 120, 30, 0.1), true)

        expectEqual(f(120.3, 120, 30, 0.1), false)

        expectEqual(f(30.2, 120, 30, 5.0), false)

        expectEqual(f(100.0, 100.5, 100, 0.1), true)

        expectEqual(f(75, 100, 50, 0.1), false)

        expectEqual(f(30, 120, 30, -1), false)
    }

    do {
        let arg = MusicPlaybackController.seekArgument(forSeconds:)
        expectEqual(arg(2.2), "2.200")
        expectEqual(arg(255.4567), "255.457")
        expectEqual(arg(0), "0.000")
        expectEqual(arg(-5), "0.000")

        expectEqual(arg(99999.5), "99999.500")

        expectEqual(arg(.nan), "0.000")
        expectEqual(arg(.infinity), "0.000")

        expectEqual(arg(2.2).contains(","), false)
    }

    do {
        let yrc = [
            "[60,900](60,400,0)特别的人 - 方大同",
            "[1110,600](1110,600,0)词：方大同",
            "[1760,600](1760,600,0)曲：方大同",
        ].joined(separator: "\n")
        var lrcLines: [String] = []
        for i in 0..<10 {
            lrcLines.append("[00:" + String(format: "%02d", i * 5) + ".000]第 " + String(i) + " 句歌词")
        }
        let lrc = lrcLines.joined(separator: "\n")

        let engine = LyricsSyncEngine()
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)

        expectEqual(engine.activeLine(atMs: 45_000)?.plainText, "第 9 句歌词")

        let onlyWords = LyricsSyncEngine()
        onlyWords.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
        expectEqual(onlyWords.hasContent, true)
    }

    do {
        typealias Tier = LocalPlaybackSource.PositionSourceTier
        func ratchet(_ reported: Double, _ predicted: Double, tier: Tier) -> Bool {
            LocalPlaybackSource.shouldRatchetForward(
                reported: reported, predicted: predicted, tier: tier)
        }

        expectEqual(ratchet(23.1, 22.1, tier: .noisyFloored), true)
        expectEqual(ratchet(22.4, 22.1, tier: .noisyFloored), true)

        expectEqual(ratchet(21.5, 22.1, tier: .noisyFloored), false)

        expectEqual(ratchet(22.102, 22.1, tier: .noisyFloored), false)

        expectEqual(ratchet(23.1, 22.1, tier: .precise), false)

        expectEqual(ratchet(23.1, 22.1, tier: .cleanExtrapolated), false)
    }

    do {
        typealias P = BrowserPositionProbe
        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"168|0\""), 168)
        expectEqual(P.parseSeconds(fromOsascriptOutput: "168|0"), 168)
        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"168|1\""), nil)
        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"NOTFOUND\""), nil)
        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"\""), nil)
        expectEqual(P.parseSeconds(fromOsascriptOutput: ""), nil)

        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"{\\\"found\\\":true,\\\"seconds\\\":168}\""),
                    nil)
    }

    do {
        expectEqual(BrowserPositionProbe.supportedPlatforms.contains { $0.id == "youtubeMusic" }, true)
        expectEqual(BrowserPositionProbe.supportedPlatforms.contains { $0.id == "spotifyWeb" }, true)

        do {
            let t0 = Date()
            let p = CGPoint(x: 100, y: 200)
            typealias A = ScrollForwardDecision
            expectEqual(A.canReuse(cachedWindow: 7, cachedPoint: p, cachedAt: t0,
                                                 window: 7, point: p, now: t0.addingTimeInterval(0.05)),
                        true)
            expectEqual(A.canReuse(cachedWindow: 7, cachedPoint: p, cachedAt: t0,
                                                 window: 8, point: p, now: t0.addingTimeInterval(0.05)),
                        false)
            expectEqual(A.canReuse(cachedWindow: 7, cachedPoint: p, cachedAt: t0,
                                                 window: 7, point: CGPoint(x: 140, y: 200),
                                                 now: t0.addingTimeInterval(0.05)),
                        false)
            expectEqual(A.canReuse(cachedWindow: 7, cachedPoint: p, cachedAt: t0,
                                                 window: 7, point: p, now: t0.addingTimeInterval(5)),
                        false)
        }

        for (first, second, want, _) in [
            (7.0, 8.0, true, "正常播放:整秒读数 +1 就是钟在走"),
            (7.0, 9.0, true, "间隔跨了两个整秒边界(+2)同样算在走"),
            (120.0, 121.0, true, "判据跟位置绝对值无关 —— 这正是旧守卫栽的地方,必须钉住"),
            (7.0, 7.0, false, "陈旧镜像标签页:实测 15 次采样一直读 7 秒,必须挡掉"),
            (35.0, 7.0, false, "读数往回跳(拖进度条/读到别的标签页)不采信,下一轮重试"),
        ] as [(Double, Double, Bool, String)] {
            expectEqual(BrowserPositionProbe.pageClockIsRunning(first: first, second: second), want)
        }

        expectEqual(BrowserPositionProbe.livenessGapSeconds > 1.0, true)

        expectEqual(BrowserPositionProbe.maxProbeAttempts >= 2, true)
        expectEqual(BrowserPositionProbe.probeRetryBackoffSecs > BrowserPositionProbe.livenessGapSeconds, true)

        expectEqual(BrowserPositionProbe.pageDurationToleranceSecs >= 1
                    && BrowserPositionProbe.pageDurationToleranceSecs <= 5, true)

        expectEqual(LocalPlaybackSource.servoDecision(errEMA: 0, error: -0.7, tier: .noisyFloored).snap,
                    false)
        expectEqual(0.7 > LocalPlaybackSource.groundTruthSnapToleranceSecs, true)
        expectEqual(BrowserPositionProbe.flooredMidpointBiasSecs, 0.5)

        expectEqual(BrowserPositionProbe.probeTargetBundleID(forReported: "com.apple.WebKit.GPU"),
                    "com.apple.Safari")
        expectEqual(BrowserPositionProbe.probeTargetBundleID(forReported: "company.thebrowser.Browser"),
                    "company.thebrowser.Browser")
        expectEqual(BrowserPositionProbe.probeTargetBundleID(forReported: nil), nil)

        expectEqual(BrowserPositionProbe.platformIDsWithSiteRules,
                    Set(BrowserPositionProbe.supportedPlatforms.map(\.id)))

        expectEqual(Set(BrowserPositionProbe.supportedPlatforms.map(\.id)).count,
                    BrowserPositionProbe.supportedPlatforms.count)
        let probe = BrowserPositionProbe.shared
        probe.trackChanged()
        probe.platformBrowserPairs = [:]
        let key = "selftest-pairing-gate-key"
        probe.kickIfNeeded(bundleIdentifier: "company.thebrowser.Browser", key: key, expectedDuration: 240)

        Thread.sleep(forTimeInterval: 2.0)
        expectEqual(probe.consumeCorrection(forKey: key, rate: 1, now: Date()), nil)
        probe.trackChanged()
        probe.platformBrowserPairs = [:]

        probe.platformBrowserPairs = ["spotifyWeb": ["com.apple.Safari"]]
        expectEqual(probe.isPaired(bundleID: "com.apple.Safari", platformID: "spotifyWeb"), true)
        expectEqual(probe.isPaired(bundleID: "com.apple.Safari", platformID: "youtubeMusic"), false)
        expectEqual(probe.isPaired(bundleID: "com.microsoft.edgemac", platformID: "spotifyWeb"), false)
        expectEqual(probe.isPaired(bundleID: nil, platformID: "spotifyWeb"), false)
        probe.platformBrowserPairs = [:]
    }

    do {
        typealias P = BrowserPositionProbe
        let both: Set<String> = ["youtubeMusic", "spotifyWeb"]

        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: both, recentMatch: "youtubeMusic"),
                    "youtubeMusic")
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: both, recentMatch: "spotifyWeb"),
                    "spotifyWeb")

        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: ["youtubeMusic"], recentMatch: nil),
                    "youtubeMusic")

        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: both, recentMatch: nil), nil)

        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: [], recentMatch: nil), nil)

        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: ["spotifyWeb"],
                                               recentMatch: "youtubeMusic"),
                    "spotifyWeb")
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: [], recentMatch: "youtubeMusic"),
                    nil)

        expectEqual(Set(P.supportedPlatforms.map(\.id)), both)
    }

    do {
        typealias R = RadioTrackClock
        let t0 = Date(timeIntervalSince1970: 1_788_000_000)

        let first = R.advance(nil, trackKey: "Daniel Caesar|Who Knows", playing: true, now: t0)
        expectEqual(first.position, 0)
        expectEqual(first.trackKey, "Daniel Caesar|Who Knows")

        let t10 = R.advance(R.advance(first, trackKey: "Daniel Caesar|Who Knows", playing: true, now: t0.addingTimeInterval(5)),
                            trackKey: "Daniel Caesar|Who Knows", playing: true, now: t0.addingTimeInterval(10))
        expectEqual(t10.position, 10)

        let changed = R.advance(t10, trackKey: "Clairo|Juna", playing: true, now: t0.addingTimeInterval(11))
        expectEqual(changed.position, 0)

        let played = R.advance(changed, trackKey: "Clairo|Juna", playing: true, now: t0.addingTimeInterval(21))
        expectEqual(played.position, 10)
        let pausing = R.advance(played, trackKey: "Clairo|Juna", playing: false, now: t0.addingTimeInterval(23))
        expectEqual(pausing.position, 12)
        let paused = R.advance(pausing, trackKey: "Clairo|Juna", playing: false, now: t0.addingTimeInterval(120))
        expectEqual(paused.position, 12)

        let resumed = R.advance(paused, trackKey: "Clairo|Juna", playing: true, now: t0.addingTimeInterval(125))
        expectEqual(resumed.position, 12)
        let afterResume = R.advance(resumed, trackKey: "Clairo|Juna", playing: true, now: t0.addingTimeInterval(128))
        expectEqual(afterResume.position, 15)

        let slept = R.advance(afterResume, trackKey: "Clairo|Juna", playing: true, now: t0.addingTimeInterval(128 + 7200))
        expectEqual(slept.position, 15 + R.maxAdvancePerTick)

        expectEqual(R.advance(slept, trackKey: "Clairo|Juna", playing: true, now: t0).position, slept.position)
    }

    do {
        typealias R = RadioTrackClock
        typealias W = MediaControlStreamWatcher
        let t0 = Date(timeIntervalSince1970: 1_788_000_000)

        expectEqual(R.seedPosition(startedAt: nil, now: t0), 0)
        expectEqual(R.seedPosition(startedAt: t0.addingTimeInterval(5), now: t0), 0)
        expectEqual((R.seedPosition(startedAt: t0, now: t0.addingTimeInterval(1.43)) * 1000).rounded(), 1430)
        expectEqual(R.seedPosition(startedAt: t0, now: t0.addingTimeInterval(600)), R.maxStartSeed)

        let seeded = R.advance(nil, trackKey: "NCT 127|英雄", playing: true, now: t0.addingTimeInterval(1.816),
                               startedAt: t0.addingTimeInterval(0.999))
        expectEqual((seeded.position * 1000).rounded(), 817)
        let next = R.advance(seeded, trackKey: "NCT 127|英雄", playing: true, now: t0.addingTimeInterval(4.816),
                             startedAt: t0.addingTimeInterval(0.999))
        expectEqual((next.position * 1000).rounded(), 3817)

        expectEqual(W.changedTrackKey(before: ["artist": "NCT 127", "title": "英雄"],
                                      after: ["artist": "NCT 127", "title": "Fact Check (不可思议)"]),
                    "NCT 127|Fact Check (不可思议)")
        expectEqual(W.changedTrackKey(before: ["artist": "NCT 127", "title": "英雄"],
                                      after: ["artist": "NCT 127", "title": "英雄"]),
                    nil)
        expectEqual(W.changedTrackKey(before: ["artist": "周杰伦", "title": "说好的幸福呢"],
                                      after: ["artist": "NCT 127", "title": "  "]),
                    nil)

        let ts = t0
        expectEqual(W.trackChangeInstant(anchorTimestamp: ts, tight: true, arrivedAt: ts.addingTimeInterval(1.425)),
                    ts.addingTimeInterval(0.999))
        expectEqual(W.trackChangeInstant(anchorTimestamp: ts, tight: false, arrivedAt: ts.addingTimeInterval(236.8)),
                    ts.addingTimeInterval(236.8))
        expectEqual(W.trackChangeInstant(anchorTimestamp: nil, tight: true, arrivedAt: ts.addingTimeInterval(3)),
                    ts.addingTimeInterval(3))
    }

    do {
        typealias R = RadioTrackClock
        expectEqual(R.passedTrackEnd(position: 300, durationSecs: nil), false)
        expectEqual(R.passedTrackEnd(position: 300, durationSecs: 0), false)
        expectEqual(R.passedTrackEnd(position: 180, durationSecs: 184.653), false)
        expectEqual(R.passedTrackEnd(position: 184.653 + R.tailGraceSecs, durationSecs: 184.653), false)
        expectEqual(R.passedTrackEnd(position: 184.653 + R.tailGraceSecs + 0.001, durationSecs: 184.653), true)
    }

    do {
        typealias F = RadioClockFile
        let t0 = Date(timeIntervalSince1970: 1_788_000_000)
        func rec(_ key: String, _ pos: Double, _ at: Date, _ playing: Bool) -> RadioClockRecord {
            RadioClockRecord(trackKey: key, position: pos, tickedAtMs: Int64(at.timeIntervalSince1970 * 1000),
                             playing: playing)
        }
        let saved = rec("NCT 127|Step Up", 12.6, t0, true)

        let data = try! F.encode(saved)
        expectEqual(String(data: data, encoding: .utf8),
                    "{\"playing\":true,\"position\":12.6,\"ticked_at_ms\":1788000000000,\"track_key\":\"NCT 127|Step Up\"}")
        expectEqual(F.decode(data), saved)
        expectEqual(F.decode(Data("not json".utf8)), nil)

        expectEqual(F.restorable(nil, trackKey: "NCT 127|Step Up", now: t0.addingTimeInterval(8)), nil)
        expectEqual(F.restorable(saved, trackKey: "NCT 127|Piñata", now: t0.addingTimeInterval(8)), nil)
        expectEqual(F.restorable(rec("NCT 127|Step Up", 12.6, t0, false), trackKey: "NCT 127|Step Up",
                                 now: t0.addingTimeInterval(8)), nil)
        expectEqual(F.restorable(saved, trackKey: "NCT 127|Step Up",
                                 now: t0.addingTimeInterval(F.maxRestoreGap + 1)), nil)
        expectEqual(F.restorable(saved, trackKey: "NCT 127|Step Up", now: t0.addingTimeInterval(-5)), nil)
        let restored = F.restorable(saved, trackKey: "NCT 127|Step Up", now: t0.addingTimeInterval(8))
        expectEqual(restored?.position, 12.6)
        expectEqual(restored?.playing, true)

        let after = RadioTrackClock.advance(restored, trackKey: "NCT 127|Step Up", playing: true,
                                            now: t0.addingTimeInterval(8))
        expectEqual((after.position * 1000).rounded(), 20600)
        let longGap = RadioTrackClock.advance(
            F.restorable(rec("NCT 127|Step Up", 12.6, t0, true), trackKey: "NCT 127|Step Up",
                         now: t0.addingTimeInterval(50)),
            trackKey: "NCT 127|Step Up", playing: true, now: t0.addingTimeInterval(50))
        expectEqual(longGap.position, 12.6 + RadioTrackClock.maxAdvancePerTick)

        expectEqual(F.shouldWrite(previous: nil, next: saved, now: t0), true)
        expectEqual(F.shouldWrite(previous: saved, next: rec("NCT 127|Piñata", 0, t0, true), now: t0), true)
        expectEqual(F.shouldWrite(previous: saved, next: rec("NCT 127|Step Up", 14, t0, false), now: t0), true)
        expectEqual(F.shouldWrite(previous: saved, next: rec("NCT 127|Step Up", 14, t0, true),
                                  now: t0.addingTimeInterval(2)), false)
        expectEqual(F.shouldWrite(previous: saved, next: rec("NCT 127|Step Up", 30, t0, true),
                                  now: t0.addingTimeInterval(F.minWriteInterval)), true)
    }

    do {
        typealias C = RadioStationCardFile
        let hash = "CgkIBRoF0aDTpxkQBA"
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "", artist: "petal radio"),
                    "petal radio")
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "YEONJUN", artist: ""),
                    "YEONJUN")
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "   ", artist: "petal radio"),
                    "petal radio")
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "big feelings", artist: "Ariana Grande"),
                    nil)
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "", artist: ""),
                    nil)
        expectEqual(C.stationName(isRadio: false, stationHash: hash, title: "", artist: "petal radio"),
                    nil)
        expectEqual(C.stationName(isRadio: true, stationHash: nil, title: "", artist: "petal radio"),
                    nil)
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "",
                                  artist: String(repeating: "长", count: C.maxNameLength + 1)),
                    nil)

        let card = RadioStationCard(stationHash: hash, name: "petal radio", artwork: Data([1, 2, 3]))
        expectEqual(C.card(card, forStation: hash)?.name, "petal radio")
        expectEqual(C.card(card, forStation: "别的台"), nil)
        expectEqual(C.card(card, forStation: nil), nil)
        expectEqual(C.card(nil, forStation: hash), nil)
    }

    do {
        typealias M = MediaControlClient
        expectEqual(M.radioProbeNeeded(cachedKey: nil, trackKey: "Clairo|Juna"), true)
        expectEqual(M.radioProbeNeeded(cachedKey: "Clairo|Juna", trackKey: "Clairo|Juna"), false)
        expectEqual(M.radioProbeNeeded(cachedKey: "Clairo|Juna", trackKey: "NCT 127|Step Up"), true)
        expectEqual(M.radioProbeNeeded(cachedKey: "|petal radio", trackKey: "Clairo|Juna"), true)
        expectEqual(M.radioProbeNeeded(cachedKey: "Clairo|Juna", trackKey: ""), true)
    }
}
