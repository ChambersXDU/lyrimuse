package main

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestYtmusicParseDurationText(t *testing.T) {
	cases := map[string]float64{
		"3:21":    201,
		"0:45":    45,
		"1:02:03": 3723,
		"":        0,
		"abc":     0,
		"3":       0,
		"-1:00":   0,
	}
	for in, want := range cases {
		if got := ytmusicParseDurationText(in); got != want {
			t.Errorf("ytmusicParseDurationText(%q) = %v, want %v", in, got, want)
		}
	}
}

func ytmusicSearchItemJSON(title, meta, videoID, musicVideoType string) string {
	return `{"musicResponsiveListItemRenderer":{` +
		`"flexColumns":[` +
		`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"` + title + `"}]}}},` +
		`{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"` + meta + `"}]}}}` +
		`],` +
		`"thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[` +
		`{"url":"https://example.com/60.jpg","width":60},` +
		`{"url":"https://example.com/120.jpg","width":120}` +
		`]}}},` +
		`"overlay":{"musicItemThumbnailOverlayRenderer":{"content":{"musicPlayButtonRenderer":{` +
		`"playNavigationEndpoint":{"watchEndpoint":{` +
		`"videoId":"` + videoID + `",` +
		`"watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"` + musicVideoType + `"}}` +
		`}}}}}}` +
		`}}`
}

func TestYtmusicParseSearchItem(t *testing.T) {
	raw := ytmusicSearchItemJSON("Anti-Hero", "Taylor Swift • Midnights • 3:21", "3YgtjHZyCIQ", "MUSIC_VIDEO_TYPE_ATV")
	var item ytmusicSearchItem
	if err := json.Unmarshal([]byte(raw), &item); err != nil {
		t.Fatalf("解析测试用例本身失败: %v", err)
	}
	p, ok := ytmusicParseSearchItem(item)
	if !ok {
		t.Fatal("应该解析成功")
	}
	if p.videoID != "3YgtjHZyCIQ" || p.title != "Anti-Hero" || p.artist != "Taylor Swift" ||
		p.album != "Midnights" || p.durationSecs != 201 || !p.isATV {
		t.Errorf("字段解析不对: %+v", p)
	}
	if p.cover == "" {
		t.Error("应该拿到封面 URL")
	}

	raw2 := ytmusicSearchItemJSON("彩虹+軌跡", "周杰倫 • 魔天倫世界巡迴演唱會 • 3:18", "x", "MUSIC_VIDEO_TYPE_ATV")
	var item2 ytmusicSearchItem
	if err := json.Unmarshal([]byte(raw2), &item2); err != nil {
		t.Fatalf("解析测试用例本身失败: %v", err)
	}
	p2, ok := ytmusicParseSearchItem(item2)
	if !ok || p2.album != "魔天倫世界巡迴演唱會" || p2.artist != "周杰倫" {
		t.Errorf("中日文/长专辑名解析不对: %+v ok=%v", p2, ok)
	}

	raw3 := ytmusicSearchItemJSON("Foo", "Bar • Baz • 3:00", "", "MUSIC_VIDEO_TYPE_ATV")
	var item3 ytmusicSearchItem
	_ = json.Unmarshal([]byte(raw3), &item3)
	if _, ok := ytmusicParseSearchItem(item3); ok {
		t.Error("缺 videoId 的条目不该被接受")
	}
}

func TestYtmusicPickSearchItem(t *testing.T) {
	atv := func(title, artist, album string, dur float64) ytmusicParsedSearchItem {
		return ytmusicParsedSearchItem{videoID: "v", title: title, artist: artist, album: album, durationSecs: dur, isATV: true}
	}

	items := []ytmusicParsedSearchItem{
		atv("Anti-Hero", "Someone Else", "Midnights", 201),
		atv("A Completely Different Song", "Taylor Swift", "Midnights", 201),
	}
	if _, ok := ytmusicPickSearchItem(items, "Taylor Swift", "Anti-Hero", "Midnights", 201); ok {
		t.Error("曲名/歌手都对不上,不该选出任何候选")
	}

	items = []ytmusicParsedSearchItem{atv("Anti-Hero", "Taylor Swift", "Midnights", 201)}
	if _, ok := ytmusicPickSearchItem(items, "Taylor Swift", "Anti-Hero (Live)", "", 201); ok {
		t.Error("版本限定词相反的候选不该被采纳")
	}

	nonATV := atv("Anti-Hero", "Taylor Swift", "Midnights", 201)
	nonATV.isATV = false
	realATV := ytmusicParsedSearchItem{videoID: "v2", title: "Anti-Hero", artist: "Taylor Swift", album: "Midnights", durationSecs: 205, isATV: true}
	got, ok := ytmusicPickSearchItem([]ytmusicParsedSearchItem{nonATV, realATV}, "Taylor Swift", "Anti-Hero", "", 201)
	if !ok || got.videoID != "v2" {
		t.Errorf("应该优先选 ATV(真录音室曲目),实际 %+v", got)
	}

	multi := []ytmusicParsedSearchItem{
		atv("Anti-Hero", "Taylor Swift", "", 270),
		atv("Anti-Hero", "Taylor Swift", "", 202),
		atv("Anti-Hero", "Taylor Swift", "", 150),
	}
	got, ok = ytmusicPickSearchItem(multi, "Taylor Swift", "Anti-Hero", "", 201)
	if !ok || got.durationSecs != 202 {
		t.Errorf("应该挑最接近 201s 的 202s,实际 %+v", got)
	}

	got, ok = ytmusicPickSearchItem(multi, "Taylor Swift", "Anti-Hero", "", 0)
	if !ok || got.durationSecs != 270 {
		t.Errorf("时长未知时应退回第一个过门的候选,实际 %+v", got)
	}
}

func TestYtmusicExtractSearchItems(t *testing.T) {

	raw := `{"someWeirdContainer":{"nested":[` +
		ytmusicSearchItemJSON("Song A", "Artist A • Album A • 3:00", "vidA", "MUSIC_VIDEO_TYPE_ATV") + `,` +
		ytmusicSearchItemJSON("Song B", "Artist B • Album B • 4:00", "vidB", "MUSIC_VIDEO_TYPE_ATV") +
		`]}}`
	items := ytmusicExtractSearchItems([]byte(raw))
	if len(items) != 2 {
		t.Fatalf("应该找到 2 条候选,实际 %d", len(items))
	}
}

func TestYtmusicLyricsBrowseID(t *testing.T) {

	raw := `{
		"contents": {"singleColumnMusicWatchNextResultsRenderer": {"tabbedRenderer": {
			"watchNextTabbedResultsRenderer": {"tabs": [
				{"tabRenderer": {"title": "Up next"}},
				{"tabRenderer": {"endpoint": {"browseEndpoint": {
					"browseId": "MPLYt_MOJF3UvLsif-3",
					"browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig": {
						"pageType": "MUSIC_PAGE_TYPE_TRACK_LYRICS"
					}}
				}}}},
				{"tabRenderer": {"title": "Comments"}},
				{"tabRenderer": {"endpoint": {"browseEndpoint": {
					"browseId": "MPTRt_MOJF3UvLsif-3",
					"browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig": {
						"pageType": "MUSIC_PAGE_TYPE_TRACK_RELATED"
					}}
				}}}}
			]}
		}}}
	}`
	if got := ytmusicLyricsBrowseID([]byte(raw)); got != "MPLYt_MOJF3UvLsif-3" {
		t.Errorf("应该挑中歌词 tab 的 browseId,实际 %q", got)
	}

	noLyrics := `{"contents": {"singleColumnMusicWatchNextResultsRenderer": {"tabbedRenderer": {
		"watchNextTabbedResultsRenderer": {"tabs": [{"tabRenderer": {"title": "Up next"}}]}
	}}}}`
	if got := ytmusicLyricsBrowseID([]byte(noLyrics)); got != "" {
		t.Errorf("没有歌词 tab 应该返回空串,实际 %q", got)
	}
}

func TestYtmusicIsLyricFindSource(t *testing.T) {
	cases := map[string]bool{
		"Source: LyricFind":   true,
		"Source: Musixmatch":  false,
		"":                    false,
		"source: lyricfind":   true,
		"LyricFind":           true,
		"Some Other Provider": false,
	}
	for in, want := range cases {
		if got := ytmusicIsLyricFindSource(in); got != want {
			t.Errorf("ytmusicIsLyricFindSource(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestYtmusicParseTimedLyrics(t *testing.T) {

	raw := `{"contents": {"elementRenderer": {"newElement": {"type": {"componentType": {"model": {
		"timedLyricsModel": {"lyricsData": {
			"sourceMessage": "Source: LyricFind",
			"timedLyricsData": [
				{"lyricLine": "♪", "cueRange": {"startTimeMilliseconds": "0", "endTimeMilliseconds": "5370", "metadata": {"id": "0"}}},
				{"lyricLine": "I have this thing", "cueRange": {"startTimeMilliseconds": "5370", "endTimeMilliseconds": "10310", "metadata": {"id": "1"}}}
			]
		}}
	}}}}}}}`
	lines, source := ytmusicParseTimedLyrics([]byte(raw))
	if source != "Source: LyricFind" {
		t.Errorf("来源标注不对: %q", source)
	}
	if len(lines) != 2 || lines[0].text != "♪" || lines[0].startMs != 0 || lines[0].endMs != 5370 ||
		lines[1].text != "I have this thing" || lines[1].startMs != 5370 {
		t.Errorf("逐行歌词解析不对: %+v", lines)
	}

	notAvailable := `{"contents": {"messageRenderer": {"text": {"runs": [{"text": "Lyrics not available"}]}}}}`
	lines, source = ytmusicParseTimedLyrics([]byte(notAvailable))
	if len(lines) != 0 || source != "" {
		t.Errorf("歌词不可用时应该返回空,实际 lines=%v source=%q", lines, source)
	}

	dirty := `{"timedLyricsData": [
		{"lyricLine": "bad", "cueRange": {"startTimeMilliseconds": "100", "endTimeMilliseconds": "50", "metadata": {"id": "0"}}},
		{"lyricLine": "good", "cueRange": {"startTimeMilliseconds": "100", "endTimeMilliseconds": "200", "metadata": {"id": "1"}}}
	], "sourceMessage": "Source: Musixmatch"}`
	lines, _ = ytmusicParseTimedLyrics([]byte(dirty))
	if len(lines) != 1 || lines[0].text != "good" {
		t.Errorf("时间戳倒退的行应该被跳过,实际 %+v", lines)
	}
}

func TestYtmusicBuildLRC(t *testing.T) {
	lines := []ytmusicLyricLine{
		{text: "♪", startMs: 0, endMs: 5370},
		{text: "I have this thing", startMs: 5370, endMs: 10310},
	}
	lrc := ytmusicBuildLRC(lines)
	want := "[00:00.00]♪\n[00:05.37]I have this thing\n"
	if lrc != want {
		t.Errorf("拼出的 LRC 不对:\n实际 %q\n期望 %q", lrc, want)
	}

	longer := ytmusicBuildLRC([]ytmusicLyricLine{
		{text: "♪", startMs: 0, endMs: 5370},
		{text: "I have this thing", startMs: 5370, endMs: 10310},
		{text: "where I get older", startMs: 10310, endMs: 15120},
	})
	if !isTimedLRC(longer) {
		t.Error("拼出的 LRC 应该能通过 isTimedLRC")
	}
}

func TestYtmusicExtractVisitorID(t *testing.T) {

	html := `<html><script>ytcfg.set({"VISITOR_DATA":"abc123==","INNERTUBE_CONTEXT":{}});</script></html>`
	if got := ytmusicExtractVisitorID(html); got != "abc123==" {
		t.Errorf("应该抠出 abc123==,实际 %q", got)
	}
	if got := ytmusicExtractVisitorID("<html>没有 ytcfg</html>"); got != "" {
		t.Errorf("没有 ytcfg.set 时应该返回空串,实际 %q", got)
	}
	if got := ytmusicExtractVisitorID(`ytcfg.set({"OTHER_FIELD":1});`); got != "" {
		t.Errorf("有 ytcfg.set 但没有 VISITOR_DATA 字段时应该返回空串,实际 %q", got)
	}
}

func TestYtmusicEnsureVisitorIDSingleFlight(t *testing.T) {
	ytmusicVisitorMu.Lock()
	ytmusicVisitorID = ""
	ytmusicVisitorMu.Unlock()

	orig := ytmusicDoFetchVisitorID
	defer func() { ytmusicDoFetchVisitorID = orig }()

	var calls int32
	ytmusicDoFetchVisitorID = func(ctx context.Context) string {
		atomic.AddInt32(&calls, 1)
		time.Sleep(30 * time.Millisecond)
		return "visitor-A"
	}

	const n = 16
	var wg sync.WaitGroup
	results := make([]string, n)
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer wg.Done()
			results[i] = ytmusicEnsureVisitorID(context.Background())
		}(i)
	}
	wg.Wait()

	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("单飞失效: %d 个并发调用触发了 %d 次真实抓取(应为 1)", n, got)
	}
	for i, r := range results {
		if r != "visitor-A" {
			t.Errorf("goroutine %d 拿到的 visitor id 不对: 实际 %q", i, r)
		}
	}
}

func TestYtmusicEnsureVisitorIDSkipsFetchWhenCached(t *testing.T) {
	ytmusicVisitorMu.Lock()
	ytmusicVisitorID = "already-have-one"
	ytmusicVisitorMu.Unlock()

	orig := ytmusicDoFetchVisitorID
	defer func() { ytmusicDoFetchVisitorID = orig }()
	ytmusicDoFetchVisitorID = func(ctx context.Context) string {
		t.Error("已经有值了,不该去真的抓")
		return "should-not-happen"
	}

	if got := ytmusicEnsureVisitorID(context.Background()); got != "already-have-one" {
		t.Errorf("应该直接返回缓存值,实际 %q", got)
	}
}

func TestYtmusicEnsureVisitorIDRetriesAfterFailure(t *testing.T) {
	ytmusicVisitorMu.Lock()
	ytmusicVisitorID = ""
	ytmusicVisitorMu.Unlock()

	orig := ytmusicDoFetchVisitorID
	defer func() { ytmusicDoFetchVisitorID = orig }()
	var calls int32
	ytmusicDoFetchVisitorID = func(ctx context.Context) string {
		n := atomic.AddInt32(&calls, 1)
		if n == 1 {
			return ""
		}
		return "visitor-B"
	}

	if got := ytmusicEnsureVisitorID(context.Background()); got != "" {
		t.Fatalf("第一次应该失败返回空串,实际 %q", got)
	}
	if got := ytmusicEnsureVisitorID(context.Background()); got != "visitor-B" {
		t.Fatalf("第二次应该重试成功,实际 %q", got)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Fatalf("应该真的抓了两次,实际 %d", got)
	}
}

func TestYtmusicWebClientVersionFormat(t *testing.T) {
	v := ytmusicWebClientVersion()

	if !strings.HasPrefix(v, "1.") || !strings.HasSuffix(v, ".01.00") || len(v) != len("1.20260825.01.00") {
		t.Errorf("客户端版本号格式不对: %q", v)
	}
}
