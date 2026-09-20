package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type goldenCacheEntry struct {
	Lyrics               string  `json:"lyrics"`
	LyricsSource         string  `json:"lyrics_source"`
	DurationSecs         float64 `json:"duration_secs"`
	ResolvedDurationSecs float64 `json:"resolved_duration_secs"`
	Instrumental         bool    `json:"instrumental"`
	ManualLyrics         bool    `json:"manual_lyrics"`
	Decision             *struct {
		QueryArtist  string  `json:"query_artist"`
		QueryTitle   string  `json:"query_title"`
		QueryAlbum   string  `json:"query_album"`
		DurationSecs float64 `json:"duration_secs"`
		Winner       string  `json:"winner"`
	} `json:"lyrics_decision_applied"`
}

func TestLyricsGoldenCapture(t *testing.T) {
	if os.Getenv("LYRICS_GOLDEN_CAPTURE") == "" {
		t.Skip("LYRICS_GOLDEN_CAPTURE 未设置,跳过联网采集")
	}
	key := os.Getenv("LYRICS_GOLDEN_KEY")
	id := os.Getenv("LYRICS_GOLDEN_ID")
	category := os.Getenv("LYRICS_GOLDEN_CATEGORY")
	note := os.Getenv("LYRICS_GOLDEN_NOTE")
	player := os.Getenv("LYRICS_GOLDEN_PLAYER")
	if key == "" || id == "" || category == "" {
		t.Fatal("LYRICS_GOLDEN_KEY / LYRICS_GOLDEN_ID / LYRICS_GOLDEN_CATEGORY 都必须给")
	}
	if _, ok := goldenRequiredCategories[category]; !ok {
		t.Fatalf("category=%q 不在 goldenRequiredCategories 里", category)
	}
	if strings.ContainsAny(id, "/\\ .") {
		t.Fatalf("id=%q 不能含路径分隔符、空格或点", id)
	}
	parts := strings.SplitN(key, "|", 3)
	if len(parts) != 3 {
		t.Fatalf("key=%q 必须是 歌手|歌名|专辑 三段", key)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	cfgDir := filepath.Join(home, ".config", clientName)
	rawCache, err := os.ReadFile(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	if err != nil {
		t.Fatalf("读 enrich 缓存: %v", err)
	}
	var cache map[string]goldenCacheEntry
	if err := json.Unmarshal(rawCache, &cache); err != nil {
		t.Fatalf("解析 enrich 缓存: %v", err)
	}
	entry, ok := cache[key]
	if !ok {
		t.Fatalf("缓存里没有 key=%q", key)
	}
	if entry.ManualLyrics {
		t.Logf("注意:这条是用户手选的(manual_lyrics),缓存正文是人挑的、不是自动决策的产物")
	}

	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	loadArtistAliasCache(filepath.Join(cfgDir, clientName+"-artist-alias-cache.json"))
	loadMBPrimaryNameCache(filepath.Join(cfgDir, clientName+"-artist-primary-cache.json"))
	loadAppleCatalogCache(filepath.Join(cfgDir, clientName+"-apple-catalog-cache.json"))
	loadAppleStorefrontArtistCache(filepath.Join(cfgDir, clientName+"-apple-storefront-artist-cache.json"))
	loadQQArtistNameCache(filepath.Join(cfgDir, clientName+"-qq-artist-name-cache.json"))

	artistAliasPath, mbPrimaryNamePath, qqArtistNamePath, appleStorefrontArtistPath, appleCatalogPath = "", "", "", "", ""
	setNativeLyricSourcesForPlayer(player)

	qArtist, qTitle, qAlbum := toSimplified(parts[0]), toSimplified(parts[1]), toSimplified(parts[2])
	dur := entry.ResolvedDurationSecs
	if dur <= 0 {
		dur = entry.DurationSecs
	}
	if d := entry.Decision; d != nil {
		if d.QueryTitle != "" {

			qArtist, qTitle, qAlbum = toSimplified(d.QueryArtist), toSimplified(d.QueryTitle), toSimplified(d.QueryAlbum)
		}
		if d.DurationSecs > 0 {
			dur = d.DurationSecs
		}
	}
	if dur <= 0 {

		if m := appleMusicMatchCached(context.Background(), qArtist, qTitle, qAlbum); m.durationSecs > 0 {
			t.Logf("缓存没有时长,用 Apple 目录的 %.3fs", m.durationSecs)
			dur = m.durationSecs
		} else if !entry.Instrumental {
			t.Fatalf("这条缓存没有时长,Apple 目录也查不到,打分的时长判据全部失效,不适合当金标")
		}
	}

	var tapped []lyricSourceResult
	lyricSourceResultTap = func(r lyricSourceResult) { tapped = append(tapped, r) }
	t.Cleanup(func() { lyricSourceResultTap = nil })
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	_, live := scoredLyricCandidatesStreaming(ctx, qArtist, qTitle, qAlbum, dur, func(neteaseInfo, []scoredLyricCandidateResult, int, int) {})
	livePick := pickLyricCandidate(live)

	rounds := splitGoldenRounds(tapped)
	if len(rounds) == 0 {
		t.Fatal("一个源都没有应答,没有可采的东西")
	}
	raw := rounds[0]
	t.Logf("联网共 %d 轮,第一轮 %d 个源应答(含 applecover)", len(rounds), len(raw))
	for i := 1; i < len(rounds); i++ {
		var names []string
		for s := range rounds[i] {
			names = append(names, s)
		}
		t.Logf("  第 %d 轮(别名/变体重试): %v", i+1, names)
	}

	replay := rankLyricSourceResults(qArtist, qTitle, qAlbum, dur, raw)
	replayPick := pickLyricCandidate(replay)
	for _, c := range replay {
		t.Logf("  %-11s %5d  %s  | %s / %s / %s  srcDur=%.1f", c.Source, c.Score, goldenTermsString(c.ScoreTerms), c.Title, c.Artist, c.Album, c.SourceReportedDurationSecs)
	}
	switch {
	case livePick == nil && replayPick == nil:
	case livePick == nil || replayPick == nil:
		t.Fatalf("闸1 不可回放:联网冠军=%v,单轮回放冠军=%v(一边有一边没有,说明正确性来自后续轮次)", goldenSrc(livePick), goldenSrc(replayPick))
	case livePick.Source != replayPick.Source || livePick.Lyrics != replayPick.Lyrics:
		t.Fatalf("闸1 不可回放:联网冠军 %s 与单轮回放冠军 %s 不一致(多轮合并的结果,单轮样本复现不了)", livePick.Source, replayPick.Source)
	}

	ev := goldenComputeEvidence(goldenQuery{Artist: qArtist, Title: qTitle, Album: qAlbum, DurationSecs: dur}, replay)
	switch {
	case entry.ManualLyrics:
		ev.CacheAgreement = "manual"
	case entry.Lyrics == "" && entry.Instrumental:
		ev.CacheAgreement = "instrumental"
	case entry.Lyrics == "":
		ev.CacheAgreement = "no-cache"
	case livePick == nil:
		ev.CacheAgreement = "cache-has-lyrics-but-no-winner"
	case normalizeGoldenNewlines(livePick.Lyrics) == normalizeGoldenNewlines(entry.Lyrics):
		ev.CacheAgreement = "exact"
	default:
		sim := gramJaccard(lyricGram3Set(lyricConsensusBody(livePick.Lyrics)), lyricGram3Set(lyricConsensusBody(entry.Lyrics)))

		if sim >= lyricConsensusSimThreshold {
			ev.CacheAgreement = fmt.Sprintf("similar=%.2f", sim)
		} else {
			ev.CacheAgreement = fmt.Sprintf("differs=%.2f", sim)
		}
	}
	winnerName := ""
	if livePick != nil {
		winnerName = livePick.Source
		t.Logf("冠军 %s 正文头尾(明文,只打到终端,不入样本):\n%s\n    …\n%s", livePick.Source, goldenHeadLines(livePick.Lyrics, 4), goldenTailLines(livePick.Lyrics, 4))
		if entry.Lyrics != "" && ev.CacheAgreement != "exact" {
			t.Logf("缓存里当前生效(%s)正文头尾:\n%s\n    …\n%s", entry.LyricsSource, goldenHeadLines(entry.Lyrics, 4), goldenTailLines(entry.Lyrics, 4))
		}
	}
	if strings.HasPrefix(ev.CacheAgreement, "differs") && os.Getenv("LYRICS_GOLDEN_CACHE_KNOWN_WRONG") != "" {
		ev.CacheAgreement += " (cache known wrong, see note)"
	}
	t.Logf("独立判据: %+v", ev)
	if err := goldenJudgeEvidence(goldenQuery{Artist: qArtist, Title: qTitle, Album: qAlbum, DurationSecs: dur}, winnerName, ev); err != nil {
		t.Fatalf("闸2 冠军的正确性证明不了,不写入: %v", err)
	}
	if livePick != nil && livePick.Source != entry.LyricsSource && entry.LyricsSource != "" {
		t.Logf("注意:联网冠军源 %s ≠ 缓存里的源 %s(正文关系 %s)", livePick.Source, entry.LyricsSource, ev.CacheAgreement)
	}

	scrambled := scrambleLyricRound(raw, id)
	before := goldenExpectFromRanked(replay)
	after := goldenExpectFromRanked(rankLyricSourceResults(qArtist, qTitle, qAlbum, dur, scrambled))
	after.WinnerFingerprint = before.WinnerFingerprint
	if d := diffGoldenExpect(before, after); len(d.semantic)+len(d.snapshot) > 0 {
		t.Fatalf("闸3 置乱破坏了打分特征,拒绝写入:\n  %s", strings.Join(append(d.semantic, d.snapshot...), "\n  "))
	}
	for src, r := range scrambled {
		for _, text := range []string{r.lyr, r.yrc, r.tr, r.roma, r.ne.Lyrics, r.ne.YRC, r.ne.Trans, r.ne.Roma, r.amll.lrc, r.amll.yrc, r.amll.tr} {
			if line, bad := goldenFindUnscrambledLine(text); bad {
				t.Fatalf("闸3 %s 置乱后仍有明文迹象: %q", src, line)
			}
		}
	}

	fx := &goldenFixture{
		ID: id, Category: category, Note: note, LabelEvidence: ev,
		Track:                   goldenTrack{Artist: parts[0], Title: parts[1], Album: parts[2]},
		CapturedAt:              time.Now().Format("2006-01-02"),
		ScoringVersionAtCapture: lyricsScoringVersion,
		Query:                   goldenQuery{Artist: qArtist, Title: qTitle, Album: qAlbum, DurationSecs: dur},
		Settings: goldenSettings{
			TranslationLanguage: features.LyricsTranslationLanguage,
			Sources:             copyGoldenSources(getFeaturesLyricsSources()),
			SourceMode:          features.LyricsSourceMode,
			SourceOrder:         append([]string(nil), features.LyricsSourceOrder...),
			PlayerBundleID:      player,
			ArtistCJKHint:       resolvedArtistCJKHint(qArtist),
		},
		Sources: map[string]goldenSourceRaw{},
	}
	for src, r := range scrambled {
		fx.Sources[src] = goldenSourceFromRaw(src, r)
	}
	fx.Expect = goldenExpectFromRanked(rankLyricSourceResults(qArtist, qTitle, qAlbum, dur, goldenRawRound(fx)))
	if err := goldenCategoryCheck(fx, category, fx.Expect); err != nil {
		t.Fatalf("这首歌的这一轮结果没有体现类别 %s(%v),不写入——换一首,或者这一类的判据这次没触发", category, err)
	}

	if err := os.MkdirAll(lyricsGoldenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writeGoldenFixture(fx); err != nil {
		t.Fatalf("写样本: %v", err)
	}
	var back goldenFixture
	rawFx, err := os.ReadFile(filepath.Join(lyricsGoldenDir, id+".json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(rawFx, &back); err != nil {
		t.Fatal(err)
	}
	applyGoldenSettings(t, &back)
	if d := diffGoldenExpect(back.Expect, runGoldenFixture(&back)); len(d.semantic)+len(d.snapshot) > 0 {
		os.Remove(filepath.Join(lyricsGoldenDir, id+".json"))
		t.Fatalf("闸4 样本读回来跑不出同样的结果,已删除:\n  %s", strings.Join(append(d.semantic, d.snapshot...), "\n  "))
	}

	t.Logf("已写入 %s/%s.json", lyricsGoldenDir, id)
	t.Logf("  冠军 %s;判决 %v", fx.Expect.Winner, fx.Expect.Verdicts)
	if fx.Expect.InstrumentalMarker != "" {
		t.Logf("  纯音乐标记来自 %s", fx.Expect.InstrumentalMarker)
	}
}

func splitGoldenRounds(tapped []lyricSourceResult) []map[string]lyricSourceResult {
	var rounds []map[string]lyricSourceResult
	cur := map[string]lyricSourceResult{}
	for _, r := range tapped {
		if _, dup := cur[r.source]; dup {
			rounds = append(rounds, cur)
			cur = map[string]lyricSourceResult{}
		}
		cur[r.source] = r
	}
	if len(cur) > 0 {
		rounds = append(rounds, cur)
	}
	return rounds
}

func goldenSrc(c *scoredLyricCandidateResult) string {
	if c == nil {
		return "<nil>"
	}
	return c.Source
}

func normalizeGoldenNewlines(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return strings.TrimSpace(strings.ReplaceAll(s, "\r", "\n"))
}

func goldenHeadLines(s string, n int) string {
	var out []string
	for _, line := range splitLyricLines(s) {
		text := strings.TrimSpace(strings.TrimPrefix(lrcTimestampRe.ReplaceAllString(line, ""), "\uFEFF"))
		if text == "" || isLRCMetaTagLine(text) || isCreditLine(text) {
			continue
		}
		out = append(out, "    "+line)
		if len(out) >= n {
			break
		}
	}
	return strings.Join(out, "\n")
}

func goldenTailLines(s string, n int) string {
	var body []string
	for _, line := range splitLyricLines(s) {
		text := strings.TrimSpace(strings.TrimPrefix(lrcTimestampRe.ReplaceAllString(line, ""), "\uFEFF"))
		if text == "" || isLRCMetaTagLine(text) || isCreditLine(text) {
			continue
		}
		body = append(body, "    "+line)
	}
	if len(body) > n {
		body = body[len(body)-n:]
	}
	return strings.Join(body, "\n")
}

func copyGoldenSources(m map[string]bool) map[string]bool {
	if len(m) == 0 {
		return nil
	}
	out := make(map[string]bool, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}
