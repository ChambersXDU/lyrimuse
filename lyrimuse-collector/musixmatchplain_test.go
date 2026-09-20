package main

import "testing"

func TestSanitizeMusixmatchPlainLyricsKeepsCleanBody(t *testing.T) {

	clean := "\"I hear there's a storm warning\nMy baby blowin' back into town\n\nShe's got long wavy hair\nThunder in her hips\""
	if got := sanitizeMusixmatchPlainLyrics(clean); got != clean {
		t.Errorf("干净正文被改动了:\n原=%q\n后=%q", clean, got)
	}
}

func TestSanitizeMusixmatchPlainLyricsStripsNotice(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{

			"星号围栏及其之后整段丢掉",
			"Line one\nLine two\n\n*******\nThis Lyrics is NOT for Commercial use\n*******\n(1409618012345)",
			"Line one\nLine two",
		},
		{
			"没有围栏、只有免责声明那句",
			"Line one\nthis lyrics is not for commercial use",
			"Line one",
		},
		{
			"围栏缺失、只剩尾部追踪号",
			"Line one\nLine two\n(1409618012345)",
			"Line one\nLine two",
		},
		{"尾部空行一并裁掉", "Line one\n\n\n", "Line one"},
		{"CRLF 换行要能处理", "Line one\r\nLine two\r\n*******\r\nfoo", "Line one\nLine two"},
		{"全是水印 → 空", "*******\nThis Lyrics is NOT for Commercial use\n*******", ""},
		{"空输入", "", ""},
	}
	for _, c := range cases {
		if got := sanitizeMusixmatchPlainLyrics(c.in); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestMusixmatchNoticeDetectionDoesNotOverreach(t *testing.T) {
	notNotice := []string{
		"(2)",
		"(chorus)",
		"(12345)",
		"*",
		"**",
		"*emphasis*",
		"She's got (2) hearts",
	}
	for _, ln := range notNotice {
		if musixmatchNoticeLine(ln) {
			t.Errorf("%q 不该被当成水印起点", ln)
		}
		if musixmatchTrackingNumberLine(ln) {
			t.Errorf("%q 不该被当成追踪号", ln)
		}
	}

	for _, ln := range []string{"***", "*******", "  ****  ", "This Lyrics is NOT for Commercial use"} {
		if !musixmatchNoticeLine(ln) {
			t.Errorf("%q 应该被认成水印起点", ln)
		}
	}
	for _, ln := range []string{"(1409618012345)", "(123456)"} {
		if !musixmatchTrackingNumberLine(ln) {
			t.Errorf("%q 应该被认成追踪号", ln)
		}
	}

	body := "Line one\nShe counts (1234567) stars"
	if got := sanitizeMusixmatchPlainLyrics(body); got != body {
		t.Errorf("行内括号数字不该被裁:\n原=%q\n后=%q", body, got)
	}
}

func TestPickMusixmatchTrackRow(t *testing.T) {
	const artist, title = "Charlie Musselwhite", "Storm Warning"

	rows := []musixmatchTrackRow{
		{TrackID: 322223735, TrackName: "Storm Warning", ArtistName: "Charlie Musselwhite",
			AlbumName: "Look Out Highway", HasSubtitles: 0, HasLyrics: 1, TrackLength: 245},
		{TrackID: 999, TrackName: "Storm Warning", ArtistName: "Dynatones (featuring Charlie Musselwhite)",
			AlbumName: "Curtain Call", HasSubtitles: 0, HasLyrics: 0, TrackLength: 422},
	}
	got, ok := pickMusixmatchTrackRow(rows, artist, title)
	if !ok {
		t.Fatal("有词无时间轴的曲目必须能被挑出来(放宽前就是死在这一步)")
	}
	if got.trackID != 322223735 {
		t.Errorf("挑错了条目:trackID=%d", got.trackID)
	}
	if got.hasSubtitles {
		t.Error("这条没有时间轴,hasSubtitles 应为 false(调用方据此跳过 subtitle 请求)")
	}
	if got.durationSecs != 245 {
		t.Errorf("时长应透传:%v", got.durationSecs)
	}

	mixed := []musixmatchTrackRow{
		{TrackID: 1, TrackName: "Storm Warning", ArtistName: artist, HasSubtitles: 0, HasLyrics: 1},
		{TrackID: 2, TrackName: "Storm Warning", ArtistName: artist, HasSubtitles: 1, HasLyrics: 1},
	}
	got, ok = pickMusixmatchTrackRow(mixed, artist, title)
	if !ok || got.trackID != 2 || !got.hasSubtitles {
		t.Errorf("有时间轴的必须优先,得到 ok=%v id=%d hasSubtitles=%v", ok, got.trackID, got.hasSubtitles)
	}

	wrongArtist := []musixmatchTrackRow{
		{TrackID: 3, TrackName: "Storm Warning", ArtistName: "Michael Burks", HasSubtitles: 0, HasLyrics: 1},
	}
	if _, ok := pickMusixmatchTrackRow(wrongArtist, artist, title); ok {
		t.Error("歌手对不上的候选不该被采纳")
	}

	neither := []musixmatchTrackRow{
		{TrackID: 4, TrackName: "Storm Warning", ArtistName: artist, HasSubtitles: 0, HasLyrics: 0},
	}
	if _, ok := pickMusixmatchTrackRow(neither, artist, title); ok {
		t.Error("既无时间轴也无词、又没有纯音乐标记的候选不该被采纳")
	}

	if _, ok := pickMusixmatchTrackRow(nil, artist, title); ok {
		t.Error("空结果不该返回命中")
	}
}

func TestPickMusixmatchTrackRowInstrumentalPass(t *testing.T) {
	const artist, title = "Explosions In The Sky", "Your Hand In Mine"

	rows := []musixmatchTrackRow{
		{TrackID: 11, TrackName: title, ArtistName: artist,
			HasSubtitles: 0, HasLyrics: 0, Instrumental: 1, TrackLength: 497},
	}
	got, ok := pickMusixmatchTrackRow(rows, artist, title)
	if !ok {
		t.Fatal("源明确标了 instrumental 的行必须能被第三趟认下来")
	}
	if !got.instrumental {
		t.Error("第三趟认下来的必须置 instrumental —— 调用方据此直接返回、不再发任何请求")
	}
	if got.hasSubtitles || got.hasRichsync {
		t.Error("纯音乐行不该带 hasSubtitles / hasRichsync")
	}
	if got.durationSecs != 497 {
		t.Errorf("时长仍要透传:%v", got.durationSecs)
	}

	mixed := []musixmatchTrackRow{
		{TrackID: 21, TrackName: title, ArtistName: artist, HasSubtitles: 0, HasLyrics: 0, Instrumental: 1},
		{TrackID: 22, TrackName: title, ArtistName: artist, HasSubtitles: 1, HasLyrics: 1, Instrumental: 0},
	}
	got, ok = pickMusixmatchTrackRow(mixed, artist, title)
	if !ok || got.trackID != 22 {
		t.Fatalf("有正文的行必须压过纯音乐标记,得到 ok=%v id=%d", ok, got.trackID)
	}
	if got.instrumental {
		t.Error("被前两趟认下来的行不该置 instrumental —— 那会把一份真歌词报成纯音乐")
	}

	wrongArtist := []musixmatchTrackRow{
		{TrackID: 31, TrackName: title, ArtistName: "Sigur Rós", HasSubtitles: 0, HasLyrics: 0, Instrumental: 1},
	}
	if _, ok := pickMusixmatchTrackRow(wrongArtist, artist, title); ok {
		t.Error("第三趟不能绕过身份闸")
	}
}

func TestPickMusixmatchTrackRowCarriesHasRichsync(t *testing.T) {
	const artist, title = "Mayday", "倔強"

	withRich := []musixmatchTrackRow{
		{TrackID: 41, TrackName: title, ArtistName: artist, HasSubtitles: 1, HasLyrics: 1, HasRichsync: 1},
	}
	if got, ok := pickMusixmatchTrackRow(withRich, artist, title); !ok || !got.hasRichsync {
		t.Errorf("has_richsync=1 要带出来,得到 ok=%v hasRichsync=%v", ok, got.hasRichsync)
	}

	noRich := []musixmatchTrackRow{
		{TrackID: 42, TrackName: title, ArtistName: artist, HasSubtitles: 1, HasLyrics: 1, HasRichsync: 0},
	}
	got, ok := pickMusixmatchTrackRow(noRich, artist, title)
	if !ok || !got.hasSubtitles {
		t.Fatalf("这一档仍要走主路径,得到 ok=%v hasSubtitles=%v", ok, got.hasSubtitles)
	}
	if got.hasRichsync {
		t.Error("has_richsync=0 时不能置 hasRichsync,否则那道闸白加")
	}
}
