// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
)

// featureFlagsFile is the on-disk shape written by desktop-lyrics's "设置" →
// "功能开关" section and read once at collector startup — same "Swift 写共享
// 文件 → launchctl kickstart 重启 collector → collector 下次启动读到新内容"
// 约定,已经在 enrichCache/lyrics 文件夹这两处验证过(见 main.go 顶部注释),collector
// 没有文件监听,状态只在启动时读一次。用 *bool 而不是 bool——文件不存在、或者文件里
// 缺某个字段,都要解读成"沿用现有行为"(默认开启),而不是"关闭";bool 零值会把两者
// 都错误地解读成"关闭",导致这个改动从"纯增量开关"变成"静默改变现有行为"。
//
// 这里的开关跟 config.go 里已有的凭据判断是 AND 关系,不是替代:没配凭据的功能,
// 开关打开也没用;已经配了凭据的功能,现在才第一次有独立的"关"(尤其是
// lastfm_bridge/weekly_digest/top_artists_digest 这三个,过去共用同一对
// lastfm_user/lastfm_api_key 凭据当唯一开关,逻辑上是三个独立能力)。
// 九个歌词源的 key——跟 enrich.go 里 lyricCandidate.source/scoredLyricCandidateResult.
// Source 的取值、以及 desktop-lyrics「歌词管理」窗口 LyricsManagerView.swift 的
// sourceDisplayName 逐字对应,这是整个项目里"歌词源"唯一的一套 id,不是这里新起的。
const (
	lyricSourceNetease    = "netease"
	lyricSourceQQ         = "qq"
	lyricSourceKugou      = "kugou"
	lyricSourceMusixmatch = "musixmatch"
	lyricSourceLRCLIB     = "lrclib"
	// AMLL TTML database community repository (see amllttml.go).
	// Provides structured duet/dialogue attribution via TTML ttm:agent without relying on line prefix heuristics.
	lyricSourceAMLL = "amll"
	// LyricFind via YouTube Music backend (see ytmusic.go).
	// YouTube Music lyrics backends include Musixmatch and LyricFind; duplicate Musixmatch results
	// are filtered out via timedLyricsData sourceMessage. Provides synchronized line-by-line lyrics.
	lyricSourceLyricFind = "lyricfind"
	// Kuwo Music lyrics source (see kuwo.go).
	// Employs customized re-scoring and ranking heuristics for search results. Provides line-by-line lyrics.
	lyricSourceKuwo = "kuwo"
	// Migu Music lyrics source (see migu.go).
	// Provides line-by-line LRC lyrics and Chinese translations for foreign language tracks.
	lyricSourceMigu = "migu"
	// Deezer lyrics source (see deezer.go).
	// Queries Deezer's GraphQL API with anonymous token, providing line-by-line synchronized lyrics
	// with strong coverage for European catalogs.
	lyricSourceDeezer = "deezer"
)

const (
	lyricsModeSmart    = "smart"
	lyricsModePriority = "priority"
)

// Supported media player identifiers matching Swift PlaybackPlayer rawValues in shared configuration.
// Apple Music is queried via AppleScript; QQ Music, NetEase Music, Spotify, and Kugou Music
// lack dedicated AppleScript dictionaries (no .sdef / NSAppleScriptEnabled) and publish playback
// state to system-level MediaRemote, read via media-control.
// playerAuto queries media-control for the current system Now Playing app.
const (
	playerAppleMusic = "apple_music"
	playerQQMusic    = "qq_music"
	playerNetease    = "netease_music"
	playerSpotify    = "spotify"
	// Kugou Music is a Mac Catalyst application publishing Now Playing state to system MediaRemote.
	playerKugou      = "kugou_music"
	playerAuto       = "auto"
)

// lyricsSourceDefaultOrder defines the default source order for priority mode, aligned with
// Swift LyricsSource.allCases declaration order.
var lyricsSourceDefaultOrder = []string{
	lyricSourceKugou, lyricSourceNetease, lyricSourceQQ, lyricSourceMusixmatch, lyricSourceLRCLIB,
	lyricSourceAMLL, lyricSourceLyricFind, lyricSourceKuwo, lyricSourceMigu, lyricSourceDeezer,
}

type featureFlagsFile struct {
	// Player: Legacy single-player field maintained for one-time migration to Players.
	Player string `json:"player,omitempty"`
	// Players: Multi-player selection set corresponding to Swift FeatureSettingsStore.players.
	Players       []string `json:"players,omitempty"`
	AlbumPrefetch *bool    `json:"album_prefetch,omitempty"`
	// LyricsAutoUpgrade controls whether previously resolved lyrics may be automatically upgraded
	// in the background when matching/scoring algorithms change. Defaults to true.
	LyricsAutoUpgrade    *bool `json:"lyrics_auto_upgrade,omitempty"`
	LastfmMirrorScrobble *bool `json:"lastfm_mirror_scrobble,omitempty"`
	// LastfmScrobbleArtistMode determines artist attribution for collaborative tracks ("A & B")
	// sent to Last.fm (scrobbleArtistAll / scrobbleArtistFirst / scrobbleArtistSmart).
	LastfmScrobbleArtistMode string `json:"lastfm_scrobble_artist_mode,omitempty"`
	// LastfmScrobbleFirstArtistOnly: Legacy boolean flag maintained for backward compatibility.
	LastfmScrobbleFirstArtistOnly *bool `json:"lastfm_scrobble_first_artist_only,omitempty"`
	// ScrobbleShortTracks allows scrobbling tracks shorter than 30s to Last.fm (default: false,
	// complying with standard Last.fm rules). Only affects Last.fm scrobbles; ListenBrainz is unaffected.
	ScrobbleShortTracks *bool `json:"scrobble_short_tracks,omitempty"`
	// LastfmScrobblePoint configures the playback progress milestone for triggering Last.fm scrobbles
	// (scrobblePointHalf / scrobblePoint75 / scrobblePoint90 / scrobblePointEnd). Default: 50% or 4 min.
	LastfmScrobblePoint string `json:"lastfm_scrobble_point,omitempty"`
	WeeklyDigest        *bool  `json:"weekly_digest,omitempty"`
	// DailyDigest：见 daily.go。跟 WeeklyDigest 是独立开关，两个可以同时开、只开一个、
	// 或都不开。
	DailyDigest *bool `json:"daily_digest,omitempty"`
	// WeeklyDigestSource/DailyDigestSource："lastfm"/"listenbrainz"/空。空值(用户
	// 从没在设置里手动选过)交给 resolveDigestSource(digest.go)按"两个账号都配了→
	// lastfm,只配了一个→用那个,都没配→跳过"自动判定,不是"缺省当 lastfm 处理"这么
	// 简单——所以这里特意留空字符串而不是给一个非空的默认值常量。
	WeeklyDigestSource string `json:"weekly_digest_source,omitempty"`
	DailyDigestSource  string `json:"daily_digest_source,omitempty"`
	// LyricsSources：启用的歌词源集合(lyricSourceXxx 常量的子集)。nil/缺失 = 全部
	// 启用,维持这个字段加之前的既有行为不变。
	LyricsSources []string `json:"lyrics_sources,omitempty"`
	// AMLLLyrics: Migration marker for AMLL source. Ensures existing configurations missing
	// this entry automatically enable AMLL on upgrade without overriding explicit customizations.
	AMLLLyrics *bool `json:"amll_lyrics,omitempty"`
	// LyricFindLyrics: Migration marker for LyricFind source.
	LyricFindLyrics *bool `json:"lyricfind_lyrics,omitempty"`
	// KuwoLyrics: Migration marker for Kuwo source.
	KuwoLyrics *bool `json:"kuwo_lyrics,omitempty"`
	// MiguLyrics: Migration marker for Migu source.
	MiguLyrics *bool `json:"migu_lyrics,omitempty"`
	// DeezerLyrics: Migration marker for Deezer source.
	DeezerLyrics *bool `json:"deezer_lyrics,omitempty"`
	// LyricsSourceMode："smart"(默认,全部源全查+打分取最高分,见 enrich.go 的
	// scoredLyricCandidates/pickLyricCandidate)或"priority"(按 LyricsSourceOrder
	// 的顺序,取第一个通过质量校验(score>=0)的源,不比较分数高低)。空值按 smart 处理。
	LyricsSourceMode string `json:"lyrics_source_mode,omitempty"`
	// LyricsSourceOrder：只有 LyricsSourceMode == "priority" 时才生效。缺失时按
	// lyricsSourceDefaultOrder 兜底。
	LyricsSourceOrder []string `json:"lyrics_source_order,omitempty"`
	// LyricsDir：歌词文件夹("歌词文件夹作为权威源"读写的那个文件夹)的自定义位置。
	// 留空则用默认位置(config.json 同目录下的 lyrics/,main.go 里兜底)。
	LyricsDir string `json:"lyrics_dir,omitempty"`
	// LyricsTranslationLanguage："auto"(跟随系统语言,默认)或 ISO 639-1 两位小写代码
	// (如"en"/"es"/"ja")——Musixmatch 译文(crowd.track.translations.get)的目标语言。
	// 网易云/QQ 音乐的译文固定是中文,只有 Musixmatch 这个源支持指定任意语言。
	// resolveLyricsTranslationLanguage 负责把"auto"/空值解析成具体代码,见其注释。
	LyricsTranslationLanguage string `json:"lyrics_translation_language,omitempty"`
	// LyricsMachineTranslation:歌词源没带社区译文时,用机器翻译补一份(见 translate.go)。
	// **默认关**,跟其它附加功能一致 —— 它会把歌词正文发给第三方翻译服务,而现有的五个
	// 歌词源只发歌手/歌名,这是一条新的外发数据,该由用户显式同意。
	LyricsMachineTranslation *bool `json:"lyrics_machine_translation,omitempty"`
	// LaunchLyrimuseOnMusicOpen：检测到 Music.app 从没运行变成运行时,顺带启动/唤起
	// Lyrimuse.app(见 companionlaunch.go)。反方向("打开 Lyrimuse 时唤起 Music")
	// 不在这份共享文件里,是 Swift 侧 AppSettings 自己的纯本地设置,不需要 collector
	// 知道。
	LaunchLyrimuseOnMusicOpen *bool `json:"launch_lyrimuse_on_music_open,omitempty"`
	// LaunchLyrimuseOnPlayers specifies per-player auto-launch preferences matching Swift FeatureSettingsStore.
	// An empty list disables auto-launch. When omitted from legacy configuration, falls back to LaunchLyrimuseOnMusicOpen.
	LaunchLyrimuseOnPlayers []string `json:"launch_lyrimuse_on_players,omitempty"`
	// TrustedPlayers: Map of user-trusted third-party player bundle IDs to display names.
	// By default, unknown players are excluded from track monitoring and scrobbling to prevent
	// non-music browser media or podcasts from polluting scrobble history and lyric caches.
	// Users can explicitly grant trust in settings.
	TrustedPlayers map[string]string `json:"trusted_players,omitempty"`
	// LastfmExcludedBundles: Application bundle IDs excluded from Last.fm scrobbling,
	// corresponding to Swift FeatureFlagsFile.lastfmExcludedBundles. Only affects Last.fm
	// scrobbles and local logs; ListenBrainz remains unaffected.
	LastfmExcludedBundles []string `json:"lastfm_excluded_bundles,omitempty"`
	// LyricsDecisionTrace enables append-only NDJSON logging of lyric resolution decisions (see lyricstrace.go).
	// Intended strictly for offline diagnostic tracing.
	LyricsDecisionTrace *bool `json:"lyrics_decision_trace,omitempty"`
}

// featureFlags is the resolved (never-nil) configuration consulted across collector routines.
// Background dispatchers (pushRelayState, topArtistsDigest) execute when required credentials
// and endpoints are configured.
type featureFlags struct {
	// Players is the validated set of active player identifiers populated by resolvePlayers.
	Players       map[string]bool
	AlbumPrefetch bool
	// See featureFlagsFile.LyricsAutoUpgrade.
	LyricsAutoUpgrade    bool
	LastfmMirrorScrobble bool
	// Collaborative track artist mode (scrobbleArtistAll / scrobbleArtistFirst / scrobbleArtistSmart).
	LastfmScrobbleArtistMode string
	// See featureFlagsFile.ScrobbleShortTracks.
	ScrobbleShortTracks bool
	// See featureFlagsFile.LastfmScrobblePoint.
	LastfmScrobblePoint string
	WeeklyDigest        bool
	DailyDigest         bool
	WeeklyDigestSource  string
	DailyDigestSource   string
	// LyricsSources, LyricsSourceMode, and LyricsSourceOrder configure candidate evaluation
	// in pickLyricCandidate (enrich.go) and searchcli.go.
	LyricsSources     map[string]bool
	LyricsSourceMode  string
	LyricsSourceOrder []string
	// LyricsDir 空字符串表示"用默认位置",由 main.go 里设置包级变量 lyricsDir 时兜底,
	// 不在这里(loadFeatureFlags)展开成绝对路径——那时候 *cfgPath 还没解析完。
	LyricsDir string
	// LyricsTranslationLanguage 是已经解析过的具体 ISO 639-1 代码(不会是"auto"或空值,
	// 见 resolveLyricsTranslationLanguage)。三处读取,含义都是"译文要什么语言":
	// musixmatchTranslationLRC(musixmatch.go)向 Musixmatch 索取该语言的社区译文;
	// appleLangCode / myMemoryLangCode(translate.go)把它转成端上翻译和网络兜底
	// 各自的语言代码。网易云/QQ 不在此列——它们自带的社区译文只有中文,给不了别的语言。
	LyricsTranslationLanguage string
	// 见上面同名字段的注释。只被 needsTranslationBackfill/backfillTranslation 读取。
	LyricsMachineTranslation bool
	// LaunchLyrimuseOnMusicOpen 只被 companionlaunch.go 读取。
	LaunchLyrimuseOnMusicOpen bool
	// LaunchLyrimuseOnPlayers 是逐播放器勾选的集合(键是 player* 常量);nil = 文件里没有这个键(老配置),
	// 由 companionLaunchProcessNames 退回布尔年代语义。只被 companionlaunch.go 读取。
	LaunchLyrimuseOnPlayers map[string]bool
	// LyricsDecisionTrace 只被 lyricstrace.go 读取,见那边注释。
	LyricsDecisionTrace bool
	// TrustedPlayers 是已经清洗过的形态(见 resolveTrustedPlayers):键一定非空、一定不是
	// 五个内置播放器之一;值可能是空字符串(反查不到 App 名),此时标签退回 bundle id。
	TrustedPlayers map[string]string
	// LastfmExcludedBundles 是已清洗的集合(见 resolveLastfmExcludedBundles),空 map 而不是 nil。
	// 只被 lastfmexclude.go 的 lastfmExcluded 读取;poller 在开会话那一拍算一次存进 playSession。
	LastfmExcludedBundles map[string]bool
}

// features is set once in main() before run() starts; every gate site reads
// this package-level value (same style as enrichCache/lyricsDir等既有包级状态)。
// featuresMu protects concurrent reads and writes to features and its configuration maps.
var (
	featuresMu sync.RWMutex
	features   featureFlags
)

// resolveLaunchLyrimuseOnPlayers 把「跟随哪些播放器启动」的原始列表清洗成集合:键缺失(nil,布尔年代
// 的老配置)原样返回 nil,由 companionLaunchProcessNames 退回旧语义;键在(哪怕是空列表)就严格按它来,
// 不认识的值丢掉(auto 也丢 —— 它不是一个可以"启动"的进程)。
func resolveLaunchLyrimuseOnPlayers(raw []string) map[string]bool {
	if raw == nil {
		return nil
	}
	out := map[string]bool{}
	for _, p := range raw {
		switch p {
		case playerAppleMusic, playerQQMusic, playerNetease, playerKugou, playerSpotify:
			out[p] = true
		}
	}
	return out
}

func boolOr(p *bool, def bool) bool {
	if p == nil {
		return def
	}
	return *p
}

// loadFeatureFlags reads the shared feature-toggle file (best-effort — missing
// file / unparseable content all resolve to defaults below). Core behavior
// toggles (lyrics/albumPrefetch) miss-field-defaults to true — a
// pure increment that never silently changes existing behavior. The toggles
// that each require an external account (Last.fm mirror / weekly digest /
// daily digest) default to false instead: turning them on by default for a
// stranger who never opened Settings would silently start network calls to
// services they never configured.
func loadFeatureFlags(path string) featureFlags {
	var f featureFlagsFile
	if data, err := os.ReadFile(path); err == nil {
		if jerr := json.Unmarshal(data, &f); jerr != nil {
			log.Printf("parse feature flags %s: %v (falling back to defaults)", path, jerr)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		log.Printf("read feature flags %s: %v (falling back to defaults)", path, err)
	}
	return featureFlags{
		Players:        resolvePlayers(f.Players, f.Player),
		TrustedPlayers: resolveTrustedPlayers(f.TrustedPlayers),
		// 缺失 / 空 = 全部上送:跟 TrustedPlayers 一样"少一个键不改变现有行为"。
		LastfmExcludedBundles: resolveLastfmExcludedBundles(f.LastfmExcludedBundles),
		AlbumPrefetch:         boolOr(f.AlbumPrefetch, true),
		// 默认 true = 保持这个能力上线以来的行为;Swift 侧 `lyricsAutoUpgrade` 的属性初值
		// 必须跟这里一致(两侧默认值对齐那条老规矩,见上面 AlbumPrefetch 的注释)。
		LyricsAutoUpgrade:    boolOr(f.LyricsAutoUpgrade, true),
		LastfmMirrorScrobble: boolOr(f.LastfmMirrorScrobble, false),
		// 默认 scrobbleArtistAll:原样发整串。理由见 lastfm.go resolveScrobbleArtist ——
		// ListenBrainz 文档要求合唱 credit "include them all",Navidrome 同名开关默认也是 false。
		LastfmScrobbleArtistMode: resolveScrobbleArtistMode(f.LastfmScrobbleArtistMode, f.LastfmScrobbleFirstArtistOnly),
		// 默认 false:照 Last.fm 官方规则,短于 30 秒不记。fail-closed 跟其余"改变上送内容"的
		// 开关一致——字段缺失不能让老用户的历史突然多出一批短曲目。
		ScrobbleShortTracks:       boolOr(f.ScrobbleShortTracks, false),
		LastfmScrobblePoint:       resolveScrobblePoint(f.LastfmScrobblePoint),
		WeeklyDigest:              boolOr(f.WeeklyDigest, false),
		DailyDigest:               boolOr(f.DailyDigest, false),
		WeeklyDigestSource:        f.WeeklyDigestSource,
		DailyDigestSource:         f.DailyDigestSource,
		LyricsSources:             resolveLyricsSources(f.LyricsSources, f.AMLLLyrics, f.LyricFindLyrics, f.KuwoLyrics, f.MiguLyrics, f.DeezerLyrics),
		LyricsSourceMode:          resolveLyricsSourceMode(f.LyricsSourceMode),
		LyricsSourceOrder:         resolveLyricsSourceOrder(f.LyricsSourceOrder),
		LyricsDir:                 f.LyricsDir,
		LyricsTranslationLanguage: resolveLyricsTranslationLanguage(f.LyricsTranslationLanguage),
		LyricsMachineTranslation:  boolOr(f.LyricsMachineTranslation, false),
		LaunchLyrimuseOnMusicOpen: boolOr(f.LaunchLyrimuseOnMusicOpen, true),
		LaunchLyrimuseOnPlayers:   resolveLaunchLyrimuseOnPlayers(f.LaunchLyrimuseOnPlayers),
		LyricsDecisionTrace:       boolOr(f.LyricsDecisionTrace, false),
	}
}

// 合唱串上送档位(features.LastfmScrobbleArtistMode)。字符串值跟 Swift 侧
// LastfmScrobbleArtistMode 的 rawValue 逐字相同 —— 两侧通过同一份 features.json 交换。
const (
	// 原样发播放器报的整串(默认)。
	scrobbleArtistAll = "all"
	// 纯字符串取第一位(firstCreditedArtist),不联网。
	scrobbleArtistFirst = "first"
	// 按 Last.fm 编目判定:合唱串已被收录就原样发;没收录、而第一位歌手名下这首歌已被
	// 收录才折成第一位;两边都查不到或查询失败维持原样。见 lastfmcollapse.go。
	scrobbleArtistSmart = "smart"
)

// resolveScrobbleArtistMode 把文件里的档位字符串校验成三个常量之一;缺失/非法时退回
// 遗留的二态开关 lastfm_scrobble_first_artist_only 做一次迁移(true → first),两者都没有
// 才兜底 all。非法值**不**当成 all 静默吞掉之外还会记一行日志 —— 拼错档位名的后果是
// "设置里选了智能、collector 一直在发整串",不报出来查不到。
func resolveScrobbleArtistMode(raw string, legacyFirstOnly *bool) string {
	switch raw {
	case scrobbleArtistAll, scrobbleArtistFirst, scrobbleArtistSmart:
		return raw
	case "":
	default:
		log.Printf("feature flags: unknown lastfm_scrobble_artist_mode %q (falling back)", raw)
	}
	if legacyFirstOnly != nil && *legacyFirstOnly {
		return scrobbleArtistFirst
	}
	return scrobbleArtistAll
}

// Last.fm scrobble trigger points (features.LastfmScrobblePoint). Values correspond
// directly to Swift LastfmScrobblePoint rawValues shared via features.json.
const (
	// 官方规则:播满曲长一半、或满 4 分钟,先到为准(默认)。这也是 ListenBrainz 那一路提交的时刻,
	// 所以这一档下 Last.fm 跟原来一样当场发。
	scrobblePointHalf = "50"
	// 播满曲长的 75% / 90%。纯按已播时长算,不再套 4 分钟上限——"听了 75%"就是字面意思。
	scrobblePoint75 = "75"
	scrobblePoint90 = "90"
	// 一直放到结尾才记,中途切歌不记。判据见 poller.go sessionEndedNaturally。
	scrobblePointEnd = "end"
)

// resolveScrobblePoint 把文件里的时点字符串校验成四个常量之一;缺失兜底 scrobblePointHalf,
// 非法值同样兜底但记一行日志(理由同 resolveScrobbleArtistMode:拼错了不报出来查不到)。
func resolveScrobblePoint(raw string) string {
	switch raw {
	case scrobblePointHalf, scrobblePoint75, scrobblePoint90, scrobblePointEnd:
		return raw
	case "":
	default:
		log.Printf("feature flags: unknown lastfm_scrobble_point %q (falling back)", raw)
	}
	return scrobblePointHalf
}

// isValidPlayerValue 核对一个字符串是不是六个已知播放器 rawValue 之一——resolvePlayers
// 校验列表条目、以及迁移路径校验 legacy 字段共用同一份判据。
func isValidPlayerValue(p string) bool {
	switch p {
	case playerAppleMusic, playerQQMusic, playerNetease, playerSpotify, playerKugou, playerAuto:
		return true
	default:
		return false
	}
}

// resolvePlayers resolves active players from featureFlagsFile.Players.
// Validates each entry against supported players, falling back to legacy Player
// if the list contains no valid entries, and ultimately defaulting to playerAuto.
func resolvePlayers(list []string, legacy string) map[string]bool {
	m := map[string]bool{}
	for _, p := range list {
		if isValidPlayerValue(p) {
			m[p] = true
		}
	}
	if len(m) > 0 {
		return m
	}
	if isValidPlayerValue(legacy) {
		return map[string]bool{legacy: true}
	}
	return map[string]bool{playerAuto: true}
}

// resolveTrustedPlayers 清洗用户信任列表:去掉空 bundle id、去掉首尾空白、去掉五个
// 内置播放器(它们本来就认,留在这里只会让"已信任"列表看起来莫名多几条)。
//
// 返回 nil(而不是空 map)是刻意的:调用方一律用 `m[k]` 取值,对 nil map 取值是合法的
// 零值读取,不需要在每个调用点判空。
func resolveTrustedPlayers(m map[string]string) map[string]string {
	if len(m) == 0 {
		return nil
	}
	builtin := map[string]bool{
		"com.apple.Music": true, qqMusicBundleID: true,
		neteaseMusicBundleID: true, spotifyBundleID: true, kugouMusicBundleID: true,
	}
	out := make(map[string]string, len(m))
	for bundleID, name := range m {
		id := strings.TrimSpace(bundleID)
		if id == "" || builtin[id] {
			continue
		}
		out[id] = strings.TrimSpace(name)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func resolveLyricsSources(list []string, amllSeen *bool, lyricFindSeen *bool, kuwoSeen *bool, miguSeen *bool, deezerSeen *bool) map[string]bool {
	if len(list) == 0 {
		return map[string]bool{
			lyricSourceNetease: true, lyricSourceQQ: true, lyricSourceKugou: true,
			lyricSourceMusixmatch: true, lyricSourceLRCLIB: true,
			lyricSourceAMLL: true, lyricSourceLyricFind: true, lyricSourceKuwo: true, lyricSourceMigu: true,
			lyricSourceDeezer: true,
		}
	}
	m := make(map[string]bool, len(list)+1)
	for _, s := range list {
		m[s] = true
	}
	// One-time migration for newly introduced sources (see featureFlagsFile migration markers).
	// Evaluated independently so that newly introduced sources are enabled by default on upgrades
	// without overriding manual user customizations for previously existing sources.
	if amllSeen == nil {
		m[lyricSourceAMLL] = true
	}
	if lyricFindSeen == nil {
		m[lyricSourceLyricFind] = true
	}
	if kuwoSeen == nil {
		m[lyricSourceKuwo] = true
	}
	if miguSeen == nil {
		m[lyricSourceMigu] = true
	}
	if deezerSeen == nil {
		m[lyricSourceDeezer] = true
	}
	return m
}

// lyricSourceEnabled 是"这个歌词源开着吗"的**唯一**判据。判定原先散在六处、形式还不
// 完全一致(有的带 len==0 兜底、有的不带),统一到这里。
// 注:resolveLyricsSources 在列表为空时返回全集,所以 LyricsSources 永远非 nil,
// 那些 len==0 的兜底其实是历史冗余,留着不碍事。
func lyricSourceEnabled(source string) bool {
	featuresMu.RLock()
	defer featuresMu.RUnlock()
	return len(features.LyricsSources) == 0 || features.LyricsSources[source]
}

func getFeaturesLyricsSources() map[string]bool {
	featuresMu.RLock()
	defer featuresMu.RUnlock()
	if features.LyricsSources == nil {
		return nil
	}
	out := make(map[string]bool, len(features.LyricsSources))
	for k, v := range features.LyricsSources {
		out[k] = v
	}
	return out
}

func setFeaturesLyricsSources(m map[string]bool) {
	featuresMu.Lock()
	defer featuresMu.Unlock()
	if m == nil {
		features.LyricsSources = nil
		return
	}
	out := make(map[string]bool, len(m))
	for k, v := range m {
		out[k] = v
	}
	features.LyricsSources = out
}

func resolveLyricsSourceMode(mode string) string {
	if mode == lyricsModePriority {
		return lyricsModePriority
	}
	return lyricsModeSmart
}

func resolveLyricsSourceOrder(order []string) []string {
	if len(order) == 0 {
		return append([]string(nil), lyricsSourceDefaultOrder...)
	}
	return order
}

// resolveLyricsTranslationLanguage 把共享文件里的"auto"/空值解析成一个具体的 ISO
// 639-1 代码——collector 是长驻后台进程(launchd gui/$(id -u) 用户级 agent,跟登录用户
// 的 Aqua 会话同一身份运行),用 `defaults read -g AppleLocale` 能可靠读到这台 Mac 当前
// 的系统语言,不依赖 launchd 环境变量(环境变量对用户级 agent 不一定完整继承登录 shell
// 的 locale 设置)。读不到/查不到对应语言代码时兜底 "en"——总比整段不请求译文更有用。
// 只在启动时解析一次(跟这个文件里其它字段同一个"读一次,重启才生效"的既定约定),运行
// 中途切系统语言不会实时生效。
func resolveLyricsTranslationLanguage(lang string) string {
	if lang != "" && lang != "auto" {
		return lang
	}
	if code := systemLanguageCode(); code != "" {
		return code
	}
	return "en"
}

// systemLanguageCode 读 macOS 当前系统语言,取 AppleLocale("zh_Hans_CN"/"en_US"/
// "ja_JP"这类形式)下划线前的两位语言代码并转小写。查询失败(命令不存在/超时/返回值
// 解析不出下划线分隔的语言段)一律返回空串,交给调用方兜底,不 panic、不重试。
func systemLanguageCode() string {
	out, err := exec.Command("defaults", "read", "-g", "AppleLocale").Output()
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(string(out))
	if i := strings.IndexByte(s, '_'); i > 0 {
		s = s[:i]
	}
	if s == "" {
		return ""
	}
	return strings.ToLower(s)
}
