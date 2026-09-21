import LyrimuseCore

private func testPlainTimeline() {
    let engine = LyricsSyncEngine()
    let loaded = engine.load(
        lyrics: """
        [00:01.00]first
        [00:05.00]second
        [00:09.00]last
        """,
        lyricsTr: "",
        lyricsRoma: "",
        lyricsYRC: ""
    )
    expectEqual(loaded, true, "首次加载普通 LRC")

    let first = engine.tickQuery(atMs: 1500)
    expectEqual(
        first.index,
        0
    )
    expectEqual(
        first.line?.plainText,
        "first"
    )
    expectEqual(
        first.nextText,
        "second"
    )
    expectEqual(
        engine.activeLine(atMs: 4999)?.plainText,
        "first"
    )

    let second = engine.tickQuery(atMs: 5000)
    expectEqual(second.index, 1, "跨过时间点后进入下一行")
    expectEqual(
        second.line?.plainText,
        "second"
    )
    expectEqual(
        second.nextText,
        "last"
    )
    expectEqual(
        engine.activeLine(atMs: 9000)?.plainText,
        "last"
    )
    expectEqual(
        engine.activeLine(atMs: 20_000)?.plainText,
        "last",
        "最后一行持续到歌曲结束"
    )
    expectEqual(
        engine.activeLine(atMs: 500)?.plainText,
        nil
    )
    expectEqual(
        engine.upcomingLineText(afterMs: 500),
        "first"
    )
}

private func testSeekingUsesTheNewPosition() {
    let engine = LyricsSyncEngine()
    engine.load(
        lyrics: """
        [00:01.00]first
        [00:05.00]second
        [00:09.00]last
        """,
        lyricsTr: "",
        lyricsRoma: "",
        lyricsYRC: ""
    )

    expectEqual(
        engine.tickQuery(atMs: 7000).line?.plainText,
        "second"
    )
    expectEqual(
        engine.tickQuery(atMs: 1000).line?.plainText,
        "first",
        "seek 回前一行"
    )
    expectEqual(
        engine.tickQuery(atMs: 9000).line?.plainText,
        "last",
        "seek 跳到最后一行"
    )
    expectEqual(engine.activeLineIndex(atMs: 9000), 2)
}

private func testOffsetsChangeDisplayedLine() {
    let engine = LyricsSyncEngine()
    engine.load(
        lyrics: """
        [offset:500]
        [00:10.00]a
        [00:20.00]b
        """,
        lyricsTr: "",
        lyricsRoma: "",
        lyricsYRC: ""
    )

    expectEqual(engine.effectiveOffsetMs, 500)
    engine.offsetMs = 1000
    expectEqual(engine.effectiveOffsetMs, 1500)
    expectEqual(
        engine.activeLine(atMs: 8500)?.plainText,
        "a",
        "LRC offset 与单曲 offset 叠加"
    )
    expectEqual(
        engine.activeLine(atMs: 18_500)?.plainText,
        "b"
    )
}

private func testWordTiming() {
    let engine = LyricsSyncEngine()
    let loaded = engine.load(
        lyrics: "",
        lyricsTr: "",
        lyricsRoma: "",
        lyricsYRC: """
        [1000,2000](1000,1000,0)one (2000,1000,0)two
        [5000,1000](5000,500,0)next
        """
    )
    expectEqual(loaded, true)

    let wordTick = engine.tickQuery(atMs: 1500)
    expectEqual(
        wordTick.index,
        0
    )
    expectEqual(
        wordTick.line?.plainText,
        "one two"
    )
    expectEqual(
        wordTick.line?.words?.map(\.text),
        ["one ", "two"]
    )
    expectEqual(
        wordTick.line?.words?.map(\.startMs),
        [1000, 2000]
    )
    expectEqual(
        wordTick.line?.words?.first?.durationMs,
        1000
    )
    expectEqual(
        engine.activeLine(atMs: 4999)?.plainText,
        "one two"
    )
    expectEqual(
        engine.activeLine(atMs: 5000)?.plainText,
        "next"
    )
    expectEqual(
        engine.activeLine(atMs: 20_000)?.plainText,
        "next"
    )
    expectEqual(
        engine.upcomingLineText(afterMs: 20_000),
        nil
    )
    expectEqual(
        engine.activeLineIndex(atMs: 20_000),
        1
    )
}

private func testReloadReplacesTheDisplayedSong() {
    let engine = LyricsSyncEngine()
    engine.load(
        lyrics: "[00:10.00]old song",
        lyricsTr: "",
        lyricsRoma: "",
        lyricsYRC: ""
    )
    expectEqual(
        engine.activeLine(atMs: 12_000)?.plainText,
        "old song"
    )

    engine.load(
        lyrics: "[00:02.00]new song",
        lyricsTr: "",
        lyricsRoma: "",
        lyricsYRC: ""
    )
    expectEqual(engine.activeLine(atMs: 12_000)?.plainText, "new song", "换歌后不显示旧时间轴")
    expectEqual(
        engine.activeLine(atMs: 1000)?.plainText,
        nil
    )
}

private func testOneDuetTimeline() {
    let engine = LyricsSyncEngine()
    engine.load(
        lyrics: """
        [00:01.00]男：
        [00:02.00]All night
        [00:03.00]女：
        [00:04.00]U got to dance all night
        [00:05.00]男：
        [00:06.00]All night yeah
        """,
        lyricsTr: "",
        lyricsRoma: "",
        lyricsYRC: ""
    )

    let duetTick = engine.tickQuery(atMs: 2500)
    expectEqual(
        duetTick.line?.plainText,
        "All night"
    )
    expectEqual(
        duetTick.line?.side,
        .leading
    )
    expectEqual(
        duetTick.nextText,
        "U got to dance all night"
    )
    expectEqual(
        duetTick.nextSide,
        .trailing
    )
    expectEqual(
        engine.activeLine(atMs: 6500)?.plainText,
        "All night yeah"
    )
    expectEqual(
        engine.activeLine(atMs: 6500)?.side,
        .leading
    )
}

func runSyncEngineTests() {
    testPlainTimeline()
    testSeekingUsesTheNewPosition()
    testOffsetsChangeDisplayedLine()
    testWordTiming()
    testReloadReplacesTheDisplayedSong()
    testOneDuetTimeline()
}
