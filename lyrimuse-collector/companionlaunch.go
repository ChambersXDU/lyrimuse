// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bufio"
	"bytes"
	"context"
	"log"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

var (
	lastRunningByName   = map[string]bool{}
	wasCompanionEnabled = false
)

// companionLaunchInterval is the relaxed check interval for companion launch detection.
const companionLaunchInterval = 3 * time.Second

// startCompanionLaunchWatcher runs independently of the poller loop, spawned by run
// in a dedicated goroutine and terminates cleanly when ctx is cancelled.
func startCompanionLaunchWatcher(ctx context.Context) {
	ticker := time.NewTicker(companionLaunchInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if ctx.Err() != nil {
				return
			}
			if !features.LaunchLyrimuseOnMusicOpen {
				wasCompanionEnabled = false
				clear(lastRunningByName)
				continue
			}
			checkCompanionLaunch(ctx)
		}
	}
}

// batchRunningProcesses queries pgrep once for all candidate names in a single subprocess
// execution and returns a set of running process names.
func batchRunningProcesses(ctx context.Context, names []string) (map[string]bool, error) {
	running := make(map[string]bool, len(names))
	if len(names) == 0 {
		return running, nil
	}
	escaped := make([]string, len(names))
	for i, name := range names {
		escaped[i] = regexp.QuoteMeta(name)
	}
	pattern := strings.Join(escaped, "|")
	cmdCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	out, err := exec.CommandContext(cmdCtx, "pgrep", "-l", "-x", pattern).Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			// Exit code 1 indicates no matching processes found
			return running, nil
		}
		return running, err
	}

	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			procName := strings.TrimSpace(line[len(fields[0]):])
			for _, candidate := range names {
				if candidate == procName {
					running[candidate] = true
					break
				}
			}
		}
	}
	return running, nil
}

// checkCompanionLaunch checks whether any tracked player has transitioned from
// not-running to running. When enabled, it batches the check into a single pgrep
// query to avoid subprocess fork storms.
func checkCompanionLaunch(ctx context.Context) {
	if !features.LaunchLyrimuseOnMusicOpen {
		wasCompanionEnabled = false
		clear(lastRunningByName)
		return
	}

	names := companionLaunchProcessNames()
	if len(names) == 0 {
		return
	}

	runningMap, err := batchRunningProcesses(ctx, names)
	if err != nil {
		log.Printf("companion launch: error querying running processes: %v", err)
		return
	}

	// On the transition from disabled to enabled, initialize lastRunningByName
	// with the current state to prevent falsely triggering companion launch for
	// players that were already running.
	if !wasCompanionEnabled {
		wasCompanionEnabled = true
		for _, name := range names {
			lastRunningByName[name] = runningMap[name]
		}
		return
	}

	var justStarted string
	for _, name := range names {
		running := runningMap[name]
		if running && !lastRunningByName[name] && justStarted == "" {
			justStarted = name
		}
		lastRunningByName[name] = running
	}

	alreadyRunning := false
	if !shouldCompanionLaunch(justStarted, features.LaunchLyrimuseOnMusicOpen, func() bool {
		alreadyRunning = isProcessRunning(lyrimuseAppProcessName)
		return alreadyRunning
	}) {
		if alreadyRunning {
			log.Printf("companion launch: %s just started, Lyrimuse.app already running, skipping", justStarted)
		}
		return
	}
	log.Printf("companion launch: %s just started, launching Lyrimuse.app", justStarted)
	launchLyrimuseApp()
}

// lyrimuseAppProcessName 是 Lyrimuse.app 的可执行文件名(/Applications/Lyrimuse.app/
// Contents/MacOS/lyrimuse),给 pgrep -x 用。collector 自己的可执行名是 collector,
// 两者不会互相误命中(测试核实过)。
const lyrimuseAppProcessName = "lyrimuse"

// shouldCompanionLaunch 把"这一轮到底要不要去启动 Lyrimuse.app"收成一个纯函数,便于
// 单测覆盖三个否决条件。
//
// lyrimuseRunning 传的是函数而不是 bool,为的是保住短路:前两个条件绝大多数轮次就已经
// 否决了,而查 Lyrimuse 在不在跑要 fork 一次 pgrep,没必要每秒都白跑一次。
//
// ⚠️ 第三个条件(已在运行就跳过)是 的,之前这里和 launchLyrimuseApp 的注释
// 都断言"已经在运行时 open 是空操作、不需要提前判断",这个前提是错的,当天日志里有两种
// 反例:
//
//	① `open` 会给已运行的实例投递 reopen 事件,而 AppDelegate.applicationShouldHandleReopen
//	   在没有可见窗口时(菜单栏常驻 App 的常态)会把设置窗口当"主窗口"打开——表现成
//	   "打开 Music 之后 Lyrimuse 的设置窗口自己弹出来了"(处理)。
//	② 更糟的一种:launchd 直接拉起的 App 进程没有以 GUI 实例身份注册进 LaunchServices,
//	   `open` 当它不存在、又起了第二个实例(当天 launchctl list 里同时出现
//	   me.yudaotor.lyrimuse 和 application.me.yudaotor.lyrimuse.* 两条,两个进程跑同一个
//	   .app,菜单栏出现两个图标)。
//
// 这个功能的语义本来就是"播放器起来了、顺手把没在跑的 Lyrimuse 拉起来",已经在跑时跳过
// 不损失任何东西。
func shouldCompanionLaunch(justStarted string, enabled bool, lyrimuseRunning func() bool) bool {
	if justStarted == "" || !enabled {
		return false
	}
	return !lyrimuseRunning()
}

// isProcessRunning 用 pgrep 按可执行文件名精确匹配(-x)查进程是否存在,不发送任何
// Apple Event。
func isProcessRunning(name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "pgrep", "-x", name).Run() == nil
}

// companionLaunchProcessNames 是这一轮要盯的可执行文件名列表——手动选定播放器时盯
// features.Players 里的每一个(可多选;单选年代只有一个 key,行为跟合并
// 前完全一致,不会因为多了 playerAuto 而误报别的播放器启动);「自动识别」在选中集合里
// (不管是否同时还勾了别的具体播放器,都按超集处理)时没有唯一确定的目标,同时盯着
// 全部五个已知播放器,任意一个启动都算数,这也是自动识别模式下这个方向反而更有用的
// 地方——用户不需要事先告诉 Lyrimuse 自己接下来要开哪个播放器。
func companionLaunchProcessNames() []string {
	var candidates []string
	if features.Players[playerAuto] {
		candidates = knownPlayerProcessNames
	} else {
		candidates = make([]string, 0, len(features.Players))
		for player := range features.Players {
			candidates = append(candidates, playerProcessNameFor(player))
		}
	}
	// 「跟随播放器启动」按播放器逐个勾选(features.LaunchLyrimuseOnPlayers,用户拍板):键在就
	// 只盯勾了的、且仍在候选(选中集合 / auto 全量)里的那几个 —— 勾了但已经取消选中的播放器不算,跟 Swift 侧
	// PlayerLinkage.effective 同一条规则;键缺失是布尔年代的老配置,退回盯整个候选集合。
	if features.LaunchLyrimuseOnPlayers == nil {
		return candidates
	}
	names := make([]string, 0, len(features.LaunchLyrimuseOnPlayers))
	for player := range features.LaunchLyrimuseOnPlayers {
		name := playerProcessNameFor(player)
		for _, candidate := range candidates {
			if candidate == name {
				names = append(names, name)
				break
			}
		}
	}
	return names
}

// knownPlayerProcessNames 是全部五个已知播放器的可执行文件名——QQ音乐.app 是
// QQMusic、网易云音乐.app 是 NeteaseMusic、Spotify.app 是 Spotify、酷狗音乐.app 是
// **中文的**「酷狗音乐」(都用 PlistBuddy 读 CFBundleExecutable 核实过),Music.app 是
// Music。playerProcessNameFor 给 features.Players 里手动选定的每个成员各查一个出来;
// playerAuto 在选中集合里时直接用整份列表。
//
// ⚠️ 酷狗那一项是非 ASCII 的,确认两件事都成立才敢这么写:
//  1. `pgrep -x 酷狗音乐` 能匹配到 comm 为中文的进程(拿一个中文名符号链接起进程验过);
//  2. UTF-8 下「酷狗音乐」是 12 字节,没超过内核 p_comm 的 16 字节上限(pgrep 比的就是
//     这个被截断过的名字)——再长两个汉字就会被截断、`-x` 精确匹配当场失效。往这份列表
//     里加新播放器时这条限制要一起核。
var knownPlayerProcessNames = []string{"Music", "QQMusic", "NeteaseMusic", "Spotify", "酷狗音乐"}

// playerProcessNameFor 是某个具体播放器常量的可执行文件名,给手动选定的场景用,见
// knownPlayerProcessNames 注释。从读包级 features.Player 的 playerProcessName
// 改成纯函数——多选之后 companionLaunchProcessNames 要对 features.Players 里的每个
// 成员分别求进程名,不能再读一个包级单值。
func playerProcessNameFor(player string) string {
	switch player {
	case playerQQMusic:
		return "QQMusic"
	case playerNetease:
		return "NeteaseMusic"
	case playerSpotify:
		return "Spotify"
	case playerKugou:
		return "酷狗音乐"
	default:
		return "Music"
	}
}

// launchLyrimuseApp 用 bundle id(不是路径)启动 Lyrimuse.app——不依赖它具体装在哪个
// 路径下,LaunchServices 自己按已注册的 bundle id 找。用 --background 避免把它带到前台
// 抢用户当前的焦点(跟 AppDelegate.swift 里 launchMusicOnLyrimuseOpen 那半用
// config.activates=false 的用意一致)。
//
// ⚠️ 调用方必须先确认 Lyrimuse.app 没在跑(见 shouldCompanionLaunch 的注释)。这里再自查
// 一次是纵深防御:对已运行的实例 `open` **不是**空操作,会弹设置窗口、甚至起第二个实例。
func launchLyrimuseApp() {
	if isProcessRunning(lyrimuseAppProcessName) {
		return
	}
	// bundle id 来自 paths.go appBundleID(环境变量可覆盖,缺省正式 id),上面按可执行名 `lyrimuse` 查"在不在跑"。
	if err := exec.Command("open", "--background", "-b", appBundleID()).Start(); err != nil {
		log.Printf("companion launch: failed to open Lyrimuse.app: %v", err)
	}
}
