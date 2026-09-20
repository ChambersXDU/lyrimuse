package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type healthStatus string

const (
	healthOK   healthStatus = "ok"
	healthWarn healthStatus = "warn"
	healthFail healthStatus = "fail"
)

type healthCheckItem struct {
	Name   string       `json:"name"`
	Status healthStatus `json:"status"`
	Detail string       `json:"detail"`
}

type healthReport struct {
	Items            []healthCheckItem `json:"items"`
	NetworkLooksDown bool              `json:"networkLooksDown"`
	OK               bool              `json:"ok"`
}

func runHealthcheckCLI(args []string) {
	fs := flag.NewFlagSet("healthcheck", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "output JSON instead of text")
	skipNetwork := fs.Bool("local-only", false, "skip the lyric source probes (no network)")
	if err := fs.Parse(args); err != nil {
		os.Exit(2)
	}

	if configDir() == "" {
		fmt.Fprintf(os.Stderr, "healthcheck: 拿不到家目录(LYRIMUSE_CONFIG_DIR 也没设)\n")
		os.Exit(1)
	}
	configDir := configDir()
	cfgPath := filepath.Join(configDir, "config.json")

	var report healthReport
	add := func(name string, status healthStatus, format string, a ...any) {
		report.Items = append(report.Items, healthCheckItem{
			Name: name, Status: status, Detail: fmt.Sprintf(format, a...),
		})
	}

	cfg, err := loadConfig(cfgPath)
	switch {
	case err != nil:

		add("配置文件", healthFail, "%v", err)
		cfg = &config{}
	case len(cfg.loadIssues) > 0:
		add("配置文件", healthWarn, "%d 个字段被跳过: %s",
			len(cfg.loadIssues), strings.Join(cfg.loadIssues, "; "))
	default:
		add("配置文件", healthOK, "%s", cfgPath)
	}

	features = loadFeatureFlags(filepath.Join(configDir, clientName+"-features.json"))
	enabled := enabledLyricSourceNames()
	if len(enabled) == 0 {
		add("歌词来源开关", healthFail, "一个源都没启用,永远不会有歌词")
	} else {
		add("歌词来源开关", healthOK, "已启用 %s", strings.Join(enabled, "/"))
	}

	cachePath := filepath.Join(configDir, clientName+"-enrich-cache.json")
	if data, err := os.ReadFile(cachePath); err != nil {
		if os.IsNotExist(err) {
			add("歌词缓存", healthWarn, "还没有缓存文件(第一次运行时正常)")
		} else {
			add("歌词缓存", healthFail, "读不了: %v", err)
		}
	} else {
		var m map[string]json.RawMessage
		if err := json.Unmarshal(data, &m); err != nil {
			add("歌词缓存", healthFail, "解析失败,每首歌都会被重新解析一遍: %v", err)
		} else {
			add("歌词缓存", healthOK, "%d 条", len(m))
		}
	}

	dir := features.LyricsDir
	if dir == "" {
		dir = filepath.Join(configDir, "lyrics")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		add("歌词导出目录", healthFail, "建不了 %s: %v", dir, err)
	} else {
		probe := filepath.Join(dir, ".lyrimuse-healthcheck-write-probe")
		if err := os.WriteFile(probe, []byte("probe"), 0o600); err != nil {
			add("歌词导出目录", healthFail, "%s 写不进去: %v", dir, err)
		} else {
			os.Remove(probe)
			n := 0
			if entries, err := os.ReadDir(dir); err == nil {
				for _, e := range entries {
					if strings.HasSuffix(strings.ToLower(e.Name()), ".lrc") {
						n++
					}
				}
			}
			add("歌词导出目录", healthOK, "%s(%d 个 .lrc,可写)", dir, n)
		}
	}

	if cfg.Token == "" {
		add("ListenBrainz", healthWarn, "未配置 token,不会提交收听(不影响歌词显示)")
	} else {
		add("ListenBrainz", healthOK, "已配置 token,api_root=%s", cfg.APIRoot)
	}
	if !*skipNetwork {
		type probeTrack struct{ artist, title, album string }

		probes := []probeTrack{
			{"梦然", "少年", ""},
			{"The Beatles", "Yesterday", "Help!"},
		}
		answered := map[string]int{}
		start := time.Now()
		for _, p := range probes {
			_, scored := scoredLyricCandidates(context.Background(), toSimplified(p.artist), toSimplified(p.title), toSimplified(p.album), 0)
			for _, src := range distinctLyricSources(scored, false) {
				answered[src]++
			}
		}
		elapsed := time.Since(start).Round(time.Millisecond)
		report.NetworkLooksDown = networkLooksDown()

		if report.NetworkLooksDown {
			add("网络", healthFail, "所有请求都发不出去(DNS/连接失败),歌词解析这一轮全部无效")
		} else {
			add("网络", healthOK, "探测 %d 首用时 %s", len(probes), elapsed)
		}

		dead := 0
		for _, src := range enabled {
			n := answered[src]
			switch {
			case n == len(probes):
				add("源 "+src, healthOK, "%d/%d 首探测曲给出了候选", n, len(probes))
			case n > 0:

				add("源 "+src, healthOK, "%d/%d 首(另一首不在它的曲库里属正常)", n, len(probes))
			default:
				dead++
				add("源 "+src, healthWarn, "两首探测曲都没有候选,这个源目前可能不可用")
			}
		}
		if dead > 0 && dead == len(enabled) {
			add("歌词源整体", healthFail, "%d 个启用的源全部没有候选,歌词不会出现", dead)
		} else if dead > 0 {
			add("歌词源整体", healthOK, "%d/%d 个源可用,歌词功能正常", len(enabled)-dead, len(enabled))
		}
	}

	report.OK = true
	for _, it := range report.Items {
		if it.Status == healthFail {
			report.OK = false
		}
	}

	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(report)
	} else {
		width := 0
		for _, it := range report.Items {
			if n := displayWidth(it.Name); n > width {
				width = n
			}
		}
		for _, it := range report.Items {
			fmt.Printf("  %-4s %s%s  %s\n", it.Status,
				it.Name, strings.Repeat(" ", width-displayWidth(it.Name)), it.Detail)
		}
		fmt.Println()
		if report.OK {
			fmt.Println("没有发现会导致歌词不显示的问题。")
		} else {
			fmt.Println("有 fail 项 —— 上面标 fail 的那几条会直接导致歌词出不来。")
		}
	}
	if !report.OK {
		os.Exit(1)
	}
}

func enabledLyricSourceNames() []string {
	var out []string
	for _, name := range lyricSourceNames {
		if lyricSourceEnabled(name) {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

func displayWidth(s string) int {
	w := 0
	for _, r := range s {
		switch {
		case r >= 0x1100 && r <= 0x115F,
			r >= 0x2E80 && r <= 0xA4CF,
			r >= 0xAC00 && r <= 0xD7A3,
			r >= 0xF900 && r <= 0xFAFF,
			r >= 0xFE30 && r <= 0xFE6F,
			r >= 0xFF00 && r <= 0xFF60,
			r >= 0xFFE0 && r <= 0xFFE6:
			w += 2
		default:
			w++
		}
	}
	return w
}
