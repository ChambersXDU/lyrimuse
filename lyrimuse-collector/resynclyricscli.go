package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"
)

func runResyncLyricsCLI(args []string) {
	fs := flag.NewFlagSet("resync-lyrics", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回缓存;不加就是预演,只打印计划")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("resync-lyrics: %v", err)
	}
	keys := fs.Args()
	if len(keys) == 0 {
		fmt.Fprintln(os.Stderr, `用法: collector resync-lyrics [-apply] "歌手|歌名|专辑" ...`)
		os.Exit(2)
	}

	if configDir() == "" {
		log.Fatalf("resync-lyrics: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfgDir := configDir()
	features = loadFeatureFlags(filepath.Join(cfgDir, clientName+"-features.json"))

	loadArtistAliasCache(filepath.Join(cfgDir, clientName+"-artist-alias-cache.json"))
	loadMBPrimaryNameCache(filepath.Join(cfgDir, clientName+"-artist-primary-cache.json"))
	loadAppleCatalogCache(filepath.Join(cfgDir, clientName+"-apple-catalog-cache.json"))
	loadAppleStorefrontArtistCache(filepath.Join(cfgDir, clientName+"-apple-storefront-artist-cache.json"))
	loadQQArtistNameCache(filepath.Join(cfgDir, clientName+"-qq-artist-name-cache.json"))

	if *apply && !ensureExclusiveForDedupe(cfgDir) {
		fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
		fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
		os.Exit(1)
	}

	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runResyncLyrics(keys, *apply))
}

func runResyncLyrics(keys []string, apply bool) int {
	changed, unchanged, failed := 0, 0, 0
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
		if e.ManualLyrics {
			fmt.Println("   跳过:用户手改过(一切自动路径对它一票否决)")
			continue
		}
		duration := e.ResolvedDurationSecs
		if duration <= 0 {
			duration = e.DurationSecs
		}

		artist, title, album = toSimplified(artist), toSimplified(title), toSimplified(album)
		_, scored := scoredLyricCandidates(context.Background(), artist, title, album, duration)
		picked := pickLyricCandidatePreferring(scored, e.LyricsSourceChoice)

		decidable := rescoreDecidable(scored, e.LyricsSource, e.Lyrics == "")
		seen := lyricSourcesWithCandidates(scored)
		responded := lyricSourcesResponded(scored)

		if !decidable {
			fmt.Printf("   跳过:当前源 %q 这轮没应答(见 rescoreDecidable)\n", e.LyricsSource)
			failed++
			continue
		}
		if picked == nil {
			fmt.Println("   跳过:这轮没有能用的候选")
			failed++
			continue
		}

		lyricsSame := picked.Lyrics == e.Lyrics
		trSame := picked.LyricsTr == e.LyricsTr
		romaSame := picked.LyricsRoma == e.LyricsRoma
		if lyricsSame && trSame && romaSame {
			fmt.Println("   没变化:重新解析结果跟缓存里一样")
			unchanged++
			continue
		}
		fmt.Printf("   %s(%d) -> %s(%d)  歌词%s 译文%s 罗马音%s\n",
			e.LyricsSource, e.LyricsScore, picked.Source, picked.Score,
			changedMark(!lyricsSame), changedMark(!trSame), changedMark(!romaSame))
		changed++
		if !apply {
			continue
		}
		enrichMu.Lock()
		cur, still := enrichCache[key]
		if !still {
			enrichMu.Unlock()
			fmt.Println("   写回时这条已不在缓存里,跳过")
			continue
		}

		if cur.LyricsRescoreVersion != lyricsScoringVersion {
			cur.LyricsRescoreCount = 0
			cur.LyricsRescoreVersion = lyricsScoringVersion
		}
		cur.LyricsRescoreCount++
		cur.LyricsRescoreTS = time.Now().Unix()
		if len(seen) > 0 {
			cur.LyricsSourcesSeen = seen
		}
		if len(responded) > 0 {
			cur.LyricsSourcesResponded = responded
		}
		cur.LyricsDecision = buildLyricsDecision(
			lyricsDecisionPathRescore, artist, title, album, duration, scored, picked,
			!lyricsSame || !trSame || !romaSame)
		traceLyricsDecision(key, cur.LyricsDecision)
		cur.LyricsDecisionApplied = cur.LyricsDecision
		cur.Lyrics = picked.Lyrics
		cur.LyricsTr, cur.LyricsRoma, cur.LyricsYRC = picked.LyricsTr, picked.LyricsRoma, picked.LyricsYRC
		if !trSame {

			cur.LyricsTrLang, cur.LyricsTrSource = picked.LyricsTrLang, ""
		}
		cur.LyricsSource = picked.Source
		cur.LyricsScore = picked.Score
		cur.LyricsScoringVersion = lyricsScoringVersion
		cur.ResolvedDurationSecs = duration
		enrichCache[key] = cur
		enrichDirty = true
		enrichMu.Unlock()
		fmt.Println("   已写入")
	}
	if apply && changed > 0 {
		saveEnrichCache()
		exportLyricsFiles()
	}
	verb := "预演"
	if apply {
		verb = "完成"
	}
	fmt.Printf("\n%s:%d 条改动,%d 条没变化,%d 条失败\n", verb, changed, unchanged, failed)
	if failed > 0 {
		return 1
	}
	return 0
}

func changedMark(v bool) string {
	if v {
		return "✓变"
	}
	return "不变"
}
