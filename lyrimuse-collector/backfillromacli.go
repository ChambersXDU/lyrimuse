package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"time"
)

func runBackfillRomaCLI(args []string) {
	fs := flag.NewFlagSet("backfill-roma", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回;不加就是预演,只打印计划")
	limit := fs.Int("limit", 0, "最多处理多少条(0=不限);先小批量试跑用")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("backfill-roma: %v", err)
	}

	if configDir() == "" {
		log.Fatalf("backfill-roma: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
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
	os.Exit(runBackfillRoma(*apply, *limit))
}

func runBackfillRoma(apply bool, limit int) int {

	type candidate struct {
		key    string
		lyrics string
	}
	var cands []candidate
	skipped := map[string]int{}

	enrichMu.Lock()
	for k, e := range enrichCache {
		if e.Lyrics == "" {
			skipped["没有歌词"]++
			continue
		}
		if e.LyricsRoma != "" {
			skipped["已有罗马音(源自带/粤拼),不覆盖"]++
			continue
		}
		switch dominantScript(e.Lyrics) {
		case scriptHan, scriptKana, scriptHangul:
		default:
			skipped["不是中日韩文字,无需注音"]++
			continue
		}
		cands = append(cands, candidate{key: k, lyrics: e.Lyrics})
	}
	enrichMu.Unlock()

	sort.Slice(cands, func(i, j int) bool { return cands[i].key < cands[j].key })
	if limit > 0 && len(cands) > limit {
		cands = cands[:limit]
	}

	fmt.Printf("候选(有歌词 + 没罗马音 + 中日韩文字): %d\n", len(cands))
	for _, reason := range []string{"没有歌词", "已有罗马音(源自带/粤拼),不覆盖", "不是中日韩文字,无需注音"} {
		fmt.Printf("  跳过 %-28s : %d\n", reason, skipped[reason])
	}
	if len(cands) == 0 {
		fmt.Println("没有需要处理的条目。")
		return 0
	}
	if !apply {
		fmt.Println()
		fmt.Println("以上是预演(还没有真正调用 lyrics-romanize)。")
		fmt.Println("确认无误后加 -apply 真正生成并写回(需要先停掉常驻 collector);")
		fmt.Println("可以先 -apply -limit 20 小批量试一下效果。")
		return 0
	}

	generated := map[string]string{}
	var empty, failed int
	start := time.Now()
	for i, c := range cands {
		roma, err := onDeviceRomanize(c.lyrics)
		switch {
		case err != nil:
			failed++
			log.Printf("backfill-roma: %s: %v", c.key, err)
		case roma == "":

			empty++
		default:
			generated[c.key] = roma
		}
		if (i+1)%100 == 0 || i+1 == len(cands) {
			fmt.Printf("  进度 %d/%d  已生成 %d  无产出 %d  失败 %d  用时 %s\n",
				i+1, len(cands), len(generated), empty, failed, time.Since(start).Round(time.Second))
		}
	}

	if len(generated) == 0 {
		fmt.Println("一条都没能生成(helper 是不是没随包打进 Contents/Resources/?)。")
		return 0
	}

	enrichMu.Lock()
	for k, roma := range generated {
		e, ok := enrichCache[k]
		if !ok {
			continue
		}

		if e.LyricsRoma != "" {
			continue
		}
		e.LyricsRoma = roma
		enrichCache[k] = e
	}

	enrichDirty = true
	enrichMu.Unlock()

	saveEnrichCache()

	exportLyricsFiles()
	fmt.Printf("已生成 %d 条,并写出 lyrics/ 里对应的 .roma.lrc(无产出 %d,失败 %d)。\n",
		len(generated), empty, failed)
	return 0
}
