package main

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"
)

func princeResults() []itunesResult {
	const title = "Why You Wanna Treat Me So Bad?"
	return []itunesResult{
		{TrackName: title, ArtistName: "Prince", CollectionName: "The Hits/The B-Sides", CollectionID: 212972881, TrackTimeMillis: 231000, ReleaseDate: "1979-10-19T07:00:00Z"},
		{TrackName: title, ArtistName: "Prince", CollectionName: "Prince", CollectionID: 1544298981, TrackTimeMillis: 231000, ReleaseDate: "1979-10-19T07:00:00Z"},
		{TrackName: title, ArtistName: "Tuesday Knight", CollectionName: "Tuesday Knight", CollectionID: 1124764563, TrackTimeMillis: 245000, ReleaseDate: "1987-01-01T08:00:00Z"},
		{TrackName: title, ArtistName: "Blakeleeluv", CollectionName: "Covers", CollectionID: 1536542433, TrackTimeMillis: 187300, ReleaseDate: "2020-10-17T07:00:00Z"},
		{TrackName: title, ArtistName: "Tuesday Knight", CollectionName: "Tuesday Knight (2018 Remaster)", CollectionID: 1778733373, TrackTimeMillis: 233400, ReleaseDate: "1987-05-27T07:00:00Z"},
		{TrackName: title + " (Live)", ArtistName: "Prince", CollectionName: "One Nite Alone... Live!", TrackTimeMillis: 300000},

		{TrackName: title, ArtistName: "Prince", CollectionName: "Prince", CollectionID: 1544298981, TrackTimeMillis: 231000, ReleaseDate: "1979-10-19T07:00:00Z"},
	}
}

func TestAlbumHintCandidatesFromResults(t *testing.T) {
	cands := albumHintCandidatesFromResults(princeResults(), "Why You Wanna Treat Me So Bad?", 230.121)
	var got []string
	for _, c := range cands {
		got = append(got, c.Artist+"/"+c.Album)
	}
	want := []string{"Prince/The Hits/The B-Sides", "Prince/Prince", "Tuesday Knight/Tuesday Knight (2018 Remaster)"}
	if len(got) != len(want) {
		t.Fatalf("候选过滤:want %v, got %v", want, got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("候选过滤第 %d 条:want %q, got %q", i, want[i], got[i])
		}
	}

	if cands[1].Order != 1 || cands[1].CollectionID != 1544298981 {
		t.Fatalf("候选 Order / CollectionID 没带对:%+v", cands[1])
	}
	if albumHintCandidatesFromResults(princeResults(), "Why You Wanna Treat Me So Bad?", 40) != nil {
		t.Fatalf("短于 75s 不取候选")
	}
	if albumHintCandidatesFromResults(princeResults(), "", 230) != nil {
		t.Fatalf("没曲名不取候选")
	}
}

func TestPickAppleAlbumHint(t *testing.T) {
	cands := albumHintCandidatesFromResults(princeResults(), "Why You Wanna Treat Me So Bad?", 230.121)
	releases := map[int64]string{212972881: "1993-09-13T07:00:00Z", 1544298981: "1979-10-19T07:00:00Z", 1778733373: "1987-05-27T07:00:00Z"}
	for i := range cands {
		cands[i].AlbumRelease = releases[cands[i].CollectionID]
	}

	if got := pickAppleAlbumHint(cands, "王子", []string{"Prince"}); got != "Prince" {
		t.Fatalf("旁证 Prince:want Prince, got %q", got)
	}

	if got := pickAppleAlbumHint(cands, "王子", nil); got != "" {
		t.Fatalf("没有旁证不采跨文字系统的候选, got %q", got)
	}

	if got := pickAppleAlbumHint(cands, "王子", []string{"Tuesday Knight"}); got != "Tuesday Knight (2018 Remaster)" {
		t.Fatalf("旁证 Tuesday Knight:got %q", got)
	}

	if got := pickAppleAlbumHint(cands, "Prince", nil); got != "Prince" {
		t.Fatalf("署名相等:want Prince, got %q", got)
	}

	if got := pickAppleAlbumHint(cands, "Tuesday Knight", []string{"Prince"}); got != "Tuesday Knight (2018 Remaster)" {
		t.Fatalf("0 档优先于 1 档:got %q", got)
	}

	noAlbumDates := albumHintCandidatesFromResults(princeResults(), "Why You Wanna Treat Me So Bad?", 230.121)
	if got := pickAppleAlbumHint(noAlbumDates, "Prince", nil); got != "The Hits/The B-Sides" {
		t.Fatalf("无专辑级日期时按曲目级日期再按顺序:got %q", got)
	}
}

func TestPickAppleAlbumHintRanking(t *testing.T) {

	seal := []albumHintCandidate{
		{Artist: "Seal", Album: "Seal: Best 1991-2004 (Deluxe Version)", AlbumRelease: "2004-11-08T08:00:00Z", Order: 0},
		{Artist: "Seal", Album: "Seal (Deluxe Edition)", AlbumRelease: "1994-05-23T07:00:00Z", Order: 1},
		{Artist: "Seal", Album: "Seal II", AlbumRelease: "1994-05-31T07:00:00Z", Order: 2},
		{Artist: "Seal", Album: "Seal: Hits", AlbumRelease: "2009-11-30T08:00:00Z", Order: 3},
	}
	if got := pickAppleAlbumHint(seal, "Seal", nil); got != "Seal II" {
		t.Fatalf("豪华版减分、精选靠日期排后:want Seal II, got %q", got)
	}

	comp := []albumHintCandidate{
		{Artist: "Seal", CollectionArtist: "Various Artists", Album: "Batman Forever (Soundtrack)", AlbumRelease: "1995-06-06T07:00:00Z", Order: 0},
		{Artist: "Seal", Album: "Seal II", AlbumRelease: "1996-01-01T08:00:00Z", Order: 1},
	}
	if got := pickAppleAlbumHint(comp, "Seal", nil); got != "Seal II" {
		t.Fatalf("群星合辑排后:want Seal II, got %q", got)
	}
	if got := pickAppleAlbumHint(comp[:1], "Seal", nil); got != "Batman Forever (Soundtrack)" {
		t.Fatalf("只有合辑时照样给, got %q", got)
	}

	single := []albumHintCandidate{
		{Artist: "Prince", Album: "Why You Wanna Treat Me So Bad? - Single", AlbumRelease: "1979-01-01T08:00:00Z", Order: 0},
		{Artist: "Prince", Album: "The Hits/The B-Sides", AlbumRelease: "1993-09-13T07:00:00Z", Order: 1},
	}
	if got := pickAppleAlbumHint(single, "Prince", nil); got != "The Hits/The B-Sides" {
		t.Fatalf("单曲排后:want The Hits/The B-Sides, got %q", got)
	}

	noDate := []albumHintCandidate{
		{Artist: "X", Album: "Later", Order: 0},
		{Artist: "X", Album: "Dated", AlbumRelease: "2001-01-01T00:00:00Z", Order: 1},
	}
	if got := pickAppleAlbumHint(noDate, "X", nil); got != "Dated" {
		t.Fatalf("缺日期排后:want Dated, got %q", got)
	}

	credit := []albumHintCandidate{{Artist: "Prince & The Revolution", Album: "Around the World in a Day", AlbumRelease: "1985-04-22T07:00:00Z"}}
	if got := pickAppleAlbumHint(credit, "Prince", nil); got != "Around the World in a Day" {
		t.Fatalf("credit 子集:got %q", got)
	}
	if got := pickAppleAlbumHint(credit, "The Revolution & Prince", nil); got != "Around the World in a Day" {
		t.Fatalf("credit 顺序不同:got %q", got)
	}
	if got := pickAppleAlbumHint([]albumHintCandidate{{Artist: "周杰倫", Album: "七里香", AlbumRelease: "2004-08-03T00:00:00Z"}}, "周杰伦", nil); got != "七里香" {
		t.Fatalf("繁简折叠算 0 档:got %q", got)
	}

	jay := []albumHintCandidate{
		{Artist: "阿紫", Album: "船歌", AlbumRelease: "2005-06-01T07:00:00Z", Order: 0},
		{Artist: "Choiyl", Album: "Jay - Piano Cover (Piano Version)", AlbumRelease: "2024-04-05T07:00:00Z", Order: 1},
	}
	if got := pickAppleAlbumHint(jay, "周杰伦", []string{"周杰伦"}); got != "" {
		t.Fatalf("同名翻唱 / 钢琴版不采:got %q", got)
	}
}

func TestAppleAlbumHintHelpers(t *testing.T) {
	if got := appleAlbumHintKey(" 王子 ", "Why You Wanna Treat Me So Bad?", 230.121); got != "王子|Why You Wanna Treat Me So Bad?|230" {
		t.Fatalf("key 形状(原样署名|曲名|整秒时长):got %q", got)
	}
	for _, c := range []struct {
		artist, title string
		dur           float64
		want          bool
	}{
		{"王子", "Why You Wanna Treat Me So Bad?", 230, true},
		{"", "Why You Wanna Treat Me So Bad?", 230, false},
		{"王子", "", 230, false},
		{"王子", "Intro", 40, false},
		{"王子", "Why You Wanna Treat Me So Bad?", 0, false},
	} {
		if got := appleAlbumHintEligible(c.artist, c.title, c.dur); got != c.want {
			t.Fatalf("eligible(%q,%q,%.0f) = %v, want %v", c.artist, c.title, c.dur, got, c.want)
		}
	}
	for _, c := range []struct {
		album string
		want  bool
	}{
		{"Why You Wanna Treat Me So Bad? - Single", true}, {"Something - EP", true}, {"Prince", false}, {"Single Ladies", false},
	} {
		if got := albumHintIsSingleOrEP(c.album); got != c.want {
			t.Fatalf("isSingleOrEP(%q) = %v, want %v", c.album, got, c.want)
		}
	}
	for _, c := range []struct {
		album string
		want  bool
	}{
		{"Seal (Deluxe Edition)", true}, {"Tuesday Knight (2018 Remaster)", true}, {"七里香 (豪华版)", true}, {"Seal II", false}, {"Prince", false},
	} {
		if got := albumHintHasEditionQualifier(c.album); got != c.want {
			t.Fatalf("editionQualifier(%q) = %v, want %v", c.album, got, c.want)
		}
	}

	if got := (snapshot{Album: "Prince", AlbumHint: "X"}).albumForUpload(); got != "Prince" {
		t.Fatalf("Album 非空时原样:got %q", got)
	}
	if got := (snapshot{AlbumHint: "Prince"}).albumForUpload(); got != "Prince" {
		t.Fatalf("Album 空时用回填:got %q", got)
	}
	if got := (snapshot{}).albumForUpload(); got != "" {
		t.Fatalf("都空则空:got %q", got)
	}

	appleAlbumHintMu.Lock()
	appleAlbumHintPath = ""
	key := appleAlbumHintKey("王子", "Why You Wanna Treat Me So Bad?", 230.121)
	appleAlbumHintCache[key] = []albumHintCandidate{
		{Artist: "Prince", Album: "Prince", AlbumRelease: "1979-10-19T07:00:00Z"},
		{Artist: "Tuesday Knight", Album: "Tuesday Knight", AlbumRelease: "1987-01-01T00:00:00Z", Order: 1},
	}
	delete(appleAlbumHintLogged, key)
	appleAlbumHintMu.Unlock()
	if got := appleAlbumHint(context.Background(), "王子", "Why You Wanna Treat Me So Bad?", 230.121, nil); got != "" {
		t.Fatalf("旁证未到:want 空, got %q", got)
	}
	if got := appleAlbumHint(context.Background(), "王子", "Why You Wanna Treat Me So Bad?", 230.121, []string{"Prince"}); got != "Prince" {
		t.Fatalf("旁证到了:want Prince, got %q", got)
	}
	if got := appleAlbumHint(context.Background(), "", "x", 230, nil); got != "" {
		t.Fatalf("不合格的请求不问也不返回:got %q", got)
	}
}

func TestCoverNeedsHintCheck(t *testing.T) {
	apple := enrichEntry{CoverURL: "https://is1-ssl.mzstatic.com/x.jpg", CoverSource: "apple", CoverAlbum: "The Hits/The B-Sides"}
	cases := []struct {
		name        string
		e           enrichEntry
		album, hint string
		want        bool
	}{
		{"王子那首:合集封面 vs 回填原版", apple, "", "Prince", true},
		{"播放器报了专辑就不归这条管", apple, "Prince", "Prince", false},
		{"没有回填名", apple, "", "", false},
		{"回填名跟现有封面同一张专辑", enrichEntry{CoverURL: "u", CoverSource: "netease", CoverAlbum: "Prince"}, "", "Prince", false},
		{"写法差异(宽松包含 100 分)不复查", enrichEntry{CoverURL: "u", CoverSource: "netease", CoverAlbum: "1999 (2019 Remaster)"}, "", "1999", false},
		{"qq 从不报专辑名,判不了", enrichEntry{CoverURL: "u", CoverSource: "qq"}, "", "Prince", false},
		{"device 身份不靠文字", enrichEntry{CoverURL: "u", CoverSource: "device", CoverAlbum: "Something Else"}, "", "Prince", false},
		{"没有封面", enrichEntry{CoverSource: "apple", CoverAlbum: "Something Else"}, "", "Prince", false},
	}
	for _, c := range cases {
		if got := coverNeedsHintCheck(c.e, c.album, c.hint); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func seedPrinceHintCache(t *testing.T) (key string, restore func()) {
	t.Helper()
	const title = "Why You Wanna Treat Me So Bad?"
	cands := albumHintCandidatesFromResults(princeResults(), title, 230.121)
	releases := map[int64]string{212972881: "1993-09-13T07:00:00Z", 1544298981: "1979-10-19T07:00:00Z", 1778733373: "1987-05-27T07:00:00Z"}
	for i := range cands {
		cands[i].AlbumRelease = releases[cands[i].CollectionID]
	}
	savedCache, savedHint, savedMisses, savedInflight, savedLogged :=
		enrichCache, appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintLogged
	key = appleAlbumHintKey("王子", title, 230.121)
	appleAlbumHintCache = map[string][]albumHintCandidate{key: cands}
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{}
	appleAlbumHintLogged = map[string]string{}
	enrichCache = map[string]enrichEntry{
		"王子|" + title + "|": {LyricsDecisionApplied: &lyricsDecision{Winner: "kugou",
			Candidates: []lyricsDecisionCandidate{{Source: "kugou", Artist: "Prince"}}}},
	}
	return key, func() {
		enrichCache, appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintLogged =
			savedCache, savedHint, savedMisses, savedInflight, savedLogged
	}
}

func TestCoverAlbumForTrack(t *testing.T) {
	_, restore := seedPrinceHintCache(t)
	defer restore()
	ctx := context.Background()
	const title = "Why You Wanna Treat Me So Bad?"

	if got := coverAlbumForTrack(ctx, "Prince", "Sexy Dancer", "Prince", 258); got != "Prince" {
		t.Fatalf("album given: got %q", got)
	}

	if got := coverAlbumForTrack(ctx, "王子", title, "", 230.121); got != "Prince" {
		t.Fatalf("album-less MV: got %q want Prince", got)
	}

	enrichCache = map[string]enrichEntry{}
	if got := coverAlbumForTrack(ctx, "王子", title, "", 230.121); got != "" {
		t.Fatalf("no corroboration yet: got %q want empty", got)
	}

	if got := coverAlbumForTrack(ctx, "王子", title, "", 40); got != "" {
		t.Fatalf("short track: got %q", got)
	}
}

func TestCoverAlbumCorroboration(t *testing.T) {
	_, restore := seedPrinceHintCache(t)
	defer restore()
	const title = "Why You Wanna Treat Me So Bad?"
	picked := &scoredLyricCandidateResult{Source: "kugou", Artist: "Prince"}
	got := coverAlbumCorroboration("王子", title, "", "PRINCE", picked)

	want := []string{"Prince", "PRINCE", "Prince"}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}

	enrichCache = map[string]enrichEntry{}
	if got := coverAlbumCorroboration("王子", title, "", "", nil); len(got) != 0 {
		t.Fatalf("empty corroboration: got %v", got)
	}
	if got := coverAlbumCorroboration("王子", title, "", "  ", &scoredLyricCandidateResult{Artist: " "}); len(got) != 0 {
		t.Fatalf("blank names must be dropped: got %v", got)
	}
}

func TestAppleAlbumHintSyncUsesCacheAndGivesUp(t *testing.T) {
	key, restore := seedPrinceHintCache(t)
	defer restore()
	const title = "Why You Wanna Treat Me So Bad?"

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got := appleAlbumHintSync(ctx, "王子", title, 230.121, []string{"Prince"}); got != "Prince" {
		t.Fatalf("cached: got %q want Prince", got)
	}

	appleAlbumHintMu.Lock()
	logged := appleAlbumHintLogged[key]
	appleAlbumHintMu.Unlock()
	if logged != "Prince" {
		t.Fatalf("logged marker: got %q", logged)
	}

	otherKey := appleAlbumHintKey("Nobody", "Nothing Here", 200)
	appleAlbumHintMisses[otherKey] = appleAlbumHintMaxMisses
	if got := appleAlbumHintSync(ctx, "Nobody", "Nothing Here", 200, nil); got != "" {
		t.Fatalf("maxed misses: got %q want empty", got)
	}

	inflightKey := appleAlbumHintKey("Somebody", "Still Loading", 200)
	appleAlbumHintInflight[inflightKey] = true
	if got := appleAlbumHintSync(ctx, "Somebody", "Still Loading", 200, nil); got != "" {
		t.Fatalf("inflight + cancelled ctx: got %q want empty", got)
	}

	if got := appleAlbumHintSync(ctx, "王子", title, 40, []string{"Prince"}); got != "" {
		t.Fatalf("short: got %q", got)
	}
}

func TestPeripheralBackfillWindowOpen(t *testing.T) {
	now := time.Now().Unix()
	if peripheralBackfillWindowOpen(enrichEntry{PeripheralRetryCount: peripheralBackfillMaxAttempts, TS: 1}) {
		t.Fatal("capped entry must not reopen")
	}
	if peripheralBackfillWindowOpen(enrichEntry{PeripheralTS: now}) {
		t.Fatal("just backfilled: window closed")
	}
	if !peripheralBackfillWindowOpen(enrichEntry{TS: now - int64(enrichPeripheralRetryInterval/time.Second) - 1}) {
		t.Fatal("old entry without PeripheralTS falls back to TS and reopens")
	}
}

func TestAppleAlbumHintQueryConcluded(t *testing.T) {
	cases := []struct {
		name               string
		n                  int
		attempts, failures int32
		want               bool
	}{
		{"有候选就算数", 3, 4, 4, true},
		{"网络通、Apple 说没有", 0, 4, 1, true},
		{"四个请求全在传输层失败(断网 / DNS)", 0, 4, 4, false},
		{"一个请求都没发出去", 0, 0, 0, false},
		{"只发出一个且失败", 0, 1, 1, false},
	}
	for _, c := range cases {
		if got := appleAlbumHintQueryConcluded(c.n, c.attempts, c.failures); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestStoreAppleAlbumHintResultNetworkDownNoMiss(t *testing.T) {
	savedMisses, savedInflight := appleAlbumHintMisses, appleAlbumHintInflight
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{}
	defer func() { appleAlbumHintMisses, appleAlbumHintInflight = savedMisses, savedInflight }()
	key := appleAlbumHintKey("Nobody", "Offline Song", 200)
	appleAlbumHintInflight[key] = true

	storeAppleAlbumHintResult(key, nil, false)
	if appleAlbumHintInflight[key] || appleAlbumHintMisses[key] != 0 {
		t.Fatalf("network-down round: inflight=%v misses=%d", appleAlbumHintInflight[key], appleAlbumHintMisses[key])
	}

	storeAppleAlbumHintResult(key, nil, true)
	storeAppleAlbumHintResult(key, nil, true)
	if appleAlbumHintMisses[key] != appleAlbumHintMaxMisses {
		t.Fatalf("concluded misses: got %d want %d", appleAlbumHintMisses[key], appleAlbumHintMaxMisses)
	}
}

func TestAlbumHintTitleSplit(t *testing.T) {
	cases := []struct {
		title        string
		artist, song string
		ok           bool
	}{

		{"Musiq Soulchild - Buddy (Official Video)", "Musiq Soulchild", "Buddy", true},
		{"Prince - 1999 (Official Music Video) [HD]", "Prince", "1999", true},
		{"Prince – 1999", "Prince", "1999", true},

		{"Prince - 1999 (Live)", "Prince", "1999 (Live)", true},

		{"A - B - C", "A", "B - C", true},
		{"Buddy", "", "", false},
		{"Buddy (Official Video)", "", "", false},
		{" - Buddy", "", "", false},
		{"Buddy - ", "", "", false},
		{"Buddy - (…)", "", "", false},
	}
	for _, c := range cases {
		artist, song, ok := albumHintTitleSplit(c.title)
		if artist != c.artist || song != c.song || ok != c.ok {
			t.Errorf("%q: got (%q, %q, %v) want (%q, %q, %v)", c.title, artist, song, ok, c.artist, c.song, c.ok)
		}
	}
}

func buddyResults() []itunesResult {
	return []itunesResult{
		{TrackName: "B.U.D.D.Y.", ArtistName: "Musiq Soulchild", CollectionName: "Luvanmusiq", CollectionID: 1, TrackTimeMillis: 223800, ReleaseDate: "2007-03-13T07:00:00Z"},
		{TrackName: "Buddy", ArtistName: "Musiq Soulchild", CollectionName: "Buddy - Single", CollectionID: 2, TrackTimeMillis: 223800, ReleaseDate: "2007-01-23T08:00:00Z"},
		{TrackName: "B.U.D.D.Y.", ArtistName: "Musiq Soulchild", CollectionName: "Sobeautiful", CollectionID: 3, TrackTimeMillis: 223800, ReleaseDate: "2009-11-17T08:00:00Z"},

		{TrackName: "Buddy", ArtistName: "De La Soul", CollectionName: "3 Feet High and Rising", CollectionID: 4, TrackTimeMillis: 224000, ReleaseDate: "1989-03-03T08:00:00Z"},
	}
}

func TestAlbumHintCandidatesFromTitleSplit(t *testing.T) {

	cands := albumHintCandidatesFromTitleSplit(buddyResults(), "Musiq Soulchild", "Buddy", 225)
	var got []string
	for _, c := range cands {
		if c.TitleArtist != "Musiq Soulchild" {
			t.Fatalf("TitleArtist 没记上: %+v", c)
		}
		got = append(got, c.Album)
	}
	want := []string{"Luvanmusiq", "Buddy - Single", "Sobeautiful"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("拆分身份候选:want %v, got %v", want, got)
	}

	for _, c := range albumHintCandidatesFromResults(buddyResults(), "Buddy", 225) {
		if c.TitleArtist != "" {
			t.Fatalf("主查询候选不该带 TitleArtist: %+v", c)
		}
	}

	if got := albumHintCandidatesFromTitleSplit(buddyResults(), "Musiq Soulchild", "Buddy", 231.441); len(got) != 0 {
		t.Fatalf("MV 时长超容差仍应零候选, got %v", got)
	}
}

func TestPickAppleAlbumHintTitleArtist(t *testing.T) {
	cands := albumHintCandidatesFromTitleSplit(buddyResults(), "Musiq Soulchild", "Buddy", 225)
	releases := map[int64]string{1: "2007-03-13T07:00:00Z", 2: "2007-01-23T08:00:00Z", 3: "2009-11-17T08:00:00Z"}
	for i := range cands {
		cands[i].AlbumRelease = releases[cands[i].CollectionID]
	}

	if got := pickAppleAlbumHint(cands, "音樂頑童", nil); got != "Luvanmusiq" {
		t.Fatalf("TitleArtist 当 0 档:want Luvanmusiq, got %q", got)
	}

	for i := range cands {
		cands[i].TitleArtist = ""
	}
	if got := pickAppleAlbumHint(cands, "音樂頑童", nil); got != "" {
		t.Fatalf("没有 TitleArtist 不该采, got %q", got)
	}

	cands[0].TitleArtist = "Someone Else"
	if got := pickAppleAlbumHint(cands[:1], "音樂頑童", nil); got != "" {
		t.Fatalf("TitleArtist 与署名不符不该采, got %q", got)
	}
}

func TestAppleAlbumHintSyncChannelCoordination(t *testing.T) {
	savedCache, savedMisses, savedInflight, savedWaiters, savedLogged :=
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged
	defer func() {
		appleAlbumHintCache, appleAlbumHintMisses, appleAlbumHintInflight, appleAlbumHintWaiters, appleAlbumHintLogged =
			savedCache, savedMisses, savedInflight, savedWaiters, savedLogged
	}()

	key := appleAlbumHintKey("TestArtist", "TestTitle", 200)
	appleAlbumHintCache = map[string][]albumHintCandidate{}
	appleAlbumHintMisses = map[string]int{}
	appleAlbumHintInflight = map[string]bool{key: true}
	waitCh := make(chan struct{})
	appleAlbumHintWaiters = map[string]chan struct{}{key: waitCh}
	appleAlbumHintLogged = map[string]string{}

	ctx := t.Context()
	const numWaiters = 5
	results := make([]string, numWaiters)
	var wg sync.WaitGroup

	for i := 0; i < numWaiters; i++ {
		wg.Add(1)
		idx := i
		go func() {
			defer wg.Done()
			results[idx] = appleAlbumHintSync(ctx, "TestArtist", "TestTitle", 200, nil)
		}()
	}

	time.Sleep(50 * time.Millisecond)

	testCands := []albumHintCandidate{
		{Artist: "TestArtist", Album: "ExpectedAlbum"},
	}
	storeAppleAlbumHintResult(key, testCands, true)

	wg.Wait()

	for i, res := range results {
		if res != "ExpectedAlbum" {
			t.Errorf("waiter %d got %q, want ExpectedAlbum", i, res)
		}
	}
}
