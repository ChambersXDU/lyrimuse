package main

import (
	"os"
	"reflect"
	"testing"
)

func TestMBAliasCandidatesForRetry(t *testing.T) {
	weeknd := []mbAlias{
		{Name: "Abel Makkonen Tesfaye", Type: "Legal name", Locale: "en"},
		{Name: "Abel Tesfaye", Type: "Artist name", Locale: "en"},
		{Name: "The Weekend", Type: "Search hint"},
		{Name: "The Weeknd", Type: "Artist name", Locale: "en"},
		{Name: "The Weeknd feat. Playboi Carti"},
		{Name: "አቤል መኮንን ተስፋዬ", Type: "Artist name", Locale: "am"},
		{Name: "ザ・ウィークエンド", Type: "Artist name", Locale: "ja"},
	}
	cases := []struct {
		name    string
		primary string
		aliases []mbAlias
		raw     string
		want    []string
	}{
		{
			name:    "本名标签 → 换成艺名主名+其它同类型别名(真实案例)",
			primary: "The Weeknd", aliases: weeknd, raw: "Abel Tesfaye",
			want: []string{"The Weeknd", "አቤል መኮንን ተስፋዬ", "ザ・ウィークエンド"},
		},
		{
			name:    "大小写/空格差异照样算命中(normLoose 口径)",
			primary: "The Weeknd", aliases: weeknd, raw: "abel  TESFAYE",
			want: []string{"The Weeknd", "አቤል መኮንን ተስፋዬ", "ザ・ウィークエンド"},
		},
		{

			name:    "法定名也算证据 —— 这里只问「MB 认不认识这个写法」,不是挑展示名",
			primary: "The Weeknd", aliases: weeknd, raw: "Abel Makkonen Tesfaye",
			want: []string{"The Weeknd", "Abel Tesfaye", "አቤል መኮንን ተስፋዬ", "ザ・ウィークエンド"},
		},
		{

			name:    "拼错的搜索提示别名同样算命中(候选不受影响)",
			primary: "The Weeknd", aliases: weeknd, raw: "The Weekend",
			want: []string{"The Weeknd", "Abel Tesfaye", "አቤል መኮንን ተስፋዬ", "ザ・ウィークエンド"},
		},
		{
			name:    "本地标签已经是主名:主名本身被排除,只剩其它候选(不再整体返回空)",
			primary: "The Weeknd", aliases: weeknd, raw: "The Weeknd",
			want: []string{"Abel Tesfaye", "አቤል መኮንን ተስፋዬ", "ザ・ウィークエンド"},
		},
		{
			name:    "只是姓氏之类的部分命中:不认 —— 模糊搜到的人不能拿来当身份",
			primary: "The Weeknd", aliases: weeknd, raw: "Tesfaye", want: nil,
		},
		{
			name:    "本地标签压根不在这位艺人名下:不认",
			primary: "The Weeknd", aliases: weeknd, raw: "Drake", want: nil,
		},
		{
			name:    "主名为空:不认",
			primary: "", aliases: weeknd, raw: "Abel Tesfaye", want: nil,
		},
		{
			name:    "本地标签为空:不认",
			primary: "The Weeknd", aliases: weeknd, raw: "", want: nil,
		},
		{
			name:    "一条别名都没有、且主名跟本地标签不同:没有任何证据证明 raw 是这个人,不认",
			primary: "The Weeknd", aliases: nil, raw: "Abel Tesfaye", want: nil,
		},
	}
	for _, c := range cases {
		got := mbAliasCandidatesForRetry(c.primary, c.aliases, c.raw)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: mbAliasCandidatesForRetry(%q, …, %q) = %v, want %v",
				c.name, c.primary, c.raw, got, c.want)
		}
	}
}

func TestMBAliasCandidatesForRetryPrimaryEqualsRawStillReturnsOtherAliases(t *testing.T) {
	aliases := []mbAlias{
		{Name: "方大同", Type: "Artist name", Locale: "zh"},
		{Name: "Khalil Fong Tai Tung", Type: "Legal name", Locale: "en"},
		{Name: "Khalil Fong", Type: "Artist name", Locale: "en"},
	}
	got := mbAliasCandidatesForRetry("方大同", aliases, "方大同")
	want := []string{"Khalil Fong"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestMBPrimaryNameCachePersistsOnlyHits(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/primary.json"

	savedCache, savedPath, savedDirty := mbPrimaryNameCache, mbPrimaryNamePath, mbPrimaryNameDirty
	defer func() {
		mbPrimaryNameCache, mbPrimaryNamePath, mbPrimaryNameDirty = savedCache, savedPath, savedDirty
	}()

	mbPrimaryNamePath = path
	mbPrimaryNameCache = map[string][]string{
		"Abel Tesfaye": {"The Weeknd"},
		"Nobody Here":  nil,
	}
	mbPrimaryNameDirty = true
	saveMBPrimaryNameCache()

	mbPrimaryNameCache = map[string][]string{}
	loadMBPrimaryNameCache(path)
	if got := mbPrimaryNameCache["Abel Tesfaye"]; !reflect.DeepEqual(got, []string{"The Weeknd"}) {
		t.Errorf("查到的那条没被持久化:got %v", got)
	}
	if _, ok := mbPrimaryNameCache["Nobody Here"]; ok {
		t.Error("查空的那条落盘了 —— 一次偶发限速会被永久钉死")
	}

	mbPrimaryNamePath = ""
	mbPrimaryNameDirty = true
	saveMBPrimaryNameCache()
}

func TestMBPrimaryNameCacheLoadsLegacyFormat(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/primary.json"
	legacy := `{"Abel Tesfaye":"The Weeknd","Khalil Fong":"方大同"}`
	if err := os.WriteFile(path, []byte(legacy), 0o644); err != nil {
		t.Fatal(err)
	}

	savedCache, savedPath, savedDirty := mbPrimaryNameCache, mbPrimaryNamePath, mbPrimaryNameDirty
	defer func() {
		mbPrimaryNameCache, mbPrimaryNamePath, mbPrimaryNameDirty = savedCache, savedPath, savedDirty
	}()

	mbPrimaryNameCache = map[string][]string{}
	loadMBPrimaryNameCache(path)
	if got := mbPrimaryNameCache["Abel Tesfaye"]; !reflect.DeepEqual(got, []string{"The Weeknd"}) {
		t.Errorf("旧格式没有被正确迁移:got %v", got)
	}
	if got := mbPrimaryNameCache["Khalil Fong"]; !reflect.DeepEqual(got, []string{"方大同"}) {
		t.Errorf("旧格式没有被正确迁移:got %v", got)
	}
}
