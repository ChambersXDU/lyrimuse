package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

const lyricsSearchGoldenDir = "testdata/lyricsgolden/search"

var lyricsSearchGoldenSources = []string{"netease", "qq", "kugou", "lrclib"}

type searchGoldenFixture struct {
	ID         string      `json:"id"`
	Source     string      `json:"source"`
	Note       string      `json:"note,omitempty"`
	Track      goldenTrack `json:"track"`
	CapturedAt string      `json:"captured_at"`

	Query goldenQuery `json:"query"`

	LocalDurationSecs float64 `json:"local_duration_secs"`

	Items []searchGoldenItem `json:"items"`

	AlbumLookup map[string]string  `json:"album_lookup,omitempty"`
	Expect      searchGoldenExpect `json:"expect"`
	Judge       searchGoldenJudge  `json:"judge"`
}

type searchGoldenItem struct {

	ID     string `json:"id"`
	Title  string `json:"title"`
	Artist string `json:"artist,omitempty"`

	Artists      []string `json:"artists,omitempty"`
	Album        string   `json:"album,omitempty"`
	AlbumID      string   `json:"album_id,omitempty"`
	DurationSecs float64  `json:"duration_secs,omitempty"`

	Language string `json:"language,omitempty"`

	Instrumental bool   `json:"instrumental,omitempty"`
	SyncedLyrics string `json:"synced_lyrics,omitempty"`
	PlainLyrics  string `json:"plain_lyrics,omitempty"`
}

type searchGoldenExpect struct {

	PickedID string `json:"picked_id"`

	AcceptedStrict []string `json:"accepted_strict,omitempty"`
	AcceptedLoose  []string `json:"accepted_loose,omitempty"`
	PickedNoAlbum  string   `json:"picked_no_album,omitempty"`

	PlainOnly bool `json:"plain_only,omitempty"`
}

type searchGoldenJudge struct {
	TitleAccepted          bool    `json:"title_accepted"`
	ArtistMatches          bool    `json:"artist_matches"`
	SourceDurationDeltaPct float64 `json:"source_duration_delta_pct"`
	VersionTagsOK          bool    `json:"version_tags_ok"`
	LiveMismatch           bool    `json:"live_mismatch"`

	PlausibleAlternatives int `json:"plausible_alternatives"`
}

func loadSearchGoldenFixtures(t *testing.T) []*searchGoldenFixture {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(lyricsSearchGoldenDir, "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(files)
	var out []*searchGoldenFixture
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		var fx searchGoldenFixture
		if err := json.Unmarshal(raw, &fx); err != nil {
			t.Fatalf("解析 %s: %v", f, err)
		}
		if want := strings.TrimSuffix(filepath.Base(f), ".json"); fx.ID != want {
			t.Fatalf("%s: id=%q 与文件名不一致", f, fx.ID)
		}
		out = append(out, &fx)
	}
	return out
}

func searchItemsFromNetease(songs []neSearchSong) []searchGoldenItem {
	out := make([]searchGoldenItem, 0, len(songs))
	for _, s := range songs {
		it := searchGoldenItem{ID: strconv.FormatInt(s.ID, 10), Title: s.Name, Album: s.Album.Name, DurationSecs: s.Duration / 1000}
		if s.Album.ID != 0 {
			it.AlbumID = strconv.FormatInt(s.Album.ID, 10)
		}
		for _, a := range s.Artists {
			it.Artists = append(it.Artists, a.Name)
		}
		out = append(out, it)
	}
	return out
}

func neteaseSongsFromItems(items []searchGoldenItem) []neSearchSong {
	out := make([]neSearchSong, 0, len(items))
	for _, it := range items {
		var s neSearchSong
		s.ID, _ = strconv.ParseInt(it.ID, 10, 64)
		s.Name = it.Title
		s.Album.Name = it.Album
		s.Album.ID, _ = strconv.ParseInt(it.AlbumID, 10, 64)
		s.Duration = it.DurationSecs * 1000
		for _, a := range it.Artists {
			s.Artists = append(s.Artists, struct {
				Name string `json:"name"`
			}{Name: a})
		}
		out = append(out, s)
	}
	return out
}

func searchItemsFromQQ(items []qqSearchItem) []searchGoldenItem {
	out := make([]searchGoldenItem, 0, len(items))
	for _, s := range items {
		out = append(out, searchGoldenItem{ID: s.Mid, Title: s.Name, Artist: s.Singer, Album: s.Album, DurationSecs: s.Interval})
	}
	return out
}

func qqItemsFromSearch(items []searchGoldenItem) []qqSearchItem {
	out := make([]qqSearchItem, 0, len(items))
	for _, it := range items {
		out = append(out, qqSearchItem{Mid: it.ID, Name: it.Title, Singer: it.Artist, Album: it.Album, Interval: it.DurationSecs})
	}
	return out
}

func searchItemsFromKugou(songs []kugouSong) []searchGoldenItem {
	out := make([]searchGoldenItem, 0, len(songs))
	for _, s := range songs {
		out = append(out, searchGoldenItem{ID: s.Hash, Title: s.SongName, Artist: s.SingerName, Album: s.AlbumName, AlbumID: s.AlbumID, DurationSecs: s.Duration, Language: s.TransParam.Language})
	}
	return out
}

func kugouSongsFromItems(items []searchGoldenItem) []kugouSong {
	out := make([]kugouSong, 0, len(items))
	for _, it := range items {
		var s kugouSong
		s.Hash, s.SongName, s.SingerName, s.AlbumName, s.AlbumID, s.Duration = it.ID, it.Title, it.Artist, it.Album, it.AlbumID, it.DurationSecs
		s.TransParam.Language = it.Language
		out = append(out, s)
	}
	return out
}

func searchItemsFromLRCLIB(items []lrclibSearchItem) []searchGoldenItem {
	out := make([]searchGoldenItem, 0, len(items))
	for i, s := range items {
		out = append(out, searchGoldenItem{ID: "#" + strconv.Itoa(i), Title: s.TrackName, Artist: s.ArtistName, Album: s.AlbumName, DurationSecs: s.Duration, Instrumental: s.Instrumental, SyncedLyrics: s.SyncedLyrics, PlainLyrics: s.PlainLyrics})
	}
	return out
}

func lrclibItemsFromSearch(items []searchGoldenItem) []lrclibSearchItem {
	out := make([]lrclibSearchItem, 0, len(items))
	for _, it := range items {
		out = append(out, lrclibSearchItem{TrackName: it.Title, ArtistName: it.Artist, AlbumName: it.Album, Duration: it.DurationSecs, Instrumental: it.Instrumental, SyncedLyrics: it.SyncedLyrics, PlainLyrics: it.PlainLyrics})
	}
	return out
}

func runSearchGolden(fx *searchGoldenFixture) searchGoldenExpect {
	q := fx.Query
	var e searchGoldenExpect
	switch fx.Source {
	case "netease":
		if p := neteasePickSong(neteaseSongsFromItems(fx.Items), q.Artist, q.Title, q.Album, q.DurationSecs); p != nil {
			e.PickedID = strconv.FormatInt(p.ID, 10)
		}
	case "qq":
		items := qqItemsFromSearch(fx.Items)
		strict := qqCollectCandidates(items, q.Artist, q.Title, true)
		loose := qqCollectCandidates(items, q.Artist, q.Title, false)
		for _, c := range strict {
			e.AcceptedStrict = append(e.AcceptedStrict, c.mid)
		}
		for _, c := range loose {
			e.AcceptedLoose = append(e.AcceptedLoose, c.mid)
		}
		cands := strict
		if len(cands) == 0 {
			cands = loose
		}
		if len(cands) == 0 {
			break
		}
		if c, ok := qqPickCandidate(cands, q.Artist, q.DurationSecs); ok {
			e.PickedNoAlbum = c.mid
		}

		if q.Album != "" {
			best, haveBest, _ := qqPickCandidateWithAlbum(cands, q.Artist, q.Album, q.DurationSecs, func(mid string) string { return fx.AlbumLookup[mid] })
			if haveBest {
				e.PickedID = best.mid
				break
			}
		}
		e.PickedID = e.PickedNoAlbum
	case "kugou":
		if p := pickKugouSearchCandidate(kugouSongsFromItems(fx.Items), q.Artist, q.Title, q.Album, q.DurationSecs); p != nil {
			e.PickedID = p.Hash
		}
	case "lrclib":
		items := lrclibItemsFromSearch(fx.Items)
		best, plainOnly := pickLRCLIBSearchResultDetailed(items, q.Artist, q.Title, q.Album, q.DurationSecs, false)
		if best == nil {
			best, plainOnly = pickLRCLIBSearchResultDetailed(items, q.Artist, q.Title, q.Album, q.DurationSecs, true)
		}
		if best != nil {
			for i := range items {
				if &items[i] == best {
					e.PickedID = fx.Items[i].ID
				}
			}
			e.PlainOnly = plainOnly
		}
	}
	return e
}

func searchGoldenItemByID(fx *searchGoldenFixture, id string) *searchGoldenItem {
	for i := range fx.Items {
		if fx.Items[i].ID == id {
			return &fx.Items[i]
		}
	}
	return nil
}

func searchGoldenItemArtist(it searchGoldenItem) string {
	if len(it.Artists) > 0 {
		return strings.Join(it.Artists, "/")
	}
	return it.Artist
}

func searchGoldenItemPlausible(q goldenQuery, localDur float64, it searchGoldenItem) bool {
	if !lyricTitleAccepted(it.Title, q.Title) {
		return false
	}
	artistOK := false
	if len(it.Artists) > 0 {
		for _, a := range it.Artists {
			if artistMatches(a, q.Artist) {
				artistOK = true
			}
		}
	} else {
		artistOK = lyricSourceArtistMatches(it.Artist, q.Artist) || looseContains(it.Artist, q.Artist)
	}
	if !artistOK {
		return false
	}
	if it.DurationSecs > 0 && localDur > 0 && 100*abs(it.DurationSecs-localDur)/localDur > 3 {
		return false
	}
	return true
}

func goldenComputeSearchJudge(fx *searchGoldenFixture, e searchGoldenExpect) searchGoldenJudge {
	j := searchGoldenJudge{SourceDurationDeltaPct: -1}
	q := fx.Query
	localDur := q.DurationSecs
	if localDur <= 0 {
		localDur = fx.LocalDurationSecs
	}
	if e.PickedID == "" {
		for _, it := range fx.Items {
			if searchGoldenItemPlausible(q, localDur, it) {
				j.PlausibleAlternatives++
			}
		}
		return j
	}
	it := searchGoldenItemByID(fx, e.PickedID)
	if it == nil {
		return j
	}
	j.TitleAccepted = lyricTitleAccepted(it.Title, q.Title)
	j.ArtistMatches = false
	if len(it.Artists) > 0 {
		for _, a := range it.Artists {
			if artistMatches(a, q.Artist) {
				j.ArtistMatches = true
			}
		}
	} else {

		j.ArtistMatches = lyricSourceArtistMatches(it.Artist, q.Artist) || looseContains(it.Artist, q.Artist)
	}
	if it.DurationSecs > 0 && localDur > 0 {
		j.SourceDurationDeltaPct = 100 * abs(it.DurationSecs-localDur) / localDur
	}
	j.VersionTagsOK = !versionTagsMismatch(q.Title, q.Album, it.Title, it.Album) &&
		!liveAlbumIdentityConflict(q.Artist, q.Title, q.Album, it.Title, it.Album)
	localLive := recordingVersionTags(q.Title, q.Album)["live"] || albumHasLiveMarker(q.Album)
	itemLive := recordingVersionTags(it.Title, it.Album)["live"] || albumHasLiveMarker(it.Album)
	j.LiveMismatch = localLive != itemLive
	return j
}

func goldenJudgeSearchPick(e searchGoldenExpect, j searchGoldenJudge) error {
	if e.PickedID == "" {
		if j.PlausibleAlternatives > 0 {
			return fmt.Errorf("选了空,但这批结果里有 %d 条歌名/歌手/时长都对得上的候选——放弃的理由有争议", j.PlausibleAlternatives)
		}
		return nil
	}
	var problems []string
	if !j.TitleAccepted {
		problems = append(problems, "选中的歌名没过 lyricTitleAccepted")
	}
	if !j.ArtistMatches {
		problems = append(problems, "选中的歌手对不上")
	}
	if j.SourceDurationDeltaPct > 3 {
		problems = append(problems, fmt.Sprintf("选中的自报时长偏差 %.1f%% > 3%%", j.SourceDurationDeltaPct))
	}
	if !j.VersionTagsOK {
		problems = append(problems, "版本限定词不一致或另一场演出")
	}
	if j.LiveMismatch {
		problems = append(problems, "一边是现场录音一边不是")
	}
	if len(problems) > 0 {
		return fmt.Errorf("%s", strings.Join(problems, ";"))
	}
	return nil
}

func TestLyricsSearchGolden(t *testing.T) {
	fixtures := loadSearchGoldenFixtures(t)
	if len(fixtures) == 0 {
		t.Fatal("testdata/lyricsgolden/search 里一个样本都没有——金标集是入库资产,目录被删/被清就是红,不是跳过")
	}
	for _, fx := range fixtures {
		fx := fx
		t.Run(fx.ID, func(t *testing.T) {
			got := runSearchGolden(fx)
			var diffs []string
			if got.PickedID != fx.Expect.PickedID {
				diffs = append(diffs, fmt.Sprintf("选中: 期望 %s, 实际 %s", searchGoldenDescribe(fx, fx.Expect.PickedID), searchGoldenDescribe(fx, got.PickedID)))
			}
			if a, b := strings.Join(fx.Expect.AcceptedStrict, ","), strings.Join(got.AcceptedStrict, ","); a != b {
				diffs = append(diffs, fmt.Sprintf("strict 档放行: 期望 [%s], 实际 [%s]", a, b))
			}
			if a, b := strings.Join(fx.Expect.AcceptedLoose, ","), strings.Join(got.AcceptedLoose, ","); a != b {
				diffs = append(diffs, fmt.Sprintf("loose 档放行: 期望 [%s], 实际 [%s]", a, b))
			}
			if fx.Expect.PickedNoAlbum != got.PickedNoAlbum {
				diffs = append(diffs, fmt.Sprintf("不看专辑的挑选: 期望 %s, 实际 %s", fx.Expect.PickedNoAlbum, got.PickedNoAlbum))
			}
			if fx.Expect.PlainOnly != got.PlainOnly {
				diffs = append(diffs, fmt.Sprintf("纯文本兜底: 期望 %v, 实际 %v", fx.Expect.PlainOnly, got.PlainOnly))
			}
			if len(diffs) == 0 {
				return
			}
			if goldenUpdateEnabled() {
				if !goldenSemanticAccepted(fx.ID) {
					t.Errorf("检索层挑选变了,不允许静默改写:\n  %s\n确认之后加 LYRICS_GOLDEN_ACCEPT_SEMANTIC=%s 再跑", strings.Join(diffs, "\n  "), fx.ID)
					return
				}
				fx.Expect = got
				fx.Judge = goldenComputeSearchJudge(fx, got)
				if err := writeSearchGoldenFixture(fx); err != nil {
					t.Fatal(err)
				}
				t.Logf("已更新 %s.json", fx.ID)
				return
			}
			t.Errorf("%s(%s)与金标不一致 —— %s《%s》\n  %s", fx.ID, fx.Source, fx.Track.Artist, fx.Track.Title, strings.Join(diffs, "\n  "))
		})
	}
}

func searchGoldenDescribe(fx *searchGoldenFixture, id string) string {
	if id == "" {
		return "<空>"
	}
	if it := searchGoldenItemByID(fx, id); it != nil {
		return fmt.Sprintf("%s(%q / %q / %.0fs)", id, it.Title, it.Album, it.DurationSecs)
	}
	return id
}

func TestLyricsSearchGoldenPicksAreJustified(t *testing.T) {
	for _, fx := range loadSearchGoldenFixtures(t) {
		j := goldenComputeSearchJudge(fx, fx.Expect)
		if err := goldenJudgeSearchPick(fx.Expect, j); err != nil {
			t.Errorf("%s: 挑选结果的独立判据不成立: %v\n  %+v", fx.ID, err, j)
		}
		if j != fx.Judge {
			t.Errorf("%s: 样本里记的判据跟重算的不一致(有人手改过样本?):\n  记录 %+v\n  重算 %+v", fx.ID, fx.Judge, j)
		}
	}
}

func TestLyricsSearchGoldenSourceCoverage(t *testing.T) {
	fixtures := loadSearchGoldenFixtures(t)
	if len(fixtures) == 0 {
		t.Fatal("testdata/lyricsgolden/search 里一个样本都没有——金标集是入库资产,目录被删/被清就是红,不是跳过")
	}
	count, negatives := map[string]int{}, map[string]int{}
	for _, fx := range fixtures {
		count[fx.Source]++
		if fx.Expect.PickedID == "" {
			negatives[fx.Source]++
		}
	}
	total := 0
	for _, src := range lyricsSearchGoldenSources {
		if count[src] < 3 {
			t.Errorf("%s 只有 %d 个检索层样本(要 ≥3)", src, count[src])
		}
		total += negatives[src]
	}
	if total < 2 {
		t.Errorf("'选空'的负样本只有 %d 个(要 ≥2)——身份闸的价值一半在拒绝", total)
	}
}

func writeSearchGoldenFixture(fx *searchGoldenFixture) error {
	raw, err := json.MarshalIndent(fx, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(lyricsSearchGoldenDir, fx.ID+".json"), append(raw, '\n'), 0o644)
}

func TestLyricsSearchGoldenCapture(t *testing.T) {
	if os.Getenv("LYRICS_SEARCH_GOLDEN_CAPTURE") == "" {
		t.Skip("LYRICS_SEARCH_GOLDEN_CAPTURE 未设置,跳过联网采集")
	}
	key, prefix, note := os.Getenv("LYRICS_GOLDEN_KEY"), os.Getenv("LYRICS_GOLDEN_ID"), os.Getenv("LYRICS_GOLDEN_NOTE")
	parts := strings.SplitN(key, "|", 3)
	if len(parts) != 3 || prefix == "" {
		t.Fatal("LYRICS_GOLDEN_KEY(歌手|歌名|专辑)与 LYRICS_GOLDEN_ID 都必须给")
	}
	home, _ := os.UserHomeDir()
	cfgDir := filepath.Join(home, ".config", clientName)
	rawCache, err := os.ReadFile(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cache map[string]goldenCacheEntry
	if err := json.Unmarshal(rawCache, &cache); err != nil {
		t.Fatal(err)
	}
	entry, ok := cache[key]
	if !ok {
		t.Fatalf("缓存里没有 key=%q", key)
	}
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	loadArtistAliasCache(filepath.Join(cfgDir, clientName+"-artist-alias-cache.json"))
	loadMBPrimaryNameCache(filepath.Join(cfgDir, clientName+"-artist-primary-cache.json"))
	loadAppleCatalogCache(filepath.Join(cfgDir, clientName+"-apple-catalog-cache.json"))
	loadAppleStorefrontArtistCache(filepath.Join(cfgDir, clientName+"-apple-storefront-artist-cache.json"))
	loadQQArtistNameCache(filepath.Join(cfgDir, clientName+"-qq-artist-name-cache.json"))
	artistAliasPath, mbPrimaryNamePath, qqArtistNamePath, appleStorefrontArtistPath, appleCatalogPath = "", "", "", "", ""

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
		t.Fatal("这条缓存没有时长,检索层的时长判据失效,不适合当金标")
	}

	type call struct {
		q     goldenQuery
		items []searchGoldenItem
	}
	calls := map[string][]call{}
	lyricSearchItemsTap = func(source, artist, title, album string, durationSecs float64, items any) {
		var conv []searchGoldenItem
		switch v := items.(type) {
		case []neSearchSong:
			conv = searchItemsFromNetease(v)
		case []qqSearchItem:
			conv = searchItemsFromQQ(v)
		case []kugouSong:
			conv = searchItemsFromKugou(v)
		case []lrclibSearchItem:
			conv = searchItemsFromLRCLIB(v)
		default:
			t.Errorf("tap 收到未知类型 %T(source=%s)", items, source)
			return
		}
		if len(conv) == 0 {
			return
		}
		calls[source] = append(calls[source], call{q: goldenQuery{Artist: artist, Title: title, Album: album, DurationSecs: durationSecs}, items: conv})
	}
	t.Cleanup(func() { lyricSearchItemsTap = nil })
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	scoredLyricCandidatesStreaming(ctx, qArtist, qTitle, qAlbum, dur, func(neteaseInfo, []scoredLyricCandidateResult, int, int) {})

	if err := os.MkdirAll(lyricsSearchGoldenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, src := range lyricsSearchGoldenSources {
		cs := calls[src]
		if len(cs) == 0 {
			t.Logf("%s: 没有非空搜索结果,跳过", src)
			continue
		}

		chosen, chosenPicked := cs[0], false
		for _, c := range cs {
			picked := runSearchGolden(&searchGoldenFixture{Source: src, Query: c.q, Items: c.items, LocalDurationSecs: dur}).PickedID != ""
			switch {
			case picked && !chosenPicked, picked == chosenPicked && len(c.items) > len(chosen.items):
				chosen, chosenPicked = c, picked
			}
		}
		fx := &searchGoldenFixture{
			ID: prefix + "-" + src, Source: src, Note: note,
			Track:      goldenTrack{Artist: parts[0], Title: parts[1], Album: parts[2]},
			CapturedAt: time.Now().Format("2006-01-02"),
			Query:      chosen.q, Items: chosen.items, LocalDurationSecs: dur,
		}
		if src == "qq" && chosen.q.Album != "" {

			items := qqItemsFromSearch(fx.Items)
			cands := qqCollectCandidates(items, chosen.q.Artist, chosen.q.Title, true)
			if len(cands) == 0 {
				cands = qqCollectCandidates(items, chosen.q.Artist, chosen.q.Title, false)
			}
			rec := map[string]string{}
			qqPickCandidateWithAlbum(cands, chosen.q.Artist, chosen.q.Album, chosen.q.DurationSecs, func(mid string) string {
				a := qqSongAlbum(ctx, mid)
				rec[mid] = a
				return a
			})
			if len(rec) > 0 {
				fx.AlbumLookup = rec
			}
		}
		if src == "lrclib" {

			before := runSearchGolden(fx)
			var texts []goldenText
			for _, it := range fx.Items {
				texts = append(texts, goldenText{it.SyncedLyrics, false}, goldenText{it.PlainLyrics, false})
			}
			scr := newGoldenScrambler(fx.ID, texts)
			for i := range fx.Items {
				fx.Items[i].SyncedLyrics = scr.scrambleText(fx.Items[i].SyncedLyrics, false)
				fx.Items[i].PlainLyrics = scr.scrambleText(fx.Items[i].PlainLyrics, false)
			}
			after := runSearchGolden(fx)
			if fmt.Sprintf("%+v", before) != fmt.Sprintf("%+v", after) {
				t.Errorf("%s: 置乱改变了挑选结果(%+v → %+v),不写入", fx.ID, before, after)
				continue
			}
		}
		fx.Expect = runSearchGolden(fx)
		fx.Judge = goldenComputeSearchJudge(fx, fx.Expect)
		t.Logf("%s: %d 条结果,选中 %s", fx.ID, len(fx.Items), searchGoldenDescribe(fx, fx.Expect.PickedID))
		for _, it := range fx.Items {
			mark := "  "
			if it.ID == fx.Expect.PickedID {
				mark = "→ "
			}
			t.Logf("  %s%-14s %-30q %-24q %-30q %.0fs", mark, it.ID, it.Title, searchGoldenItemArtist(it), it.Album, it.DurationSecs)
		}
		if err := goldenJudgeSearchPick(fx.Expect, fx.Judge); err != nil {
			t.Errorf("%s: 挑选结果证明不了,不写入: %v", fx.ID, err)
			continue
		}
		if err := writeSearchGoldenFixture(fx); err != nil {
			t.Fatal(err)
		}
		t.Logf("  已写入 %s/%s.json  判据 %+v", lyricsSearchGoldenDir, fx.ID, fx.Judge)
	}
}
