package main

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"testing"
)

const (
	anchorMedleyID = int64(1485220321)
	anchorNextID   = int64(1485220325)
	anchorAlbum    = "周杰伦地表最强世界巡回演唱会 (Live)"
)

func seedAnchorCache(t *testing.T) {
	t.Helper()
	appleCatalogMu.Lock()
	defer appleCatalogMu.Unlock()
	appleCatalogPath = ""
	appleCatalogCache = map[string]appleCatalogTrack{
		fmt.Sprint(anchorMedleyID): {
			TrackName: "枫+退后+搁浅 (Live)", ArtistName: "南拳妈妈弹头",
			AlbumArtist: "周杰伦", AlbumName: "周杰伦地表最强世界巡回演唱会 (Live)",
			AlbumID: 1485220306, DurationSecs: 119.213,
		},
		fmt.Sprint(anchorNextID): {
			TrackName: "印地安老斑鸠 (Live)", ArtistName: "周杰伦",
			AlbumName: "周杰伦地表最强世界巡回演唱会 (Live)",
			AlbumID:   1485220306, DurationSecs: 208.293,
		},
	}
	appleCatalogByTrack = map[string]appleCatalogTrack{}
	appleCatalogInflight = map[int64]bool{}
	appleCatalogMisses = map[int64]int{}
}

func TestAppleCatalogPlausibleID(t *testing.T) {
	cases := []struct {
		id   int64
		want bool
		why  string
	}{
		{1485220321, true, "真实目录 ID"},
		{1485220325, true, "真实目录 ID"},
		{-3446272063698972557, false, "本地导入曲目的持久 ID(实测负数,lookup 直接 400)"},
		{3446272063698972557, false, "上面那个取绝对值——防'顺手 abs 一下'的错误实现"},
		{0, false, "字段缺省"},
		{-1, false, "负数"},
	}
	for _, c := range cases {
		if got := appleCatalogPlausibleID(c.id); got != c.want {
			t.Errorf("appleCatalogPlausibleID(%d) = %v, want %v —— %s", c.id, got, c.want, c.why)
		}
	}
}

func TestAppleCatalogAnchorGuards(t *testing.T) {
	seedAnchorCache(t)

	got, ok := appleCatalogAnchor(appleMusicBundleID, anchorMedleyID, 0, "枫+退后+搁浅 (Live)", anchorAlbum)
	if !ok {
		t.Fatalf("基准情形应拿到锚点")
	}
	if got.DurationSecs != 119.213 {
		t.Errorf("权威时长 = %v, want 119.213", got.DurationSecs)
	}
	if got.AlbumArtist != "周杰伦" {
		t.Errorf("专辑署名 = %q, want 周杰伦", got.AlbumArtist)
	}

	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorNextID, 0, "枫+退后+搁浅 (Live)", anchorAlbum); ok {
		t.Errorf("曲目名对不上时不该拿到锚点(这正是脏快照的形态)")
	}

	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorMedleyID, 0, "枫+退后+搁浅 (Live)", "叶惠美"); ok {
		t.Errorf("专辑名对不上时不该拿到锚点")
	}

	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorMedleyID, 0, "枫+退后+搁浅 (Live)", ""); !ok {
		t.Errorf("本地专辑标签为空时应只校曲目名并通过")
	}

	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorMedleyID, 0, "", anchorAlbum); ok {
		t.Errorf("本地标题为空时不该拿到锚点")
	}
	if _, ok := appleCatalogAnchor(appleMusicBundleID, -3446272063698972557, 0, "枫+退后+搁浅 (Live)", anchorAlbum); ok {
		t.Errorf("本地持久 ID(负数)不该拿到锚点")
	}
}

func TestAppleCatalogAnchorCacheMissDoesNotBlock(t *testing.T) {
	seedAnchorCache(t)
	const unknown = int64(999999999)
	appleCatalogMu.Lock()
	appleCatalogMisses[unknown] = appleCatalogMaxMisses
	appleCatalogMu.Unlock()
	if _, ok := appleCatalogAnchor(appleMusicBundleID, unknown, 0, "某首歌", "某专辑"); ok {
		t.Errorf("缓存没命中时不该返回锚点")
	}
}

func TestAppleCatalogSearchIdentities(t *testing.T) {
	seedAnchorCache(t)

	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorMedleyID, 0, "枫+退后+搁浅 (Live)", anchorAlbum); !ok {
		t.Fatalf("准备阶段:锚点应成立")
	}

	got := appleCatalogSearchIdentities("南拳妈妈弹头", "枫+退后+搁浅 (Live)", anchorAlbum)
	if !reflect.DeepEqual(got, []string{"周杰伦"}) {
		t.Errorf("appleCatalogSearchIdentities = %#v, want [周杰伦]", got)
	}

	if got := appleCatalogSearchIdentities("周杰伦", "根本没播过的歌", "某专辑"); got != nil {
		t.Errorf("没有锚点时应返回 nil,得到 %#v", got)
	}

	if _, ok := appleCatalogAnchor(appleMusicBundleID, anchorNextID, 0, "印地安老斑鸠 (Live)", anchorAlbum); !ok {
		t.Fatalf("准备阶段:第二条锚点应成立")
	}
	if got := appleCatalogSearchIdentities("周杰伦", "印地安老斑鸠 (Live)", anchorAlbum); got != nil {
		t.Errorf("署名与本地一致时应返回 nil,得到 %#v", got)
	}
}

func TestAppleStorefrontArtistIdentitiesLive(t *testing.T) {

	got := appleStorefrontArtistIdentities(context.Background(), "方大同", "Lovers Policy", "15", 243.3, nil)
	found := false
	for _, s := range got {
		if normLoose(s) == normLoose("Khalil Fong") {
			found = true
		}
	}
	if !found {
		t.Fatalf("应该能从 US 商店拿到 Khalil Fong 这个身份, got %v", got)
	}
	if album := ""; appleStorefrontArtistIdentities(context.Background(), "方大同", "Lovers Policy", album, 243.3, nil) != nil {
		t.Errorf("没有专辑名时应返回 nil(这条技巧靠专辑名精确定位)")
	}
}

func TestAppleStorefrontCanonicalTitleLive(t *testing.T) {
	savedTitles := appleStorefrontTitleCache
	savedNames := appleStorefrontArtistCache
	defer func() {
		appleStorefrontTitleCache, appleStorefrontArtistCache = savedTitles, savedNames
	}()
	appleStorefrontTitleCache = map[string]string{}
	appleStorefrontArtistCache = map[string][]string{}

	const wantTitle = "クスシキ"

	samples := []string{"摩訶不思議だ　言霊は誠か\n偽ってる彼奴は　天に堕ちていった"}
	got := appleStorefrontCanonicalTitle(context.Background(),
		"Mrs. GREEN APPLE", "KUSUSHIKI", "KUSUSHIKI - Single", 188.348, samples)
	if normLoose(got) != normLoose(wantTitle) {
		t.Fatalf("应该能从 JP 商店拿回日文原名 %q, got %q", wantTitle, got)
	}

	names := appleStorefrontArtistIdentities(context.Background(),
		"Mrs. GREEN APPLE", "KUSUSHIKI", "KUSUSHIKI - Single", 188.348, samples)
	for _, n := range names {
		if normLoose(n) != normLoose("Mrs. GREEN APPLE") {
			t.Fatalf("这首歌各商店署名应该一致,却多出了 %q(全部: %v)", n, names)
		}
	}
}

func TestAppleStorefrontTitleCachePersistsEmptyResult(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/title-cache.json"
	savedCache, savedPath, savedDirty := appleStorefrontTitleCache, appleStorefrontTitlePath, appleStorefrontTitleDirty
	defer func() {
		appleStorefrontTitleCache, appleStorefrontTitlePath, appleStorefrontTitleDirty = savedCache, savedPath, savedDirty
	}()
	appleStorefrontTitlePath = path
	appleStorefrontTitleCache = map[string]string{
		"mrs green apple|kusushiki  single|kusushiki": "クスシキ",
		"某人|某专辑|本地写法就是规范的":                            "",
	}
	appleStorefrontTitleDirty = true
	saveAppleStorefrontTitleCache()

	appleStorefrontTitleCache = map[string]string{}
	loadAppleStorefrontTitleCache(path)
	if got := appleStorefrontTitleCache["mrs green apple|kusushiki  single|kusushiki"]; got != "クスシキ" {
		t.Errorf("日文原名应原样回来, got %q", got)
	}
	v, ok := appleStorefrontTitleCache["某人|某专辑|本地写法就是规范的"]
	if !ok || v != "" {
		t.Errorf("空串结论也要落盘(否则每首歌每次都重查), ok=%v v=%q", ok, v)
	}
}

func TestAppleStorefrontArtistCachePersistsOnlyHits(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/storefront.json"

	savedCache, savedPath, savedDirty := appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty
	defer func() {
		appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty = savedCache, savedPath, savedDirty
	}()

	appleStorefrontArtistPath = path
	appleStorefrontArtistCache = map[string][]string{
		"方大同|15":    {"Khalil Fong"},
		"某个没查到的|专辑": nil,
	}
	appleStorefrontArtistDirty = true
	saveAppleStorefrontArtistCache()

	appleStorefrontArtistCache = map[string][]string{}
	loadAppleStorefrontArtistCache(path)
	if got := appleStorefrontArtistCache["方大同|15"]; !reflect.DeepEqual(got, []string{"Khalil Fong"}) {
		t.Errorf("查到的那条没被持久化:got %v", got)
	}
	if _, ok := appleStorefrontArtistCache["某个没查到的|专辑"]; ok {
		t.Error("查空的那条落盘了 —— 一次偶发网络抖动会被永久钉死")
	}

	appleStorefrontArtistPath = ""
	appleStorefrontArtistDirty = true
	saveAppleStorefrontArtistCache()
}

func TestDedupeArtistIdentities(t *testing.T) {
	got := dedupeArtistIdentities(
		[]string{"周杰伦", ""},
		[]string{"Jay Chou", "周杰伦", "  周杰伦  "},
		nil,
	)
	if !reflect.DeepEqual(got, []string{"周杰伦", "Jay Chou"}) {
		t.Errorf("dedupeArtistIdentities = %#v, want [周杰伦 Jay Chou]", got)
	}
	if got := dedupeArtistIdentities(nil, nil); got != nil {
		t.Errorf("全空应返回 nil,得到 %#v", got)
	}
}

func TestAppleCatalogAnchorRejectsSiblingTracks(t *testing.T) {
	const albumXscape = "XSCAPE (Deluxe)"
	appleCatalogMu.Lock()
	appleCatalogPath = ""
	appleCatalogCache = map[string]appleCatalogTrack{

		"850697814": {TrackName: "Xscape (Original Version)", AlbumName: albumXscape, TrackNumber: 16, DurationSecs: 344.442},

		"850697815": {TrackName: "Love Never Felt So Good", AlbumName: albumXscape, TrackNumber: 17, DurationSecs: 245.671},

		"850697799": {TrackName: "Love Never Felt So Good", AlbumName: albumXscape, TrackNumber: 1, DurationSecs: 234.911},
	}
	appleCatalogByTrack = map[string]appleCatalogTrack{}
	appleCatalogInflight = map[int64]bool{}
	appleCatalogMisses = map[int64]int{}
	appleCatalogMu.Unlock()

	if _, ok := appleCatalogAnchor(appleMusicBundleID, 850697814, 8, "Xscape", albumXscape); ok {
		t.Errorf("「Xscape」不该被「Xscape (Original Version)」的锚点认领(差 99.5s)")
	}

	if _, ok := appleCatalogAnchor(appleMusicBundleID, 850697815, 1, "Love Never Felt So Good", albumXscape); ok {
		t.Errorf("本地是 #1、ID 指向 #17,序号对不上就该作废(234.911 vs 245.671)")
	}

	got, ok := appleCatalogAnchor(appleMusicBundleID, 850697799, 1, "Love Never Felt So Good", albumXscape)
	if !ok || got.DurationSecs != 234.911 {
		t.Errorf("序号对得上的正主应成立,得到 ok=%v dur=%v", ok, got.DurationSecs)
	}

	if _, ok := appleCatalogAnchor(appleMusicBundleID, 850697815, 0, "Love Never Felt So Good", albumXscape); !ok {
		t.Errorf("本地没有序号时应退回只校曲目名+专辑名")
	}
}

func TestPickAppleTitleSearchIdentities(t *testing.T) {
	results := []itunesResult{
		{TrackName: "Why You Wanna Treat Me So Bad?", ArtistName: "Prince", CollectionName: "The Hits/The B-Sides", TrackTimeMillis: 230121},
		{TrackName: "Why You Wanna Treat Me So Bad? (Live)", ArtistName: "Prince", TrackTimeMillis: 250000},
		{TrackName: "Why You Wanna Treat Me So Bad?", ArtistName: "Some Tribute Band", TrackTimeMillis: 199000},
		{TrackName: "Why You Wanna Treat Me So Bad?", ArtistName: "王子", TrackTimeMillis: 230000},
		{TrackName: "Why You Wanna Treat Me So Bad?", ArtistName: "prince", TrackTimeMillis: 230500},
		{TrackName: "Why You Wanna Treat Me So Bad?", ArtistName: "Prince & The Revolution", TrackTimeMillis: 231000},
		{TrackName: "Why You Wanna Treat Me So Bad?", ArtistName: "Third Artist", TrackTimeMillis: 229000},
	}
	got := pickAppleTitleSearchIdentities(results, "王子", "Why You Wanna Treat Me So Bad?", 230.121)
	want := []string{"Prince", "Prince & The Revolution"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("pick = %v, want %v", got, want)
	}

	sameScript := []itunesResult{
		{TrackName: "Outro", ArtistName: "Some Other Band", TrackTimeMillis: 184000},
		{TrackName: "Outro", ArtistName: "尾奏乐队", TrackTimeMillis: 184500},
	}
	if got := pickAppleTitleSearchIdentities(sameScript, "deca joins", "Outro", 184.16); !reflect.DeepEqual(got, []string{"尾奏乐队"}) {
		t.Errorf("同文字系统的同名艺人不该采、跨文字系统的才采, got %v", got)
	}
	if got := pickAppleTitleSearchIdentities([]itunesResult{{TrackName: "序曲", ArtistName: "某某", TrackTimeMillis: 94560}},
		"刘若英", "序曲", 94.56); len(got) != 0 {
		t.Errorf("中文本地署名对中文同名艺人不该采, got %v", got)
	}

	if got := pickAppleTitleSearchIdentities([]itunesResult{{TrackName: "Doxology", ArtistName: "A Covering", TrackTimeMillis: 47400}},
		"陶喆", "Doxology", 47.427); len(got) != 0 {
		t.Errorf("短于 %ds 的曲目不该采, got %v", appleTitleSearchMinDurationSecs, got)
	}

	if got := pickAppleTitleSearchIdentities([]itunesResult{{TrackName: "两只恋人", ArtistName: "Gary Chaw"}},
		"曹格", "两只恋人", 0); !reflect.DeepEqual(got, []string{"Gary Chaw"}) {
		t.Errorf("无时长时不套下限, got %v", got)
	}
	if !artistScriptDiffers("王子", "Prince") || !artistScriptDiffers("Michael Jackson", "迈克尔·杰克逊") ||
		artistScriptDiffers("deca joins", "Some Band") || artistScriptDiffers("周杰伦", "周杰倫") ||
		!artistScriptDiffers("Prince", "プリンス") || !artistScriptDiffers("BTS", "방탄소년단") {
		t.Error("artistScriptDiffers 的 CJK/非 CJK 判定不对")
	}

	if got := pickAppleTitleSearchIdentities(results, "王子", "Why You Wanna Treat Me So Bad?", 180); len(got) != 0 {
		t.Errorf("时长 180s 时不该采任何署名, got %v", got)
	}

	if got := pickAppleTitleSearchIdentities(results, "王子", "Why You Wanna Treat Me So Bad?", 0); !reflect.DeepEqual(got, []string{"Prince"}) {
		t.Errorf("无时长时只信第一条, got %v", got)
	}

	noDur := []itunesResult{{TrackName: "Hello", ArtistName: "Adele"}}
	if got := pickAppleTitleSearchIdentities(noDur, "某人", "Hello", 295); len(got) != 0 {
		t.Errorf("iTunes 未报时长时不该采, got %v", got)
	}

	if got := pickAppleTitleSearchIdentities(results, "王子", "", 230); len(got) != 0 {
		t.Errorf("空曲名不该采, got %v", got)
	}

	if tol := appleTitleSearchDurationTolerance(230.121); tol < 6.9 || tol > 6.91 {
		t.Errorf("230s 的容差应为 3%% ≈ 6.9s, got %v", tol)
	}
	if tol := appleTitleSearchDurationTolerance(60); tol != 4 {
		t.Errorf("60s 的容差应为下限 4s, got %v", tol)
	}
}

func TestAppleStorefrontTrackMatches(t *testing.T) {
	rothy := itunesResult{TrackName: "Happy End", ArtistName: "Rothy", TrackTimeMillis: 232400}
	jp := itunesResult{TrackName: "ハッピーエンド", ArtistName: "back number", TrackTimeMillis: 314100}
	other := itunesResult{TrackName: "Something Else", ArtistName: "back number", TrackTimeMillis: 314100}
	if appleStorefrontTrackMatches("Happy End", 314.279, rothy) {
		t.Error("同名不同歌:时长差 82s 必须挡住")
	}
	if !appleStorefrontTrackMatches("Happy End", 314.279, jp) {
		t.Error("同一录音的日文曲名 + 时长相等应放行")
	}
	if appleStorefrontTrackMatches("Happy End", 314.279, other) {
		t.Error("同文字系统、曲名不同、只是时长相等:不放行")
	}
	if !appleStorefrontTrackMatches("Lovers Policy", 243.3, itunesResult{TrackName: "情勝策略", TrackTimeMillis: 243300}) {
		t.Error("方大同《Lovers Policy》↔「情勝策略」:跨文字系统 + 时长相等应放行")
	}

	if !appleStorefrontTrackMatches("Happy End", 0, rothy) {
		t.Error("无时长时曲名相等应放行(没有别的证据可用)")
	}
	if appleStorefrontTrackMatches("Happy End", 0, jp) {
		t.Error("无时长时跨文字系统的曲名不能放行")
	}
	if appleStorefrontTrackMatches("", 314, jp) {
		t.Error("本地曲名为空不放行")
	}
}

func TestAppleStorefrontsFor(t *testing.T) {
	cases := []struct {
		name    string
		samples []string
		want    []string
	}{
		{"全拉丁字母", []string{"back number", "Happy End", "Happy End - EP"}, []string{"CN", "US"}},
		{"标签拉丁、歌词日文", []string{"back number", "Happy End", "Happy End - EP", "初めてのルーブルは なんてことはなかったわ"}, []string{"CN", "US", "JP"}},
		{"谚文", []string{"아이유", "밤편지"}, []string{"CN", "US", "KR"}},
		{"简体汉字不加", []string{"周杰伦", "七里香"}, []string{"CN", "US"}},
		{"繁体汉字加 TW", []string{"陶喆", "今天沒回家", "Soul Power 現場原音"}, []string{"CN", "US", "TW"}},
		{"西里尔 + 泰文各一个,最多加两个", []string{"Земфира", "ลูกทุ่ง", "アイドル"}, []string{"CN", "US", "RU", "TH"}},
		{"空样本", nil, []string{"CN", "US"}},
	}
	for _, c := range cases {
		if got := appleStorefrontsFor(c.samples...); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestAppleStorefrontArtistCacheDiscardsV1(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/storefront-v1.json"
	if err := os.WriteFile(path, []byte(`{"backnumber|happyendep":["Rothy"]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	savedCache, savedPath, savedDirty := appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty
	defer func() {
		appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty = savedCache, savedPath, savedDirty
	}()
	appleStorefrontArtistCache = map[string][]string{}
	loadAppleStorefrontArtistCache(path)
	if len(appleStorefrontArtistCache) != 0 {
		t.Fatalf("v1 条目不该被加载: %v", appleStorefrontArtistCache)
	}

	appleStorefrontArtistCache = map[string][]string{"方大同|15": {"Khalil Fong"}}
	appleStorefrontArtistDirty = true
	saveAppleStorefrontArtistCache()
	appleStorefrontArtistCache = map[string][]string{}
	loadAppleStorefrontArtistCache(path)
	if got := appleStorefrontArtistCache["方大同|15"]; !reflect.DeepEqual(got, []string{"Khalil Fong"}) {
		t.Fatalf("v2 回读失败: %v", appleStorefrontArtistCache)
	}
}
