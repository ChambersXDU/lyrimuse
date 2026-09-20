import LyrimuseCore
import Foundation

@MainActor
func runLyricsOffsetTests() {

    do {
        let keyA = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:10.00]第一句\n", lyricsYRC: "")
        let keyASame = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:10.00]第一句\n", lyricsYRC: "")
        let keyBDifferentLyrics = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:12.00]第一句(重新匹配的另一份歌词)\n", lyricsYRC: "")
        expectEqual(keyA, keyASame)
        expectEqual(keyA == keyBDifferentLyrics, false)
    }

    do {
        let lrc = "[00:10.00]句\n"
        func key(_ artist: String, _ title: String) -> String {
            LyricsOffsetStore.trackKey(artist: artist, title: title, lyrics: lrc, lyricsYRC: "")
        }

        expectEqual(key("丁世光", "不散的筵席（I Miss You）"), key("丁世光", "不散的筵席"))
        expectEqual(key("Ari Lennox", "Queen Space (with Summer Walker)"), key("Ari Lennox", "Queen Space"))

        expectEqual(key("丁世光", "不散的筵席"), key("丁世光", "不散的筵席"))

        expectEqual(key("宇多田ヒカル", "Automatic (Remastered 2014)") == key("宇多田ヒカル", "Automatic"),
                    false)

        expectEqual(key("Hikaru Utada", "Gold\u{3000}～また逢う日まで～"),
                    key("Hikaru Utada", "Gold ～また逢う日まで～"))
    }

    do {
        let fp = "abc123def456"
        let legacy = "丁世光|不散的筵席（I Miss You）|\(fp)"
        let canonical = "丁世光|不散的筵席|\(fp)"

        let moved = LyricsOffsetStore.migratedOffsetKeys([legacy: 1800])
        expectEqual(moved, [canonical: 1800])

        let untouched = LyricsOffsetStore.migratedOffsetKeys([canonical: 700])
        expectEqual(untouched, [canonical: 700])

        let collided = LyricsOffsetStore.migratedOffsetKeys([legacy: 1800, canonical: 700])
        expectEqual(collided, [canonical: 700])

        let weird = LyricsOffsetStore.migratedOffsetKeys(["没有分隔符": 1, "只有一个|分隔符": 2])
        expectEqual(weird, ["没有分隔符": 1, "只有一个|分隔符": 2])

        let emptyFp = LyricsOffsetStore.migratedOffsetKeys(["丁世光|不散的筵席（I Miss You）|": 300])
        expectEqual(emptyFp, ["丁世光|不散的筵席|": 300])
    }

    MainActor.assumeIsolated {
        let store = LyricsOffsetStore.shared
        let key = LyricsOffsetStore.trackKey(artist: "A", title: "T", lyrics: "[00:01.00]x", lyricsYRC: "")

        store.setGlobalOffset(0)
        store.reset(forKey: key, pinKey: "")
        for id in store.playerOffsets.keys { store.setPlayerOffset(0, forBundleID: id) }
        expectEqual(store.effectiveOffset(forKey: key), 0)

        store.setGlobalOffset(300)
        expectEqual(store.effectiveOffset(forKey: key), 300)

        store.nudge(by: -100, forKey: key, pinKey: "")
        expectEqual(store.offset(forKey: key), -100)
        expectEqual(store.effectiveOffset(forKey: key), 200)

        store.reset(forKey: key, pinKey: "")
        expectEqual(store.offset(forKey: key), 0)
        expectEqual(store.globalOffsetMs, 300)
        expectEqual(store.effectiveOffset(forKey: key), 300)

        store.setOffset(-250, forKey: key, pinKey: "")
        store.setGlobalOffset(-50)
        expectEqual(store.offset(forKey: key), -250)
        expectEqual(store.effectiveOffset(forKey: key), -300)

        store.setGlobalOffset(120)
        store.nudge(by: 500, forKey: "||", pinKey: "")
        expectEqual(store.offset(forKey: "||"), 0)
        expectEqual(store.effectiveOffset(forKey: "||"), 120)

        store.setGlobalOffset(0)
        store.reset(forKey: key, pinKey: "")
        for id in store.playerOffsets.keys { store.setPlayerOffset(0, forBundleID: id) }
    }

    MainActor.assumeIsolated {

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-selftest-pins-\(ProcessInfo.processInfo.processIdentifier).json")
        LyricsPinStore.redirectForTesting(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = LyricsOffsetStore.shared
        let pins = LyricsPinStore.shared
        let pinKey = "已校准测试歌手|已校准测试歌名|已校准测试专辑"
        let keyA = LyricsOffsetStore.trackKey(
            artist: "已校准测试歌手", title: "已校准测试歌名", lyrics: "[00:01.00]甲", lyricsYRC: "")
        let keyB = LyricsOffsetStore.trackKey(
            artist: "已校准测试歌手", title: "已校准测试歌名", lyrics: "[00:02.00]乙", lyricsYRC: "")
        expectEqual(keyA == keyB, false)
        expectEqual(pins.isPinned(pinKey), false)

        store.nudge(by: 300, forKey: keyA, pinKey: pinKey)
        expectEqual(pins.isPinned(pinKey), true)

        expectEqual(store.offset(forKey: keyB), 0)
        expectEqual(pins.isPinned(pinKey), true)

        store.reset(forKey: keyA, pinKey: pinKey)
        expectEqual(pins.isPinned(pinKey), false)

        store.nudge(by: 100, forKey: keyA, pinKey: "")
        expectEqual(pins.count, 0)

        expectEqual(store.offset(forKey: keyA), 100)
        store.syncPinToOffset(forKey: keyA, pinKey: pinKey)
        expectEqual(pins.isPinned(pinKey), true)

        store.reset(forKey: keyA, pinKey: pinKey)
        store.syncPinToOffset(forKey: keyA, pinKey: pinKey)
        expectEqual(pins.count, 0)

        pins.setPinned(true, forKey: pinKey)
        expectEqual(store.offset(forKey: keyA), 0)
        expectEqual(pins.isPinned(pinKey), true)
        store.syncPinToOffset(forKey: keyA, pinKey: pinKey)
        expectEqual(pins.isPinned(pinKey), false)

        store.setGlobalOffset(700)
        store.setPlayerOffset(-300, forBundleID: "company.thebrowser.Browser")
        store.setOffset(-900, forKey: keyA, pinKey: pinKey)
        expectEqual(store.trackOffsetCount, 1)
        expectEqual(pins.isPinned(pinKey), true)

        let onDisk = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        expectEqual(onDisk.contains("\"version\""), true)
        expectEqual(onDisk.contains("\"pins\""), true)
        expectEqual(onDisk.contains(pinKey), true)

        store.clearAllTrackOffsets()
        expectEqual(store.offset(forKey: keyA), 0)
        expectEqual(store.trackOffsetCount, 0)
        expectEqual(pins.count, 0)
        expectEqual(store.globalOffsetMs, 700)
        expectEqual(store.playerOffset(forBundleID: "company.thebrowser.Browser"), -300)

        store.setGlobalOffset(0)
        for id in store.playerOffsets.keys { store.setPlayerOffset(0, forBundleID: id) }
    }

}
