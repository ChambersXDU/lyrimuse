package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

type dedupePlan struct {
	groups []dedupeGroup

	staleFiles []string
}

type dedupeGroup struct {
	loose string

	winner string
	source string
	losers []string
}

func planDedupe(cache map[string]enrichEntry) dedupePlan {
	byLoose := map[string][]string{}
	for k := range cache {
		loose := loosenEnrichKey(k)
		byLoose[loose] = append(byLoose[loose], k)
	}

	looseKeys := make([]string, 0, len(byLoose))
	for loose, keys := range byLoose {
		if len(keys) > 1 {
			looseKeys = append(looseKeys, loose)
		}
	}

	sort.Strings(looseKeys)

	plan := dedupePlan{}
	for _, loose := range looseKeys {
		keys := byLoose[loose]
		sort.Strings(keys)

		source := keys[0]
		for _, k := range keys[1:] {
			if betterEnrichEntry(cache[k], cache[source], k, source) {
				source = k
			}
		}

		winner := pickDisplayKey(keys)
		losers := make([]string, 0, len(keys)-1)
		for _, k := range keys {
			if k != winner {
				losers = append(losers, k)
			}
		}
		plan.groups = append(plan.groups, dedupeGroup{loose: loose, winner: winner, source: source, losers: losers})
	}
	return plan
}

func pickDisplayKey(keys []string) string {
	rank := func(k string) (int, int, string) {
		return simplifiedDistance(k), -len([]rune(k)), k
	}
	best := keys[0]
	bs, bl, bk := rank(best)
	for _, k := range keys[1:] {
		s, l, kk := rank(k)
		if s < bs || (s == bs && l < bl) || (s == bs && l == bl && kk < bk) {
			best, bs, bl, bk = k, s, l, kk
		}
	}
	return best
}

func simplifiedDistance(k string) int {
	a := []rune(k)
	b := []rune(toSimplified(k))
	if len(a) != len(b) {

		return len(a) + len(b)
	}
	n := 0
	for i := range a {
		if a[i] != b[i] {
			n++
		}
	}
	return n
}

func resolveStaleFiles(plan dedupePlan) []string {
	if lyricsDir == "" {
		return nil
	}

	winnerFiles := map[string]bool{}
	for _, g := range plan.groups {
		if g.winner != g.source {
			continue
		}
		for _, name := range enrichExportedFileNames(g.winner) {
			winnerFiles[name] = true
		}
	}
	var out []string
	for _, g := range plan.groups {
		stale := append([]string{}, g.losers...)
		if g.winner != g.source {

			stale = append(stale, g.winner)
		}
		for _, loser := range stale {
			for _, name := range enrichExportedFileNames(loser) {
				if winnerFiles[name] {

					log.Printf("dedupe: refusing to delete %q — it is also the winner's export file", name)
					continue
				}
				p := filepath.Join(lyricsDir, name)
				if _, err := os.Stat(p); err == nil {
					out = append(out, p)
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

func runDedupeEntries(apply bool) int {
	enrichMu.Lock()
	plan := planDedupe(enrichCache)
	total := len(enrichCache)
	enrichMu.Unlock()

	plan.staleFiles = resolveStaleFiles(plan)

	if len(plan.groups) == 0 {
		fmt.Println("没有发现重复条目。")
		return 0
	}

	removed := 0
	for _, g := range plan.groups {
		removed += len(g.losers)
	}

	mode := "预演(不会改动任何东西)"
	if apply {
		mode = "执行"
	}
	fmt.Printf("== %s ==\n", mode)
	fmt.Printf("缓存条目 %d → %d(合并 %d 组,移除 %d 条)\n\n", total, total-removed, len(plan.groups), removed)
	for _, g := range plan.groups {
		if g.winner == g.source {
			fmt.Printf("  保留  %s\n", g.winner)
		} else {
			fmt.Printf("  保留  %s   (歌词内容取自 %s)\n", g.winner, g.source)
		}
		for _, l := range g.losers {
			fmt.Printf("  移除  %s\n", l)
		}
		fmt.Println()
	}
	fmt.Printf("待删除的导出文件 %d 个:\n", len(plan.staleFiles))
	for _, f := range plan.staleFiles {
		fmt.Printf("  %s\n", strings.TrimPrefix(f, lyricsDir+"/"))
	}

	if !apply {
		fmt.Println("\n这是预演。确认无误后加 -apply 真正执行。")
		fmt.Println("⚠️ 执行前请先备份 ~/.config/lyrimuse/lyrimuse-enrich-cache.json 和 lyrics/ 整个目录 ——")
		fmt.Println("   删除不可逆,请务必做好数据备份。")
		return 0
	}

	for _, f := range plan.staleFiles {
		if err := os.Remove(f); err != nil && !os.IsNotExist(err) {
			log.Printf("dedupe: failed to remove %q: %v", f, err)
		}
	}

	enrichMu.Lock()
	for _, g := range plan.groups {

		entry := enrichCache[g.source]
		for _, l := range g.losers {
			delete(enrichCache, l)
		}
		enrichCache[g.winner] = entry
	}
	enrichDirty = true
	enrichMu.Unlock()
	saveEnrichCache()

	exportLyricsFiles()

	fmt.Printf("\n完成:移除 %d 条重复条目,删除 %d 个导出文件。\n", removed, len(plan.staleFiles))
	return 0
}

func runDedupeEntriesCLI(args []string) {
	fs := flag.NewFlagSet("dedupe-entries", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正执行合并;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("dedupe-entries: %v", err)
	}

	if configDir() == "" {
		log.Fatalf("dedupe-entries: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfgDir := configDir()
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))
	lyricsDir = features.LyricsDir
	if lyricsDir == "" {
		lyricsDir = filepath.Join(cfgDir, "lyrics")
	}

	if *apply {
		if !ensureExclusiveForDedupe(cfgDir) {
			fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
			fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
			os.Exit(1)
		}
	}

	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runDedupeEntries(*apply))
}

func ensureExclusiveForDedupe(dir string) bool {
	f, err := os.OpenFile(filepath.Join(dir, "collector.lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		log.Printf("dedupe: cannot open lock file: %v", err)
		return false
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return false
	}
	singleInstanceLockFile = f
	return true
}
