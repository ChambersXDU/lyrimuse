package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

func allLyricSourceConstants() []string {
	return []string{
		lyricSourceNetease, lyricSourceQQ, lyricSourceKugou,
		lyricSourceMusixmatch, lyricSourceLRCLIB, lyricSourceAMLL, lyricSourceLyricFind,
		lyricSourceKuwo, lyricSourceMigu, lyricSourceDeezer,
	}
}

func TestEveryLyricSourceIsRegistered(t *testing.T) {
	all := allLyricSourceConstants()

	inNames := map[string]bool{}
	for _, s := range lyricSourceNames {
		inNames[s] = true
	}
	for _, s := range all {
		if !inNames[s] {
			t.Errorf("源 %q 不在 lyricSourceNames 里(进度分母会少算、收集循环也读它)", s)
		}
	}
	if len(lyricSourceNames) != len(all) {
		t.Errorf("lyricSourceNames 有 %d 个,源常量有 %d 个,对不上", len(lyricSourceNames), len(all))
	}

	inOrder := map[string]bool{}
	for _, s := range lyricsSourceDefaultOrder {
		inOrder[s] = true
	}
	for _, s := range all {
		if !inOrder[s] {
			t.Errorf("源 %q 不在 lyricsSourceDefaultOrder 里", s)
		}
	}

	full := resolveLyricsSources(nil, nil, nil, nil, nil, nil)
	for _, s := range all {
		if !full[s] {
			t.Errorf("源 %q 不在 resolveLyricsSources 的全集兜底里(全新安装会禁用它)", s)
		}
	}

	old := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, nil, nil)
	if !old[lyricSourceAMLL] {
		t.Error("老配置(amll_lyrics 缺失)应当把 amll 补进启用集合")
	}
	if !old[lyricSourceLyricFind] {
		t.Error("老配置(lyricfind_lyrics 缺失)应当把 lyricfind 补进启用集合——这正是 2026-08-25 实测复现过的那个 bug")
	}
	if !old[lyricSourceKuwo] {
		t.Error("老配置(kuwo_lyrics 缺失)应当把 kuwo 补进启用集合")
	}
	if !old[lyricSourceMigu] {
		t.Error("老配置(migu_lyrics 缺失)应当把 migu 补进启用集合")
	}
	if !old[lyricSourceDeezer] {
		t.Error("老配置(deezer_lyrics 缺失)应当把 deezer 补进启用集合")
	}
	no := false
	statedAMLL := resolveLyricsSources([]string{"netease", "qq"}, &no, nil, nil, nil, nil)
	if statedAMLL[lyricSourceAMLL] {
		t.Error("用户已表态(amll_lyrics=false)时不该再把 amll 补回来")
	}
	if !statedAMLL[lyricSourceLyricFind] {
		t.Error("amll 已表态不影响 lyricfind 的迁移——lyricfind_lyrics 仍缺失时应该照常补它")
	}
	if !statedAMLL[lyricSourceKuwo] {
		t.Error("amll 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	statedLF := resolveLyricsSources([]string{"netease", "qq"}, nil, &no, nil, nil, nil)
	if statedLF[lyricSourceLyricFind] {
		t.Error("用户已表态(lyricfind_lyrics=false)时不该再把 lyricfind 补回来")
	}
	if !statedLF[lyricSourceAMLL] {
		t.Error("lyricfind 已表态不影响 amll 的迁移——amll_lyrics 仍缺失时应该照常补它")
	}
	if !statedLF[lyricSourceKuwo] {
		t.Error("lyricfind 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	statedKuwo := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, &no, nil, nil)
	if statedKuwo[lyricSourceKuwo] {
		t.Error("用户已表态(kuwo_lyrics=false)时不该再把 kuwo 补回来")
	}
	if !statedKuwo[lyricSourceAMLL] {
		t.Error("kuwo 已表态不影响 amll 的迁移——amll_lyrics 仍缺失时应该照常补它")
	}
	if !statedKuwo[lyricSourceLyricFind] {
		t.Error("kuwo 已表态不影响 lyricfind 的迁移——lyricfind_lyrics 仍缺失时应该照常补它")
	}
	if !statedKuwo[lyricSourceMigu] {
		t.Error("kuwo 已表态不影响 migu 的迁移——migu_lyrics 仍缺失时应该照常补它")
	}
	statedMigu := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, &no, nil)
	if statedMigu[lyricSourceMigu] {
		t.Error("用户已表态(migu_lyrics=false)时不该再把 migu 补回来")
	}
	if !statedMigu[lyricSourceKuwo] {
		t.Error("migu 已表态不影响 kuwo 的迁移——kuwo_lyrics 仍缺失时应该照常补它")
	}
	if !statedMigu[lyricSourceDeezer] {
		t.Error("migu 已表态不影响 deezer 的迁移——deezer_lyrics 仍缺失时应该照常补它")
	}
	statedDeezer := resolveLyricsSources([]string{"netease", "qq"}, nil, nil, nil, nil, &no)
	if statedDeezer[lyricSourceDeezer] {
		t.Error("用户已表态(deezer_lyrics=false)时不该再把 deezer 补回来")
	}
	if !statedDeezer[lyricSourceMigu] {
		t.Error("deezer 已表态不影响 migu 的迁移——migu_lyrics 仍缺失时应该照常补它")
	}
}

func TestLyricSourceCollectLoopTracksSourceCount(t *testing.T) {
	raw, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatalf("读不到 enrich.go: %v", err)
	}
	body := string(raw)
	for _, want := range []string{

		"for i := 0; i < len(lyricSourceNames)+1; i++ {",

		"make(chan lyricSourceResult, len(lyricSourceNames)+1)",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("enrich.go 里没找到 %q —— 这两处必须跟源数联动,写死字面量会在下次加源时静默丢结果", want)
		}
	}

	if m := regexp.MustCompile(`for i := 0; i < \d+; i\+\+`).FindString(body); m != "" {
		t.Errorf("enrich.go 里出现了写死次数的循环 %q —— 见本测试头注那个丢结果的坑", m)
	}
}

func TestSwiftLyricsSourceEnumCoversAllSources(t *testing.T) {
	const p = "../lyrimuse/Sources/lyrimuse/Settings/FeatureSettingsStore.swift"
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("读不到 %s: %v", p, err)
	}

	re := regexp.MustCompile(`(?s)public enum LyricsSource: String.*?\n\s*case\s+([^\n]+)`)
	m := re.FindStringSubmatch(string(raw))
	if m == nil {
		t.Fatalf("没在 %s 里找到 LyricsSource 的 case 行(枚举被改写了?同步更新这个测试)", p)
	}
	cases := map[string]bool{}
	for _, c := range strings.Split(m[1], ",") {
		cases[strings.TrimSpace(c)] = true
	}
	for _, s := range allLyricSourceConstants() {
		if !cases[s] {
			t.Errorf("Swift 侧 LyricsSource 枚举缺 %q —— 设置里的勾选框/顺序列表/搜索徽章都会漏掉它", s)
		}
	}
}

func TestSwiftSourceDisplayNameCoversAllSources(t *testing.T) {
	const p = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsManagerView.swift"
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("读不到 %s: %v", p, err)
	}
	body := string(raw)
	for _, s := range allLyricSourceConstants() {
		if !strings.Contains(body, `case "`+s+`": return`) {
			t.Errorf("Swift 侧 sourceDisplayName/sourceColor 缺 %q 的分支", s)
		}
	}
}

func TestSwiftSearchEmptyStateCountMatchesSourceCount(t *testing.T) {
	chineseDigits := map[int]string{5: "五", 6: "六", 7: "七", 8: "八", 9: "九", 10: "十"}
	n := len(allLyricSourceConstants())
	digit, ok := chineseDigits[n]
	if !ok {
		t.Fatalf("源数量是 %d,没有对应的中文数字——请在 chineseDigits 里补上再跑这个测试", n)
	}

	const p = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsSearchSheet.swift"
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("读不到 %s: %v", p, err)
	}
	body := string(raw)
	needles := []string{
		digit + `个源都没找到可用的候选`,
		digit + `个源的请求全部失败`,
	}
	for _, needle := range needles {
		if !strings.Contains(body, needle) {
			t.Errorf("在 %s 里没找到 %q——源数量是 %d(%s个),这两句空状态文案的数字要跟着改",
				p, needle, n, digit)
		}
	}
}

func TestDocsSourceCountMatchesSourceCount(t *testing.T) {
	chineseDigits := map[int]string{5: "五", 6: "六", 7: "七", 8: "八", 9: "九", 10: "十"}
	englishWords := map[int]string{5: "Five", 6: "Six", 7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten"}
	n := len(allLyricSourceConstants())
	zh, okZh := chineseDigits[n]
	en, okEn := englishWords[n]
	if !okZh || !okEn {
		t.Fatalf("源数量是 %d,没有对应的中英数字——请在两张表里补上再跑这个测试", n)
	}
	checks := []struct{ path, needle string }{
		{"../README.md", en + " lyrics sources checked automatically"},
		{"../README.md", "to the " + strings.ToLower(en) + " lyric sources above"},
		{"../README.zh-CN.md", "自动查" + zh + "个歌词源"},
		{"../README.zh-CN.md", "发给上面" + zh + "个歌词源"},
		{"../docs/features/01-overview.md", zh + "个歌词源:`music.163.com`"},
		{"../docs/features/01-overview.md", zh + "个歌词源(网易云/QQ/酷狗/"},
		{"../docs/features/09-lyrics-resolution.md", "### 3. " + zh + "源并发收集"},
		{"../docs/features/09-lyrics-resolution.md", "去" + zh + "个歌词源（"},
		{"../docs/features/14-settings-config.md", "歌词来源" + zh + "源勾选"},
		{"../docs/features/README.md", zh + "源检索、守卫"},
	}
	for _, c := range checks {
		raw, err := os.ReadFile(c.path)
		if err != nil {
			t.Errorf("读不到 %s: %v", c.path, err)
			continue
		}
		if !strings.Contains(string(raw), c.needle) {
			t.Errorf("%s 里没找到 %q——源数量是 %d,这处的数字要跟着改", c.path, c.needle, n)
		}
	}
}
