import Foundation
import LyrimuseCore

@MainActor
func runRomanizationTests() {
    expectEqual(Romanizer.romanize(""), nil)
    expectEqual(Romanizer.romanize("hello"), nil)
    expectEqual(Romanizer.looksJapanese("こんにちは"), true)
    expectEqual(Romanizer.containsHan("你好"), true)
    expectEqual(RomanizationScripts.default.contains(.japanese), true)
    expectEqual(RomanizationScripts.default.contains(.korean), true)

    let engine = LyricsSyncEngine()
    engine.load(lyrics: "[00:10.00]こんにちは", lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
    expectEqual(engine.activeLine(atMs: 10_000)?.romanization != nil, true)

    let chinese = LyricsSyncEngine()
    chinese.load(lyrics: "[00:10.00]你好", lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
    expectEqual(chinese.activeLine(atMs: 10_000)?.romanization, nil)
}
