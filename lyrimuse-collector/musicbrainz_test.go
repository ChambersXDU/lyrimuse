package main

import (
	"context"
	"reflect"
	"testing"
)

func TestPickChineseAlias(t *testing.T) {

	mjAliases := []mbAlias{
		{Name: "迈克尔·杰克逊", Locale: "yue_Hans_CN"},
		{Name: "迈克尔·杰克逊", Locale: "zh_Hans"},
	}
	chanAliases := []mbAlias{
		{Name: "陈柏宇", Locale: "zh_Hans"},
		{Name: "陳柏宇", Locale: "zh_Hant"},
	}
	douAliases := []mbAlias{
		{Name: "窦靖童", Locale: "zh_Hans"},
	}

	cases := []struct {
		label   string
		aliases []mbAlias
		country string
		want    string
	}{

		{"美国艺人(Michael Jackson)的中文译名不采纳", mjAliases, "US", ""},
		{"英国艺人同理", mjAliases, "GB", ""},

		{"香港艺人(陈柏宇)采纳中文名", chanAliases, "HK", "陈柏宇"},
		{"大陆艺人(窦靖童)采纳中文名", douAliases, "CN", "窦靖童"},
		{"台湾/澳门/新加坡同属中文圈", chanAliases, "TW", "陈柏宇"},
		{"新加坡(华语歌手常见归属)", chanAliases, "SG", "陈柏宇"},

		{"country 缺失时不采纳", chanAliases, "", ""},

		{"country 小写也认", chanAliases, "hk", "陈柏宇"},
		{"country 带空白也认", chanAliases, " HK ", "陈柏宇"},

		{"繁体别名转简体", []mbAlias{{Name: "陳柏宇", Locale: "zh_Hant"}}, "HK", "陈柏宇"},

		{"日文 locale 别名跳过", []mbAlias{{Name: "日本語名", Locale: "ja"}}, "HK", ""},
		{"没有任何含汉字别名", []mbAlias{{Name: "Some Latin Name", Locale: "en"}}, "HK", ""},
		{"空别名列表", nil, "HK", ""},

		{"法定名别名跳过", []mbAlias{{Name: "陳奕凡", Locale: "zh_Hant", Type: "Legal name"}}, "TW", ""},
		{"搜索提示别名跳过", []mbAlias{{Name: "某搜索词", Type: "Search hint"}}, "TW", ""},
		{"跳过法定名后仍采纳后面的艺名", []mbAlias{
			{Name: "陳奕凡", Locale: "zh_Hant", Type: "Legal name"},
			{Name: "街巷", Locale: "zh_Hant", Type: "Artist name"},
		}, "TW", "街巷"},
	}
	for _, c := range cases {
		if got := pickChineseAlias(c.aliases, c.country); got != c.want {
			t.Errorf("%s: pickChineseAlias(...) = %q, want %q", c.label, got, c.want)
		}
	}
}

func TestArtistAliasCachePersistsOnlyHits(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/alias.json"

	savedCache, savedPath, savedDirty := artistAliasCache, artistAliasPath, artistAliasDirty
	defer func() {
		artistAliasCache, artistAliasPath, artistAliasDirty = savedCache, savedPath, savedDirty
	}()

	artistAliasPath = path
	artistAliasCache = map[string]string{
		"David Tao": "陶喆",
		"Na Ying":   "",
	}
	artistAliasDirty = true
	saveArtistAliasCache()

	artistAliasCache = map[string]string{}
	loadArtistAliasCache(path)
	if got := artistAliasCache["David Tao"]; got != "陶喆" {
		t.Errorf("查到的那条没被持久化:got %q", got)
	}
	if _, ok := artistAliasCache["Na Ying"]; ok {
		t.Error("查空的那条落盘了 —— 一次偶发限速会被永久钉死")
	}

	artistAliasPath = ""
	artistAliasDirty = true
	saveArtistAliasCache()
}

func TestCanonicalArtistViaMusicBrainzCacheHitSkipsNetwork(t *testing.T) {
	savedCache, savedPath, savedDirty := artistAliasCache, artistAliasPath, artistAliasDirty
	defer func() {
		artistAliasCache, artistAliasPath, artistAliasDirty = savedCache, savedPath, savedDirty
	}()

	artistAliasPath = ""
	artistAliasCache = map[string]string{"Cached Artist": "缓存艺人"}
	artistAliasDirty = false

	if got := canonicalArtistViaMusicBrainz(context.Background(), "Cached Artist"); got != "缓存艺人" {
		t.Errorf("缓存命中应直接返回,不该发起网络请求:got %q", got)
	}
	if !reflect.DeepEqual(artistAliasCache, map[string]string{"Cached Artist": "缓存艺人"}) {
		t.Errorf("缓存命中不该修改缓存内容:got %v", artistAliasCache)
	}
}

func TestResolveGenericArtistCanonicalNamePrefersHandTableOverGenericMisfire(t *testing.T) {
	savedQQCache, savedQQPath, savedQQDirty := qqArtistNameCache, qqArtistNamePath, qqArtistNameDirty
	savedAlias := artistAliasCache
	defer func() {
		qqArtistNameCache, qqArtistNamePath, qqArtistNameDirty = savedQQCache, savedQQPath, savedQQDirty
		artistAliasCache = savedAlias
	}()
	qqArtistNamePath = ""
	artistAliasCache = map[string]string{}

	qqArtistNameCache = map[string]string{"wanting": "婉婷"}

	if got := resolveGenericArtistCanonicalName(context.Background(), "wanting"); got != "曲婉婷" {
		t.Errorf("手工表应该优先于通用机制的(错误)结果:got %q, want 曲婉婷", got)
	}
}
