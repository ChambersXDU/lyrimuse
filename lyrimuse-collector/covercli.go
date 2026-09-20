package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
)

func runRecheckCoverCLI(args []string) {
	fs := flag.NewFlagSet("recheck-cover", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回缓存;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("recheck-cover: %v", err)
	}
	keys := fs.Args()
	if len(keys) == 0 {
		fmt.Fprintln(os.Stderr, `用法: collector recheck-cover [-apply] "歌手|歌名|专辑" ...`)
		fmt.Fprintln(os.Stderr, `key 就是"歌词管理"列表里那三段(enrich 缓存的 key),原样照抄。`)
		os.Exit(2)
	}

	if configDir() == "" {
		log.Fatalf("recheck-cover: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfgDir := configDir()

	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))

	if *apply && !ensureExclusiveForDedupe(cfgDir) {
		fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
		fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
		os.Exit(1)
	}
	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runRecheckCover(keys, *apply))
}

type recheckCoverPlan struct {
	key                         string
	found                       bool
	oldURL, oldSource, oldAlbum string
	newURL, newSource, newAlbum string
	newAccent                   string
	swap                        bool
	reason                      string
}

func planRecheckCover(key string) recheckCoverPlan {
	p := recheckCoverPlan{key: key}

	artist, title, album := splitEnrichKey(key)
	if title == "" {
		p.reason = `key 不是 "歌手|歌名|专辑" 三段`
		return p
	}
	enrichMu.Lock()
	e, exists := enrichCache[key]
	if !exists {

		if alt, found := canonicalEnrichKey(key); found {
			p.key, e, exists = alt, enrichCache[alt], true
			artist, title, album = splitEnrichKey(alt)
		}
	}
	enrichMu.Unlock()
	if !exists {
		p.reason = "缓存里没有这条记录"
		return p
	}
	p.found = true
	p.oldURL, p.oldSource, p.oldAlbum = e.CoverURL, e.CoverSource, e.CoverAlbum

	duration := e.ResolvedDurationSecs
	if duration <= 0 {
		duration = e.DurationSecs
	}

	fresh := resolveTrackEnrichment(context.Background(), artist, title, album, duration)
	p.newURL, p.newSource, p.newAlbum, p.newAccent = fresh.CoverURL, fresh.CoverSource, fresh.CoverAlbum, fresh.AccentColor

	p.swap = coverSwapAllowed(e, fresh, coverAlbumForTrack(context.Background(), artist, title, album, duration))
	switch {
	case fresh.CoverURL == "":
		p.reason = "这一轮一个源都没给出封面(疑似限流/网络),保持原样"
	case !p.swap:
		p.reason = "coverSwapAllowed 拒绝替换(见那个函数的注释)"
	case fresh.CoverURL == e.CoverURL:
		p.reason = "还是同一张图,只补上 cover_album"
	default:
		p.reason = "换封面"
	}
	return p
}

func runRecheckCover(keys []string, apply bool) int {
	changed, failed := 0, 0
	for _, key := range keys {
		p := planRecheckCover(key)
		fmt.Printf("── %s\n", p.key)
		if !p.found {
			fmt.Printf("   跳过:%s\n", p.reason)
			failed++
			continue
		}
		fmt.Printf("   旧:%-8s %-28s %s\n", p.oldSource, abbrev(p.oldAlbum, 28), abbrev(p.oldURL, 96))
		fmt.Printf("   新:%-8s %-28s %s\n", p.newSource, abbrev(p.newAlbum, 28), abbrev(p.newURL, 96))
		fmt.Printf("   判定:%s\n", p.reason)
		if !p.swap {
			continue
		}
		if !apply {
			changed++
			continue
		}
		enrichMu.Lock()
		e, exists := enrichCache[p.key]
		if !exists {

			enrichMu.Unlock()
			fmt.Println("   写回时这条已不在缓存里,跳过")
			continue
		}
		e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = p.newURL, p.newSource, p.newAlbum, p.newAccent
		enrichCache[p.key] = e
		enrichDirty = true
		enrichMu.Unlock()
		changed++
		fmt.Println("   已写入")
	}
	if apply && changed > 0 {
		saveEnrichCache()
	}
	if apply {
		fmt.Printf("\n完成:%d 条改动,%d 条没找到\n", changed, failed)
	} else {
		fmt.Printf("\n预演:%d 条会改动,%d 条没找到(加 -apply 才真写)\n", changed, failed)
	}
	if failed > 0 {
		return 1
	}
	return 0
}

func abbrev(s string, n int) string {
	if s == "" {
		return "—"
	}
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

func runRecheckInstrumentalCLI(args []string) {
	fs := flag.NewFlagSet("recheck-instrumental", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回缓存;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("recheck-instrumental: %v", err)
	}
	keys := fs.Args()
	if len(keys) == 0 {
		fmt.Fprintln(os.Stderr, `用法: collector recheck-instrumental [-apply] "歌手|歌名|专辑" ...`)
		os.Exit(2)
	}
	if configDir() == "" {
		log.Fatalf("recheck-instrumental: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfgDir := configDir()
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))

	if *apply && !ensureExclusiveForDedupe(cfgDir) {
		fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
		fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
		os.Exit(1)
	}
	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runRecheckInstrumental(keys, *apply))
}

func runRecheckInstrumental(keys []string, apply bool) int {
	changed, failed := 0, 0
	for _, key := range keys {
		artist, title, album := splitEnrichKey(key)
		enrichMu.Lock()
		e, exists := enrichCache[key]
		if !exists {
			if alt, found := canonicalEnrichKey(key); found {
				key, e, exists = alt, enrichCache[alt], true
				artist, title, album = splitEnrichKey(alt)
			}
		}
		enrichMu.Unlock()
		fmt.Printf("── %s\n", key)
		if !exists || title == "" {
			fmt.Println("   跳过:缓存里没有这条记录")
			failed++
			continue
		}
		switch {
		case e.ManualLyrics:
			fmt.Println("   跳过:用户手改过(一切自动路径对它一票否决)")
			continue
		case e.Instrumental:
			fmt.Println("   跳过:已经标着纯音乐了")
			continue
		case e.Lyrics != "":
			fmt.Println("   跳过:这条已经有歌词(有词就不是纯音乐)")
			continue
		}
		duration := e.ResolvedDurationSecs
		if duration <= 0 {
			duration = e.DurationSecs
		}
		_, scored := scoredLyricCandidates(context.Background(), artist, title, album, duration)
		marker := ""
		for _, c := range scored {
			if c.Instrumental {
				marker = c.Source
				break
			}
		}
		if picked := pickLyricCandidate(scored); picked != nil {
			fmt.Printf("   这轮居然搜到歌词了(%s,%d 分)—— 不在这条命令的职责内,交给补空路径\n",
				picked.Source, picked.Score)
			continue
		}
		if marker == "" {
			fmt.Println("   判定:没有任何源说它是纯音乐,保持原样")
			continue
		}
		fmt.Printf("   判定:%s 明确说这是纯音乐\n", marker)
		if !apply {
			changed++
			continue
		}
		enrichMu.Lock()
		cur, still := enrichCache[key]
		if !still {
			enrichMu.Unlock()
			fmt.Println("   写回时这条已不在缓存里,跳过")
			continue
		}
		cur.Instrumental = true
		enrichCache[key] = cur
		enrichDirty = true
		enrichMu.Unlock()
		changed++
		fmt.Println("   已写入")
	}
	if apply && changed > 0 {
		saveEnrichCache()
	}
	verb := "预演:"
	if apply {
		verb = "完成:"
	}
	fmt.Printf("\n%s%d 条标记为纯音乐,%d 条没找到\n", verb, changed, failed)
	if failed > 0 {
		return 1
	}
	return 0
}
