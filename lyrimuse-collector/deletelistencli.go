package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func runDeleteListenCLI(args []string) {
	fs := flag.NewFlagSet("delete-listen", flag.ExitOnError)
	var utsList utsFlag
	fs.Var(&utsList, "uts", "要删除的收听时间戳(Unix 秒),可重复,或用逗号分隔")
	asJSON := fs.Bool("json", true, "以 JSON 输出结果")

	cfgPath := fs.String("config", "", "配置文件路径(默认 ~/.config/lyrimuse/config.json)")
	if err := fs.Parse(args); err != nil {
		os.Exit(2)
	}
	if len(utsList) == 0 {
		fmt.Fprintln(os.Stderr, "delete-listen: 至少要给一个 -uts")
		os.Exit(2)
	}

	resolved := *cfgPath
	if resolved == "" {
		if configDir() == "" {
			fmt.Fprintf(os.Stderr, "delete-listen: 拿不到家目录(LYRIMUSE_CONFIG_DIR 也没设)\n")
			os.Exit(1)
		}
		resolved = filepath.Join(configDir(), "config.json")
	}

	setListenLogPath(filepath.Join(filepath.Dir(resolved), clientName+"-listens.jsonl"))

	deleted, remaining, err := deleteListensByUTS(utsList)
	if err != nil {
		fmt.Fprintf(os.Stderr, "delete-listen: %v\n", err)
		os.Exit(1)
	}
	if *asJSON {
		_ = json.NewEncoder(os.Stdout).Encode(struct {
			Deleted   int `json:"deleted"`
			Remaining int `json:"remaining"`
		}{deleted, remaining})
	} else {
		fmt.Printf("deleted %d line(s), %d remaining\n", deleted, remaining)
	}
}

type utsFlag []int64

func (f *utsFlag) String() string { return fmt.Sprint(*f) }

func (f *utsFlag) Set(v string) error {
	for _, part := range strings.Split(v, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		n, err := strconv.ParseInt(part, 10, 64)
		if err != nil {
			return fmt.Errorf("%q 不是合法的时间戳", part)
		}

		if n <= 0 {
			return fmt.Errorf("时间戳必须为正数,收到 %d", n)
		}
		*f = append(*f, n)
	}
	return nil
}

func deleteListensByUTS(targets []int64) (deleted, remaining int, err error) {
	drop := make(map[int64]bool, len(targets))
	for _, u := range targets {
		drop[u] = true
	}

	lines := readListenLog()
	kept := make([]listenLogLine, 0, len(lines))
	for _, line := range lines {
		if drop[line.UTS] {
			deleted++
			continue
		}
		kept = append(kept, line)
	}
	if deleted == 0 {

		return 0, len(lines), nil
	}

	listenLogMu.Lock()
	defer listenLogMu.Unlock()
	if listenLogPath == "" {
		return 0, 0, fmt.Errorf("收听日志路径未设置")
	}
	tmp := listenLogPath + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return 0, 0, fmt.Errorf("建临时文件失败: %w", err)
	}
	w := bufio.NewWriter(f)
	for _, line := range kept {
		data, err := json.Marshal(line)
		if err != nil {
			continue
		}
		if _, err := w.Write(append(data, '\n')); err != nil {
			f.Close()
			os.Remove(tmp)
			return 0, 0, fmt.Errorf("写临时文件失败: %w", err)
		}
	}
	if err := w.Flush(); err != nil {
		f.Close()
		os.Remove(tmp)
		return 0, 0, fmt.Errorf("刷新临时文件失败: %w", err)
	}
	f.Close()
	if err := os.Rename(tmp, listenLogPath); err != nil {
		os.Remove(tmp)
		return 0, 0, fmt.Errorf("替换日志失败: %w", err)
	}
	return deleted, len(kept), nil
}

func setListenLogPath(path string) {
	listenLogMu.Lock()
	listenLogPath = path
	listenLogMu.Unlock()
}
