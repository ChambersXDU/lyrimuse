package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func runRetranslateRepeatedCLI(args []string) {
	fs := flag.NewFlagSet("retranslate-repeated", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回缓存;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("retranslate-repeated: %v", err)
	}

	if configDir() == "" {
		log.Fatalf("retranslate-repeated: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfgDir := configDir()
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))

	if *apply && !ensureExclusiveForDedupe(cfgDir) {
		fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
		fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
		os.Exit(1)
	}

	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runRetranslateRepeated(*apply))
}

func hasRepeatedTranslatableLine(lyrics, target string) bool {
	lines := parseLRCLines(lyrics)
	speakers := lyricSpeakerLabels(lyrics)
	seen := map[string]bool{}
	for _, l := range lines {
		if isCreditLineWithSpeakers(strings.TrimSpace(l.text), speakers) {
			continue
		}
		if !lineNeedsTranslation(l.text, target) {
			continue
		}
		if seen[l.text] {
			return true
		}
		seen[l.text] = true
	}
	return false
}

func runRetranslateRepeated(apply bool) int {
	target := myMemoryLangCode(features.LyricsTranslationLanguage)
	if target == "" {
		fmt.Fprintln(os.Stderr, "没有配置译文目标语言,无事可做")
		return 1
	}

	enrichMu.Lock()
	var keys []string
	for k, e := range enrichCache {
		if e.ManualLyrics || e.Lyrics == "" || e.LyricsTr == "" {
			continue
		}
		if !translationUsable(e, target) {
			continue
		}
		if !hasRepeatedTranslatableLine(e.Lyrics, target) {
			continue
		}
		keys = append(keys, k)
	}
	enrichMu.Unlock()
	sort.Strings(keys)

	fmt.Printf("扫描完成:%d 条命中(歌词有重复行、当前译文可能被旧的逐行翻译 bug 坑过)\n\n", len(keys))

	ctx := context.Background()
	changed, unchanged, failed := 0, 0, 0
scan:
	for i, key := range keys {
		enrichMu.Lock()
		e, ok := enrichCache[key]
		lyrics, oldTr := e.Lyrics, e.LyricsTr
		enrichMu.Unlock()
		if !ok {
			continue
		}
		res, err := machineTranslateLRC(ctx, translateClient, lyrics, target)
		oldLines := strings.Count(oldTr, "\n") + 1
		fmt.Printf("── %s\n", key)
		switch {
		case res.quotaReached:

			fmt.Println("   跳过:MyMemory 当天配额用尽,停止扫描剩余条目")
			failed += len(keys) - i
			break scan
		case err != nil:
			fmt.Printf("   失败:%v\n", err)
			failed++
			continue
		case res.lrc == "":
			fmt.Println("   跳过:这轮没翻出可用结果,保留原有译文")
			unchanged++
			continue
		case res.lrc == oldTr:
			fmt.Println("   没变化:重翻结果跟原来一样")
			unchanged++
			continue
		}
		newLines := strings.Count(res.lrc, "\n") + 1
		fmt.Printf("   %d 行 → %d 行\n", oldLines, newLines)
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
		cur.LyricsTr = res.lrc
		cur.LyricsTrSource = lyricsTrSourceMachine
		cur.LyricsTrLang = target
		cur.TranslationTS = time.Now().Unix()
		cur.TranslationRetryCount = 0
		enrichCache[key] = cur
		enrichDirty = true
		enrichMu.Unlock()
		changed++
		fmt.Println("   已写入")
	}
	if apply && changed > 0 {
		saveEnrichCache()
	}
	verb := "预演"
	if apply {
		verb = "完成"
	}
	fmt.Printf("\n%s:%d 条改动,%d 条没变化,%d 条失败", verb, changed, unchanged, failed)
	if !apply {
		fmt.Print("(加 -apply 才真写)")
	}
	fmt.Println()
	if failed > 0 {
		return 1
	}
	return 0
}
