package main

import (
	"encoding/base64"
	"encoding/json"
	"testing"
)

func deezerTrackFromJSON(t *testing.T, raw string) deezerTrack {
	t.Helper()
	var tr deezerTrack
	if err := json.Unmarshal([]byte(raw), &tr); err != nil {
		t.Fatalf("解析测试用的搜索结果失败: %v", err)
	}
	return tr
}

func TestDeezerBuildLRC(t *testing.T) {
	raw := `[
		{"lrcTimestamp":"[00:00.00]","line":"200 sur le compteur"},
		{"lrcTimestamp":"[00:01.41]","line":""},
		{"lrcTimestamp":"","line":"没有时间戳的行"},
		{"lrcTimestamp":"[00:02.99]","line":"  Est-ce que ça nous fait peur  "}
	]`
	var lines []deezerSyncLine
	if err := json.Unmarshal([]byte(raw), &lines); err != nil {
		t.Fatalf("解析 synchronizedLines 失败: %v", err)
	}
	want := "[00:00.00]200 sur le compteur\n[00:02.99]Est-ce que ça nous fait peur\n"
	if got := deezerBuildLRC(lines); got != want {
		t.Fatalf("拼出来的 LRC 不对:\n got=%q\nwant=%q", got, want)
	}

	if got := deezerBuildLRC([]deezerSyncLine{{LRCTimestamp: "[00:01.00]", Line: "   "}}); got != "" {
		t.Fatalf("全是空正文时应当返回空串,得到 %q", got)
	}
}

func TestDeezerCandidateScore(t *testing.T) {
	original := deezerTrackFromJSON(t, `{"id":3877025581,"title":"Crash","duration":165,
		"artist":{"name":"Joseph Kamel"},"album":{"title":"Crash"}}`)
	if got := deezerCandidateScore(original, "Joseph Kamel", "Crash", "Crash - Single", 164); got < 0 {
		t.Fatalf("原版应当通过,得到 %d", got)
	}

	if got := deezerCandidateScore(original, "Joseph Kamel", "Crash", "Crash - Single", 164); got < 140 {
		t.Fatalf("时长几乎相等时应当拿到高额时长加分,得到 %d", got)
	}

	if got := deezerCandidateScore(original, "Joseph Kamel", "Crash", "Crash - Single", 0); got != 100 {
		t.Fatalf("本地时长未知时应当只有基础分 100,得到 %d", got)
	}

	if got := deezerCandidateScore(original, "Joseph Kamel", "Crash", "Crash - Single", 88); got >= 0 {
		t.Fatalf("时长差超出容差应当淘汰,得到 %d", got)
	}

	other := deezerTrackFromJSON(t, `{"id":1,"title":"Crash","duration":165,
		"artist":{"name":"Charli xcx"},"album":{"title":"CRASH"}}`)
	if got := deezerCandidateScore(other, "Joseph Kamel", "Crash", "Crash - Single", 164); got >= 0 {
		t.Fatalf("歌手对不上应当淘汰,得到 %d", got)
	}

	live := deezerTrackFromJSON(t, `{"id":2,"title":"Crash (Live)","duration":165,
		"artist":{"name":"Joseph Kamel"},"album":{"title":"Crash"}}`)
	if got := deezerCandidateScore(live, "Joseph Kamel", "Crash", "Crash - Single", 164); got >= 0 {
		t.Fatalf("版本限定词对不上应当淘汰,得到 %d", got)
	}

	acoustique := deezerTrackFromJSON(t, `{"id":4074630991,"title":"Crash (Version acoustique)","duration":165,
		"artist":{"name":"Joseph Kamel"},"album":{"title":"Crash"}}`)
	if got := deezerCandidateScore(acoustique, "Joseph Kamel", "Crash", "Crash - Single", 164); got < 0 {
		t.Fatalf("现状是认不出法语版本词、照常通过;这条一旦变红说明词表补了法语,把这段注释一起更新: %d", got)
	}

	noID := deezerTrackFromJSON(t, `{"title":"Crash","duration":165,"artist":{"name":"Joseph Kamel"},"album":{"title":"Crash"}}`)
	if got := deezerCandidateScore(noID, "Joseph Kamel", "Crash", "Crash - Single", 164); got >= 0 {
		t.Fatalf("没有 id 应当淘汰,得到 %d", got)
	}
}

func TestDeezerIsLyricsNotFound(t *testing.T) {
	real := `[{"message":"Lyrics does not exists","type":"LyricsNotFoundError","path":["track","lyrics"]}]`
	if !deezerIsLyricsNotFound(real) {
		t.Fatal("实测原文应当被认成「这首没有歌词」")
	}
	if !deezerIsLyricsNotFound(`[{"type":"LyricsNotFoundError"}]`) {
		t.Fatal("只有 type 也要认出来")
	}
	if deezerIsLyricsNotFound(`[{"message":"Unauthorized","type":"AuthenticationError"}]`) {
		t.Fatal("认证失败不是「没有歌词」—— 那一支要清掉 JWT 重试,别混")
	}
	if deezerIsLyricsNotFound("") {
		t.Fatal("没有错误时不该认成「没有歌词」")
	}
}

func TestDeezerHasError(t *testing.T) {
	for _, empty := range []string{"", "null", "[]", "{}", "  []  "} {
		if deezerHasError([]byte(empty)) {
			t.Fatalf("%q 应当算「没有错误」", empty)
		}
	}
	if !deezerHasError([]byte(`[{"type":"LyricsNotFoundError"}]`)) {
		t.Fatal("有内容时应当算有错误")
	}
}

func TestDeezerJWTExpiry(t *testing.T) {

	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"exp":1789300000,"unlogged":true}`))
	jwt := "header." + payload + ".sig"
	if got := deezerJWTExpiry(jwt); got.Unix() != 1789300000 {
		t.Fatalf("exp 没读对: %v", got)
	}
	for _, bad := range []string{"", "只有一段", "header.!!!不是base64!!!.sig", "header." + base64.RawURLEncoding.EncodeToString([]byte(`{"unlogged":true}`)) + ".sig"} {
		if got := deezerJWTExpiry(bad); !got.IsZero() {
			t.Fatalf("%q 应当解不出 exp,得到 %v", bad, got)
		}
	}
}

func TestDeezerTrackCover(t *testing.T) {
	xl := deezerTrackFromJSON(t, `{"album":{"cover_xl":"https://x/1000x1000.jpg","cover_big":"https://x/500x500.jpg"}}`)
	if got := xl.cover(); got != "https://x/1000x1000.jpg" {
		t.Fatalf("应当优先取 cover_xl,得到 %q", got)
	}
	big := deezerTrackFromJSON(t, `{"album":{"cover_big":"https://x/500x500.jpg"}}`)
	if got := big.cover(); got != "https://x/500x500.jpg" {
		t.Fatalf("没有 cover_xl 时应当退到 cover_big,得到 %q", got)
	}
	none := deezerTrackFromJSON(t, `{"album":{}}`)
	if got := none.cover(); got != "" {
		t.Fatalf("都没有时应当留空,得到 %q", got)
	}
}
