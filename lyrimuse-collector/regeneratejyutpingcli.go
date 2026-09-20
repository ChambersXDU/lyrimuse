package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

func runRegenerateJyutpingCLI(args []string) {
	fs := flag.NewFlagSet("regenerate-jyutping", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("regenerate-jyutping: %v", err)
	}

	if configDir() == "" {
		log.Fatalf("regenerate-jyutping: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
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

	importLyricsFromFiles()
	os.Exit(runRegenerateJyutping(*apply))
}

var jyutpingTonedSyllable = regexp.MustCompile(`[a-z]+[1-6]`)

type jyutpingRegenItem struct {
	key      string
	oldLines int
	newLines int
}

func runRegenerateJyutping(apply bool) int {
	var (
		plan       []jyutpingRegenItem
		regen      = map[string]string{}
		skipNoTone int
		upToDate   int
		scanned    int
	)

	enrichMu.Lock()
	for k, e := range enrichCache {
		if e.SongLanguage != songLanguageCantonese || e.Lyrics == "" || e.LyricsRoma == "" {
			continue
		}
		scanned++
		if !jyutpingTonedSyllable.MatchString(e.LyricsRoma) {
			skipNoTone++
			continue
		}
		fresh := jyutpingLRC(e.Lyrics)
		if fresh == "" || fresh == e.LyricsRoma {
			upToDate++
			continue
		}
		plan = append(plan, jyutpingRegenItem{
			key:      k,
			oldLines: countLines(e.LyricsRoma),
			newLines: countLines(fresh),
		})
		regen[k] = fresh
	}
	enrichMu.Unlock()

	sort.Slice(plan, func(i, j int) bool { return plan[i].key < plan[j].key })

	fmt.Printf("粤语条目(有歌词+有粤拼): %d\n", scanned)
	fmt.Printf("  已经是当前算法的结果,无需处理 : %d\n", upToDate)
	fmt.Printf("  无声调(源自带罗马音),跳过不动 : %d\n", skipNoTone)
	fmt.Printf("  需要重新生成                  : %d\n", len(plan))
	for _, it := range plan {
		note := ""
		if it.oldLines != it.newLines {
			note = fmt.Sprintf("   [行数 %d → %d,旧粤拼跟当前歌词已经对不上]", it.oldLines, it.newLines)
		}
		fmt.Printf("    - %s%s\n", it.key, note)
	}

	if len(plan) == 0 {
		fmt.Println("没有需要处理的条目。")
		return 0
	}
	if !apply {
		fmt.Println()
		fmt.Println("以上是预演。确认无误后加 -apply 真正写回(需要先停掉常驻 collector)。")
		return 0
	}

	enrichMu.Lock()
	for k, fresh := range regen {
		e, ok := enrichCache[k]
		if !ok {
			continue
		}
		e.LyricsRoma = fresh
		enrichCache[k] = e
	}

	enrichDirty = true
	enrichMu.Unlock()

	saveEnrichCache()

	exportLyricsFiles()
	fmt.Printf("已重新生成 %d 条,并刷新 lyrics/ 里对应的 .roma.lrc。\n", len(regen))
	return 0
}

func countLines(s string) int {
	if s == "" {
		return 0
	}
	n := 1
	for _, r := range s {
		if r == '\n' {
			n++
		}
	}
	return n
}
