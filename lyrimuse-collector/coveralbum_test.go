package main

import (
	"testing"
	"time"
)

func TestPreferAppleCoverOverNetease(t *testing.T) {
	const cover = "https://is1-ssl.mzstatic.com/…/600x600bb.jpg"
	cases := []struct {
		name                        string
		neAlbum, appAlbum, appCover string
		local                       string
		want                        bool
	}{
		{
			name:    "网易云给的是单曲版、Apple 给的是这张专辑:换成 Apple(真实案例)",
			neAlbum: "Deadman", appAlbum: "KUN", appCover: cover, local: "KUN", want: true,
		},
		{
			name:    "网易云本来就对得上这张专辑:不动",
			neAlbum: "KUN", appAlbum: "KUN", appCover: cover, local: "KUN", want: false,
		},
		{
			name:    "Apple 那张也是单曲版:不换 —— 换了不解决问题,还丢掉国内可加载的图源",
			neAlbum: "Deadman", appAlbum: "Deadman - Single", appCover: cover, local: "KUN", want: false,
		},
		{
			name:    "Apple 压根没给封面:不换",
			neAlbum: "Deadman", appAlbum: "KUN", appCover: "", local: "KUN", want: false,
		},
		{
			name:    "本地没有专辑标签:不换 —— 对不对版无从判断,不能拿判不出来的条件掀掉已有封面",
			neAlbum: "Deadman", appAlbum: "KUN", appCover: cover, local: "", want: false,
		},
		{
			name:    "只是写法宽松不同(繁简/带副标题):算对得上,不换",
			neAlbum: "神经志", appAlbum: "神經志 The Journal", appCover: cover,
			local: "神經志 The Journal", want: false,
		},
	}
	for _, c := range cases {
		if got := preferAppleCoverOverNetease(c.neAlbum, c.appAlbum, c.appCover, c.local); got != c.want {
			t.Errorf("%s: preferAppleCoverOverNetease = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestCoverNeedsAlbumCheck(t *testing.T) {
	cases := []struct {
		name  string
		e     enrichEntry
		album string
		want  bool
	}{
		{
			name:  "老条目(网易云封面、cover_album 不详):补查一次",
			e:     enrichEntry{CoverSource: "netease", CoverURL: "u"},
			album: "KUN", want: true,
		},
		{
			name:  "明确对不上这张专辑:补查",
			e:     enrichEntry{CoverSource: "netease", CoverURL: "u", CoverAlbum: "Deadman"},
			album: "KUN", want: true,
		},
		{
			name:  "对得上:不查",
			e:     enrichEntry{CoverSource: "netease", CoverURL: "u", CoverAlbum: "KUN"},
			album: "KUN", want: false,
		},
		{

			name:  "只是宽松包含(100 分,版本后缀被当成子串忽略):也要补查,不是真的对上版",
			e:     enrichEntry{CoverSource: "netease", CoverURL: "u", CoverAlbum: "JTW西游记"},
			album: "JTW 西游记 (Gold) [Explicit]", want: true,
		},
		{
			name:  "Apple 那档不查(本来就是按 albumScore 择优选的)",
			e:     enrichEntry{CoverSource: "apple", CoverURL: "u"},
			album: "KUN", want: false,
		},
		{
			name:  "QQ 那档不查(qqCoverFallback 内部已避开精选集)",
			e:     enrichEntry{CoverSource: "qq", CoverURL: "u"},
			album: "KUN", want: false,
		},
		{
			name:  "本地没有专辑标签:不查",
			e:     enrichEntry{CoverSource: "netease", CoverURL: "u"},
			album: "", want: false,
		},
	}
	for _, c := range cases {
		if got := coverNeedsAlbumCheck(c.e, c.album); got != c.want {
			t.Errorf("%s: coverNeedsAlbumCheck = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestNeedsPeripheralBackfillCoversAlbumMismatch(t *testing.T) {
	long := time.Now().Unix() - int64(enrichPeripheralRetryInterval/time.Second) - 1
	full := enrichEntry{
		AccentColor: "#fff", AppleURL: "a", QQURL: "q", NeteaseURL: "n",
		CanonicalArtist: "蔡徐坤", TS: long,
		CoverURL:    "https://p1.music.126.net/…/1.jpg",
		CoverSource: "netease",
	}
	if !needsPeripheralBackfill(full, "蔡徐坤", "KUN") {
		t.Error("字段齐全但封面专辑不详的老条目该补查一次")
	}
	matched := full
	matched.CoverAlbum = "KUN"
	if needsPeripheralBackfill(matched, "蔡徐坤", "KUN") {
		t.Error("封面已经确认对得上这张专辑,不该再补")
	}
	offAlbum := full
	offAlbum.CoverAlbum = "Deadman"
	if !needsPeripheralBackfill(offAlbum, "蔡徐坤", "KUN") {
		t.Error("封面明确属于另一次发行,该补")
	}

	capped := offAlbum
	capped.PeripheralRetryCount = peripheralBackfillMaxAttempts
	if needsPeripheralBackfill(capped, "蔡徐坤", "KUN") {
		t.Error("重试次数用尽后不该再补")
	}
}

func TestCoverSwapAllowed(t *testing.T) {
	oldNetease := enrichEntry{
		CoverURL: "https://p1.music.126.net/…/1.jpg", CoverSource: "netease", CoverAlbum: "KUN",
	}
	cases := []struct {
		name       string
		old, fresh enrichEntry
		album      string

		upgradable bool
		want       bool
	}{
		{
			name:  "这一轮没拿到封面:不换(防抖动抹空)",
			old:   oldNetease,
			fresh: enrichEntry{},
			album: "KUN", want: false,
		},
		{
			name:  "本来就没有封面:补上",
			old:   enrichEntry{},
			fresh: enrichEntry{CoverURL: "x", CoverSource: "apple", CoverAlbum: "KUN"},
			album: "KUN", want: true,
		},
		{
			name:  "同源刷新:换(顺带把 cover_album 补上)",
			old:   enrichEntry{CoverURL: "old", CoverSource: "netease"},
			fresh: enrichEntry{CoverURL: "new", CoverSource: "netease", CoverAlbum: "KUN", NeteaseURL: "n"},
			album: "KUN", want: true,
		},
		{
			name:  "跨源 + 网易云应答过 + 新封面对得上专辑:换(这正是那三首的修法)",
			old:   enrichEntry{CoverURL: "old", CoverSource: "netease", CoverAlbum: "Deadman"},
			fresh: enrichEntry{CoverURL: "new", CoverSource: "apple", CoverAlbum: "KUN", NeteaseURL: "n"},
			album: "KUN", want: true,
		},
		{
			name:  "跨源但网易云这一轮没应答(疑似限流):不换",
			old:   oldNetease,
			fresh: enrichEntry{CoverURL: "new", CoverSource: "apple", CoverAlbum: "KUN"},
			album: "KUN", want: false,
		},
		{
			name:  "跨源、网易云应答了,但新封面也对不上专辑:不换",
			old:   enrichEntry{CoverURL: "old", CoverSource: "netease", CoverAlbum: "Deadman"},
			fresh: enrichEntry{CoverURL: "new", CoverSource: "apple", CoverAlbum: "Deadman - Single", NeteaseURL: "n"},
			album: "KUN", want: false,
		},
		{

			name:  "跨源到 QQ:即使没有 NeteaseURL/CoverAlbum 也换(qqCoverFallback 自己已经把关)",
			old:   enrichEntry{CoverURL: "old", CoverSource: "netease", CoverAlbum: "JTW西游记"},
			fresh: enrichEntry{CoverURL: "new", CoverSource: "qq"},
			album: "JTW 西游记 (Gold) [Explicit]", want: true,
		},
		{

			name:  "旧封面来自device且不可升级:哪怕新结果来自QQ也不换",
			old:   enrichEntry{CoverURL: "device.jpg", CoverSource: "device", CoverAlbum: "Immortal"},
			fresh: enrichEntry{CoverURL: "wrong.jpg", CoverSource: "qq"},
			album: "Immortal", want: false,
		},
		{
			name:  "旧封面来自device且不可升级:哪怕新结果对得上专辑也不换",
			old:   enrichEntry{CoverURL: "device.jpg", CoverSource: "device", CoverAlbum: "Immortal"},
			fresh: enrichEntry{CoverURL: "new.jpg", CoverSource: "apple", CoverAlbum: "Immortal", NeteaseURL: "n"},
			album: "Immortal", want: false,
		},
		{

			name:  "旧封面来自device但可升级:换",
			old:   enrichEntry{CoverURL: "device.jpg", CoverSource: "device", CoverAlbum: "24K Magic"},
			fresh: enrichEntry{CoverURL: "big.jpg", CoverSource: "netease", CoverAlbum: "24K Magic", NeteaseURL: "n"},
			album: "24K Magic", upgradable: true, want: true,
		},
	}
	for _, c := range cases {

		saved := deviceCoverUpgradable
		upgradable := c.upgradable
		deviceCoverUpgradable = func(string, string) bool { return upgradable }
		got := coverSwapAllowed(c.old, c.fresh, c.album)
		deviceCoverUpgradable = saved
		if got != c.want {
			t.Errorf("%s: coverSwapAllowed = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestSiblingAlbumCover(t *testing.T) {
	savedCache := enrichCache
	defer func() { enrichCache = savedCache }()

	const album = "JTW 西游记 (Gold) [Explicit]"
	enrichCache = map[string]enrichEntry{
		"方大同|很不低调|" + album: {CoverURL: "https://qq/right.jpg", CoverSource: "qq"},

		"方大同|放不过自己|" + album: {CoverURL: "https://netease/loose.jpg", CoverSource: "netease", CoverAlbum: "JTW 西游记 (Gold)"},

		"某歌手|同名曲|" + album: {CoverURL: "https://qq/wrong-artist.jpg", CoverSource: "qq"},

		"方大同|烦|JTW西游记": {CoverURL: "https://qq/wrong-album.jpg", CoverSource: "qq"},
	}

	url, source, verified := siblingAlbumCover("方大同", "Once", album)
	if url != "https://qq/right.jpg" || source != "qq" {
		t.Errorf("siblingAlbumCover = (%q, %q), want (https://qq/right.jpg, qq)", url, source)
	}

	if verified {
		t.Error("借来的 qq 封面不该报 albumVerified —— 那会让调用方盖上 cover_album,凭空造出一条归属证据")
	}

	enrichCache = map[string]enrichEntry{
		"方大同|放不过自己|" + album: {CoverURL: "https://netease/loose.jpg", CoverSource: "netease", CoverAlbum: "JTW 西游记 (Gold)"},
	}
	if url, _, _ := siblingAlbumCover("方大同", "Once", album); url != "" {
		t.Errorf("没有 qq 定案的邻居时不该借到东西,got %q", url)
	}
}

func TestSiblingAlbumCoverPrefersDeviceSibling(t *testing.T) {
	savedCache := enrichCache
	defer func() { enrichCache = savedCache }()

	const album = "Michael"
	deviceCover := "file:///Users/x/.config/lyrimuse/artwork/abc.jpg"
	enrichCache = map[string]enrichEntry{

		"Michael Jackson|Hollywood Tonight|" + album: {CoverURL: deviceCover, CoverSource: "device", CoverAlbum: album},

		"Michael Jackson|Much Too Soon|" + album: {CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq"},
	}
	url, source, verified := siblingAlbumCover("Michael Jackson", "Hold My Hand", album)
	if url != deviceCover || source != "device" || !verified {
		t.Errorf("siblingAlbumCover = (%q, %q, %v), want (%q, device, true) —— device 邻居该赢过 qq 邻居",
			url, source, verified, deviceCover)
	}

	enrichCache = map[string]enrichEntry{
		"Michael Jackson|Hollywood Tonight|" + album: {CoverURL: deviceCover, CoverSource: "device"},
		"Michael Jackson|Much Too Soon|" + album:     {CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq"},
	}
	url, source, verified = siblingAlbumCover("Michael Jackson", "Hold My Hand", album)
	if url != "https://qq/ultimate.jpg" || source != "qq" || verified {
		t.Errorf("siblingAlbumCover = (%q, %q, %v), want (https://qq/ultimate.jpg, qq, false)", url, source, verified)
	}

	enrichCache = map[string]enrichEntry{
		"Michael Jackson|Hollywood Tonight|" + album: {CoverURL: "https://netease/exact.jpg", CoverSource: "netease", CoverAlbum: album},
		"Michael Jackson|Best of Joy|" + album:       {CoverURL: "https://apple/exact.jpg", CoverSource: "apple", CoverAlbum: album},
	}
	if url, _, _ := siblingAlbumCover("Michael Jackson", "Hold My Hand", album); url != "" {
		t.Errorf("netease/apple 的已核实邻居不该被借用,got %q", url)
	}
}

func TestSiblingAlbumCoverIsDeterministic(t *testing.T) {
	savedCache := enrichCache
	defer func() { enrichCache = savedCache }()

	const album = "同一张专辑"
	enrichCache = map[string]enrichEntry{
		"某歌手|甲|" + album: {CoverURL: "https://qq/a.jpg", CoverSource: "qq"},
		"某歌手|乙|" + album: {CoverURL: "https://qq/b.jpg", CoverSource: "qq"},
		"某歌手|丙|" + album: {CoverURL: "https://qq/c.jpg", CoverSource: "qq"},
	}
	first, _, _ := siblingAlbumCover("某歌手", "丁", album)
	if first == "" {
		t.Fatal("该借到一张 qq 邻居的图")
	}
	for i := 0; i < 30; i++ {
		if got, _, _ := siblingAlbumCover("某歌手", "丁", album); got != first {
			t.Fatalf("第 %d 次借到的是 %q,跟第一次的 %q 不一样 —— 借用结果必须跟 map 迭代顺序无关", i+1, got, first)
		}
	}
}

func TestCoverCanUpgradeToVerifiedSibling(t *testing.T) {
	savedCache := enrichCache
	defer func() { enrichCache = savedCache }()

	const album = "Michael"
	deviceSibling := map[string]enrichEntry{
		"Michael Jackson|Hollywood Tonight|" + album: {
			CoverURL: "file:///Users/x/.config/lyrimuse/artwork/abc.jpg", CoverSource: "device", CoverAlbum: album,
		},
	}
	qqStamped := enrichEntry{CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq"}

	enrichCache = deviceSibling
	if !coverCanUpgradeToVerifiedSiblingLocked(qqStamped, "Michael Jackson", album) {
		t.Error("qq 档 + 同专辑有 device 已核实邻居 → 该补一次重解析")
	}

	if coverCanUpgradeToVerifiedSiblingLocked(
		enrichEntry{CoverURL: "u", CoverSource: "apple", CoverAlbum: album}, "Michael Jackson", album) {
		t.Error("cover_album 已经逐字对上的条目不该被判成缺")
	}

	if coverCanUpgradeToVerifiedSiblingLocked(
		enrichEntry{CoverURL: "u", CoverSource: "device"}, "Michael Jackson", album) {
		t.Error("device 档不该被判成缺")
	}
	if coverCanUpgradeToVerifiedSiblingLocked(qqStamped, "Michael Jackson", "") {
		t.Error("本地没有专辑标签时判不出来,不该补查")
	}

	enrichCache = map[string]enrichEntry{
		"Michael Jackson|Much Too Soon|" + album: {CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq"},
	}
	if coverCanUpgradeToVerifiedSiblingLocked(qqStamped, "Michael Jackson", album) {
		t.Error("同专辑没有归属可外借的邻居时不该补查 —— 重解析拿不到更好的答案,只会白重试满 5 次")
	}
}

func TestCoverSwapAllowedAcceptsBorrowedDeviceCover(t *testing.T) {
	const album = "Michael"
	old := enrichEntry{CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq"}
	fresh := enrichEntry{
		CoverURL: "file:///Users/x/.config/lyrimuse/artwork/abc.jpg", CoverSource: "device", CoverAlbum: album,
	}
	if !coverSwapAllowed(old, fresh, album) {
		t.Error("借来的 device 封面该被接受 —— 它不带 NeteaseURL,旧判据会把它永远拦在缓存外")
	}

	saved := deviceCoverUpgradable
	defer func() { deviceCoverUpgradable = saved }()
	deviceCoverUpgradable = func(string, string) bool { return false }
	oldDevice := enrichEntry{CoverURL: "file:///Users/x/.config/lyrimuse/artwork/old.jpg", CoverSource: "device", CoverAlbum: album}
	if coverSwapAllowed(oldDevice, fresh, album) {
		t.Error("old 是 device 时必须先过 deviceCoverUpgradable,不该被新加的 fresh-device 档绕过")
	}
}

func TestMigrateBorrowedCoverAlbums(t *testing.T) {
	savedCache := enrichCache
	defer func() { enrichCache = savedCache }()

	enrichCache = map[string]enrichEntry{

		"Michael Jackson|Hold My Hand|Michael": {CoverURL: "https://qq/ultimate.jpg", CoverSource: "qq", CoverAlbum: "Michael"},

		"某歌手|甲|某专辑": {CoverURL: "https://qq/a.jpg", CoverSource: "qq"},

		"某歌手|乙|某专辑": {CoverURL: "file:///x/artwork/b.jpg", CoverSource: "device", CoverAlbum: "某专辑"},
		"某歌手|丙|某专辑": {CoverURL: "https://netease/c.jpg", CoverSource: "netease", CoverAlbum: "某专辑"},
		"某歌手|丁|某专辑": {CoverURL: "https://apple/d.jpg", CoverSource: "apple", CoverAlbum: "某专辑"},
	}
	migrateBorrowedCoverAlbums()
	if got := enrichCache["Michael Jackson|Hold My Hand|Michael"].CoverAlbum; got != "" {
		t.Errorf("被盖过章的 qq 条目该被擦掉 cover_album, got %q", got)
	}

	if got := enrichCache["Michael Jackson|Hold My Hand|Michael"].CoverURL; got != "https://qq/ultimate.jpg" {
		t.Errorf("迁移不该动 cover_url, got %q", got)
	}
	for _, k := range []string{"某歌手|乙|某专辑", "某歌手|丙|某专辑", "某歌手|丁|某专辑"} {
		if enrichCache[k].CoverAlbum != "某专辑" {
			t.Errorf("%s 的 cover_album 是真的,不该被擦", k)
		}
	}

	before := enrichCache["某歌手|甲|某专辑"]
	migrateBorrowedCoverAlbums()
	after := enrichCache["某歌手|甲|某专辑"]
	if after.CoverURL != before.CoverURL || after.CoverSource != before.CoverSource ||
		after.CoverAlbum != before.CoverAlbum {
		t.Error("第二遍迁移不该改动任何条目")
	}
}
