import Foundation
import Combine
import CoreImage
import CoreGraphics
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "local")

// 本地播放数据源: 从本地播放器读取播放状态(AppleScript / media-control)，
// 并读取本地 enrich 缓存加载对应歌词。
@MainActor
public final class LocalPlaybackSource: ObservableObject {
    public static let shared = LocalPlaybackSource()

    @Published public private(set) var title: String = ""
    @Published public private(set) var artist: String = ""
    @Published public private(set) var album: String = ""
    @Published public private(set) var isPlayingNow: Bool = false
    @Published public private(set) var currentLine: SyncedLyricLine?
    @Published public private(set) var nextLineText: String?
    /// 下一行声部(见 SyncedLyricLine.side)，独立于 currentLine?.side。
    @Published public private(set) var nextLineSide: LyricDuet.Side?
    /// 当前歌词行下标(20Hz tick 更新，仅在换行时重新赋值)。
    @Published public private(set) var currentLineIndex: Int?
    /// 歌词窗口滚动锚点：空档期先指向下一行，染色保持 currentLineIndex。
    @Published public private(set) var scrollLineIndex: Int?
    /// 单行展示面(灵动岛/菜单栏)当前展示行(唱完即切，间奏期为 nil)。
    @Published public private(set) var compactLine: SyncedLyricLine?
    /// compactLine 为 nil 时的状态：true 表示间奏占位符(♪)，false 表示尚无歌词。
    @Published public private(set) var compactShowsPlaceholder: Bool = false
    /// compactLine 展示停留时长(毫秒)，供菜单栏跑马灯配速。
    @Published public private(set) var compactDwellMs: Int?
    /// compactLine 唱响前的提前量(毫秒)，供跑马灯作为静止等待时长。
    @Published public private(set) var compactLeadInMs: Int?
    @Published public private(set) var allLines: [LyricsWindowLine] = []
    /// 全曲间奏标记列表。
    @Published public private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    /// 当前所处的间奏标记下标。
    @Published public private(set) var currentGapIndex: Int?
    /// 当前行逐字填色是否已定格。用于悬浮歌词 TimelineView 暂停驱动避免无视觉变化时空转。
    @Published public private(set) var currentLineFillSettled: Bool = true
    /// 当前曲目是否有歌词内容(转发自 syncEngine.hasContent)。
    @Published public private(set) var hasLyricsContent: Bool = false
    /// 经歌词源确认为纯音乐曲目。
    @Published public private(set) var isCurrentTrackInstrumental: Bool = false
    /// 联网解析完成但未匹配到歌词(与纯音乐互斥)。
    @Published public private(set) var currentTrackHasNoLyrics: Bool = false
    /// 无时间戳的纯文本歌词兜底，仅用于歌词窗口静态显示。
    @Published public private(set) var currentTrackPlainLyrics: String = ""
    /// 联网解析失败且因网络离线导致。
    @Published public private(set) var collectorNetworkDown: Bool = false
    /// 当前播放是否为广告插播。
    @Published public private(set) var isCurrentTrackAdBreak: Bool = false
    /// 当前广告插播序号及总数(例如 1/2)。
    ///
    /// 只有 **YouTube Music 网页广告**给得出 —— 它自己把「赞助商广告 1/2 ·」写在页面的广告
    /// 徽章上,探针顺路读回来(`YouTubeMusicAdProbe.Reading.adSlot`)。Spotify(原生和网页)
    /// 没有这个东西,恒 nil;英文界面的 "Ad 1 of 2" 也抓不到(探针只认斜杠写法,见那边头注)。
    /// **拿不到就是 nil,界面上那一段不画** —— 同「时长未知不画倒计时」那条纪律,不编数字。
    ///
    /// ⚠️ 跟着 `isCurrentTrackAdBreak` 一起收:广告一结束必须清掉,否则下一首歌的卡片上会
    /// 挂着上一次插播的「1/2」。
    @Published public private(set) var currentAdSlot: YouTubeMusicAdProbe.AdSlot? = nil
    /// 当前曲目实际生效的总偏移（毫秒）= 全局基准 + 本曲微调，直接同步 syncEngine.offsetMs 权威值。
    @Published public private(set) var currentLyricsOffsetMs: Int = 0
    /// 总偏移中仅属于当前曲目的微调值（不含全局基准），供重置按钮与菜单指示使用。
    @Published public private(set) var trackLyricsOffsetMs: Int = 0
    // "歌词窗口"背景用的模糊封面图——原始图片数据(JPEG/PNG),不是 NSImage:
    // LyrimuseCore 这一层刻意不引入 AppKit/SwiftUI(见 Package.swift 的单向依赖注释),
    // 解码成 NSImage/Image 交给 lyrimuse 主 App target 的 View 自己做。只在换歌那一刻
    // 异步取一次(见 apply()/fetchArtworkForCurrentTrack()),不是每 2 秒轮询的一部分。
    @Published public private(set) var artworkData: Data?
    // 从 artworkData 里算出来的单一平均色(十六进制 #RRGGBBAA)——供"跟随封面"外观模式
    // 用作悬浮歌词的动态高亮色。跟 artworkData 同一时刻算好、同一套 expectedKey 换歌
    // 校验(见 fetchArtworkForCurrentTrack()),不是每次渲染都现算。只存十六进制字符串
    // 不存 Color/NSColor——这一层刻意不引入 AppKit/SwiftUI(见 Package.swift 的单向
    // 依赖注释),转成 Color 交给 lyrimuse 主 App target(PlaybackCoordinator)做,跟
    // AppSettings 里所有颜色字段都是"存 hex、用的地方再转 Color"同一个既有模式。
    //
    // ⚠️ 2026-08-17 从 artworkAccentHex 改名成这个,同时把"提亮"从这里挪走了 —— 这里
    // 现在是**未经任何调整的原始均值**。原因见下面 accentAgainstStroke 的注释:两个消费面
    // (灵动岛永远深底 / 桌面悬浮歌词背景未知)对"这个颜色该多亮"的要求正好相反,在源头
    // 提前统一成一个"够亮"的值,等于替桌面那一侧做了错误的决定。各自的处理放在
    // PlaybackCoordinator,那里才知道自己是哪个面。
    @Published public private(set) var artworkAverageHex: String?
    /// Spotify 原生客户端这首歌在 Spotify 图床上的封面地址(AppleScript `artwork url`,640 档),由
    /// `SpotifyPositionProbe` 开播 2.5s 后那次脚本顺带带回来(2026-09-09,经 noteSpotifyArtwork 落到这里,
    /// 先核对还是这首)。换歌 / 停播置 nil;Spotify 网页版由 BrowserPositionProbe 从页面带回同一格式的地址
    /// (2026-09-09),其它播放器恒 nil。消费方是
    /// `PlaybackCoordinator.refreshSpotifyOriginalCover`:系统那份封面(实测 600×600)本来就身份精确,
    /// 这条只为把歌词窗口那张 920px 卡换成**同一张图**的原图档,见 03 章「高清替代」。
    @Published public private(set) var spotifyArtworkURL: URL?
    // "歌词窗口"进度条用(2026-08-04 随 Apple Music 风格重做补上):暂停时 anchor 会被
    // 置 nil(见 apply() 的 else 分支),进度条如果只认 anchor,一暂停就整个没有位置可
    // 显示。暂停态 media-control/AppleScript 的 elapsedTime 本身就是精确的冻结位置,
    // 这里单独发布出来,让进度条在暂停时显示冻结的进度而不是直接消失。播放中恒为 nil
    // (此时该用 anchor 外推)。
    @Published public private(set) var pausedPositionMs: Int?
    // 当前曲目时长(毫秒)——anchor 里虽然也带 durationMs,但暂停时 anchor 是 nil,
    // 冻结进度条还需要时长算比例,单独发布。没有曲目/时长未知时为 nil。
    @Published public private(set) var currentDurationMs: Int?
    /// 电台专用:当前这首歌已经越过真曲长(= 进了口白那一段)。收歌词看它,见 fastTick()。
    private var radioTrackFinished = false
    /// 同一件事发布给界面(2026-09-11):三个展示面在口白期间把歌词那一格换成「口白」,
    /// 语义与既有的 `isCurrentTrackAdBreak` 平行 —— 都是"这一刻在放的不是歌"。
    @Published public private(set) var isRadioTalkBreak = false
    /// 当前这个台的台名与台标(口白期间顶上去,见 RadioStationCard)。抓不到台卡就都是 nil,
    /// 界面退回原样(还显示上一首)—— 宁可保持现状,也不要编一个台名。
    @Published public private(set) var radioStationName: String?
    @Published public private(set) var radioStationArtwork: Data?
    /// 台卡的内存副本 + 还在等封面的那张台卡的 trackKey(台卡那一拍往往还没有图,
    /// 封面是几百毫秒后单独一行,见 noteRadioStationArtwork)。
    private var radioStationCard: RadioStationCard?
    private var radioStationCardLoaded = false
    private var pendingStationCardKey: String?

    // (2026-09-06 之前这里有一个全局的"卡拉OK效果"开关:关掉就让引擎不解析逐字数据,四个
    //  展示面一起退成整行高亮。已撤:引擎始终解析逐字数据,"要不要逐字填色"改成悬浮歌词 /
    //  灵动岛 / 菜单栏各自的开关,由各展示面在自己的消费点上把 `SyncedLyricLine` 压成整行
    //  (`SyncedLyricLine.lineLevel`);歌词窗口始终逐字。见 AppSettings.overlayLyricsKaraoke。)
    /// 要给哪几种文字标罗马音。改了立刻重新加载当前这首 —— 这道开关同时管服务端字段和
    /// 客户端兜底(见 LyricsSyncEngine.romanizationText 那道 guard)。
    @Published public var romanizationScripts: RomanizationScripts = .default {
        didSet { reloadCurrentLyrics() }
    }
    /// 歌词正文的简繁偏好。改了立刻重新加载当前这首 —— 转换发生在**送进解析引擎之前**,
    /// 缓存里存的原文一个字节都不动,切回来是无损的。
    @Published public var chineseVariant: ChineseVariant = .off {
        didSet { reloadCurrentLyrics() }
    }
    /// 本机是否检索到过中文歌词。用于控制设置界面简繁转换入口展示，持久保持 true。
    @Published public private(set) var sawChineseLyrics = false
    /// 当前曲目歌词是否支持简繁转换（正文或可见译文中包含简繁差异字符）。
    /// 满足：菜单展示 ⟺ 转换有效且对用户可见。
    @Published public private(set) var currentLyricsSupportsChineseVariant = false

    /// 译文有没有在屏幕上 —— 镜像 App 层的 `AppSettings.showTranslation`
    /// (Core 够不到 AppSettings,由 AppDelegate 订阅推进来)。
    ///
    /// ⚠️ 这个开关**不参与歌词装载**:译文转不转由 `chineseVariant` 决定,关掉它只是不画
    /// 那一行,引擎侧照常转(见 reloadCurrentLyrics 里的 `variant.converted(lyricsTr)`)。
    /// 它唯一的用途是上面那条显隐判据 —— Core 之所以需要知道一件纯展示的事,理由在那里。
    /// 也正因为不参与装载,它**不进** `LyricsReloadSnapshot`:那道闸管的是"要不要重算",
    /// 而这个标志的重算发生在闸之前,翻转时正好只更新标志、跳过整段解析。
    @Published public var showsTranslation = false {
        didSet { reloadCurrentLyrics() }
    }

    /// 「简繁转换」这一项该不该露出来。抽成纯函数是为了让 selftest 能直接钉住这条不变量——
    /// `reloadCurrentLyrics()` 要一份真实播放快照才跑得起来,测不到。
    /// (`nonisolated`:不碰任何 @MainActor 隔离状态,跟 `servoDecision` 同一个理由。)
    public nonisolated static func supportsChineseVariant(
        lyrics: String, translation: String, translationVisible: Bool
    ) -> Bool {
        ChineseVariant.affects(lyrics)
            || (translationVisible && ChineseVariant.affects(translation))
    }

    private let syncEngine = LyricsSyncEngine()
    // 公开给 View 层——逐字填色现在按渲染帧频(TimelineView)从这个锚点直接外推真实
    // 播放位置现算,不再靠这里的 20Hz tick 把预算好的 fillFraction 塞进 currentLine。
    @Published public private(set) var anchor: ProgressAnchor?
    private var lastKey = ""
    private var lastSnapshot: MediaControlSnapshot?
    /// 上一拍的播放器 bundle id —— 只为「按播放器偏移」那一层服务(见 apply() 里那处判断)。
    /// 不能靠 lastSnapshot 反推:apply() 第一行就把它换成新快照了,等走到判断处已经比不出来。
    private var lastAppliedBundleID: String?
    /// 已落 UserDefaults 的「最后播放器/最后曲目」内存镜像(去重用,见 apply() 里的写点)。
    private var lastPersistedPlayerBundleID: String?
    private var lastPersistedTrackTitle: String?

    /// 最近一次快照实际来自哪个播放器的 bundle id,拿不到就是 nil。给「导出诊断信息」用——
    /// 用户在设置里选的可能是"自动识别",那一档只报设置值等于什么都没说,必须同时报出
    /// 这一刻真正被认下来的是谁。故意不做成 @Published:诊断报告只在导出那一刻读一次,
    /// 发布它只会让所有订阅者跟着每次轮询白重算一遍。
    public var lastResolvedBundleID: String? {
        let id = lastSnapshot?.bundleIdentifier ?? ""
        return id.isEmpty ? nil : id
    }

    // ---- 播放位置平滑(2026-07-24 加,修 QQ 音乐"歌词时间不准") --------------------
    //
    // QQ 音乐没有 AppleScript,elapsedTime 来自 media-control --now 的 elapsedTimeNow
    // 外推值(见 MediaControlClient.swift)——实测坐实:同一首歌连续轮询,单次读数相对
    // 真实经过的时间能有 ±1~1.5 秒的抖动(不是持续偏向一个方向,是每次独立采样各自的
    // 误差,推测是 QQ 音乐自己上报 Now Playing 信息给系统的节奏本来就不是每次都精确
    // 刷新)。Apple Music 走的 AppleScript player position 没有这个问题,精确到
    // ~0.1s。过去不管哪个播放器,每次轮询(2 秒一次)都无条件把这次读数直接当成新锚点
    // ——QQ 音乐下逐字歌词填色因此每 2 秒就带着这份噪声跳一下,肉眼可见"歌词时间不准"。
    //
    // 改成跟 collector/poller.go 的 updatePosition() 同一套思路:只在真的发生"不
    // 连续"(换歌、暂停⇄播放切换、或者这次读数跟"按上一次锚点+经过的真实时间外推"的
    // 预测值差太多,说明真的 seek/跳曲了)时才信任这次读数重新锚定;平稳播放期间改成
    // 按真实 wall-clock 经过的时间累加,不理会每次读数自身的抖动。这套逻辑对 Apple
    // Music 同样安全——它的读数本来就精确,预测值和读数几乎总是相差无几,不会触发"跟
    // 预测差太多"这个分支,实际观感跟改之前几乎一致。
    private var trackPosSeconds: Double = 0
    private var posTrackingKey = ""
    private var posWasPlaying = false
    private var posPrevWall: Date?
    // 上一轮的报告值 —— 冻结检测(isFrozenReport)用它算"这一轮报告值前进了多少"。
    // 每次 resolvePositionSeconds 退出时统一更新(defer),换歌/暂停恢复不需要单独清:
    // 那些路径本身就会把它刷成当轮读数,下一轮的差值语义自然正确。
    private var posPrevReported: Double?
    // "真实读数 − 墙钟外推值"偏差的滑动平均——见 servoDecision() 的注释,2026-08-04
    // 实测排查坐实的"锁死偏差"问题的修复状态。播种/跳变/校正后都归零重新累计。
    private var posErrEMA: Double = 0
    private static let seekJumpToleranceSecs = 2.0

    // 地板量化源的「前向棘轮」阈值。
    //
    // 2026-08-16 实测坐实(QQ 音乐,采样 media-control 原始字段 + 程序化暂停/恢复):
    // QQ 音乐上报给 MediaRemote 的位置**只有整数秒**(6.0/21.0/23.0/25.0),而且锚点翻转
    // 瞬间 elapsedTimeNow 向前跳了 +1.001s —— 向下取整意味着每个锚点相对真实位置
    private nonisolated static let flooredForwardSnapEpsilonSecs = 0.05

    /// 播放位置数据源的三档画像：决定伺服参数与前向棘轮策略。
    public enum PositionSourceTier {
        /// Apple Music: AppleScript 播放头，精度约 0.1s。
        case precise
        /// Spotify / 酷狗音乐: media-control 连续外推，稳态读数干净，仅需收敛初期播种偏差。
        case cleanExtrapolated
        /// QQ 音乐 / 网易云: 整秒下取整且带抖动，采用大门槛与前向棘轮。
        case noisyFloored
    }

    /// bundleID → 数据源画像。纯函数,selftest 直接覆盖。
    public nonisolated static func positionSourceTier(forBundleID bundleID: String?) -> PositionSourceTier {
        if bundleID == PlaybackPlayer.appleMusic.bundleIdentifier { return .precise }
        // 2026-08-21 把默认档从 noisyFloored 翻成 cleanExtrapolated,并把真正"整秒下取整 +
        // 大抖动"的那两个显式列出来。
        //
        // 理由是实测:noisyFloored 那一档的两样东西(1.0s 大门槛 + 前向棘轮)都只对**整秒
        // 量化**的源成立 —— 棘轮的前提是"报告值 ≤ 真实位置"(下取整才恒成立)。而所有走
        // media-control 的源实测都是**纯墙钟外推、无量化**:酷狗(2026-08-21 实测 23 秒
        // 累计偏差 +0.0011s)、Arc(同款,小数位完全连续)。也就是说 noisyFloored 是**少数
        // 派**,把它当默认档等于让每一个没被显式登记的源都套上一副不适用的参数,而 1.0s
        // 门槛意味着 1 秒以内的固定偏差永远修不掉。
        //
        // bundleID 为 nil(压根没有来源信息)也走这一档:所谓"保守"应该是"别用前提不成立的
        // 棘轮",而不是"选那个门槛最大的"。
        if bundleID == PlaybackPlayer.qqMusic.bundleIdentifier
            || bundleID == PlaybackPlayer.netease.bundleIdentifier {
            return .noisyFloored
        }
        return .cleanExtrapolated
    }

    /// 见 flooredForwardSnapEpsilonSecs。纯函数,selftest 直接覆盖。
    ///
    /// 浏览器探针那笔一次性地面真值,差多少才值得重锚。
    ///
    /// 0.30s 的取法:探针值做完去地板补偿后,自身残余误差是 ±0.5s 内的均匀分布(标准差 ≈0.29s),
    /// 再叠上页面文字本身 ±0.1s 的跳变抖动。门槛低于这个量级只会来回抖,高于它就白白放过
    /// 实测中最常见的那档 0.7~0.9s 系统性偏差。
    ///
    /// ⚠️ 值得重锚的判据是"比噪声大",不是"比 1 秒大" —— 用 `servoDecision` 那套给周期性
    /// 噪声源设计的门槛来卡一次性样本,是这条纠偏此前从不生效的直接原因。
    public static let groundTruthSnapToleranceSecs: Double = 0.30

    /// 只对地板量化源(noisyFloored)生效:棘轮的依据是"reported ≤ 真实位置"这条
    /// 不等式,而 Spotify 的读数恰恰恒略**超前**真值(2026-08-18 实测),对它棘轮
    /// 只会把位置锁在抖动的上包络、且 EMA 每次吸附都被清零,永远修不回来。
    public nonisolated static func shouldRatchetForward(
        reported: Double, predicted: Double, tier: PositionSourceTier
    ) -> Bool {
        tier == .noisyFloored && reported - predicted > flooredForwardSnapEpsilonSecs
    }

    // 2026-08-04 实测排查坐实的设计缺陷修复:原来"稳定播放"分支只按墙钟外推、完全不回看
    // 真实读数,任何播种时刻带进来的偏差——App 启动那一拍的读数毛刺、恰好整个落在两次
    // 2 秒轮询之间而完全没被观察到的短暂停(墙钟累加器会把暂停时长也当播放时间加进去)——
    // 只要小于 2 秒的 seek 容差,就会永久锁死、永远不被纠正(诊断日志实锤:一次启动播种
    // 偏差 0.205s,之后每一轮 reported−predicted 恒等于 +0.205,150 秒纹丝不动;用户视角
    // 就是"本地进度跟网页差了一截,而且一直差着")。
    //
    // 修法:对偏差做指数滑动平均(EMA),持续、同号的真实偏差会让 EMA 收敛到偏差值本身,
    // 超过门槛就把外推基准一次性校正回真实读数(snap)并触发重新锚定;而零均值的读数噪声
    // (QQ 音乐 elapsedTimeNow 的 ±1~1.5s 抖动)在 EMA 里相互抵消、到不了门槛,原有的
    // 抗抖动能力不受影响。三档参数按数据源画像选(见 PositionSourceTier):
    // - precise(Apple Music,AppleScript 播放头,读数精确到 ~0.1s):alpha 0.5、门槛
    //   0.15s——持续偏差两三轮(4~6 秒)就校正,稳定期读数噪声 ±0.06s 的 EMA 幅度 ~±0.04,
    //   离门槛很远,不会误触发。
    // - cleanExtrapolated(Spotify,2026-08-18 拆档):alpha 0.3、门槛 0.4s——稳态抖动
    //   ±0.05s 离门槛很远;换歌初期播种进来的 0.4~1.3s 超前(MediaRemote 脏窗口)两轮
    //   (~4 秒)就校正;暂停/切换瞬间的单发陈旧读数(实测 -1.27s)只把 EMA 推到 -0.38,
    //   不触发回跳,下一轮干净读数就衰减掉。
    // - noisyFloored(QQ 音乐/网易云,media-control 外推读数):alpha 0.3、门槛
    //   1.0s——±1.5s 零均值抖动的 EMA 分布 ~±0.6,大部分时间到不了 1.0;真有持续 1 秒
    //   以上的锁死偏差(同样低于 2 秒 seek 容差、原来永远修不掉的那种)时几轮后能修正。
    // 纯函数,selftest 直接覆盖(nonisolated:不碰任何 @MainActor 隔离状态)。
    public nonisolated static func servoDecision(errEMA: Double, error: Double, tier: PositionSourceTier) -> (newEMA: Double, snap: Bool) {
        let alpha: Double, threshold: Double
        switch tier {
        case .precise: (alpha, threshold) = (0.5, 0.15)
        case .cleanExtrapolated: (alpha, threshold) = (0.3, 0.4)
        case .noisyFloored: (alpha, threshold) = (0.3, 1.0)
        }
        // cleanExtrapolated 的单样本限幅(2026-08-18,冻结守卫的配套):锚点冻结的
        // **第一拍**只表现为一次大负偏差(实测 -1.74),冻结检测要到第二拍(报告值
        // 连续没动)才认得出来 —— 不限幅的话第一拍 0.3×(-1.74) = -0.52 就冲过 0.4
        // 门槛,歌词被拖回半秒。限在 ±0.75:单发异常最多把 EMA 推到 ±0.225,到不了
        // 门槛;真实的持续偏差只是多等一轮(0.8s 偏差第 3 轮仍能校正,见 selftest)。
        let clamped = tier == .cleanExtrapolated ? max(-0.75, min(0.75, error)) : error
        let newEMA = errEMA * (1 - alpha) + clamped * alpha
        return (newEMA, abs(newEMA) > threshold)
    }

    /// 冻结检测(2026-08-18):曲目/广告结尾 Spotify 会把 MediaRemote 锚点冻住 ——
    /// 实测广告结尾 elapsedTimeNow 卡死 6 秒,真声一路走到落后 8 秒。播放中墙钟走了
    /// gap、报告值却几乎没动,这份读数**必然**陈旧(音频在播,诚实的位置不可能不动)。
    /// 判的是"几乎没动"(绝对值),不是"没前进":真实的向后 seek 是大负数、解冻那一拍
    /// 是大正数,都不命中,照常走 seek 分支。gap < 0.75s 的样本不判 —— 事件触发的
    /// 250ms 补查间隔太短,正常前进量也接近 0,分不出真假。只对 cleanExtrapolated
    /// 启用:QQ/网易云的整秒地板在 2s 轮询下本来就该前进 ≥1s,不需要;precise 更不需要。
    /// 纯函数,selftest 直接覆盖。
    public nonisolated static func isFrozenReport(
        reportedAdvance: Double, gap: Double, rate: Double, tier: PositionSourceTier
    ) -> Bool {
        tier == .cleanExtrapolated && gap >= 0.75
            && abs(reportedAdvance) < max(0.1, 0.15 * gap * rate)
    }

    // ---- Spotify 自然切歌(gapless)锚点超前校正(2026-08-20) --------------------------
    //
    // 实测坐实(Forever Love→在那遙遠的地方,media-control 0.25s 采样 + 旧曲连续外推
    // 做真值):gapless 自然切歌时,Spotify 在**旧曲真声还剩 ~0.84s** 时就换了元数据并
    // 打好新曲锚点(elapsedTime=0),此后整首歌 elapsedTimeNow 恒定超前真声 +0.888s
    // (±0.009s,60s 窗口内纹丝不动,锚点从不重打)。手动点播的锚点是点击瞬间打的、与
    // 真声对齐,所以准——这就是"自然切歌整首偏快、单独点播正常"的完整机理。
    //
    // 伺服(servoDecision)对这种偏差**结构性失明**:稳定播放期间每笔读数都从同一个
    // 超前锚点外推,与我们的墙钟外推步调完全一致,reported−predicted 恒 ≈0,EMA 永远
    // 够不到门槛。所以必须在换歌那一拍用外部真值把偏置量出来、之后每笔读数都扣掉。
    //
    // 真值来源=**上一首歌自己的连续外推**:音频时间是连续的,换歌被观察到那一刻,新曲
    // 的真实位置就是旧曲外推位置越过其时长的量(overrun;负值=旧曲真声还没放完,新曲
    // 位置为负,UI 侧 extrapolatedPositionMs 天然钳到 0,表现为歌词等真声开始才起走)。
    // 旧曲外推的时钟偏移实测 std 0.008s,足够当真值。08-14~08-18 的 JXA 直查路线
    // (playerPosition)不能当真值:它自己在自然切歌时同样超前(本次实测 +0.77s,08-17
    // 实测 +1.84s,每首抽签),已整体撤除,见 PositionSourceTier 注释。
    //
    // 偏置的生命周期:换歌估计(守卫见 naturalAdvanceCorrection);真实 seek(Spotify
    // 会重打锚点,重打后的锚点是准的)清零并改信原始读数;暂停⇄恢复继承(冻结的
    // elapsedTime 带着同一个超前锚点的值);手动换歌/非 Spotify 清零。
    /// 换歌被观察到时,旧曲连续外推位置与其时长的最大允许差距——超出说明不是"自然播完
    /// 切歌"(手动跳歌/外推基准已陈旧),不做校正。取值覆盖实测 ~0.84s 的元数据提前量 +
    /// 通知触发轮询的 ~0.3-0.6s 延迟,再留余量。
    public nonisolated static let naturalAdvanceWindowSecs = 4.0
    /// 锚点超前量的可信区间。下限滤掉测量噪声(Apple Music 级精度的源天然落在这之下);
    /// 上限之外视为陈旧读数(08-18 实测换歌瞬间 elapsedTimeNow 可能还挂着上一首的值,
    /// 如 30.3 vs 0.02)或模型失效,放弃校正退回原样采信(=改动前行为,seek 分支会兜住
    /// 陈旧值)。实测真实偏置 0.69~1.32s,2.5s 的上限同时把"手动跳歌恰好发生在结尾窗口
    /// 内"这种误判的伤害钉死在 ≤2.5s(且仅那一首、且是偏慢——比整首偏快的现状轻)。
    public nonisolated static let naturalAdvanceMaxBiasSecs = 2.5
    public nonisolated static let naturalAdvanceMinBiasSecs = 0.05

    /// 自然切歌锚点偏置估计。纯函数,selftest 直接覆盖。
    /// - reported: 新曲第一笔**原始**读数(elapsedTimeNow,未扣任何偏置)
    /// - overrun: 换歌被观察到那一刻,旧曲连续外推位置 − 旧曲时长(负=真声还没放完)
    /// - 返回 (seed, bias):seed=新曲播种位置(=overrun,允许为负),bias=之后每笔读数
    ///   要扣除的超前量;nil=窗口外/偏置不可信,按原逻辑采信读数。
    public nonisolated static func naturalAdvanceCorrection(
        reported: Double, overrun: Double
    ) -> (seed: Double, bias: Double)? {
        guard abs(overrun) <= naturalAdvanceWindowSecs else { return nil }
        let bias = reported - overrun
        guard bias > naturalAdvanceMinBiasSecs, bias <= naturalAdvanceMaxBiasSecs else { return nil }
        return (overrun, bias)
    }

    /// 当前曲目 MediaRemote 锚点相对真声的偏差(秒)——resolvePositionSeconds 对每笔原始读数先扣掉它。
    /// 只对 Spotify(cleanExtrapolated)非零。正=锚点超前真声(gapless 自然切歌,08-20 量法见上);
    /// **负=锚点落后真声**(2026-09-09 起允许:Spotify 给歌曲发 now-playing 常晚 ~2s 而 elapsedTime
    /// 仍是 0,`SpotifyPositionProbe` 量到的差折进来,见 resolvePositionSeconds 的地面真值分支)。
    private var posReportedBiasSecs: Double = 0
    /// 这份偏置是对着哪个锚点量的(那一刻快照的原始 anchorElapsedTime)。偏置只对这个锚点成立,
    /// 锚点一换就作废,见 biasSurvivesAnchor。偏置为 0 时恒为 nil。
    private var posBiasAnchorElapsed: Double?

    private func setReportedBias(_ bias: Double, anchorElapsed: Double?, fromProbe: Bool = false) {
        posReportedBiasSecs = bias
        posBiasAnchorElapsed = bias == 0 ? nil : anchorElapsed
        posBiasFromProbe = bias != 0 && fromProbe
    }
    /// 当前偏置是不是 Spotify 探针量出来的(而不是自然切歌估的)——只有它参与 probeLeadSecs 的学习。
    private var posBiasFromProbe = false

    // ---- Spotify 探针钟领先量（按默认音频输出设备分别记录）----
    // AppleScript `player position` 领先于蓝牙/系统音频链路的实际输出，需扣除输出延迟。
    // 每次暂停时通过对比外推位置与 Spotify 冻结锚点在线学习残差，按音频输出设备 UID 持久化；
    // 切换输出设备时自动切换校准值，并按传输类型提供合理先验（蓝牙 0.5s、内建 0.1s）。
    private static let probeLeadByDeviceDefaultsKey = "np:spotifyProbeLeadByDevice"
    /// 第三版的单值键(2026-09-09 当天几小时);启动时若表为空就把它归到当前设备名下,然后删掉。
    private static let legacyProbeLeadDefaultsKey = "np:spotifyProbeLeadSecs"
    private nonisolated static let probeLeadLearnAlpha = 0.5
    private nonisolated static let probeLeadMaxResidualSecs = 1.5

    /// 没学过的设备按传输类型给的先验。纯函数,selftest 直接覆盖。数字来自 2026-09-09 真机:蓝牙 AirPods
    /// 0.51~0.65,内建 0.06~0.14;AirPlay / USB / 显示器音频没量过,给 0(= 不假设)。
    public nonisolated static func probeLeadPrior(for transport: AudioOutputRoute.Transport) -> Double {
        switch transport {
        case .bluetooth: return 0.5
        case .builtIn: return 0.1
        case .airPlay, .display, .usb, .other: return 0
        }
    }

    /// 纯函数,selftest 直接覆盖:一次暂停量到的残差怎么更新这台设备的领先量。
    ///
    /// ⚠️ 残差是**扣过当前领先量之后**还剩的偏差(我们停在的位置已经减过 `current`),所以真值 =
    /// current + residual,不是 residual 本身 —— 第四版把它当成真值直接采信,真机 19:43 先验 0.5 下量到
    /// 残差 0.07(真值 0.57)却把领先量写成 0.07,19:49 再量到残差 0.50 又折成 0.285,越学越离谱
    /// (2026-09-09 晚,日志 `probe lead learned` 两行对出来的)。没学过的设备第一份直接采信 current +
    /// residual(先验只是起点),学过的按 α=0.5 往真值靠;残差离谱返回原值。
    public nonisolated static func learnedProbeLead(current: Double, residual: Double, hasPrior: Bool) -> Double {
        guard abs(residual) <= probeLeadMaxResidualSecs else { return current }
        guard hasPrior else { return current + residual }
        return current + residual * probeLeadLearnAlpha
    }

    /// 按设备 UID 学到的领先量表。lazy:第一次用到时从 UserDefaults 读,顺带迁移第三版的单值键。
    private lazy var probeLeadByDevice: [String: Double] = {
        var table: [String: Double] = [:]
        if let json = UserDefaults.standard.string(forKey: Self.probeLeadByDeviceDefaultsKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            table = decoded
        }
        if UserDefaults.standard.object(forKey: Self.legacyProbeLeadDefaultsKey) != nil {
            let legacy = UserDefaults.standard.double(forKey: Self.legacyProbeLeadDefaultsKey)
            if table.isEmpty, let route = AudioOutputRoute.current() {
                table[route.uid] = legacy
                logger.notice("probe lead: migrated legacy value \(legacy, format: .fixed(precision: 3)) to device \(route.name, privacy: .public)")
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyProbeLeadDefaultsKey)
            Self.persistProbeLeadTable(table)
        }
        return table
    }()

    private static func persistProbeLeadTable(_ table: [String: Double]) {
        if let data = try? JSONEncoder().encode(table), let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: probeLeadByDeviceDefaultsKey)
        }
    }

    /// 此刻默认输出设备(startObservingOutputRoute 之后随系统变化刷新;为 nil 时按 .other 处理)。
    private var currentOutputRoute: AudioOutputRoute.Current? = AudioOutputRoute.current()

    /// 此刻该从探针值里扣掉的领先量:这台输出设备学过的值,或按传输类型的先验。
    private var probeLeadSecs: Double {
        guard let route = currentOutputRoute else { return 0 }
        return probeLeadByDevice[route.uid] ?? Self.probeLeadPrior(for: route.transport)
    }

    private func learnProbeLead(residual: Double) {
        guard let route = currentOutputRoute else { return }
        let prior = probeLeadByDevice[route.uid]
        let next = Self.learnedProbeLead(current: prior ?? Self.probeLeadPrior(for: route.transport),
                                         residual: residual, hasPrior: prior != nil)
        logger.notice("probe lead learned: residual=\(residual, format: .fixed(precision: 3)) device=\(route.name, privacy: .public) (\(route.transport.rawValue, privacy: .public)) lead \(self.probeLeadSecs, format: .fixed(precision: 3)) -> \(next, format: .fixed(precision: 3))")
        guard prior != next else { return }
        probeLeadByDevice[route.uid] = next
        Self.persistProbeLeadTable(probeLeadByDevice)
    }

    /// 默认输出设备换了:换用那台设备的领先量;正在放 Spotify 且偏置是探针量的,再问一次探针让位置按新
    /// 领先量重折(否则要等用户下一次暂停)。
    private func outputRouteChanged() {
        let route = AudioOutputRoute.current()
        guard route != currentOutputRoute else { return }
        let before = probeLeadSecs
        currentOutputRoute = route
        logger.notice("output route changed: \(route?.name ?? "-", privacy: .public) (\(route?.transport.rawValue ?? "-", privacy: .public)) probe lead \(before, format: .fixed(precision: 3)) -> \(self.probeLeadSecs, format: .fixed(precision: 3))")
        if posBiasFromProbe, posWasPlaying,
           lastSnapshot?.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier {
            SpotifyPositionProbe.shared.requestConfirmation(forKey: posTrackingKey)
        }
    }

    /// 上一次写给 collector 的偏置记录(见 PositionBiasFile)。
    private var lastPublishedBias: PositionBiasRecord?

    /// 把当前偏置告诉 collector(网页 / 飞书预览那条链路走它自己的 media-control 外推,见
    /// PositionBiasFile 头注)。只在内容变了才写;非 Spotify 播放器不产生偏置,只有在需要把上一条
    /// 非零记录作废时才写一条 0 —— 免得 Apple Music 每换一首歌都落一次盘。
    private func publishPositionBiasIfChanged(snapshot: MediaControlSnapshot, isSpotifyNative: Bool, now: Date) {
        let record = PositionBiasRecord(
            artist: snapshot.artist ?? "", title: snapshot.title ?? "",
            bundleID: snapshot.bundleIdentifier ?? "",
            anchorElapsed: posBiasAnchorElapsed, biasSecs: posReportedBiasSecs,
            writtenAtMs: Int64(now.timeIntervalSince1970 * 1000))
        if let last = lastPublishedBias, last.sameContent(as: record) { return }
        guard isSpotifyNative || (lastPublishedBias?.biasSecs ?? 0) != 0 else { return }
        lastPublishedBias = record
        PositionBiasFile.write(record)
    }

    /// 偏置能不能跟着这个锚点继续用。纯函数,selftest 直接覆盖。
    ///
    /// 2026-09-07 实测推翻了 08-20 的"暂停⇄恢复继承偏置(冻结值来自同一超前锚点)":gapless 切歌
    /// 后 Spotify 自己的钟会停一下等新音频,稳态时就是音频位置(暂停冻结值 152.673 与 App 已扣偏置
    /// 的显示 152.689 只差 16ms,而当时偏置 1.080)。偏置只属于**量它时对着的那个**锚点;Spotify 后来
    /// 重新发布的任何锚点 —— 暂停冻结值、恢复、拖动 —— 都对齐它的钟,原始 elapsedTime 必然变了,这时
    /// 再扣偏置就是把准的值往回拖一个偏置量(实测暂停瞬间 −1.097s)。MediaRemote 指令暂停不重发锚点
    /// (原始 elapsedTime 不变),那时暂停值来自我们自己按开播锚点外推,偏置照旧扣 —— 所以判据是
    /// "锚点的原始 elapsedTime 还是不是量偏置时那个",不是"现在是不是暂停"。
    ///
    /// 2026-09-09 从"开播锚点 = elapsedTime 0"改成"= 量偏置时的那个值":Spotify 有时开播半秒内会把锚点
    /// 从 0@T 改发成 1.923@T(BIRDS OF A FEATHER 实测),按旧判据这首歌任何偏置都活不过下一拍;
    /// `measuredAgainst` 缺失时退回旧判据。
    public nonisolated static func biasSurvivesAnchor(anchorElapsedTime: Double?, measuredAgainst: Double? = nil) -> Bool {
        guard let anchorElapsedTime else { return true }
        guard let measuredAgainst else { return anchorElapsedTime <= 0.001 }
        return abs(anchorElapsedTime - measuredAgainst) <= 0.001
    }

    /// 播放时钟的只读快照,给「导出诊断信息」用(第 14 章 §7)。
    ///
    /// 为什么需要它:「歌词慢半拍」是这个 App 最难复现、也最常被报的一类问题,而它至少有
    /// 四种成因,修法完全不同 —— 帧率掉了 / `positionSourceTier` 判错(把精确源当成外推源)/
    /// 伺服在反复 snap(位置读数抖)/ 自然切歌偏置估歪。在此之前诊断报告里**一行播放时钟
    /// 状态都没有**,这四种在报障里长得一模一样,只能靠猜加翻 collector 日志。
    ///
    /// 这些全是本来就在内存里的字段,这里只是把它们读出来 —— 零热路径成本,不新增任何计算。
    /// 刻意做成一次性快照而不是 @Published:诊断导出是"点一下读一次"的动作,做成发布属性
    /// 会让每次伺服调整都推着订阅者重渲染。
    public struct ClockSnapshot: Sendable {
        public var tier: String
        public var posErrEMASecs: Double
        public var reportedBiasSecs: Double
        public var anchorRate: Double?
        public var anchorFresh: Bool?
        public var anchorAgeSecs: Double?
        public var effectiveLyricsOffsetMs: Int
        public var lrcOffsetMs: Int
        public var fillSettled: Bool
        public var hasLyrics: Bool
        public var isPlaying: Bool
    }

    public var clockSnapshot: ClockSnapshot {
        let tier = Self.positionSourceTier(forBundleID: lastSnapshot?.bundleIdentifier)
        return ClockSnapshot(
            tier: String(describing: tier),
            posErrEMASecs: posErrEMA,
            reportedBiasSecs: posReportedBiasSecs,
            anchorRate: anchor?.rate,
            anchorFresh: anchor?.fresh,
            anchorAgeSecs: anchor.map { Date().timeIntervalSince($0.fetchedAt) },
            effectiveLyricsOffsetMs: currentLyricsOffsetMs,
            lrcOffsetMs: syncEngine.lrcOffsetMs,
            fillSettled: currentLineFillSettled,
            hasLyrics: hasLyricsContent,
            isPlaying: isPlayingNow
        )
    }
    /// 上一轮快照的曲目时长(秒)——自然切歌判定要用"旧曲"的时长,而 resolve 被调用时
    /// snapshot 已经是新曲的了。apply() 每轮末尾更新(与 posTrackingKey 同批)。
    private var posPrevDurationSecs: Double = 0
    /// 上一轮快照是否也是 cleanExtrapolated 档(Spotify)——自然切歌校正的"旧曲真值"
    /// 必须来自 Spotify 自己的连续外推;auto 模式跨播放器切歌时,拿 QQ/网易云的整秒
    /// 地板外推或 Apple Music 的播放头当旧曲真值去估 Spotify 偏置是错的
    /// (2026-08-20 对抗审查抓出)。
    private var posPrevTierCleanExtrapolated = false
    /// 暂停期间上一轮的原始冻结读数——暂停中用户在播放器里拖进度条时,冻结值会跳变
    /// (Spotify 同时重打对齐真声的锚点),旧偏置必须作废;不检测的话恢复播放后整曲
    /// 反向偏慢一个旧偏置(2026-08-20 对抗审查抓出)。播放态清 nil。
    private var posPausedRawSecs: Double?

    /// 换曲那一拍"按字段/页面判定这条是不是广告"(纯函数,selftest 钉着;2026-09-08 收出来):
    ///   - YouTube Music 探针判成广告 → 广告(`showsAdBadge`:只有 `.ad` 算,nil 不算);
    ///   - Spotify **网页版**:只认 `SpotifyWebAdProbe` 的正向证据 `.ad`,nil / `.song` 都不算 ——
    ///     配对关系不等于此刻在放 Spotify,不能按配对套下面那套启发式;
    ///   - Spotify **原生**客户端:字段启发式(album 空 / artist 空 / 标题「—」,与 collector `isAdBreak`
    ///     同款),另有 AppleScript `spotify url` 异步复核兜底;
    ///   - 其它播放器一律不是广告。
    public static func adBreakByFields(
        isSpotifyNative: Bool, title: String, artist: String, album: String,
        youTubeMusicVerdict: YouTubeMusicAdProbe.Verdict?, spotifyWebVerdict: SpotifyWebAdProbe.Verdict?
    ) -> Bool {
        if YouTubeMusicAdProbe.showsAdBadge(verdict: youTubeMusicVerdict) { return true }
        if spotifyWebVerdict == .ad { return true }
        return isSpotifyNative && !title.isEmpty && (album.isEmpty || artist.isEmpty || title == "—")
    }

    /// 「广告中」标志的状态机(纯函数,selftest 钉着;2026-09-08 从 apply() 里收出来):
    ///   - 换曲那一拍按当下字段/页面判定定初值(`adByFields`);
    ///   - 同曲期间字段/页面说是广告 → 往 true 棘轮(Spotify 广告字段会闪变,见 apply() 里那段);
    ///   - 同曲期间**页面明确说是歌**(`.song`,不是 nil)→ 回落成 false —— 只有 YouTube Music 的
    ///     音乐视频会走到这一条:前贴片广告跟正片共用同一份 MediaSession 元数据,判定会在同一个
    ///     key 下先 ad 后 song(见 YouTubeMusicAdProbe.verdictMaxAge 的⚠️);
    ///   - 其余保持不变(含 nil:探针超时/还没探到,不许把已判定的广告抹掉,也不许把歌变成广告)。
    /// Spotify 的 AppleScript 复核在别处异步把它置 true,跟这里不冲突(它传进来的 pageVerdict 恒为 nil)。
    public static func nextAdBreakState(
        previous: Bool, isNewTrack: Bool, adByFields: Bool, pageVerdict: YouTubeMusicAdProbe.Verdict?
    ) -> Bool {
        if isNewTrack { return adByFields }
        if adByFields { return true }
        if pageVerdict == .song { return false }
        return previous
    }

    /// 换曲那一拍对 Spotify 原生客户端做广告分类(2026-09-09):先看 Spotify 自己刚广播的通知
    /// (`SpotifyNotificationHint`,Track ID 前缀是权威分类、且比 MediaRemote 早到),按快照的歌名/歌手核对是
    /// 同一首才采信 —— 说是广告就当场置位,说是曲目就到此为止,**不再 fork osascript**。通知没到 / 对不上这首
    /// (App 刚启动、Spotify 没广播)才退回下面那次 AppleScript 复核,行为不劣于旧状。
    /// 调用方约定同 verifySpotifyAdViaAppleScript:只在 换曲 + 原生 Spotify + 字段启发式没判中 时调。
    private func spotifyNativeAdCheckForNewTrack(snapshot: MediaControlSnapshot) {
        if let hint = spotifyNotificationHint, hint.matches(title: snapshot.title, artist: snapshot.artist) {
            if hint.isAd, !isCurrentTrackAdBreak { isCurrentTrackAdBreak = true }
            logger.debug("spotify ad check: notification says \(hint.isAd ? "ad" : "track", privacy: .public) for key=\(snapshot.trackKey, privacy: .public)")
            return
        }
        verifySpotifyAdViaAppleScript(forKey: snapshot.trackKey)
    }

    /// 位置探针带回这首歌的图床地址;还是这首才收(晚到的地址不能挂到下一首头上,同 verifySpotifyAdViaAppleScript
    /// 回来时那道核对)。
    public func noteSpotifyArtwork(url: URL, forKey key: String) {
        guard lastSnapshot?.trackKey == key else {
            logger.notice("spotify artwork url: dropped, track moved on (for key=\(key, privacy: .public))")
            return
        }
        if spotifyArtworkURL != url {
            spotifyArtworkURL = url
            logger.notice("spotify artwork url: \(url.lastPathComponent, privacy: .public) for key=\(key, privacy: .public)")
        }
    }

    /// 权威广告判据(2026-08-19):AppleScript 的 `spotify url` 对广告返回 "spotify:ad:…"。
    /// 每次换曲最多一次、后台异步,失败静默退回字段启发式(不劣于旧状)。结果回来时先核对
    /// 还是不是同一首 —— 广告只有二三十秒,晚到的 true 不能扣在下一首真歌头上。
    private func verifySpotifyAdViaAppleScript(forKey key: String) {
        Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "tell application \"Spotify\" to spotify url of current track"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else { return }
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let out = String(data: data, encoding: .utf8),
                  out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("spotify:ad")
            else { return }
            await MainActor.run { [weak self] in
                guard let self, self.lastSnapshot?.trackKey == key else { return }
                if !self.isCurrentTrackAdBreak { self.isCurrentTrackAdBreak = true }
            }
        }
    }

    // 调用方(apply())只在"这一轮确实在播放"时才会调用这个函数——暂停态不需要外推,
    // apply() 的 else 分支直接把 anchor 置 nil,不经过这里。
    //
    // 返回值除了外推出的秒数,还带一个 didReanchor:标记这次是不是真的发生了"不连续"
    // (换歌/刚恢复播放/第一次观察/真实 seek,即用了 reported 而不是 predicted)。
    // 调用方(apply())用这个标记判断"这次真的有必要重新构造 anchor 吗"——见那边注释。
    /// `isGroundTruthSeed`:这一笔读数是不是**探针直接问播放器要来的地面真值**(浏览器探针问网页 DOM、
    /// Spotify 探针问 AppleScript `player position`),而不是 MediaRemote 报的外推值。为真时走一条
    /// 专门的重锚路径,见函数体里那段⚠️。`anchorElapsedTime`:这拍快照的原始锚点 elapsedTime,只用来
    /// 给新量出的偏置记"对着哪个锚点量的"(biasSurvivesAnchor)。`streamRaw`:探针那一拍 MediaRemote 自己的
    /// 读数(snapshot.elapsedTime),偏置按它折,见地面真值分支。
    private func resolvePositionSeconds(reported rawReported: Double, rate: Double, key: String, now: Date, tier: PositionSourceTier, isGroundTruthSeed: Bool = false, anchorElapsedTime: Double? = nil, streamRaw: Double? = nil) -> (seconds: Double, didReanchor: Bool) {
        // 锚点偏置(见 naturalAdvanceCorrection 一带的注释):同曲期间每笔读数相对真声恒定偏
        // bias(正=超前,负=落后),先扣掉再进入后续所有判断。raw 值只在三处直接用:换歌时的偏置
        // 估计、冻结检测的逐笔差分(常量偏置在差分里天然消掉,但语义上按原始值记)、
        // 以及真实 seek 之后的重新采信(Spotify 重打的新锚点是准的,偏置随之作废)。
        if tier != .cleanExtrapolated, posReportedBiasSecs != 0 {
            // 同 key 跨播放器接续(同一首歌从 Spotify 切到别的源)不触发换歌分支——偏置
            // 只对打歪的 Spotify 锚点有意义,源变了立即作废(2026-08-20 对抗审查抓出)。
            setReportedBias(0, anchorElapsed: nil)
        }
        let reported = rawReported - posReportedBiasSecs
        // 冻结检测要用"上一轮的报告值",这里先算差值、再统一记录本轮值(defer 保证
        // 每条退出路径都记,包括下面的各个 early return)。探针那一笔**不记**:它不是
        // MediaRemote 流里的样本,记了会让下一拍的差分变成"探针值→流读数"的假倒退,
        // 恰好落进冻结守卫的"几乎没动"区间(Δ≈2s、间隔 2s 时差分≈0)。
        let reportedAdvance = rawReported - (posPrevReported ?? rawReported)
        defer { if !isGroundTruthSeed { posPrevReported = rawReported } }
        // seek 刚发出去的一小段时间里,播放器可能还没跳过去(或这份快照是 seek 之前抓的)。
        // 这种读数比目标位置更靠近旧位置,采信它就会把刚跳过去的进度条/歌词硬拽回原处。
        // 直接沿用当前外推值(等于"这一轮不更新位置"),等播放器状态跟上。
        // ⚠️ 只对同一首歌生效:seek 永远发生在曲内,换歌那一拍(拖到结尾触发自然切歌/
        // seek 后 1.2s 内恰好换歌)不能被整拍拒收——否则新曲第一拍被吞、apply() 末尾又
        // 已把 posTrackingKey 推进成新曲,换歌分支(含自然切歌校正)被永久跳过
        // (2026-08-20 对抗审查抓出)。
        if key == posTrackingKey,
           let target = lastSeekTargetSecs, let prev = lastSeekPrevSecs, let at = lastSeekAt,
           Self.shouldRejectStalePositionAfterSeek(
               reported: reported, target: target, previous: prev, elapsedSinceSeek: now.timeIntervalSince(at)
           ) {
            return (trackPosSeconds, false)
        }
        guard key == posTrackingKey, posWasPlaying, let prevWall = posPrevWall else {
            if key != posTrackingKey {
                // 换歌:先判是不是 gapless 自然切歌——上一首(还在播)按墙钟连续外推已经
                // 走到结尾附近。是的话按连续性播种 + 量出锚点超前量;否则(手动点播/首次
                // 观察/别的播放器)原样采信这次读数、偏置清零。只对 Spotify 启用:Apple
                // Music 的播放头本身就是真值,QQ/网易云的整秒地板会把偏置估计噪声化。
                var corrected: (seed: Double, bias: Double)?
                if tier == .cleanExtrapolated, posPrevTierCleanExtrapolated,
                   posWasPlaying, let prevWall = posPrevWall,
                   posPrevDurationSecs > 0 {
                    let overrun = trackPosSeconds
                        + now.timeIntervalSince(prevWall) * (rate > 0 ? rate : 1)
                        - posPrevDurationSecs
                    corrected = Self.naturalAdvanceCorrection(reported: rawReported, overrun: overrun)
                    if let corrected {
                        logger.notice("natural advance: seed \(corrected.seed, format: .fixed(precision: 3))s, anchor leads audio by \(corrected.bias, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
                    }
                }
                setReportedBias(corrected?.bias ?? 0, anchorElapsed: anchorElapsedTime)
                trackPosSeconds = corrected?.seed ?? rawReported
            } else {
                trackPosSeconds = reported
            }
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        let gap = now.timeIntervalSince(prevWall)
        let predicted = trackPosSeconds + gap * rate
        // 探针的**一次性地面真值**:不走 EMA,超过门槛直接重锚。
        //
        // ⚠️ 这条必须有,否则这个纠偏**几乎永远不会生效**(2026-09-02 用真机日志坐实)。
        // 它是"每首歌一次"的样本,而 `servoDecision` 对 noisyFloored 是 alpha 0.3 / 门槛 1.0
        // —— 单个样本最多把 EMA 推到 `0.3 × 误差`,要误差超过 **3.33 秒**才可能触发。实测
        // 连着三首歌 `ema=-0.197 / -0.206 / -0.226`、`snap=false`,而同期离屏逐帧量到的真实
        // 偏差是 0.7~0.9 秒(App 偏快):**探针每次都测准了、每次都被扔掉**。
        //
        // ⚠️ 一次性直接采信跟 `BrowserPositionProbe` 类头注那条"不要持续覆盖"的教训**不冲突**:
        // 那次的病根是**每 ~0.9 秒**拿一份整秒读数覆盖一次连续外推,造成周期性回退;这里每首歌
        // 只发生一次,采信完立刻把稳态精度交还给连续外推。
        //
        // ⚠️ 位置有讲究(2026-09-09 从 seek 分支之后挪到冻结守卫之前):探针这一笔不是流里的样本,
        // 冻结 / 回绕 / seek 三条守卫对它都是误判 —— 尤其 seek 分支:差超过 2s 时把它当"用户拖动"
        // 采信后顺手清偏置,下一拍流读数又差回 2s、再被当成一次拖动重锚回去,纠偏活不过一拍。
        // 它仍必须排在前向棘轮**之前** —— 浏览器探针值做过去地板补偿(`flooredMidpointBiasSecs`),
        // 不再满足棘轮赖以成立的"reported ≤ 真实位置"。
        //
        // ⚠️ **Spotify(cleanExtrapolated)要把量到的差折进偏置,不能只重锚**(2026-09-09,用户报
        // 「Spotify 进度很多时候偏慢,暂停再播放就准」):Spotify 给歌曲发 now-playing 常晚 ~2s 而
        // elapsedTime 仍是 0,之后整首歌 MediaRemote 的每笔读数都从这个晚打的锚点外推、恒定落后
        // ~2s。09-07 那版只重锚一次,下一拍起流读数与外推差回 ~2s:差 >2s 走 seek 分支当场拽回,
        // 差 <2s 三拍 EMA 拽回(限幅 ±0.75、门槛 0.4)—— 真机日志:vampire 15:01:07 重锚 +1.956,
        // 15:01:42 暂停时又落后 1.817、errEMA≈0(伺服认为一切正常)。把 Δ 折进 posReportedBiasSecs
        // (负值=锚点落后)之后,后续每笔读数先加回这段差,与重锚后的外推一致,伺服才不会再"纠正"回去。
        // 探针值本身在 Spotify 的钟域里,与流读数同源,先扣同一个旧偏置再比是对的(gapless 时
        // 它同样超前真声 ~0.9s,见 SpotifyPositionProbe 头注)。偏置归属这一拍的锚点
        // (biasSurvivesAnchor):暂停 / 拖动后 Spotify 重发的锚点是准的,偏置随之作废。
        if isGroundTruthSeed {
            let delta = reported - predicted
            guard abs(delta) > Self.groundTruthSnapToleranceSecs else {
                // 差在门槛内:探针与流一致,这一笔什么都不改。noisyFloored 保持 09-02 以来的
                // 行为继续往下走(棘轮 / EMA 照常吃这一笔);cleanExtrapolated 直接沿用外推。
                if tier == .cleanExtrapolated {
                    trackPosSeconds = predicted
                    return (trackPosSeconds, false)
                }
                return resolveSteadyState(reported: reported, predicted: predicted, key: key, tier: tier)
            }
            if tier == .cleanExtrapolated, let streamRaw {
                // ⚠️ 偏置 = **这一拍流读数** − 探针值,不是 predicted − 探针值(2026-09-09 当天第二版,
                // greedy 实测:开播半秒 Spotify 把锚点从 0@47 改发成 2.434@48,流读数已跟着新锚点、
                // 我们的外推还在旧锚点上,两者差 1.45s;按 predicted 折出 −2.025,流读数再扣它就
                // 超前真声 1.5s,暂停时 delta=+0.523、恢复回退 −1.100)。偏置的定义是"流读数相对
                // 真声偏多少",量它就得拿流读数本身当被减数;我们自己的外推只决定"这一下要不要重锚"。
                // 不设上限:探针已经两次采样验过钟在走(SpotifyPositionProbe.clockIsRunning),而流那边
                // 倒是会差出 60~110 秒(Spotify 把开播那份 now-playing 带着新时间戳晚发,elapsed 0.367
                // / 2.458 落在播到 60s / 110s 的时候,决策 29)—— 第一版的 6s 上限恰好把这两次真纠偏
                // 都挡了。
                setReportedBias(streamRaw - reported, anchorElapsed: anchorElapsedTime, fromProbe: true)
            }
            logger.notice("browser probe reanchor: reported=\(reported, format: .fixed(precision: 3)) predicted=\(predicted, format: .fixed(precision: 3)) delta=\(delta, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3))")
            trackPosSeconds = reported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        // 冻结守卫(2026-08-18,必须在 seek 分支**之前**):冻结的读数越冻越落后,几秒
        // 后就会超过 2s 的 seek 容差 —— 放到 seek 分支后面的话,位置会被"重锚"回冻结值,
        // 歌尾歌词整段倒回去。命中时维持墙钟外推、不喂 EMA;解冻那一拍报告值大步前跳,
        // 自然落进 seek 分支瞬间追上。判据与边界见 isFrozenReport 注释。
        if Self.isFrozenReport(reportedAdvance: reportedAdvance, gap: gap, rate: rate, tier: tier) {
            trackPosSeconds = predicted
            return (trackPosSeconds, false)
        }
        // 单曲循环(repeat-one)的 gapless 回绕:key 不变、走不到换歌分支,但与跨曲自然
        // 切歌是同一机制(引擎驱动的自然过渡,新锚点先于真声打好)——不识别的话会落进
        // 下面的 seek 分支把量准的偏置清掉,循环第 2 遍起整曲回到偏快(2026-08-20 对抗
        // 审查抓出)。签名=外推已到曲尾窗口、且按"回绕真值=越界量"估出的偏置落在可信
        // 区间(稳定播放到曲尾时 raw 是大值,估出的偏置≈整曲时长,天然不命中;向后拖到
        // 曲首的误判面与"手动跳歌落窗"同级,伤害同被 2.5s 上限钉死且方向偏慢)。
        if tier == .cleanExtrapolated, posPrevDurationSecs > 0,
           let corr = Self.naturalAdvanceCorrection(reported: rawReported, overrun: predicted - posPrevDurationSecs) {
            logger.notice("repeat-one wrap: seed \(corr.seed, format: .fixed(precision: 3))s, anchor leads audio by \(corr.bias, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
            setReportedBias(corr.bias, anchorElapsed: anchorElapsedTime)
            trackPosSeconds = corr.seed
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        if abs(reported - predicted) > Self.seekJumpToleranceSecs {
            // 真实 seek/跳变:直接重锚到这次读数。seek 时 Spotify 会重打锚点,重打后的
            // 锚点与真声对齐(与手动点播同一性质),自然切歌偏置随之作废——清零并改信
            // 原始读数,否则整首歌会反向偏慢一个旧偏置。
            //
            // 已知边界(2026-08-20 对抗审查确认,单源本质歧义、接受不修):偏置在位时,
            // 用户在 Spotify 自己界面里**小幅**拖动(幅度 < 偏置+2s ≈ 3s)——重打后的
            // 锚点是准的,但扣着旧偏置的读数跳变量 |d−bias| 不过 2s 门槛,进不来这个
            // 分支,伺服会把该曲余下部分收敛到"真声−偏置"(恒慢 ~0.9s)。单凭
            // elapsedTimeNow 分不出"带偏置的锚点没动"和"准锚点+拖了≈偏置":拖动
            // ≥3s(绝大多数)正常进此分支纠正,换歌即自愈。
            setReportedBias(0, anchorElapsed: nil)
            trackPosSeconds = rawReported
            posErrEMA = 0
            // Spotify 原生:先照单全收,再问一次 Spotify 的钟确认这个新锚点是真的(2026-09-09,
            // 见 SpotifyPositionProbe.requestConfirmation)。真拖动探针与新锚点一致、什么都不改;
            // Spotify 把开播那份 now-playing 带着新时间戳晚发(播到 60s 时来一个 0.367)那种假锚点,
            // 探针 ~1s 后把位置纠回去、差折进偏置。只对 cleanExtrapolated:探针本来就只对它开。
            if tier == .cleanExtrapolated {
                SpotifyPositionProbe.shared.requestConfirmation(forKey: key)
            }
            return (trackPosSeconds, true)
        }
        return resolveSteadyState(reported: reported, predicted: predicted, key: key, tier: tier)
    }

    /// resolvePositionSeconds 的尾段:前向棘轮 + 偏差 EMA 伺服。拆出来是因为探针那一笔差在门槛内时
    /// (noisyFloored)也要走到这里,与 09-02 以来的行为一致。
    private func resolveSteadyState(reported: Double, predicted: Double, key: String, tier: PositionSourceTier) -> (seconds: Double, didReanchor: Bool) {
        if Self.shouldRatchetForward(reported: reported, predicted: predicted, tier: tier) {
            // 地板量化源(QQ 音乐/网易云)的前向棘轮:reported 比外推值靠前就立刻向前采纳
            trackPosSeconds = reported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        // 稳定播放:默认继续墙钟外推,持续偏差超过门槛时校正
        let (newEMA, snap) = Self.servoDecision(errEMA: posErrEMA, error: reported - predicted, tier: tier)
        posErrEMA = newEMA
        if snap {
            trackPosSeconds = tier == .precise ? reported : predicted + newEMA
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        trackPosSeconds = predicted
        return (trackPosSeconds, false)
    }

    private var pollTimer: Timer?
    private var fastTimer: Timer?
    private var screenLocked = false

    // Music.app 的播放状态变化通知(2026-08-04 加,借鉴 FlowX)——见
    // startObservingPlayerInfoNotification() 的注释。
    private var playerInfoObserver: NSObjectProtocol?
    private var spotifyInfoObserver: NSObjectProtocol?
    /// Spotify 最近一条 PlaybackStateChanged 通知里的分类提示(Track ID / Name / Artist),给换曲那一拍的
    /// 广告判定用,见 spotifyNativeAdCheckForNewTrack 与 SpotifyNotificationHint 头注。只在 apply() 里读。
    private var spotifyNotificationHint: SpotifyNotificationHint?
    // media-control 的事件流(QQ 音乐/网易云没有分布式通知,靠它)。见
    // MediaControlStreamWatcher —— 事件同样只当"提前 poll 一次"的信号。
    private var streamWatcher: MediaControlStreamWatcher?
    // 通知去抖动:待触发的那次补查(收到新通知就取消重排)——见
    // handlePlayerInfoChanged() 的注释。
    private var pendingNotificationPoll: Task<Void, Never>?
    private static let playerInfoDebounce: Duration = .milliseconds(250)

    private init() {}

    public func start() {
        reschedulePollTimer()
        startObservingPlayerInfoNotification()
        // 内存紧张时让出解码后的全曲库歌词缓存(~21MB),见 EnrichCacheReader 注释。
        EnrichCacheReader.installMemoryPressureRelief()
        // enrich 缓存已经在后台解码并采纳完成时,直接重载当前歌词。不要再绕一次 poll():
        // poll 还要异步读取播放器快照,并受 pollGeneration 去乱序保护;恰好撞上另一轮 poll
        // 时这次“歌词已到达”的刷新可能被延后到下一拍。
        EnrichCacheReader.onContentAdopted = { [weak self] in self?.handleEnrichContentAdopted() }
        // 快速 tick 不在这里无条件启动——是否需要它取决于第一次 poll() 拿到的播放
        // 状态,交给 apply() 里的 ensureFastTimerRunning()/stopFastTimer() 决定。
        poll()
    }

    public func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        for observer in [playerInfoObserver, spotifyInfoObserver].compactMap({ $0 }) {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        playerInfoObserver = nil
        spotifyInfoObserver = nil
        streamWatcher?.stop()
        streamWatcher = nil
        pendingNotificationPoll?.cancel()
        pendingNotificationPoll = nil
        stopFastTimer()
    }

    /// enrich 缓存的新一代内容已经完成解码并在主线程采纳。
    ///
    /// 这条通知只代表“歌词缓存变了”,不需要为了它重新读取一次播放器状态。直接按当前
    /// lastSnapshot 重载即可;如果变化属于别的歌曲,reloadCurrentLyrics() 自己的内容等值闸
    /// 会把昂贵的解析挡掉。同步 lastEnrichMTime 后,下一拍正常 poll 也不会重复重载。
    private func handleEnrichContentAdopted() {
        let version = EnrichCacheReader.decodedContentVersion
        if enrichContentVersion != version { enrichContentVersion = version }
        guard version != lastEnrichMTime else { return }

        lastEnrichMTime = version
        reloadCurrentLyrics()

        // 跟 apply() 末尾保持同一套 fast-tick 生命周期。新歌词刚从“无”变成“有”时,
        // 20Hz timer 此前是停着的,这里必须立即拉起并补一帧,否则仍要等下一次播放器轮询。
        if anchor == nil {
            stopFastTimer()
            resolveLinesForPausedPosition()
        } else if syncEngine.hasContent {
            ensureFastTimerRunning()
            fastTick()
        } else {
            fastTick()
            stopFastTimer()
        }
    }

    // Music.app 每次换歌/暂停/恢复播放都会往分布式通知中心广播一条
    // "com.apple.Music.playerInfo"(系统级、无需任何额外权限,跟已有的"自动化"权限
    // 无关)。2026-08-04 借鉴 FlowX(Kadxy/FlowX,同类菜单栏歌词工具)加上这条订阅,
    // 补上 2 秒轮询天然的感知延迟。
    //
    // ⚠️ 设计取舍(刻意的,不要"顺手优化"掉):通知**只当作"提前触发一次 poll()"的信号**,
    // 完全不从 notification.userInfo 里取标题/播放状态/位置去直接喂状态——虽然那份
    // userInfo 里确实带着这些字段(FlowX 就是直接用的)。理由是这个类的状态机已经相当
    // 微妙(poll 世代号防乱序、resolvePositionSeconds 的位置平滑+伺服校正、
    // ensureFastTimerRunning 的生命周期),再引入一条"绕过 poll() 直接改状态"的并行
    // 路径,就会出现两套数据源需要互相对账:通知先到还是轮询先到、通知里的位置跟
    // AppleScript 读数哪个更准、平滑器该信谁——这些都是实打实的乱序 bug 温床。现在的
    // 写法让所有状态变更仍然只发生在 apply() 这一条路径上,通知的唯一作用是让那条路径
    // 提早跑一次,已有的世代号防护(见 poll())原样继续生效、不需要任何改动。
    //
    // ⚠️ 2026-09-09 起有一个划得很窄的例外(与 02 章决策 1 里 stream watcher 那条同性质):Spotify 那条通知
    // 的 userInfo 会被读 **Track ID / Name / Artist 三个键**,只为给换曲那一拍的广告分类提供权威依据
    // (`spotify:ad:` 前缀,跟 AppleScript `spotify url` 是同一个值,但不用 fork 子进程、而且比 MediaRemote
    // 那份 now-playing 早到)。位置、播放状态、标题**仍然一律不从通知喂**;分类结果也只在 apply() 里、按快照的
    // 歌名/歌手核对过之后才生效(见 spotifyNativeAdCheckForNewTrack)。通知没收到就退回原来的 osascript。
    //
    // Apple Music 和 Spotify 都广播分布式通知,两个都订阅。
    //
    // ⚠️ 这里原来写着"Spotify 不广播这个通知……这些播放器没有等价机制",那句话是错的:
    // Spotify 有自己的 com.spotify.client.PlaybackStateChanged(2026-08-16 审阅
    // lycrics_notch 时发现,它的 SpotifyController 一直在用),我们却只订阅了 Apple Music
    // 那条,于是 Spotify 用户白等 2 秒轮询。QQ 音乐/网易云确实没有等价通知,它们靠
    // media-control 的事件流(见 MediaControlStreamWatcher)。
    //
    // 两条订阅都不按 features.players 条件挂载:某个播放器可能开着但不在当前选中集合里,
    // 那种情况下补查一次 poll() 完全无害(poll() 自己会核对 bundleIdentifier,见
    // MediaControlClient.fetchSnapshot 的各条分支)。
    private func startObservingPlayerInfoNotification() {
        startStreamWatcher()
        // Spotify 位置探针顺带带回的图床地址落到 spotifyArtworkURL(还是这首才收,见 noteSpotifyArtwork)。
        SpotifyPositionProbe.shared.setArtworkSink { [weak self] key, url in
            Task { @MainActor [weak self] in self?.noteSpotifyArtwork(url: url, forKey: key) }
        }
        // 网页版 Spotify 同款(2026-09-09):浏览器位置探针从页面 cover-art-image 顺带读到图床地址,也落到同一个
        // 属性;下游 PlaybackCoordinator 那条原图档替代路不分原生还是网页。
        BrowserPositionProbe.shared.setArtworkSink { [weak self] key, url in
            Task { @MainActor [weak self] in self?.noteSpotifyArtwork(url: url, forKey: key) }
        }
        // 探针结果一落地就补查一次,不等下一拍 2s 轮询来消费(2026-09-09):poll() 自己会核对曲目,
        // 消费那边还有 posWasPlaying / key 两道门,多这一次查询完全无害。
        SpotifyPositionProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // 两条**广告闸**探针同款(2026-09-11)。它们跟上面那条位置探针不是一回事:位置探针迟到
        // 只是位置晚几秒纠偏,这两条迟到会让快照被 `gate` 整条丢掉 —— 换曲/广告边界那一拍新 key
        // 下缓存必然是空的,fail-closed 拒掉之后原本要干等一整个轮询周期才有人去读探针刚探回来的
        // 结果,这段干等就是用户看到的"广告完了之后几秒没有歌曲信息、灵动岛退到兜底图标"。
        // 挂上之后这段等待 = 探针往返本身(~187ms)。poll() 自己会核对曲目身份,多查一次无害。
        YouTubeMusicAdProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        SpotifyWebAdProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // 默认输出设备一换,探针领先量跟着换(见 probeLeadByDevice 一带注释)。
        AudioOutputRoute.startObserving { [weak self] in
            Task { @MainActor [weak self] in self?.outputRouteChanged() }
        }
        guard playerInfoObserver == nil else { return }
        let center = DistributedNotificationCenter.default()
        let handler: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePlayerInfoChanged() }
        }
        playerInfoObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main, using: handler)
        // Spotify 的这条通知同样"一次操作连发多条、且第一条可能还带着旧状态",所以走
        // 完全相同的 250ms 去抖动补查路径,不需要为它单独调参。
        spotifyInfoObserver = center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main) { [weak self] note in
                // 只读 Track ID / Name / Artist 做广告分类(上面那段 ⚠️ 里的窄例外);位置与播放状态照旧只当
                // "提前 poll 一次"的信号。userInfo 在主队列上读,跟下面 handler 同一条路。
                let hint = SpotifyNotificationHint(userInfo: note.userInfo)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let hint, self.spotifyNotificationHint != hint { self.spotifyNotificationHint = hint }
                    self.handlePlayerInfoChanged()
                }
            }
    }

    // media-control 事件流跟两条分布式通知走**同一条**去抖动补查路径:三个来源都只是
    // "有动静了"的信号,合并成一次 poll() 正是想要的效果(比如 Spotify 换歌会同时触发
    // 它自己的通知和 MediaRemote 的事件,合并后只查一次)。
    private func startStreamWatcher() {
        guard streamWatcher == nil else { return }
        let watcher = MediaControlStreamWatcher { [weak self] in
            MainActor.assumeIsolated { self?.handlePlayerInfoChanged() }
        }
        streamWatcher = watcher
        watcher.start()
    }

    // 通知到达 → 去抖动之后补查一次 poll()。
    //
    // ⚠️ 用"去抖动"(延迟一小段再查,期间再来通知就重新计时)而不是"立刻查一次+之后节流",
    // 是 2026-08-04 实测量出来的必要选择,不是随手挑的:
    // ① Music.app 一次用户操作会连发 2 条 playerInfo(实测:按暂停 → 第一条 +116ms、
    //    第二条 +231ms),而且**第一条带的往往还是操作前的旧状态**(按暂停时第一条
    //    Player State 居然是 Playing,第二条才是 Paused);
    // ② 更关键的是 Music.app 自己的 AppleScript 可见状态也不是立刻切换的——实测
    //    `player state` 在命令后 +134ms 读到的还是 playing,到 +294ms 才变成 paused。
    // 所以"收到第一条通知就立刻查"会有很大概率读到一份还没切换完的快照,再叠加
    // "之后节流把真正带新状态的第二条吞掉",结果是白跑一次子进程、状态还得等下一次 2 秒
    // 轮询才纠正过来——比不加这套通知机制还糟。250ms 去抖动同时解掉这两点:一次操作的
    // 连发被合并成一次查询,且这次查询稳定发生在状态真正切换完之后(最后一条通知
    // +231ms,再等 250ms,查询落在 ~+480ms,远晚于 ~+294ms 的状态稳定点)。
    //
    // 即便如此仍明显优于改动前:感知延迟从"平均 1 秒、最坏 2 秒"降到 ~0.5 秒且稳定。
    // 2 秒轮询 Timer 继续独立运行不动,是这套机制的兜底——去抖动/取消逻辑万一有任何
    // 边界情况没覆盖到,最坏也只是退化成改动之前的行为,不会漏状态。
    private func handlePlayerInfoChanged() {
        freezeExtrapolationUntilNextPoll()
        pendingNotificationPoll?.cancel()
        pendingNotificationPoll = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.playerInfoDebounce)
            guard !Task.isCancelled else { return }
            self?.pendingNotificationPoll = nil
            self?.poll()
        }
    }

    /// 收到"播放器状态有变"的通知之后、真正查到新状态之前,先把位置外推**冻住**。
    ///
    /// ---- 为什么需要它 ----
    ///
    /// 通知在用户按下暂停后 ~116ms 就到了,但我们要等去抖结束(查询落在 ~480ms,理由见
    /// handlePlayerInfoChanged 上面那段实测)才拿得到"确实暂停了"这个事实。这中间外推
    /// 还在按播放速度往前跑,等真相到达时显示位置已经超前了将近半秒 —— 一切到暂停的
    /// 冻结位置(pausedPositionMs 是播放器报的真实值)就往回跳:进度条退一点、时间数字
    /// 倒退一秒、运气不好还跨过一句歌词,歌词跟着"变一下"。
    /// 2026-08-17 用户报的就是这个("为什么有时候暂停的时候进度条会突然回退一点")——
    /// "有时候"正对应那半秒是否恰好跨过一句歌词的边界。
    ///
    /// 冻住之后,误差只剩通知本身那 ~116ms,跳变基本看不出来。
    ///
    /// ---- 为什么这么做是安全的 ----
    ///
    /// rate 置 0 时 extrapolatedPositionMs 直接返回锚点值、不再随时间推进(见
    /// ProgressAnchor),所以"冻结"不需要任何一处 UI 配合,进度条/歌词行照常读 anchor。
    ///
    /// 万一这条通知其实不是暂停(换歌、seek),接下来那次 poll() 会照常重建锚点、位置继续
    /// 走,代价只是这 ~360ms 里进度条没动 —— 而那两个场景本来就要把显示整个重置。
    ///
    /// 从暂停**恢复**播放时 anchor 本来就是 nil,下面的 guard 直接放行,不会误冻。
    ///
    /// ⚠️ 这个冻结锚点靠 apply() 里那句 `needsNewAnchor` 中的 `anchor?.rate != rate`
    /// 被换掉:冻结时 rate 置 0,而播放中的 rate 是 1,两者不等就必然重建锚点。仍在播放
    /// 时走这条(位置继续走),已经暂停则走 `anchor = nil` 那条。**别把 needsNewAnchor
    /// 里的 rate 比较去掉** —— 去掉之后稳定播放期间会认为"不必重锚",这个 rate=0 的锚点
    /// 就永远留在那儿,进度条从此不动。
    private func freezeExtrapolationUntilNextPoll() {
        guard let current = anchor, current.rate > 0 else { return }
        let now = Date()
        anchor = ProgressAnchor(
            durationMs: current.durationMs,
            progressMs: current.extrapolatedPositionMs(now: now),
            rate: 0,
            // 已经把外推结果落成了锚点位置本身,不需要再带任何年龄基准。
            progressTs: nil,
            baseAgeMs: nil,
            fetchedAt: now,
            fresh: current.fresh)
    }

    /// 轮询间隔按播放状态分档(2026-08-20 性能审计):每一拍都要 fork 一个子进程
    /// (media-control 或 osascript),固定 2s 意味着**彻底没在放歌**的机器也一天 fork
    /// 三万多次、常驻 0.5-1% 单核底噪。降速是安全的:三路事件唤醒(AM/Spotify 分布式
    /// 通知 + media-control stream,见 startObservingPlayerInfoNotification)会把
    /// 播放/暂停/换歌的感知拉回亚秒级,慢节拍只是它们全失效时的兜底。
    /// 播放中保持 2s 不动——scrobble 计时、enrich mtime 检查、"还没解析出歌词"的重试
    /// 全搭在这个节拍上,不能慢。
    private enum PollInterval {
        static let playing: TimeInterval = 2
        static let paused: TimeInterval = 6
        static let idle: TimeInterval = 10
        /// 刚开始拿不到快照的头几拍仍按播放档轮询,之后才认命降档。见 `desiredPollInterval`。
        static let nilGraceTicks = 3
    }

    private var currentPollInterval: TimeInterval = PollInterval.playing

    /// 动态轮询间隔：播放中 2s，暂停 6s，完全空闲 10s。
    /// 刚失去快照的头几拍(nilGraceTicks)保持 2s 档，吸收短时抖动避免过度降档延迟恢复。
    private var desiredPollInterval: TimeInterval {
        if isPlayingNow { return PollInterval.playing }
        if consecutiveNilSnapshots > 0, consecutiveNilSnapshots <= PollInterval.nilGraceTicks {
            return PollInterval.playing
        }
        return title.isEmpty ? PollInterval.idle : PollInterval.paused
    }

    private func reschedulePollTimer() {
        reschedulePollTimer(interval: PollInterval.playing)
    }

    private func reschedulePollTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        currentPollInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// 每拍 poll 末尾调:状态档位变了才重建 Timer(重建本身廉价,但没必要每拍做)。
    /// 事件唤醒(handlePlayerInfoChanged→poll)让"暂停→播放"在下一拍前就被感知,
    /// 感知到的那拍会立刻把节拍调回 2s。
    private func adjustPollCadence() {
        let desired = desiredPollInterval
        if desired != currentPollInterval { reschedulePollTimer(interval: desired) }
    }

    // 只在真的需要时(anchor 非 nil,即正在播放)才保持 20Hz 快速 tick 运行——暂停/
    // 长时间挂起时没有锚点可外推,tick 只会一遍遍把 currentLine/nextLineText 置 nil,
    // 没必要让计时器继续空转。用 fastTimer == nil 判断"已经在跑了"而不是每次 apply()
    // 都无条件重建,避免播放中每 2 秒(poll 周期)就重开一次计时器。
    /// 屏幕锁上时暂停 20Hz 的逐字 tick。
    ///
    /// 锁屏时没有任何人在看歌词,而 fastTick 是这个 App 最热的那条路径(逐字填色要 20Hz)。
    /// ⚠️ 只停这一条:2 秒 poll 必须继续跑,否则锁屏期间听的歌不会被记录、Last.fm /
    /// ListenBrainz 提交会整段丢失 —— 那是不可恢复的数据,省一点电不值当。
    public func setScreenLocked(_ locked: Bool) {
        guard screenLocked != locked else { return }
        screenLocked = locked
        logger.info("screen \(locked ? "locked" : "unlocked", privacy: .public); word-level tick \(locked ? "paused" : "resumed", privacy: .public)")
        if locked {
            stopFastTimer()
        } else if anchor != nil {
            // 解锁时只在"确实还在播"的前提下恢复,判据跟 apply() 里一致(有锚点才需要外推,
            // 且引擎里得有歌词内容 —— 没词的空转档见 apply() 末尾那段注释)。
            if syncEngine.hasContent { ensureFastTimerRunning() }
            fastTick() // 立刻补一帧,别等下一个 50ms
        }
    }

    private func ensureFastTimerRunning() {
        // 锁屏期间一律不起 —— 否则 apply() 每 2 秒会把刚停掉的计时器又拉起来。
        guard !screenLocked else { return }
        guard fastTimer == nil else { return }
        // 20Hz;必须挂 .common mode,否则菜单打开/拖拽悬浮窗时会停摆。
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fastTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        fastTimer = t
    }

    private func stopFastTimer() {
        fastTimer?.invalidate()
        fastTimer = nil
    }

    /// 没有 anchor(暂停,或曲目还在但位置已冻结)时按冻结位置 pausedPositionMs 解一次当前
    /// 歌词行;真的没有冻结位置、或引擎里没有歌词内容时才清空。
    ///
    /// ⚠️ apply() 和 fastTick() 必须都走这里。这两处本来各写了一份"anchor 为 nil 就三连
    /// 清空",于是把 apply() 那份改成"暂停不清行"之后,fastTick() 那份还在原样清 —— 而
    /// seek(toMs:) 末尾是**无条件**调 fastTick() 的(为了拖动进度条时歌词立刻跟到新位置),
    /// 所以暂停状态下拖一次进度条,行又被清掉,要等下一次 apply()(2 秒轮询)才回来。抽成
    /// 一处,两边不可能再错开。
    ///
    /// 不要在这里另外加 currentLyricsOffsetMs:activeLine/upcomingLineText/activeLineIndex
    /// 内部都会先做 rawPosMs + offsetMs(见 LyricsSyncEngine),手动再加一次就是双倍校正。
    /// 记下这个台的台卡。名字一变就落盘;封面要等取图那条路回来(台卡那一拍常常没有图)。
    private func noteRadioStationCard(name: String, hash: String, trackKey: String) {
        pendingStationCardKey = trackKey
        guard radioStationCard?.stationHash != hash || radioStationCard?.name != name else { return }
        // 换台了就整张换掉(旧台的封面扣在新台头上比没有封面更糟);同台改名只换名字、留住封面。
        let keptArtwork = radioStationCard?.stationHash == hash ? radioStationCard?.artwork : nil
        let card = RadioStationCard(stationHash: hash, name: name, artwork: keptArtwork)
        radioStationCard = card
        RadioStationCardFile.write(card)
        logger.notice("radio station card: name=\(name, privacy: .public) hasArtwork=\(keptArtwork != nil)")
    }

    /// 取图那条路拿到了图 —— 如果它属于刚才那张台卡,就补进去。
    private func noteRadioStationArtwork(_ data: Data?, forKey key: String) {
        guard let data, !data.isEmpty, key == pendingStationCardKey,
              var card = radioStationCard, card.artwork != data else { return }
        card.artwork = data
        radioStationCard = card
        RadioStationCardFile.write(card)
        if radioStationName == card.name { radioStationArtwork = data }
        logger.notice("radio station card: artwork attached bytes=\(data.count)")
    }

    /// 把"当前该显示哪一行"这一组发布状态清干净。**只清行,不碰曲目 / 封面 / 时长** ——
    /// 那是 clearIfWasPlaying() 的活(整个停播)。逐个先比再赋:这些都是 @Published,
    /// 无条件赋值会让订阅者每拍重渲染(理由同 apply() 里那段注释)。
    private func clearLineDisplay() {
        if currentLine != nil { currentLine = nil }
        if nextLineText != nil { nextLineText = nil }
        if nextLineSide != nil { nextLineSide = nil }
        if currentLineIndex != nil { currentLineIndex = nil }
        if scrollLineIndex != nil { scrollLineIndex = nil }
        if compactLine != nil { compactLine = nil }
        if compactShowsPlaceholder { compactShowsPlaceholder = false }
        if compactDwellMs != nil { compactDwellMs = nil }
        if compactLeadInMs != nil { compactLeadInMs = nil }
        // 没有可显示的行,间奏点和"填色未定格"也一并归位 —— 别让上一首歌的残留值
        // 挂着(fillSettled 归 true:没有行就没有可动的填色,表该停着)。
        if currentGapIndex != nil { currentGapIndex = nil }
        if !currentLineFillSettled { currentLineFillSettled = true }
        settledThresholdIndex = nil
    }

    private func resolveLinesForPausedPosition() {
        guard let frozen = pausedPositionMs, syncEngine.hasContent, !radioTrackFinished else {
            clearLineDisplay()
            return
        }
        let r = syncEngine.tickQuery(atMs: frozen, trackEndMs: currentDurationMs)
        if r.line != currentLine { currentLine = r.line }
        if r.compactLine != compactLine { compactLine = r.compactLine }
        if r.compactPlaceholder != compactShowsPlaceholder { compactShowsPlaceholder = r.compactPlaceholder }
        if r.compactDwellMs != compactDwellMs { compactDwellMs = r.compactDwellMs }
        if r.compactLeadInMs != compactLeadInMs { compactLeadInMs = r.compactLeadInMs }
        if r.nextText != nextLineText { nextLineText = r.nextText }
        if r.nextSide != nextLineSide { nextLineSide = r.nextSide }
        if r.index != currentLineIndex { currentLineIndex = r.index }
        if r.scrollIndex != scrollLineIndex { scrollLineIndex = r.scrollIndex }
        if r.gapIndex != currentGapIndex { currentGapIndex = r.gapIndex }
        updateLineFillSettled(line: r.line, index: r.index, atRawMs: frozen)
    }

    private func fastTick() {
        if radioTrackFinished {
            clearLineDisplay()
            return
        }
        guard let anchor else {
            resolveLinesForPausedPosition()
            return
        }
        let pos = anchor.extrapolatedPositionMs()
        let r = syncEngine.tickQuery(atMs: pos, trackEndMs: currentDurationMs)
        if r.line != currentLine { currentLine = r.line }
        if r.compactLine != compactLine { compactLine = r.compactLine }
        if r.compactPlaceholder != compactShowsPlaceholder { compactShowsPlaceholder = r.compactPlaceholder }
        if r.compactDwellMs != compactDwellMs { compactDwellMs = r.compactDwellMs }
        if r.compactLeadInMs != compactLeadInMs { compactLeadInMs = r.compactLeadInMs }
        if r.nextText != nextLineText { nextLineText = r.nextText }
        if r.nextSide != nextLineSide { nextLineSide = r.nextSide }
        if r.index != currentLineIndex { currentLineIndex = r.index }
        if r.scrollIndex != scrollLineIndex { scrollLineIndex = r.scrollIndex }
        if r.gapIndex != currentGapIndex { currentGapIndex = r.gapIndex }
        updateLineFillSettled(line: r.line, index: r.index, atRawMs: pos)
    }

    /// 行填色定格阈值(毫秒)。按行下标记忆化，换行才重算一次，tick 内仅需整数比较。
    private var settledThresholdIndex: Int?
    private var settledThresholdMs = 0

    private func updateLineFillSettled(line: SyncedLyricLine?, index: Int?, atRawMs rawMs: Int) {
        let settled: Bool
        if let words = line?.words, let index {
            if index != settledThresholdIndex {
                settledThresholdIndex = index
                settledThresholdMs = KaraokeFill.lineFillSettledMs(words: words, groups: line?.wordGroups)
            }
            settled = rawMs + syncEngine.effectiveOffsetMs >= settledThresholdMs
        } else {
            settled = true
            settledThresholdIndex = nil
        }
        if settled != currentLineFillSettled { currentLineFillSettled = settled }
    }

    // nil 快照(真的没有任何曲目在加载)和"有曲目但不是 Apple Music"共用同一套清理。
    //
    // ⚠️ 2026-08-14 改:title/artist/album 以前**故意不清**,理由写的是"保留最近一次播放
    // 的信息,跟暂停分支的既有行为一致"。那个理由站不住 —— **暂停根本不走这条路径**:
    // 暂停时 media-control 仍然给出一份带曲目的快照(playing=false),走的是 apply(),
    // 曲目信息本来就留着。能走到这里的只有"真的什么都没在放"。
    //
    // 于是一张专辑放完之后,"歌词窗口"会停在一个半吊子状态:曲名歌手还在,封面变回占位
    // 音符、配色没了、歌词列表空了写着"无歌词" —— 用户报的就是这个,看着像坏了而不是像
    // 停了。曲目信息一起清掉,各界面才会一致地表达"现在没有在放"。
    //
    // 别的界面早就防过空标题:菜单栏那条 `if !coordinator.title.isEmpty` 直接不显示这一行,
    // 灵动岛 `poller.title.isEmpty ? "♪" : poller.title` 回退成音符,都不需要改。
    //
    // allLines/artworkData 这两个是 2026-08-02 补上的——之前漏清,导致播放彻底停止(不是
    // 暂停,是这两处调用点代表的"真的没有任何曲目在加载"/"当前不是 Apple Music 在报告")
    // 后,"歌词窗口"会无限期冻结显示停播前那首歌的完整歌词列表和封面模糊背景,直到下一次
    // 真正播放新曲目才会刷新——因为 LyricsWindowView 判断"有没有内容可展示"用的是
    // `allLines.isEmpty`,不清空这个数组,视图就没有任何理由切回"无歌词"占位态。
    private func clearIfWasPlaying() {
        if isPlayingNow {
            isPlayingNow = false
            anchor = nil
            currentLine = nil
            nextLineText = nil
            nextLineSide = nil
            currentLineIndex = nil
            scrollLineIndex = nil
            compactLine = nil
            compactShowsPlaceholder = false
            compactDwellMs = nil
            compactLeadInMs = nil
            allLines = []
            lyricsGapMarkers = []
            currentGapIndex = nil
            if !currentLineFillSettled { currentLineFillSettled = true }
            settledThresholdIndex = nil
            artworkData = nil
            artworkAverageHex = nil
            if spotifyArtworkURL != nil { spotifyArtworkURL = nil }
            pausedPositionMs = nil
            currentDurationMs = nil
            // 曲目本身也清掉,理由见上面那段。跟着一起清的还有"这首歌"的几个判定 ——
            // 留着的话停播之后空状态会写成「纯音乐」/「广告中」这种明显不对的文案。
            if !title.isEmpty { title = "" }
            if !artist.isEmpty { artist = "" }
            if !album.isEmpty { album = "" }
            if hasLyricsContent { hasLyricsContent = false }
            if isCurrentTrackInstrumental { isCurrentTrackInstrumental = false }
            if currentTrackHasNoLyrics { currentTrackHasNoLyrics = false }
            if isCurrentTrackAdBreak { isCurrentTrackAdBreak = false }
            // ⚠️ 等值闸快照必须一起失效:上面把 allLines 等发布状态清空了,而引擎/缓存文件
            // 里的内容还是原样 —— 不失效的话,同一首歌再次播放时 reloadCurrentLyrics 会被
            // 内容等值闸吞掉,allLines 永远回不来(闸只保证"引擎状态不用重算",保证不了
            // "发布状态还在")。
            lastReloadSnapshot = nil
            // ⚠️ lastKey 必须一起清空,否则上面清掉的 allLines/artworkData 再也回不来。
            //
            // apply() 里重建这两样的两条路径都只在**换歌**时才跑:
            // reloadCurrentLyrics() 的条件是 `trackChanged || !syncEngine.hasContent`,
            // 而 syncEngine 在这里并没有被卸载、hasContent 仍是 true;取封面那条更是只有
            // `if trackChanged`。而 trackChanged 是 `key != lastKey` —— 不清 lastKey 的话,
            // 同一首歌恢复播放时 trackChanged 就是 false,两条路径全部跳过,"歌词窗口"会
            // 一直停在 allLines 为空的"无歌词"占位态、灵动岛也一直没有封面,直到用户换一
            // 首歌为止;而桌面悬浮歌词因为直接读 syncEngine(见 fastTick),显示的却是正常
            // 的,两个窗口互相矛盾。
            //
            // 这条路径不罕见:Music.app 退出、播放列表放完进入 stopped、以及选了 QQ 音乐/
            // 网易云/Spotify/自动识别时被别的 App(比如网页视频)抢走一次系统 Now Playing
            // 焦点,都会让快照变成 nil 走到这里。
            lastKey = ""
            // 位置追踪的私有状态也要一起断链(2026-08-20 对抗审查抓出):不清的话,
            // "上一首还在播"这份陈旧状态会一直活着,中断(焦点被抢/退出/stopped)之后
            // 另起的一首歌若恰好落进自然切歌窗口(|overrun|≤4 且假偏置落 (0.05,2.5]),
            // 会被伪判成 gapless 自然切歌、种下最多 2.5s 的假偏置且整曲不自愈——改动前
            // 换歌分支无条件采信读数,这份陈旧状态才是无害的。与 collector 侧
            // updatePosition 的 key=="" 分支清理对齐。
            posWasPlaying = false
            posPrevWall = nil
            posPrevDurationSecs = 0
            setReportedBias(0, anchorElapsed: nil)
            stopFastTimer()
        }
    }

    // poll() 之间乱序完成的保护——2026-08-02 实测排查坐实:每次 Timer 触发都新起一个
    // Task,内部子进程调用(几十~上百毫秒,但权限弹窗/系统繁忙等情况下可能明显变慢)之间
    // 没有任何互斥,较早发起的一次如果比较晚发起的一次更慢完成,会在 apply() 里用一份
    // 过期快照覆盖掉刚刚已经生效的新快照,造成标题/歌词短暂跳回上一首歌。用单调递增的
    // 世代号标记"这是第几次发起的轮询",子进程返回后只在"没有更新的轮询已经发起过"时
    // 才继续走 apply()/clearIfWasPlaying()——跟 fetchArtworkForCurrentTrack() 已经用
    // expectedKey 做的事是同一个模式,只是这里换歌与否都要防护,不能用 trackKey 当
    // 世代标识。
    //
    // 2026-08-04:poll() 现在有两个调用方(2 秒轮询 Timer + playerInfo 通知补查,见
    // handlePlayerInfoChanged),这道防护对新入口天然同样成立、不需要任何改动——它保护的
    // 是"任意两次 poll() 的返回乱序",跟这两次分别是谁触发的无关。通知补查跟定时轮询
    // 挨得很近(通知先到、轮询紧随其后)时,后发起的那次赢,先发起的那次结果被丢弃,
    // 正是想要的行为。
    private var pollGeneration = 0

    /// 连续多少次 poll() 拿到了 nil 快照——给下面"snapshot failed"那行判断该不该打日志用。
    /// 2026-08-27 实测坐实的问题:这条路径原来无条件每拍都打一遍 `.error`,而空闲档
    /// (没在放歌)轮询间隔只有 10s,一晚上挂机就是几百条一模一样的行——诊断导出一份
    /// 24 小时 App Log 里这一条能占到三成,把真正有用的信号淹没掉。改成只在**状态刚
    /// 变成这样**(从"有快照"变成"没有")时才打一次;如果这个状态持续存在(比如权限
    /// 真的被收回了),每隔一段时间(约 5 分钟,`% 30` × 10s 空闲档)再打一次,不完全
    /// 沉默——不然真出问题时诊断导出里反而一条线索都没有。
    private var consecutiveNilSnapshots = 0

    private func poll() {
        pollGeneration += 1
        let generation = pollGeneration
        // 同步阻塞调用(内部 fork 子进程等待退出),挪到后台线程跑,避免卡住主线程/UI。
        Task {
            let snapshot = await Task.detached {
                MediaControlClient.fetchSnapshot()
            }.value
            guard generation == self.pollGeneration else {
                logger.debug("poll result discarded: stale generation (\(generation) vs \(self.pollGeneration))")
                return
            }
            guard let snapshot else {
                // 返回 nil 不只是"调用失败"(比如没有"自动化"权限),更常见的是真的没有
                // 任何曲目在加载(比如 Music.app 处于 stopped 而不是 paused——paused 时
                // 仍会给一个 playing=false 的正常快照,只有"压根没曲目"才会是 nil)。必须
                // 清理播放状态(anchor=nil 时清 currentLine/nextLineText+停快速计时器,
                // 加 isPlayingNow=false),否则从"正在播放"切到这种 nil 快照时,状态栏/
                // 悬浮窗会卡在停播前那一刻不会自己恢复;title/artist/album 不清空,跟
                // "暂停"时保留最近播放信息的既有行为保持一致。
                self.consecutiveNilSnapshots += 1
                if self.consecutiveNilSnapshots == 1 || self.consecutiveNilSnapshots % 30 == 0 {
                    // logger.error(_:) 吃的是 OSLogMessage,只认编译期字符串插值,不能用
                    // `+` 拼运行时 String——先把可变的那半拼成局部变量,再一次性插值进去。
                    let streakSuffix = self.consecutiveNilSnapshots > 1
                        ? " streak=\(self.consecutiveNilSnapshots)" : ""
                    // notice 而不是 error(2026-09-05):这多数时候是正常状态(Music 没开 / 没曲目在放),
                    // 落盘留线索就够,不该在 error 级别里跟真正的故障混在一起。后缀显式 .public ——
                    // 默认 private 会把它打成 <private>,24 小时日志里 36 条全是 <private> 尾巴。
                    logger.notice("snapshot failed (no automation permission, Music.app not running, or nothing playing)\(streakSuffix, privacy: .public)")
                }
                clearIfWasPlaying()
                self.adjustPollCadence()
                return
            }
            if self.consecutiveNilSnapshots > 0 {
                logger.info("snapshot recovered after \(self.consecutiveNilSnapshots) consecutive failures")
                self.consecutiveNilSnapshots = 0
            }
            // isMusicApp 现在直接由 MediaControlClient 硬编码为 true(只在真的问到
            // Music.app 自己的当前曲目时才会返回非 nil 快照,不再是系统级 Now Playing
            // 焦点判断)——这个 guard 留着只是保持跟旧版同一套代码路径,不删这一步的
            // 保险性质。
            guard snapshot.isMusicApp == true else {
                logger.debug("snapshot ignored: not Apple Music (isMusicApp=\(String(describing: snapshot.isMusicApp)))")
                clearIfWasPlaying()
                self.adjustPollCadence()
                return
            }
            logger.debug("snapshot ok: playing=\(snapshot.playing == true)")
            self.apply(snapshot)
            // 状态落定后按播放态调轮询档位(播放 2s/暂停 6s/空闲 10s,见 PollInterval)。
            self.adjustPollCadence()
        }
    }

    private func apply(_ rawSnapshot: MediaControlSnapshot) {
        // 电台的分母(2026-09-10):系统报的 `duration` 是**整档节目**的(实测 3390.122s = 56 分半),
        // 而位置已经在 MediaControlClient 里换成了单曲口径(见 RadioTrackClock)。分母不跟着换,
        // 灵动岛和歌词窗口就会显示成「2:29 / 56:30」—— 用户 2026-09-10 当场指出这个自相矛盾。
        // 真曲长由 collector 从 Apple 目录查到(实测把 3390.122 纠成 226.283)并写进歌词缓存,这里读出来替换。
        //
        // ⚠️ 缓存里还没有这首歌时(刚换曲、歌词还在解析)**保留快照自己那份**,绝不置 0:
        // 进度锚点按 durationMs 夹位置(ProgressClock),0 会把位置钉死在开头、整档没有歌词
        // —— 2026-09-10 真踩过一次。代价只是换曲后头几秒分母偏大,缓存一落地自己纠正。
        //
        // 放在 apply 最前面而不是 MediaControlClient 里:EnrichCacheReader 是 @MainActor 隔离的,
        // 快照那条路是 nonisolated,够不着。
        var snapshot = rawSnapshot
        if rawSnapshot.isRadio == true,
           let cached = EnrichCacheReader.trackDurationSecs(
               artist: rawSnapshot.artist ?? "", title: rawSnapshot.title ?? "", album: rawSnapshot.album ?? ""),
           cached > 0, cached != rawSnapshot.duration {
            snapshot = rawSnapshot.withDuration(cached)
        }
        // 台卡:开台那一刻系统会先推一张 **artist 为空、title 就是台名**的载荷(实测三次:
        // `|NCT 127`、`|YEONJUN`、`|petal radio`,enrich key 的第一段是歌手)。这是**唯一**能拿到
        // 台名台标的时机 —— 口白期间系统一个字段都不变(2026-09-11 抓了整段 61 秒的口白坐实)。
        // 判据与理由见 RadioStationCard。
        let stationHash = MediaControlClient.currentRadioStationHash()
        if stationHash != nil, !radioStationCardLoaded {
            radioStationCardLoaded = true
            radioStationCard = RadioStationCardFile.load()
        }
        let stationCardName = stationHash.flatMap {
            RadioStationCardFile.stationName(isRadio: snapshot.isRadio == true, stationHash: $0,
                                             title: snapshot.title, artist: snapshot.artist)
        }
        if let hash = stationHash, let name = stationCardName {
            noteRadioStationCard(name: name, hash: hash, trackKey: snapshot.trackKey)
        }
        // 这首歌放完了没有(电台专用,判据见 RadioTrackClock.passedTrackEnd)。位置用快照里那份
        // **没被夹过**的原始值:进度锚点的 extrapolatedPositionMs 会把位置夹在 [0, duration],
        // 从那边永远看不到"越过曲长"。时长拿不到时 passedTrackEnd 返回 false,不会误收。
        // 台卡期间同样「不是歌」(2026-09-11 用户报「第一次开始播放一个电台时……还是会被当成一首歌
        // 去搜索,然后显示"暂无歌词"」)。开台那几十秒系统把台名当一首歌推过来(实测 33.4 秒),
        // 不拦的话歌词那一格会一路走到「搜索歌词中…」再到「暂无歌词」。收进同一个标记 = 三个展示面
        // 一起显示「口白」+ 台名台标,不用各自再判一次。collector 那侧有同判据的对应守卫
        // (`radioStationCard`,不把台卡写进歌词缓存)。
        let finished = stationCardName != nil || RadioTrackClock.passedTrackEnd(
            position: snapshot.isRadio == true ? (snapshot.elapsedTime ?? 0) : 0,
            durationSecs: snapshot.isRadio == true ? snapshot.duration : nil)
        // 这一刻在放哪个台 —— 电台时间轴校准按「台 + 曲目」记(见 LyricsOffsetStore.radioOffsets),
        // 所以要把它留到 nudge / applyOffsets 用得着的地方。不是电台就是 nil。
        if currentStationHash != stationHash { currentStationHash = stationHash }
        let station = RadioStationCardFile.card(radioStationCard, forStation: stationHash)
        if station?.name != radioStationName { radioStationName = station?.name }
        if station?.artwork != radioStationArtwork { radioStationArtwork = station?.artwork }
        if finished != isRadioTalkBreak { isRadioTalkBreak = finished }
        if finished != radioTrackFinished {
            radioTrackFinished = finished
            // 只在翻转时打一行。这个判定要靠歌词缓存里的真曲长,缓存没命中时 duration 还是整档
            // 节目那个大数、判定恒 false —— 那种"安静地不生效"只有日志看得见。
            logger.notice("radio track finished=\(finished) card=\(stationCardName != nil) pos=\(snapshot.elapsedTime ?? -1, format: .fixed(precision: 1)) dur=\(snapshot.duration ?? -1, format: .fixed(precision: 1))")
        }
        lastSnapshot = snapshot
        // title/artist/album/isPlayingNow 只在真的变化时才赋值——理由跟 fastTick() 里
        // currentLine/nextLineText/currentLineIndex 的既有注释完全一样:这几个都是
        // @Published,Combine 不管新旧值是否相等,只要赋值就会通知订阅者。同一首歌播放期间
        // 这四个字段每 2 秒轮询其实拿到的都是同一份值,无条件赋值会让"歌词窗口"(以及任何
        // 订阅 PlaybackCoordinator 的其它 View)的整个 body 跟着每 2 秒重算一次——2026-08-02
        // 实测排查坐实,这是"歌词窗口"封面模糊背景每 2 秒被重新解码+重新高斯模糊的根因
        // 之一(另一个是下面的 anchor,两处需要一起改才能真正消除这个重渲染)。
        let newTitle = snapshot.title ?? ""
        if newTitle != title { title = newTitle }
        let newArtist = snapshot.artist ?? ""
        if newArtist != artist { artist = newArtist }
        let newAlbum = snapshot.album ?? ""
        if newAlbum != album { album = newAlbum }
        let newIsPlayingNow = snapshot.playing == true
        if newIsPlayingNow != isPlayingNow { isPlayingNow = newIsPlayingNow }
        // 停播欢迎态的「继续播放/打开 XX」要知道停播前在用谁、放的什么 —— 停播时快照
        // 整个清空,这里是唯一还记得的地方(见 LyricsWindowView.idleWelcomeView)。落
        // UserDefaults,只在值变化时写,2 秒轮询不刷盘。
        let bid = snapshot.bundleIdentifier ?? ""
        if !bid.isEmpty, !newTitle.isEmpty, bid != lastPersistedPlayerBundleID {
            UserDefaults.standard.set(bid, forKey: "np:lastPlayerBundleID")
            lastPersistedPlayerBundleID = bid
        }
        // 广告判定必须在下面 np:lastTrack* 落盘**之前**算出来:那几个键是"上次在听什么"
        // (停播页的唱片 hero、待机页、歌词窗口都读它),一段广告不该被记成上次在听的歌。
        // 2026-09-02 之前不需要管这件事 —— YT Music 的广告在 MediaControlClient 那道闸
        // 就被整条丢掉了,根本走不到这里;现在它会走到(为了让 UI 能显示「广告中」,见
        // YouTubeMusicAdProbe.Gate.acceptAsAd),所以这道保护要在这里补上。
        // 判定语义见下面 isCurrentTrackAdBreak 那一段。
        let isSpotifyNative = snapshot.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier
        let resolvedBundleID = BrowserPositionProbe.probeTargetBundleID(forReported: snapshot.bundleIdentifier)
        let isSpotifyWeb = BrowserPositionProbe.shared.isPaired(bundleID: resolvedBundleID, platformID: "spotifyWeb")
        // YouTube Music 网页版的广告(2026-09-02):它的字段形状跟"真歌但没报专辑名"分不开
        // (广告的 artist 是**广告主频道名**、非空,album 空),所以下面那套 adByFields 启发式
        // 对它无效 —— 判据只能来自页面本身。这里读的正是 MediaControlClient 刚用过的同一份
        // 探针缓存(同一个 key、同一把锁),两边不会得出不同结论。
        let youTubeMusicAdKey = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        // ⚠️ 用 showsAdBadge 而不是 `!= .song`:判定**缺失**时绝不能点亮「广告中」,
        // 否则探针一超时就会在真歌上贴广告标签。方向与 gate 相反,理由见它的头注。
        // ⚠️ 读的是 **badge 口径**(`cachedBadgeVerdict`,2026-09-08,02 章决策 #26):只靠裸标题撑起来的
        // 广告判定在这里算「拿不准」(nil)。换歌那两三秒页面标题就是裸的「YouTube Music」,而 YT Music
        // 首次发布元数据常常不带 album、会被 MediaControlClient 那道闸踢一次探针 —— 恰好探到,弱 ad 就
        // 缓存到了下一首歌的 key 下,下一拍换曲按当下判定定初值,整首真歌被贴「广告中」(用户报 Safari 播
        // Prince《It's Gonna Be Lonely》1:15 处仍「广告中」、歌词却正常)。gate 那边仍按任一命中即广告。
        let youTubeMusicVerdict = YouTubeMusicAdProbe.shared.cachedBadgeVerdict(forKey: youTubeMusicAdKey)
        // Spotify **网页版**只认页面的正向证据(`SpotifyWebAdProbe` 判成广告),**不再**套原生那套
        // "album 空 / artist 空 / 标题「—」"字段启发式(2026-09-08 修,用户报「有视频的歌识别错了,变成
        // 广告了」):`isSpotifyWeb` 只说明"这个浏览器**配对过** Spotify 网页版",不说明此刻在放的是
        // Spotify —— 这台机器上 Safari / Arc 同时配对了 spotifyWeb 和 youtubeMusic,于是 YT Music 里
        // 一首 album 为空的 MV(王子《Why You Wanna Treat Me So Bad?》,MV 常常不报专辑名)被那条
        // "album 空即广告"整首标成「广告中」,而 YT Music 探针明明判它是歌;同专辑带专辑名的
        // 《Sexy Dancer》就正常 —— 差别只在 album 空不空。网页版广告的形状(artist 空)本来就只有在
        // `SpotifyWebAdProbe` 判成广告时才过得了 MediaControlClient 那道闸(见 spotifyWebAdAccepted),
        // 这里读同一份缓存,两边口径一致;原生 Spotify 的启发式 + AppleScript 复核原样不动。
        let spotifyWebVerdict: SpotifyWebAdProbe.Verdict? = isSpotifyWeb
            ? SpotifyWebAdProbe.shared.cachedVerdict(
                forKey: SpotifyWebAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title))
            : nil
        let adByFields = Self.adBreakByFields(
            isSpotifyNative: isSpotifyNative, title: newTitle, artist: newArtist, album: newAlbum,
            youTubeMusicVerdict: youTubeMusicVerdict, spotifyWebVerdict: spotifyWebVerdict)
        if !newTitle.isEmpty, !adByFields, newTitle != lastPersistedTrackTitle {
            UserDefaults.standard.set(newTitle, forKey: "np:lastTrackTitle")
            UserDefaults.standard.set(newArtist, forKey: "np:lastTrackArtist")
            // 专辑 2026-08-24 才补上(停播页的唱片 hero 要显示「歌手 · 专辑」)。它跟着
            // 曲名一起写、不单独判变化:同一首歌的专辑不会中途变,而换歌必然触发这个分支。
            // 旧安装第一次打开新版停播页时这个键还不存在 —— 消费方按「空就只显示歌手」处理。
            UserDefaults.standard.set(newAlbum, forKey: "np:lastTrackAlbum")
            lastPersistedTrackTitle = newTitle
        }
        // Spotify 广告插播判断(2026-08-19 重做:字段启发式 + 同曲棘轮 + AppleScript 权威)。
        // 老版本每一拍按"当下字段"重判 —— 实测广告字段会**闪变**(开播 album 空、几拍后
        // 补齐,Blinds.com 实锤),看走眼的那几拍 UI 会退回"歌名 + 搜索歌词中"。现在:
        // 换曲那一拍按加宽的启发式(album 空/artist 空/标题「—」,与 collector isAdBreak
        // 同款)定初值,同曲期间只往 true 棘轮、不回落;是 Spotify 就再异步问一次本尊
        // (`spotify url` 前缀是权威分类,广告可以带全 artist/title/album 骗过启发式),
        // 结果回来仍是这首才采纳。judge 与 collector 两侧口径一致,那边管上报,这边管 UI。
        //
        // ⚠️ **网页版 Spotify 也要认**(2026-09-02,用户实测截图坐实:Last.fm 那张卡的
        // "正在记录"行原样显示了一条"广告"——`!playback.isAdBreak` 那道闸没拦住,因为下面
        // `isSpotify` 原来只认原生客户端的 bundleIdentifier,浏览器代理进程报的是
        // `com.apple.WebKit.GPU`/浏览器自己的 bundle id,永远对不上)。现场抓的真实广告
        // 样本:`album=""  artist=""  title="广告"  duration≈30s`——跟原生客户端广告同一套
        // 字段信号,不需要另外发明判据,只需要把"这是不是 Spotify"的判断扩到网页版。
        // `BrowserPositionProbe.shared.platformBrowserPairs` 是用户在「网页播放器」设置页
        // 显式配对过的浏览器↔平台关系(跟 kickIfNeeded 用的是同一份数据、同一把锁),
        // 配对了 "spotifyWeb" 的浏览器标签页播放就按 Spotify 处理。
        //
        // ⚠️ **YouTube Music 网页版也要认**(2026-09-02,用户要求"chrome 上播 YT Music 的
        // 广告也像 Spotify 那样显示出来是广告")。它跟 Spotify 走的不是同一条判据:Spotify
        // 广告靠字段形状就能认(album/artist 空、标题「—」),而 YT Music 广告的 artist 是
        // 广告主频道名、**非空**,跟"真歌但没报专辑名"在字段上完全分不开 —— 只能问页面。
        // 那次查询由 `YouTubeMusicAdProbe` 异步做、结果进缓存,上面 `isYouTubeMusicAd`
        // 读的就是它。在此之前这类广告在 MediaControlClient 那道闸就被整条丢掉了,后果是
        // 30 秒广告期间灵动岛/悬浮窗整个塌成"没有在播放"、广告完了再弹回来。
        //
        // ⚠️ 上面这段"网页版也要认"的落地方式 2026-09-08 起改了:**不再**把 `isSpotify` 扩成"配对过
        // 网页版就按 Spotify 启发式判",而是网页版只认 `SpotifyWebAdProbe` 的正向证据 —— 配对关系
        // 不等于此刻在放 Spotify(Safari / Arc 两个平台都配了),按配对套启发式会把 YT Music 里
        // 没有专辑名的 MV 整首判成广告。判据收在 `adBreakByFields`(纯函数,selftest 钉着)。
        //
        // isSpotifyNative/isSpotifyWeb/youTubeMusicVerdict/adByFields 几个局部量在上面
        // np: 落盘那段之前就算好了(广告不该被记成"上次在听"),这里直接用。
        // ⚠️ 同曲棘轮例外：YouTube Music MV 前贴片广告与正片共享 MediaSession 元数据，
        // 同一 key 下页面判定会从 ad 变为 song。页面明确判定为 .song 时允许回落非广告态。
        // pageVerdict 仅在原生 Spotify 下置 nil，浏览器播放统一传 YT Music 探针判定。
        let nextAd = Self.nextAdBreakState(
            previous: isCurrentTrackAdBreak, isNewTrack: snapshot.trackKey != lastKey,
            adByFields: adByFields, pageVerdict: isSpotifyNative ? nil : youTubeMusicVerdict)
        if isCurrentTrackAdBreak != nextAd { isCurrentTrackAdBreak = nextAd }
        // 广告计数跟着广告态一起收(2026-09-09):不在广告里就必须是 nil,否则下一首歌会挂着
        // 上一次插播的「1/2」。读的是**同一份缓存**(`cachedReading`),不额外踢探针 —— 它跟
        // 上面那条 `cachedBadgeVerdict` 是同一次读数的两个字段,不会出现"判定说广告、计数
        // 却来自另一拍"的错位。徽章从 1/2 翻到 2/2 最多滞后一个探测周期(广告期间 5 秒一探),
        // 评审时确认可接受 —— 为一个装饰性计数把 AppleEvent 往返频率翻倍不值。
        let nextAdSlot = nextAd
            ? YouTubeMusicAdProbe.shared.cachedReading(forKey: youTubeMusicAdKey)?.adSlot
            : nil
        if currentAdSlot != nextAdSlot { currentAdSlot = nextAdSlot }
        // ⚠️ 只要「广告中」还亮着、而且是浏览器播放,就**每拍**再踢一次 YT Music 探针(2026-09-08,决策 #26)。
        // 原来探针只在 MediaControlClient 那道闸"album 为空"时才被踢:YT Music 首次发布元数据常常不带
        // album、几百毫秒后重发才带上 —— 重发之后基础守卫直接放行,**再没有任何地方去问页面**,状态机等的
        // 那个 `.song` 永远不会来;60 秒可读期一过判定变 nil、按「保持」走,整首歌挂着「广告中」直到换歌
        // (决策 25 修的"广告 5 秒再探"在这条路上根本没人触发)。kickIfNeeded 内部按判定分档(广告 5 秒
        // 一探、歌 60 秒不动),真广告期间也就是每 5 秒一次往返。不踢的情况:原生 Spotify(它有自己的
        // AppleScript 复核语义,pageVerdict 恒 nil);`spotifyWebVerdict == .ad`(那是 Spotify 网页广告,
        // 去问 YT Music 标签页只会 NOTFOUND 白烧一次往返);非浏览器 bundle 在 kickIfNeeded 里自然 no-op。
        if nextAd, !isSpotifyNative, spotifyWebVerdict != .ad {
            YouTubeMusicAdProbe.shared.kickIfNeeded(
                bundleIdentifier: snapshot.bundleIdentifier, key: youTubeMusicAdKey)
        }
        // 权威复核只对原生客户端有意义(`spotify url` 与通知里的 Track ID 都是原生 App 才有,网页版没有这
        // 两个接口)——网页版只吃字段启发式本身的结果。2026-09-09 起先问 Spotify 自己刚广播的通知、对不上
        // 才退回 osascript,见 spotifyNativeAdCheckForNewTrack。
        if snapshot.trackKey != lastKey, isSpotifyNative, !adByFields {
            spotifyNativeAdCheckForNewTrack(snapshot: snapshot)
        }

        let key = snapshot.trackKey
        let trackChanged = key != lastKey
        // ⚠️ 必须在这里留一份旧 key:下面 `lastKey = key` 之后,`lastKey` 就等于 `key` 了,
        // 到浏览器探针那一段(`if trackChanged`)再读它只会读到新值。留它是为了让探针的
        // "重新开放额度"日志能分辨这次到底是**真换歌**(旧 key 非空、跟新的不一样)还是
        // **中断后重新接上**(旧 key 为空 —— 快照变 nil 那条路径把 lastKey 清成了 "",
        // 见上面 `lastKey = ""` 一带)。2026-09-03 加:真机上实测到同一首歌连续播放期间
        // 探针额度被重开了 4 次(同一个 pid,排除了重启),但当时的日志分辨不出是哪一种。
        let previousKey = lastKey
        // 同一首歌播到中途,collector 还可能给它补出译文、或者换上一份更好的歌词(见
        // collector 的 backfillTranslation / retryLyricsUpgrade / rescoreLyrics)。原来这里
        // 只在换歌或"完全没歌词"时才重读,于是这类中途补上的东西要等下一次换歌才看得到 ——
        // 2026-08-09 用户问"为什么当前这歌没有英文译文",译文其实早在 19 秒前就翻好并落盘了。
        //
        // ⚠️ 不要加"已经有译文了就不用再盯"这类省事的闸门。2026-08-09 试过一版,当场被
        // 一个真实场景打脸:译文不只会从无到有,还会**被顶替** —— 网易云先给一份固定中文的
        // 社区译文(于是"已有译文"成立、不再盯了),采集器随后判定它语言跟设置对不上、机翻
        // 成英文写回去,而这边已经不看了,界面就一直停在那份中文上。
        //
        // 代价是可控的:mtime 只是一次 stat,而重新解析只在文件真的被改写时发生 —— 那时候
        // 下一次 lookup() 本来也要重新解析(EnrichCacheReader 自己就是按 mtime 缓存的)。
        // 跟下面读 enrich cache 的 mtime 挂在同一个节拍上(每次快照,约 2s 一次)。
        // 成本是一次 stat —— CollectorStatus 自己按 mtime 缓存,文件没变就不会重新解码。
        let networkDown = CollectorStatus.networkLooksDown
        if networkDown != collectorNetworkDown { collectorNetworkDown = networkDown }

        // 每拍先让 Reader 推进内容(mtime 变了在后台解码,见 refreshIfNeeded 注释),触发
        // 键用**已解码代**的版本而不是文件即时 mtime——stale 返回窗口里拿文件 mtime 触发
        // 会提前吃掉这次变化,后台解码完成后就再没有东西触发 reload 了(2026-08-20)。
        EnrichCacheReader.refreshIfNeeded()
        let enrichMTime = EnrichCacheReader.decodedContentVersion
        // 先无条件推进对外那个信号 —— 它的消费方(高清封面重查)关心的是"缓存内容变了",
        // 跟下面那个 reload 是否触发无关(reload 还看 trackChanged/hasContent)。
        if enrichContentVersion != enrichMTime { enrichContentVersion = enrichMTime }
        if trackChanged || !syncEngine.hasContent || enrichMTime != lastEnrichMTime {
            if trackChanged {
                logger.info("track changed: \(snapshot.artist ?? "", privacy: .public) - \(snapshot.title ?? "", privacy: .public)")
                // 上一首的图床地址跟着换歌走;新地址要等探针 2.5s 后带回来(见 spotifyArtworkURL)。
                if spotifyArtworkURL != nil { spotifyArtworkURL = nil }
            }
            lastKey = key
            lastEnrichMTime = enrichMTime
            reloadCurrentLyrics()
        }
        // 换了播放器也要重算偏移 —— 上面那个 reload 的触发条件是「换歌 / 没内容 / 缓存变了」,
        // **不含**"播放器变了"。而 trackKey 只由 歌手|歌名 决定:.auto 档下焦点在两个 App 之间
        // 切、或两个播放器放同名曲目时,曲目没"变"、内容也在,于是 applyOffsets 不跑,新播放器
        // 会继续套用**上一个播放器**那一档 —— 正是"把浏览器的补偿套到 Apple Music 上"这个
        // effectiveOffset 注释里明写要防的形态(2026-08-21 加播放器维度时发现)。
        //
        // 放在 reload 判断之后:换歌那一支已经经 reloadCurrentLyrics → applyOffsets 算过一遍,
        // 这里只补"没换歌但换了播放器"这一种情况,不重复跑。
        let bundleID = snapshot.bundleIdentifier
        if bundleID != lastAppliedBundleID {
            lastAppliedBundleID = bundleID
            if !trackChanged, syncEngine.hasContent { applyOffsets() }
        }

        if trackChanged {
            // 换歌时保留上一首封面，直到新封面就绪或确认无封面后再替换/清空，避免整窗闪白；
            // 同时安排超时兜底（scheduleArtworkStaleTimeout），防止子进程挂起导致旧封面常驻。
            scheduleArtworkStaleTimeout(forKey: key)
            fetchArtworkForCurrentTrack(expectedKey: key)
        }

        // elapsedTime 对 Apple Music 是 Music.app 自己实时算出来的精确播放位置;对 QQ
        // 音乐是 media-control --now 的外推值,带噪声,经 resolvePositionSeconds 平滑
        // 过再用(见该函数注释)。
        let now = Date()
        let playing = snapshot.playing == true
        // 暂停/恢复那一拍的诊断(2026-09-07):用户看到"一按暂停歌词进度变一下",要量的就是
        // "暂停前一刻屏上外推到哪"与"冻结值"之差、以及"冻结值"与"恢复后第一笔"之差。两个
        // 变量只在状态翻转的那一拍非 nil,日志也只在那一拍打一行。
        var pauseShownMs: Int?
        var pauseAnchorWasFrozenByEvent = false
        // 锚点偏置(自然切歌量的、或 Spotify 探针量的)只属于量它时对着的那个锚点:Spotify 重新发布了
        // 锚点(暂停冻结 / 恢复 / 拖动,原始 elapsedTime 变了)就作废,见 biasSurvivesAnchor。放在播放/
        // 暂停两个分支之前 —— 暂停分支的 pausedPositionMs 和播放分支的 resolvePositionSeconds 都要看到
        // 清零后的值。
        if isSpotifyNative, key == posTrackingKey, posReportedBiasSecs != 0,
           !Self.biasSurvivesAnchor(anchorElapsedTime: snapshot.anchorElapsedTime, measuredAgainst: posBiasAnchorElapsed) {
            logger.notice("anchor bias dropped: player republished anchor elapsed=\(snapshot.anchorElapsedTime ?? -1, format: .fixed(precision: 3)) measuredAgainst=\(self.posBiasAnchorElapsed ?? -1, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3)) playing=\(playing)")
            // 暂停发布的冻结值是耳朵里的位置,跟我们(探针纠过的)停在的位置一比就是探针钟的领先量。
            // 已经在暂停态(冻结锚点晚一拍才到)取 pausedPositionMs;同一拍翻转的取被事件冻住的锚点外推值。
            if !playing, posBiasFromProbe, let frozen = snapshot.anchorElapsedTime {
                let oursMs = anchor == nil ? pausedPositionMs : anchor?.extrapolatedPositionMs(now: now)
                if let oursMs {
                    learnProbeLead(residual: Double(oursMs) / 1000 - frozen)
                }
            }
            setReportedBias(0, anchorElapsed: nil)
            // 播放中换了锚点就再问一次 Spotify 的钟(见 SpotifyPositionProbe.requestConfirmation):
            // 新锚点准就什么都不改;它要是又晚了 2s(或干脆是假的),探针把新偏置量出来。暂停
            // 发的冻结锚点不问 —— 那个就是 Spotify 自己的钟,而且探针只在播放中消费。
            if playing {
                SpotifyPositionProbe.shared.requestConfirmation(forKey: key)
            }
        }
        if playing, let duration = snapshot.duration, duration > 0 {
            // 切歌/加载瞬间 Spotify 会短暂报 rate=0(playing 仍 true),按 1 计——与
            // collector 的 reconcile 规则一致。不归一的话 predicted 停走,下一拍正常
            // 前进的读数会被误判成 seek 跳变,顺手把自然切歌偏置也清了(2026-08-20
            // 对抗审查抓出)。真暂停走的是下面的 else 分支,不经过这里。
            var rate = snapshot.playbackRate ?? 1
            if rate <= 0 { rate = 1 }
            // 数据源三档画像(见 PositionSourceTier):Apple Music=AppleScript 播放头
            // (precise);Spotify=干净的 media-control 外推(cleanExtrapolated,
            // 2026-08-18 实测拆档——此前 08-14~08-18 走 JXA 直查、连修三轮仍不准已撤,
            // 撤掉后又被 noisyFloored 档的 1.0s 大门槛养出"整曲偏快",见枚举注释和
            // MediaControlClient.fetchRawMediaControlSnapshot 的决策注释);QQ 音乐/
            // 网易云=整秒下取整带抖动(noisyFloored)。各档伺服参数见 servoDecision。
            let tier = Self.positionSourceTier(forBundleID: snapshot.bundleIdentifier)
            // 浏览器地面真值探针(2026-08-30,见 BrowserPositionProbe 头注,2026-08-30
            // 改成一次性纠偏后再补一版):对受支持的浏览器+网站,换歌后探测一次网页 DOM
            // 拿真实播放位置,当"精确种子值"喂给 resolvePositionSeconds(tier 按
            // noisyFloored——它就是整秒地板量化读数),走正常的 seek-跳变/棘轮/EMA 判定,
            // 而不是绕开整套伺服逻辑直接采信。命中一次大跳变就会重锚,解决"换歌后进度
            // 偏慢"的原始问题;这首歌只消费一次(见 consumeCorrection),稳态精度交还给
            // 本来就更准的 .cleanExtrapolated 连续外推,不会被整秒精度的探针值持续覆盖
            // 导致周期性回退(2026-08-30 用户反馈坐实过这个回退,历史教训见类头注)。
            if trackChanged {
                BrowserPositionProbe.shared.trackChanged(from: previousKey, to: key)
                // Spotify 原生客户端:开播 2.5s 后问一次 player position 当地面真值,修
                // "广告后开播锚点晚发 ~2.4s"那种单看 media-control 认不出来的锚点(2026-09-07,
                // 见 SpotifyPositionProbe 头注)。
                SpotifyPositionProbe.shared.trackChanged(to: key, isSpotifyNative: isSpotifyNative)
            }
            // ⚠️ `expectedDuration` 不是可选的锦上添花:探针拿它在 JS 里认"这个标签页放的
            // 是不是同一首歌"(见 `BrowserPositionProbe.pageDurationToleranceSecs`),
            // YouTube Music 插播广告、同一浏览器里开着第二个 Spotify 标签页都靠它认出来。
            // 这里的 `duration` 已经被外层 `if playing, let duration, duration > 0` 保证 >0。
            BrowserPositionProbe.shared.kickIfNeeded(
                bundleIdentifier: snapshot.bundleIdentifier, key: key, expectedDuration: duration)
            let rawReportedForResolve: Double
            let effectiveTier: PositionSourceTier
            var usedBrowserProbe = false
            // ⚠️ **这里不要再加"拿 MediaRemote 位置当参照物"的守卫。** 2026-09-02 加过一道
            // (`isPlausibleCorrection(probed:reference:)`,reference 传 `snapshot.elapsedTime`),
            // 当天就被真机抓出来删掉了:这个探针存在的前提就是网页播放器的 `elapsedTime`
            // **恒为 0**,拿它当参照物,守卫直接退化成"只有页面放在前 8 秒内的修正才采纳",
            // 而消费又是每首歌一次性的 —— 整首歌都跑在错锚点上。完整原委和"为什么换成外推值
            // 同样不行"见 `BrowserPositionProbe.pageClockIsRunning` 一带的头注。
            // 可信度判据已经全部下沉进探针内部(同一首歌 + 页面的钟在走),那里才有能证明这
            // 两件事的材料;这一层只负责把探针值当"精确种子"喂进伺服逻辑。
            if let probed = BrowserPositionProbe.shared.consumeCorrection(forKey: key, rate: rate, now: now) {
                rawReportedForResolve = probed
                effectiveTier = .noisyFloored
                usedBrowserProbe = true
            } else if posWasPlaying, key == posTrackingKey,
                      let probed = SpotifyPositionProbe.shared.consumeCorrection(forKey: key, rate: rate, now: now) {
                // Spotify 的一次性真值(见 SpotifyPositionProbe):同样走 isGroundTruthSeed 通道,
                // 档位不变(cleanExtrapolated)。只在稳定播放中消费 —— 刚换歌那一拍要留给自然切歌
                // 校正播种,刚恢复播放那一拍恢复锚点本身就是准的。先扣掉探针钟相对耳朵的领先量
                // (probeLeadSecs,暂停时学出来的,见那一带注释)。
                rawReportedForResolve = probed - probeLeadSecs
                effectiveTier = tier
                usedBrowserProbe = true // 名字沿用:含义是"这一笔是地面真值种子",见 resolvePositionSeconds
            } else {
                rawReportedForResolve = snapshot.elapsedTime ?? 0
                effectiveTier = tier
            }
            let (positionSeconds, didReanchor) = resolvePositionSeconds(
                reported: rawReportedForResolve, rate: rate, key: key, now: now,
                tier: effectiveTier, isGroundTruthSeed: usedBrowserProbe,
                anchorElapsedTime: snapshot.anchorElapsedTime, streamRaw: snapshot.elapsedTime)
            if !posWasPlaying, key == posTrackingKey, let prevPaused = pausedPositionMs {
                // 暂停→恢复翻转的那一拍(同曲)。delta = 恢复后第一笔 − 暂停冻结值。
                logger.notice("resume transition: paused=\(Double(prevPaused) / 1000, format: .fixed(precision: 3)) resumed=\(positionSeconds, format: .fixed(precision: 3)) raw=\(rawReportedForResolve, format: .fixed(precision: 3)) delta=\(positionSeconds - Double(prevPaused) / 1000, format: .fixed(precision: 3)) rate=\(snapshot.playbackRate ?? -1, format: .fixed(precision: 2))")
            }
            // 只在真的有必要时才重新构造锚点——稳定播放期间(没有换歌/没有真实
            // seek/rate 和时长都没变),继续外推旧锚点在数学上跟重新构造一份新锚点得到
            // 完全相同的 extrapolatedPositionMs(now:) 结果(旧锚点的 fetchedAt+
            // progressMs 组合本身已经蕴含了外推到任意后续时刻的正确基准),重新赋值纯属
            // 多余的 @Published 通知。anchor 是结构体、不是 Equatable(fetchedAt 每次
            // 构造都不同,天然没法直接比较新旧是否相等),所以改成显式判断"这次是不是真的
            // 需要重新锚定"——首次锚定/换歌/真实不连续(didReanchor)/倍速或时长变化,
            // 缺一不可,不能只挑一两个条件。
            let needsNewAnchor = anchor == nil || trackChanged || didReanchor
                || anchor?.rate != rate || anchor?.durationMs != Int(duration * 1000)
            if needsNewAnchor {
                anchor = ProgressAnchor(
                    durationMs: Int(duration * 1000),
                    progressMs: Int(positionSeconds * 1000),
                    rate: rate,
                    progressTs: nil,
                    baseAgeMs: 0, // 本机直接读取,没有网络延迟需要外推的锚点年龄
                    fetchedAt: now,
                    fresh: true // 本地读取,始终当作新鲜锚点,不封顶外推
                )
            }
        } else {
            if let anchor {
                // 屏上此刻显示的位置:通知已把锚点冻住(rate=0)就是冻住那一刻的值,否则是
                // 还在往前跑的外推值 —— 两种形态的"暂停跳变"成因不同,一起记下来。
                pauseShownMs = anchor.extrapolatedPositionMs(now: now)
                pauseAnchorWasFrozenByEvent = anchor.rate == 0
                self.anchor = nil
            }
            // 暂停态里换了曲目(暂停中点了另一首):没有走 resolvePositionSeconds,自然
            // 切歌偏置的归零要在这里补上——新曲的冻结位置是新锚点的值,跟旧偏置无关。
            if key != posTrackingKey, posReportedBiasSecs != 0 { setReportedBias(0, anchorElapsed: nil) }
            // 暂停中用户在播放器里拖了进度条:冻结值跳变 = Spotify 已重打对齐真声的
            // 锚点,旧偏置作废(见 posPausedRawSecs 注释)。我们自己 UI 里的暂停拖动走
            // seek(toMs:),那边已经清过,这里再看到的跳变清一次也只是幂等。
            let frozenRaw = snapshot.elapsedTime ?? 0
            if let prev = posPausedRawSecs, abs(frozenRaw - prev) > Self.seekJumpToleranceSecs,
               posReportedBiasSecs != 0 {
                setReportedBias(0, anchorElapsed: nil)
            }
            posPausedRawSecs = frozenRaw
        }
        // "歌词窗口"进度条的暂停态冻结位置/时长——见两个属性定义处的注释。跟其它
        // @Published 一样只在真的变化时才赋值。暂停态的 snapshot.elapsedTime 就是精确的
        // 冻结位置(AppleScript 对 Apple Music、media-control 的原始 elapsedTime 对其它
        // 播放器都是"暂停即冻结",见 MediaControlClient.fetchRawMediaControlSnapshot
        // 里暂停分支的注释),不需要再经过 resolvePositionSeconds 平滑。
        let newDurationMs: Int? = {
            if let d = snapshot.duration, d > 0 { return Int(d * 1000) }
            return nil
        }()
        if newDurationMs != currentDurationMs { currentDurationMs = newDurationMs }
        // 暂停态也要挡住 seek 之后的陈旧读数——播放分支走 resolvePositionSeconds,那个
        // 函数一进门就有 shouldRejectStalePositionAfterSeek 这层保护,而这行原来是直接
        // 采信 snapshot.elapsedTime。结果:暂停时拖进度条,seek(toMs:) 刚把 pausedPositionMs
        // 设成目标位置,紧接着这一轮 apply() 抓到的快照可能还是 seek 之前的位置(播放器
        // 没跟上,或这份快照本来就是 seek 之前抓的),于是进度条和歌词被硬拽回原处,过
        // 一两轮才跳到目标——手感上就是"弹回去一下再过去"。判定为陈旧时沿用当前值
        // (seek 刚写进去的目标位置),等播放器状态跟上。
        let newPausedPositionMs: Int? = {
            guard !playing else { return nil }
            // 冻结的 elapsedTime 带着同一个超前锚点的值——自然切歌偏置在暂停态同样要扣
            // (不扣的话,暂停看歌词那一眼恰恰是偏快 ~0.9s 的)。
            let reported = max(0, (snapshot.elapsedTime ?? 0) - posReportedBiasSecs)
            if let target = lastSeekTargetSecs, let prev = lastSeekPrevSecs, let at = lastSeekAt,
               Self.shouldRejectStalePositionAfterSeek(
                   reported: reported, target: target, previous: prev, elapsedSinceSeek: now.timeIntervalSince(at)
               ) {
                return pausedPositionMs ?? Int(target * 1000)
            }
            return Int(reported * 1000)
        }()
        if newPausedPositionMs != pausedPositionMs { pausedPositionMs = newPausedPositionMs }
        if let shown = pauseShownMs, let paused = newPausedPositionMs {
            // 播放→暂停翻转的那一拍。delta<0 = 显示往回退,>0 = 往前补。
            logger.notice("pause transition: shown=\(Double(shown) / 1000, format: .fixed(precision: 3)) frozenRaw=\(snapshot.elapsedTime ?? -1, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3)) paused=\(Double(paused) / 1000, format: .fixed(precision: 3)) delta=\(Double(paused - shown) / 1000, format: .fixed(precision: 3)) frozenByEvent=\(pauseAnchorWasFrozenByEvent) errEMA=\(self.posErrEMA, format: .fixed(precision: 3))")
        }
        // 无论这一轮是否在播放,都要更新这三个状态,供下一轮判断"是不是刚从暂停里恢复
        // 播放"——只在上面播放分支里更新的话,"播放→暂停→再播放"这个序列会因为暂停期间
        // 完全没走到这行,让下一次恢复播放时的判断误用暂停前的陈旧 posPrevWall/
        // posWasPlaying,而不是正确识别出"刚从暂停恢复"。
        posTrackingKey = key
        posWasPlaying = playing
        posPrevWall = now
        publishPositionBiasIfChanged(snapshot: snapshot, isSpotifyNative: isSpotifyNative, now: now)
        // 自然切歌判定要用"旧曲"的时长/来源——resolve 被调用时 snapshot 已是新曲,所以
        // 这里每轮把本轮的存下来,下一轮它们就是"上一首的"。
        posPrevDurationSecs = snapshot.duration ?? 0
        posPrevTierCleanExtrapolated =
            Self.positionSourceTier(forBundleID: snapshot.bundleIdentifier) == .cleanExtrapolated
        if playing, posPausedRawSecs != nil { posPausedRawSecs = nil }
        if anchor == nil {
            // 暂停(anchor == nil 但曲目还在、位置已冻结)时**不能**把当前歌词行清掉。
            //
            // 这里原来是无条件三连清空,于是一按暂停,悬浮歌词/灵动岛/菜单栏那一行歌词
            // 直接消失、歌词窗口的高亮也没了——而用户按暂停的典型场景恰恰是"这句是什么?
            // 我看一下",清掉正是最不该发生的事。停掉 20Hz 定时器是对的(暂停期间位置不
            // 再前进,没有必要每秒算 20 次),但"停止推进"跟"清空显示"是两回事。
            //
            // 暂停态有精确的冻结位置(pausedPositionMs,见上面那段注释:AppleScript 和
            // media-control 在暂停时给的 elapsedTime 都是冻结值),所以直接按这个位置解一
            // 次当前行即可。真的没有位置或没有歌词内容时才回落到清空。
            stopFastTimer()
            resolveLinesForPausedPosition()
        } else if syncEngine.hasContent {
            ensureFastTimerRunning()
            fastTick()
        } else {
            // 在播、但引擎里没有任何歌词内容(纯音乐/广告/还没解析出来):每一拍 fastTick
            // 的四个查询都扫空数组、四个守卫全不触发,20Hz 定时器整首歌空转纯属浪费 ——
            // 暂停(上面)和锁屏(setScreenLocked)都已特判掉这种空转,这里补上"在播但
            // 没词"这一档。先补最后一拍把可能残留的行状态清掉再停表;collector 中途解析
            // 出歌词后,EnrichCacheReader.onContentAdopted 会直接重载当前歌词并重新拉起
            // 定时器,不再依赖下一轮 poll/apply。
            fastTick()
            stopFastTimer()
        }
    }

    // 供外部(EnrichCacheStore 保存/删除歌词后)强制重新读取当前曲目的歌词——正常情况
    // apply() 只在换歌那一刻才 reloadCurrentLyrics(),同一首歌播放中途改了缓存内容
    // 不会自动重新读。本地模式的 EnrichCacheReader 每次都是直接读磁盘文件,写完盘立刻
    // 调用这个就能拿到最新内容,不需要等 collector 重启。
    public func forceReloadLyricsForCurrentTrack() {
        // 用户显式操作(保存/删除歌词)必须立刻读到刚写的内容——同步重解,别等后台
        // 世代号那条慢路径(见 EnrichCacheReader.reloadNow 注释);版本同步推进,免得
        // 下一拍 poll 按版本差再白跑一次 reload(等值闸也会挡,这里省得它挡)。
        EnrichCacheReader.reloadNow()
        lastEnrichMTime = EnrichCacheReader.decodedContentVersion
        reloadCurrentLyrics()
        // 20Hz 定时器在"在播但没词"时是停着的(见 apply() 末尾)——刚保存进来的歌词若让
        // hasContent 从无到有,这里得立刻拉起,不能干等下一轮 2s 轮询;fastTick 无条件补
        // 一拍,让当前行马上按新内容解出来(暂停态走 anchor==nil 分支,同样立即生效)。
        if anchor != nil, syncEngine.hasContent { ensureFastTimerRunning() }
        fastTick()
    }

    /// 跳到曲目内的某个位置(毫秒)——发指令给播放器,并**立刻**把本地外推重锚到目标位置。
    ///
    /// 为什么必须自己重锚、不能等下一轮轮询自愈:
    /// ① 轮询是 2 秒一轮(reschedulePollTimer),不重锚的话最坏要等 2 秒歌词才跟上,而拖
    ///    进度条这个动作用户预期是即时反馈;
    /// ② 更要命的是小幅拖动会被**永久**吞掉:resolvePositionSeconds 里那道
    ///    seekJumpToleranceSecs(2 秒)判定"读数跟外推差 2 秒以内算稳定播放,继续按旧基准
    ///    外推",拖动幅度小于 2 秒时它压根不认为发生了跳变,伺服 EMA 也会把这点差异当噪声
    ///    慢慢磨平——歌词会一直按拖动前的基准走。
    ///
    /// 重锚要同时改三处,少一处就会被下一轮"稳定播放"分支按旧值覆盖回去:trackPosSeconds
    /// (外推累加器)、posPrevWall(外推的墙钟基准)、posErrEMA(清零,拖动不是需要伺服慢慢
    /// 校正的漂移)。anchor 也当场重建,让 UI 这一帧就跳过去,不等 apply()。
    ///
    /// 暂停状态下也允许拖:此时 anchor 是 nil、pausedPositionMs 才是显示源,所以只更新它。
    // seek 之后短暂不信"更像 seek 之前"的位置读数,见 seek(toMs:) 与
    // shouldRejectStalePositionAfterSeek 的注释。
    private var lastSeekTargetSecs: Double?
    private var lastSeekPrevSecs: Double?
    private var lastSeekAt: Date?
    public nonisolated static let seekSettleWindow: TimeInterval = 1.2

    /// seek 刚发出去之后,这一份位置读数是不是"还是 seek 之前的播放器状态"、该整份丢弃。
    ///
    /// 纯函数,便于 selftest 覆盖。判据:还在窗口内,且这次读数**更靠近 seek 前的旧位置**
    /// 而不是目标位置。相等时不丢(拖动幅度极小时两者本来就分不开,丢了反而卡住自愈)。
    public nonisolated static func shouldRejectStalePositionAfterSeek(
        reported: Double, target: Double, previous: Double, elapsedSinceSeek: TimeInterval
    ) -> Bool {
        guard elapsedSinceSeek >= 0, elapsedSinceSeek < seekSettleWindow else { return false }
        return abs(reported - previous) < abs(reported - target)
    }

    public func seek(toMs targetMs: Int) {
        let clampedMs = max(0, min(targetMs, currentDurationMs ?? targetMs))
        let seconds = Double(clampedMs) / 1000
        // .auto/多选模式下要按"这一刻实际在播的是谁"选后端,不能只看设置值——只要不是排他地
        // 选了 Apple Music 一个(PlaybackPlayerPreference.isExclusivelyAppleMusic 为 false),
        // 写路径会走 media-control,而读路径对 Apple Music 走的是精确的 AppleScript 播放头,
        // 两条路不一致。
        let resolvedIsAppleMusic = lastSnapshot?.bundleIdentifier == PlaybackPlayer.appleMusic.bundleIdentifier
        MusicPlaybackController.seek(toSeconds: seconds, preferAppleScript: resolvedIsAppleMusic)

        let now = Date()
        // 记下"从哪跳到哪",用来在接下来一小段时间里识别并丢弃 seek 之前采样的陈旧读数。
        lastSeekPrevSecs = trackPosSeconds
        lastSeekTargetSecs = seconds
        lastSeekAt = now
        // 作废所有在飞的 poll:它们的快照是 seek **之前**抓的(子进程往返几十到几百毫秒),
        // 落地后会被 resolvePositionSeconds 当成"真实 seek 跳变"硬重锚回旧位置,表现成
        // 松手跳过去、一瞬间又弹回来。这一行只治"已经在飞"的那次;seek 本身还有 ~300ms
        // 才在播放器侧生效(Music.app 的 AppleScript 状态实测要 ~294ms 才切换,见
        // handlePlayerInfoChanged 那段注释),那之后**新发起**的 poll 同样会读到旧位置,
        // 靠上面那个接受窗兜。
        pollGeneration += 1
        trackPosSeconds = seconds
        posPrevWall = now
        posErrEMA = 0
        // 我们主动发的 seek 同样会让 Spotify 重打锚点(与真声对齐)——锚点偏置作废。
        setReportedBias(0, anchorElapsed: nil)
        if let existing = anchor {
            anchor = ProgressAnchor(
                durationMs: existing.durationMs,
                progressMs: clampedMs,
                rate: existing.rate,
                progressTs: nil,
                baseAgeMs: 0,
                fetchedAt: now,
                fresh: true
            )
        } else if currentDurationMs != nil {
            // 暂停态:显示源是 pausedPositionMs(见 apply() 里那段注释),没有锚点可改。
            pausedPositionMs = clampedMs
        }
        // 歌词高亮跟着立刻走到新位置,不等 20Hz 的下一拍(它本来也会跟上,但那一拍之前
        // 屏幕上仍是旧的一句,拖动时看着像没反应)。
        fastTick()
    }

    // 单曲歌词时间轴微调——只对"当前正在播的这首歌"生效,立即体现在下一次 fastTick()
    // 里(不等换歌/下次轮询)。没有任何曲目信息(currentOffsetKey 还是空)时静默什么都
    // 不做,不会把校正值存进一个毫无意义的空 key 下面。
    @discardableResult
    public func nudgeLyricsOffset(by deltaMs: Int) -> Int {
        guard lastSnapshot != nil else { return trackLyricsOffsetMs }
        // 电台上调的是**这个台上这首歌**那一档(2026-09-11 用户拍板「仅适用于这个电台里播放的歌」)。
        // 绝不能落进按曲目那层:用户实测同一首歌正常播放本来是准的,把电台的 δ 套过去会把对的搞错。
        let radioKey = currentRadioOffsetKey
        if !radioKey.isEmpty {
            LyricsOffsetStore.shared.nudgeRadio(by: deltaMs, forKey: radioKey)
        } else {
            LyricsOffsetStore.shared.nudge(by: deltaMs, forKey: currentOffsetKey, pinKey: currentPinKey)
        }
        applyOffsets()
        // 返回**这首歌**那部分,不是总和:调用方(快捷键的提示条、菜单标题)说的是
        // "这首歌调到了多少",全局基准不该混进那个数字里。
        return trackLyricsOffsetMs
    }

    public func resetLyricsOffset() {
        guard lastSnapshot != nil else { return }
        // 只清这首歌的微调。全局基准是设备侧的固定延迟,跟"这首歌歌词准不准"是两件事,
        // 被一次「重置」连带抹掉的话,用户得回设置里重新调一遍(见 LyricsOffsetStore
        // .globalOffsetMs 的注释)。
        // 电台上「归零」清的也是电台那一档 —— 跟上面 nudge 对称,不然调得进去、清不掉。
        let radioKey = currentRadioOffsetKey
        if !radioKey.isEmpty {
            LyricsOffsetStore.shared.setRadioOffset(0, forKey: radioKey)
        } else {
            LyricsOffsetStore.shared.reset(forKey: currentOffsetKey, pinKey: currentPinKey)
        }
        applyOffsets()
    }

    /// 改全局基准(设置页那个控件)。所有歌都受影响,正在播的这首立刻跟上。
    public func setGlobalLyricsOffset(_ ms: Int) {
        LyricsOffsetStore.shared.setGlobalOffset(ms)
        guard lastSnapshot != nil else { return }
        applyOffsets()
    }

    /// 改某个播放器那档(设置页那个下拉框选中具体播放器时的控件)。只有当前正在播的**恰好
    /// 就是它**时才需要立刻重算 —— 改别的播放器的档位对眼下这首歌没有任何影响,白跑一次
    /// applyOffsets 会顺带把两个 @Published 推一遍。
    ///
    /// 2026-08-18 那个同名入口是内部为 Spotify 写死的补偿,08-20 随根修一起删了;这次是
    /// 用户显式配置的那一层,语义不同(见 LyricsOffsetStore.playerOffsets)。
    public func setPlayerLyricsOffset(_ ms: Int, forBundleID bundleID: String) {
        LyricsOffsetStore.shared.setPlayerOffset(ms, forBundleID: bundleID)
        guard lastSnapshot?.bundleIdentifier == bundleID else { return }
        applyOffsets()
    }

    /// 把「全局基准 + 这个播放器那档 + 这首歌的微调」算出来灌进引擎,并把两个对外属性刷成一致。
    ///
    /// 所有入口(换歌词内容、nudge、reset、改全局基准/从 store 重读)都走这里。
    /// 原来它们各自赋两次值,加了全局基准之后每处都要多算一步 —— 分散写迟早漏掉一处,而
    /// 漏掉的表现是"某条路径下全局偏移不生效",只在特定操作顺序下复现,极难归因。
    private func applyOffsets() {
        let track = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey)
        // 播放到这首歌时把 pin 状态跟当前校正值重新对一遍(双向,见那个方法的注释)。
        // 幂等,状态已经一致时是纯内存判断。
        LyricsOffsetStore.shared.syncPinToOffset(forKey: currentOffsetKey, pinKey: currentPinKey)
        // 播放器那层按**这一刻真正在播的那个 App** 算。拿不到身份(还没有快照)时传 nil,
        // 那层就按 0 算 —— 绝不能猜一个,否则会把浏览器的补偿套到 Apple Music 上。
        let radioKey = currentRadioOffsetKey
        let effective = LyricsOffsetStore.shared.effectiveOffset(
            forKey: currentOffsetKey, bundleID: lastSnapshot?.bundleIdentifier, radioKey: radioKey
        )
        syncEngine.offsetMs = effective
        // 对外报的是**引擎真正在用的那个数**,含这份歌词自己带的 `[offset:]`
        // (`syncEngine.lrcOffsetMs`,见 LRCParser.parseOffsetMs)。
        //
        // ⚠️ 必须含它:这个属性的唯一用途是"把歌词时间轴换算到播放位置",而歌词窗口点某一行
        // 反算 seek 目标用的就是 `行时间 − currentLyricsOffsetMs`。漏掉 LRC 那一层的话,带
        // 非零 offset 的歌点行会跳到隔壁行 —— 正是这个属性当初存在的理由(注释见上面)。
        // 用户可见的那两个数(设置页的基准、菜单里的单曲值)都不含它,那是对的:LRC offset
        // 不是用户调出来的,不该出现在"你调了多少"里。
        let effectiveWithLRC = effective + syncEngine.lrcOffsetMs
        // 只在真的变了时才赋值:这两个都是 @Published,每次赋值都会推着订阅者重渲染,
        // 而 reloadCurrentLyrics 在"歌词还没解析出来"时会被反复调用(见那边的注释)。
        if currentLyricsOffsetMs != effectiveWithLRC { currentLyricsOffsetMs = effectiveWithLRC }
        // 对外那个"这首歌调到了多少"在电台上报的是**电台那一档** —— 用户此刻按加减键改的就是它,
        // 显示另一个数会让人以为没生效。不是电台时逐字同改动前。
        let shown = radioKey.isEmpty ? track : LyricsOffsetStore.shared.radioOffset(forKey: radioKey)
        if trackLyricsOffsetMs != shown { trackLyricsOffsetMs = shown }
    }

    // 供"歌词管理"窗口的偏移输入框用——那边直接写 LyricsOffsetStore(不经过
    // nudge/reset,是敲一个具体数值),写完之后调这个让当前正在播的这首歌(如果编辑的
    // 恰好就是它)立刻用上新值,不用等下次换歌。跟别的歌词内容(key 对不上当前曲目)
    // 无关时,这里只是把 currentOffsetKey 对应的值重新读一遍、原样赋回去,是个安全的
    // 空操作。
    public func refreshOffsetFromStore() {
        guard lastSnapshot != nil else { return }
        applyOffsets()
    }

    // 跟 syncEngine 实际加载的歌词内容(lyrics+lyricsYRC)绑在一起算出来的 key——见
    // reloadCurrentLyrics() 里怎么算的。只在换歌词内容那一刻更新一次,nudge/reset 直接
    // 复用,不用每次都重新拼一遍(也保证跟当初读校正值时用的是同一个 key)。
    private var currentOffsetKey = ""

    // 同一首歌在 LyricsPinStore 里的身份 —— 归一化的 enrich key(artist|title|album),
    // **不含**歌词内容指纹。两个 key 各管一件事:上面那个决定"这份校正值属于哪一份歌词
    // 内容",这个决定"哪首歌不许后台再换歌词源"。内容指纹恰恰是会变的那一半,拿它当 pin
    // 的身份等于"内容一换 pin 也失效",正好把要防的事情放过去(见 LyricsPinStore)。
    private var currentPinKey = ""

    /// 这一刻在放的电台(载荷里的 `radioStationHash`),不是电台就是 nil。见 currentRadioOffsetKey。
    private var currentStationHash: String?

    /// 这首歌**在这个台上**的时间轴校准 key。不是电台 / 拿不到台标哈希 / 还没有曲目身份 → 空串,
    /// 那一层整个不适用,行为跟这个功能加进来之前逐字相同。
    private var currentRadioOffsetKey: String {
        guard lastSnapshot?.isRadio == true, let hash = currentStationHash else { return "" }
        return LyricsOffsetStore.radioKey(stationHash: hash, trackKey: currentOffsetKey)
    }

    /// 上一次读缓存时那个文件的 mtime。变了就说明 collector 又写过,当前这首歌的内容可能
    /// 已经不是手上这一份了(见 apply() 里那段注释)。
    private var lastEnrichMTime: Date?

    /// enrich 缓存**已解码那一代**的版本(= `EnrichCacheReader.decodedContentVersion`)。
    ///
    /// 为什么要把它 @Published 出去(2026-08-24):collector 解析一首没听过的歌要**好几秒**
    /// (实测「七月上」13:52:52 开播、13:53:00 才把 cover_url 写进缓存,晚 8 秒),而
    /// `PlaybackCoordinator.refreshHighResCover()` 原来**只**由 曲目/封面字节 的变化触发、
    /// 换歌后 300ms 查一次就完 —— 那一刻缓存里还没有这首歌,于是 clearHighRes() 之后
    /// **永不重试**,整首歌都停在系统那张 100×100 上(用户报「网易云封面依然很糊」的真根因;
    /// 之前那轮只修了 QQ 的边界判据,没碰到这条)。
    /// 这个信号让"缓存里多了东西"也能成为一个重查触发点 —— 判据跟歌词重载用的是**同一代**
    /// 版本号,不会出现"歌词换上了、封面没跟上"的偏差。
    ///
    /// 只在**变化**时赋值:@Published 是 willSet 语义,同值重复赋会白广播一轮下游订阅。
    @Published public private(set) var enrichContentVersion: Date?

    /// reloadCurrentLyrics 的**全部**会影响引擎装载/派生状态的输入快照。相等 ⇒ 整段重算
    /// (简繁转换×3 + 引擎 load + allLines/gapMarkers 重建)可以跳过。
    /// ⚠️ trackKey 必须在里面:两首都没有歌词的歌五个字段全空相等,不带曲目身份的话
    /// 换歌会被闸误吞,currentOffsetKey/applyOffsets/allLines 的 idPrefix、以及 load 的
    /// 抬头识别(trackTitle/trackArtist)全部停留在上一首,偏移校正会串歌。
    private struct LyricsReloadSnapshot: Equatable {
        let trackKey: String
        let lyrics, lyricsTr, lyricsRoma, lyricsYRC: String
        let instrumental, resolved, searchIncomplete: Bool
        let variant: ChineseVariant
        let romanizationScripts: RomanizationScripts
        let isCantonese: Bool
        // 2026-08-30 加,见 currentTrackPlainLyrics 头注——没有时间戳的纯文本兜底,跟
        // lyrics 一样得参与这道内容等值闸,不然采纳/更换一条纯文本候选之后,闸会因为
        // 其它字段(lyrics 本来就是空的,没变)误判"内容没变"而跳过重算,新内容显示不出来。
        let plainLyrics: String
    }
    private var lastReloadSnapshot: LyricsReloadSnapshot?

    private func reloadCurrentLyrics() {
        guard let snapshot = lastSnapshot else { return }
        let found = EnrichCacheReader.lookup(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            album: snapshot.album ?? ""
        )
        // 见过中文歌词就记一笔(粘性,只置不清)。判据 2026-08-31 起改用共享的
        // `ChineseVariant.affects` —— 这里原本手抄了一份"有汉字、且没有假名",注释还写着
        // "判据跟 ChineseVariant.converted 一致",那正说明它该是同一个函数而不是两份抄写。
        // 刻意放在下面的等值闸**之前**——闸命中早退时这两个标志也必须照常更新。
        let raw = found?.lyrics ?? ""
        if !sawChineseLyrics, ChineseVariant.affects(raw) {
            sawChineseLyrics = true
        }
        // 逐曲的那个每次都要**重算**(它会来回变),不能跟着上面那个 `if !sawChineseLyrics`
        // 的早退一起被跳掉。译文只在**正在显示**时才算进来,理由见它声明处。
        currentLyricsSupportsChineseVariant = Self.supportsChineseVariant(
            lyrics: raw,
            translation: found?.lyricsTr ?? "",
            translationVisible: showsTranslation)
        // 内容等值闸(2026-08-20 性能审计):失效键是整个 enrich 缓存文件的 mtime,collector
        // 给**别的歌**写盘(专辑预取最多 30 首逐个落盘/译文回填/重打分)都会带着一字未变的
        // found 走到这里 —— 原来每次都白跑简繁转换×3 + 全套解析过滤 + 整曲罗马音/分词重算
        // + allLines/gapMarkers 重建,单次 10-50ms 主线程,正撞上 30Hz 填色渲染。快照含
        // resolved/instrumental/searchIncomplete:它们翻转时快照必不相等,不会被
        // 闸吞掉;比较用 String ==(mtime 已变时 lookup 是新解码实例,引用比较必 miss,
        // 别指望它)。⚠️ 闸只跳"重算",不跳上面的粘性置位;闸后的 found 派生赋值
        // (hasLyricsContent 等)在快照相等时算出来的必然是同值,skip 无害。
        let reloadSnapshot = LyricsReloadSnapshot(
            trackKey: "\(snapshot.artist ?? "")|\(snapshot.title ?? "")|\(snapshot.album ?? "")",
            lyrics: raw,
            lyricsTr: found?.lyricsTr ?? "",
            lyricsRoma: found?.lyricsRoma ?? "",
            lyricsYRC: found?.lyricsYRC ?? "",
            instrumental: found?.instrumental ?? false,
            resolved: found?.resolved ?? false,
            searchIncomplete: found?.searchIncomplete ?? false,
            variant: chineseVariant,
            romanizationScripts: romanizationScripts,
            isCantonese: found?.isCantonese ?? false,
            plainLyrics: found?.plainLyrics ?? "")
        if reloadSnapshot == lastReloadSnapshot {
            logger.debug("lyrics reload skipped: content unchanged (mtime-only churn)")
            return
        }
        lastReloadSnapshot = reloadSnapshot
        // 简繁转换只作用在展示上:正文、译文、逐字数据都转,罗马音是拉丁字母不用转。
        // 逐字数据整串转是安全的 —— 时间戳是数字,转换只碰汉字。
        let variant = chineseVariant
        // 日文歌里被源写成简体的汉字先修回(2026-09-06,`JapaneseKanjiRepair`,规则见那边),再做
        // 用户的简繁偏好。顺序无所谓 —— `converted` 见到假名就整份放过,对日文歌本来就是空操作 ——
        // 但概念上先修源的错、再套用户的偏好。整首判定用正文,正文为空(只有逐字)才看逐字串;
        // 译文是中文、罗马音是拉丁字母,都不进修回。
        let rawYRC = found?.lyricsYRC ?? ""
        let japaneseSong = Romanizer.looksJapaneseSong(raw.isEmpty ? rawYRC : raw)
        // 引擎侧还有第二道指纹早退(见 LyricsSyncEngine.load 注释),两道闸各管一层:这里
        // 管"连转换都别做",那里兜"其它调用方/清过发布状态后的重灌"。
        syncEngine.load(
            lyrics: variant.converted(JapaneseKanjiRepair.repair(raw, japaneseSong: japaneseSong)),
            lyricsTr: variant.converted(found?.lyricsTr ?? ""),
            lyricsRoma: found?.lyricsRoma ?? "",
            lyricsYRC: variant.converted(JapaneseKanjiRepair.repair(rawYRC, japaneseSong: japaneseSong)),
            // 用来认出歌词文件开头那行「曲名 - 歌手」抬头,见 looksLikeHeaderLine。
            trackTitle: snapshot.title ?? "",
            trackArtist: snapshot.artist ?? "",
            romanizationScripts: romanizationScripts,
            songIsCantonese: found?.isCantonese ?? false
        )
        currentOffsetKey = LyricsOffsetStore.trackKey(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            lyrics: found?.lyrics ?? "",
            lyricsYRC: found?.lyricsYRC ?? ""
        )
        // ⚠️ 必须走 EnrichCacheKeys.normalizedKey,不能拿播放器报的原始三段自己拼:
        // 「歌词管理」那边的 pinKey 是缓存 key 本身(已归一化),两边不一致的话,在管理页
        // 校准的歌跟播放时钉住的歌就是两个身份 —— 而歌名带结尾译名括号的曲目(实测这台
        // 机器 2483 首里 111 首,4.5%)恰好都落在这个差异上。
        currentPinKey = EnrichCacheKeys.normalizedKey(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            album: snapshot.album ?? ""
        )
        applyOffsets()
        settledThresholdIndex = nil
        // hasLyricsContent/allLines 只在真的变化时才赋值——理由跟上面 apply() 里
        // title/artist/album 的同款注释一样。这个函数不止在真的换歌时调用,"歌词还没
        // 解析完、每轮都重试"那个分支(见 apply() 里 `!syncEngine.hasContent` 条件)会让
        // 这个函数在同一首歌播放期间被反复调用——这种情况下 hasContent 和 allLines 每次
        // 算出来的都是同一个"还没解析出来"的空结果,无条件赋值会白白触发订阅者(含"歌词
        // 窗口")重渲染。allLines 是 [LyricsWindowLine],Equatable(见 LyricsSyncEngine.swift
        // 里的定义),数组比较是安全、开销可忽略的操作(同一首歌的行数通常只有几十行)。
        let newHasContent = syncEngine.hasContent
        if newHasContent != hasLyricsContent { hasLyricsContent = newHasContent }
        let newInstrumental = found?.instrumental ?? false
        if newInstrumental != isCurrentTrackInstrumental { isCurrentTrackInstrumental = newInstrumental }
        // 解析跑完了、又不是纯音乐、还是一句都没有 —— 那就是真的没有,别再说"搜索中"。
        // ⚠️ 但"跑完了"不等于"问过了":那一轮要是有源因为熔断冷却被整个跳过(直连 DNS 抽风
        // 之类),下这个结论就是把一次网络事故说成了这首歌的属性。searchIncomplete 就是
        // 那种情况,collector 那边还欠一次快速补搜,界面继续说"搜索中"才是实话——它不会
        // 无限转圈,补搜一跑完这个标记就没了,详见 EnrichCacheLyrics.searchIncomplete。
        let newNoLyrics = (found?.resolved ?? false) && !newHasContent && !newInstrumental
            && !(found?.searchIncomplete ?? false)
        if newNoLyrics != currentTrackHasNoLyrics { currentTrackHasNoLyrics = newNoLyrics }
        // 纯文本兜底只在"确实没有能同步显示的版本"时才有展示意义——newHasContent 为 true
        // 时(不管是不是这首歌待会儿又补出了带时间戳的版本)优先用那份,不显示纯文本,
        // 避免"歌词窗口"同时收到两份内容不一定完全一致的候选、不知道信哪个。
        let newPlainLyrics = newHasContent ? "" : (found?.plainLyrics ?? "")
        if newPlainLyrics != currentTrackPlainLyrics { currentTrackPlainLyrics = newPlainLyrics }
        // "歌词窗口"的全部行只在换歌词内容这一刻重新构造一次——同一首歌播放期间歌词
        // 本身不变,不需要每 20Hz tick 都重算。idPrefix 用 currentOffsetKey(已经是
        // 按当前曲目算出来的标识),保证换歌后这里产出的每个 LyricsWindowLine.id 整体
        // 跟上一首歌不同,SwiftUI 的 ForEach 才会做一次干净的整体替换而不是逐行"变形"
        // (见 LyricsWindowLine 类型定义处的注释)。
        let newAllLines = syncEngine.allLines(idPrefix: currentOffsetKey)
        if newAllLines != allLines { allLines = newAllLines }
        // 间奏点跟 allLines 同一时机重算 —— 纯由时间轴决定,同一首歌播放期间不变。
        let newMarkers = syncEngine.gapMarkers()
        if newMarkers != lyricsGapMarkers { lyricsGapMarkers = newMarkers }
        logger.debug("lyrics reloaded: hasContent=\(self.syncEngine.hasContent) found=\(found != nil)")
    }

    // 换歌那一刻异步取一次封面图(子进程调用,挪到后台线程,理由跟 poll() 一样)。等
    // 结果回来时如果又换了下一首歌(expectedKey 跟这时的 lastKey 对不上),说明这份图
    // 已经过时,直接丢弃——不会把上一首歌的封面错挂到新歌上。拿不到(没有 media-control
    // 二进制/bundle id 对不上/这首歌本来就没有封面数据)时置 nil,不保留上一首歌的封面
    // 硬挂着——跟 title/artist/album 故意保留"最近一次播放信息"是两回事:那三个字段是
    // 文字,显示旧值不会误导人;封面是背景图,挂着上一首歌的图会让人以为"这就是当前
    // 这首歌的封面",必须清空。
    // 换歌后"旧封面最多还能挂多久"的兜底期限。取 3 秒:封面取图正常在几百毫秒内回来(见
    // fetchArtwork 的子进程往返),3 秒还没回来只可能是子进程卡死或那个二进制出了问题,
    // 此时挂着上一首的封面已经不合理了,宁可回落到系统背景。
    private static let artworkStaleTimeout: TimeInterval = 3
    private var artworkStaleTimeoutTask: Task<Void, Never>?

    /// 换歌时安排一次"旧封面过期清理"。只在真的有旧封面可挂时才安排——本来就没有封面的
    /// 情况下什么都不用做。取图回调先到就会把这个任务取消掉(见 fetchArtworkForCurrentTrack)。
    private func scheduleArtworkStaleTimeout(forKey key: String) {
        artworkStaleTimeoutTask?.cancel()
        artworkStaleTimeoutTask = nil
        guard artworkData != nil else { return }
        artworkStaleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.artworkStaleTimeout))
            guard !Task.isCancelled, let self, self.lastKey == key else { return }
            logger.debug("artwork stale timeout: clearing previous cover after \(Self.artworkStaleTimeout)s")
            self.artworkData = nil
            self.artworkAverageHex = nil
            self.artworkStaleTimeoutTask = nil
        }
    }

    // 换歌后若系统 Now Playing 封面尚未更新就绪，按递增间隔重试；
    // 每次重试前刷新超时任务，避免子进程往返耗时导致过早清空旧封面。
    private static let artworkRetryDelays: [TimeInterval] = [0.3, 0.6, 1.2]

    // 首轮定案后延迟 3 秒二次确认，防止系统侧元数据与封面更新不同步（如新标题残留旧封面），
    // 并在播放器中途升级封面（占位图换高清真图）时及时应用。
    private static let artworkConfirmDelay: TimeInterval = 3

    /// 封面载荷的曲目标识和当前曲目是否算同一首。大小写不敏感:media-control 对同一首歌
    /// 报过大小写不一致的元数据(enrich 缓存那边为 "2 Bad"/"Scream" 踩过,见相应 memory),
    /// 这里按大小写敏感比对的话,那类歌会被误判成"别的歌的封面"而永远显示占位。
    public nonisolated static func artworkKeyMatches(_ payloadKey: String, _ expectedKey: String) -> Bool {
        payloadKey.compare(expectedKey, options: [.caseInsensitive]) == .orderedSame
    }

    private func fetchArtworkForCurrentTrack(expectedKey: String) {
        Task {
            // 取图和算平均色在后台异步任务中完成，采纳后再计算均值色以避免无效重试的计算开销。
            func attempt() async -> (data: Data?, payloadKey: String?) {
                await Task.detached { () -> (Data?, String?) in
                    guard let result = MediaControlClient.fetchArtwork() else { return (nil, nil) }
                    return (result.data, result.trackKey)
                }.value
            }
            func hexFor(_ data: Data?) async -> String? {
                guard let data else { return nil }
                return await Task.detached { Self.computeAverageHex(from: data) }.value
            }
            // 验证封面有效性：已获取图片且 payload 标识与当前曲目匹配，防止挂上上一首残留封面。
            func isFinal(_ data: Data?, _ payloadKey: String?) -> Bool {
                guard data != nil, let payloadKey else { return false }
                return Self.artworkKeyMatches(payloadKey, expectedKey)
            }
            var (data, payloadKey) = await attempt()
            // 没定案就重试几次。每次重试前都重新核对 expectedKey
            var round = 0
            while !isFinal(data, payloadKey), round < Self.artworkRetryDelays.count {
                guard expectedKey == self.lastKey else { return }
                self.scheduleArtworkStaleTimeout(forKey: expectedKey)
                try? await Task.sleep(for: .seconds(Self.artworkRetryDelays[round]))
                guard expectedKey == self.lastKey else { return }
                (data, payloadKey) = await attempt()
                round += 1
            }
            guard expectedKey == self.lastKey else { return }
            if let payloadKey, data != nil, !Self.artworkKeyMatches(payloadKey, expectedKey) {
                logger.info("artwork payload key mismatch after retries: payload=\(payloadKey, privacy: .public) expected=\(expectedKey, privacy: .public), dropping")
                data = nil
            }
            // 结果定案后先取消超时清理任务，再异步计算平均色，避免竞态导致闪白。
            self.artworkStaleTimeoutTask?.cancel()
            self.artworkStaleTimeoutTask = nil
            // 定案才取色(后台),丢弃路径一次都不算。
            let averageHex = await hexFor(data)
            guard expectedKey == self.lastKey else { return }
            self.artworkData = data
            self.artworkAverageHex = averageHex
            self.noteRadioStationArtwork(data, forKey: expectedKey)
            logger.debug("artwork fetched: bytes=\(data?.count ?? 0) retries=\(round) average=\(averageHex ?? "nil")")

            // 二次确认,理由见 artworkConfirmDelay 的注释。
            try? await Task.sleep(for: .seconds(Self.artworkConfirmDelay))
            guard expectedKey == self.lastKey else { return }
            let confirm = await attempt()
            guard expectedKey == self.lastKey else { return }
            guard let confirmData = confirm.data, let confirmKey = confirm.payloadKey,
                  Self.artworkKeyMatches(confirmKey, expectedKey),
                  confirmData != self.artworkData else { return }
            // 先比完字节确认真的要换,才算这一份的均值色(原来 attempt 顺手预算,字节相同
            // 丢弃的常态路径每次白算一遍取色)。
            let confirmHex = await hexFor(confirmData)
            guard expectedKey == self.lastKey else { return }
            logger.debug("artwork confirm pass replaced cover: bytes=\(confirmData.count)")
            self.artworkData = confirmData
            self.artworkAverageHex = confirmHex
            self.noteRadioStationArtwork(confirmData, forKey: expectedKey)
        }
    }

    // 从封面原始图片数据算出一个单一的平均色,供"跟随封面"外观模式当动态高亮色用——
    // 算法跟同类开源实现一致:CIAreaAverage 把
    // 整张图平均成一个像素,而不是 K-means/直方图那类更贵的聚类算法,对"给悬浮歌词提供
    // 一个跟封面基调呼应的强调色"这个用途完全够用。
    //
    // ⚠️ 这里**只求均值,不做任何亮度调整**。2026-08-17 之前它顺手调了 brightenedAccent,
    // 结果是桌面悬浮歌词也吃到了那条为灵动岛(永远深底)定的"保证够亮"地板 —— 见
    // artworkAverageHex 和 accentAgainstStroke 的注释。提亮/压暗按消费面各自处理。
    //
    // nonisolated:纯函数,不读写这个类的任何 @MainActor 隔离状态,允许从
    // fetchArtworkForCurrentTrack() 里的后台 Task.detached 闭包(非 MainActor)直接调用,
    // 不需要为了调用它专门跳回主线程再跳出去。
    nonisolated private static func computeAverageHex(from data: Data) -> String? {
        guard let ciImage = CIImage(data: data) else { return nil }
        return computeAverageHex(ciImage: ciImage)
    }

    /// CGImage 入口——给已经解码好的图用(PlaybackCoordinator 的高清封面是下载回来的
    /// NSImage,拿不到原始字节,没必要为了走 Data 入口再编码一遍)。
    public nonisolated static func computeAverageHex(cgImage: CGImage) -> String? {
        computeAverageHex(ciImage: CIImage(cgImage: cgImage))
    }

    // CIContext 创建不便宜且线程安全,进程级复用一个。
    nonisolated(unsafe) private static let averageHexContext =
        CIContext(options: [.workingColorSpace: NSNull()])

    nonisolated private static func computeAverageHex(ciImage: CIImage) -> String? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }
        // 不指定 workingColorSpace ——只是要把一整张图迅速塌缩成一个像素
        // 的均值,不需要色彩管理带来的准确性,换来的是渲染更快。
        let context = averageHexContext
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return String(
            format: "#%02X%02X%02XFF", Int(bitmap[0]), Int(bitmap[1]), Int(bitmap[2]))
    }

    /// 把封面均值色调整成"能当文字色用"的亮度。纯函数,selftest 直接覆盖。
    ///
    /// ⚠️ 2026-08-17 起这条规则**只服务于永远深色的表面**(灵动岛)。它保证的是"够亮",
    /// 而桌面悬浮歌词压在壁纸/任意窗口上,"够亮"在浅色背景下正好是最坏的选择 ——
    /// 那一侧改走 accentAgainstStroke,见那里的注释。
    ///
    /// 2026-08-16 重写。原来是**在 RGB 空间按亮度整体乘一个 boost**,两个毛病:
    ///  ① 近黑封面(纯黑背景专辑)均值可能只有 (2,1,3)/255,boost 达到 11 倍,于是把
    ///    JPEG 噪点放大成一个饱和的随机色 —— 同一张黑封面每次取到的颜色都不一样;
    ///  ② 乘法保持 RGB 比例 = 保持饱和度,一个暗而浓的酒红被提到该亮度后依然浓,
    ///    贴在歌词上非常刺眼。
    ///
    /// 改成 HSB 空间处理(借鉴 boringNotch 的 ensureMinimumBrightness 思路):
    ///  - 近黑直接兜底成中性灰,不试图从噪点里"抢救"色相;
    ///  - 提亮多少,就按同一比例压低多少饱和度 —— 被提亮的颜色天然该更淡,这正是
    ///    人眼对"亮色"的预期,也避免了上面第 ② 条的刺眼。
    ///
    /// ⚠️ 手写 RGB↔HSB 而不是用 NSColor:LyrimuseCore 这一层刻意不引入 AppKit
    /// (见 Package.swift 的单向依赖注释)。
    nonisolated public static func brightenedAccent(
        r: Double, g: Double, b: Double, floor: Double = 0.62
    ) -> (r: Double, g: Double, b: Double) {
        // 近黑:三个通道都低到这个程度时,色相完全由压缩噪点决定,没有任何可信信息。
        // 给一个固定的中性灰,至少保证"同一张封面每次结果一样"。
        if r < 0.03, g < 0.03, b < 0.03 { return (0.72, 0.72, 0.72) }

        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let brightness = maxC
        let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
        guard brightness < floor else { return (r, g, b) }

        let ratio = brightness / floor  // < 1
        return hsbToRGB(
            hue: hueOf(r: r, g: g, b: b, maxC: maxC, minC: minC),
            saturation: saturation * ratio,
            brightness: floor)
    }

    /// 在 brightenedAccent 基础之上保证感知亮度(Rec.709 luma)下限，专供深色背景界面(灵动岛)。
    /// 采用朝白色线性混合以保持色相族并解析调整感知明度。
    nonisolated public static func accentForDarkBackdrop(
        r: Double, g: Double, b: Double, lumaFloor: Double = 0.62
    ) -> (r: Double, g: Double, b: Double) {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard luma < lumaFloor, luma < 1 else { return (r, g, b) }
        // luma(c + t*(1-c)) = luma(c) + t*(1-luma(c)),反解出恰好到地板的 t。
        let t = min(1, max(0, (lumaFloor - luma) / (1 - luma)))
        return (r + t * (1 - r), g + t * (1 - g), b + t * (1 - b))
    }

    /// `NotchCardStyle.coverArt` 背景黑色叠加层不透明度，用于背景亮度估算与渲染。
    nonisolated public static let notchCoverArtOverlayOpacity: Double = 0.45

    /// coverArt 卡片风格下为灵动岛文字保证对比度(minContrast 默认 4.5)。
    /// 根据原始封面色乘以叠加层透光率估算背景色，调用 accentAgainstStroke 保证可读性。
    ///
    /// - Parameters:
    ///   - r/g/b: `accentForDarkBackdrop` 处理过的候选文字色。
    ///   - rawR/rawG/rawB: 封面**原始**均值色(未经 brightenedAccent/accentForDarkBackdrop
    ///     提亮)——背景是拿这份原始色乘 `(1 - notchCoverArtOverlayOpacity)` 得出的,不能拿
    ///     已经被提亮过的文字色去算,那样估出来的背景会比实际渲染的亮得多。
    nonisolated public static func accentForCoverArtBackground(
        r: Double, g: Double, b: Double,
        rawR: Double, rawG: Double, rawB: Double,
        minContrast: Double = 4.5
    ) -> (r: Double, g: Double, b: Double) {
        let dim = 1 - notchCoverArtOverlayOpacity
        return accentAgainstStroke(
            r: r, g: g, b: b,
            strokeR: rawR * dim, strokeG: rawG * dim, strokeB: rawB * dim,
            minContrast: minContrast)
    }

    // MARK: - 桌面悬浮歌词的封面取色(跟描边拉开对比)

    /// 针对文字描边调整封面均值色，确保文字在描边包围下的可读性(WCAG 相对亮度对比度)。
    /// 1. 近黑像素转为同等亮度的中性灰，消除压缩噪点产生的杂色。
    /// 2. 对比度已满足阈值(默认 3.0)时保留原色。
    /// 3. 对比度不足时，沿离开描边亮度的方向二分混合至达标(描边亮则压暗，描边暗则提亮)。
    /// - Parameter minContrast: 目标对比度，默认 3.0(WCAG 大号文字门槛)。
    nonisolated public static func accentAgainstStroke(
        r: Double, g: Double, b: Double,
        strokeR: Double, strokeG: Double, strokeB: Double,
        minContrast: Double = 3.0
    ) -> (r: Double, g: Double, b: Double) {
        // ① 近黑去噪:保留亮度,只丢掉不可信的色相。
        var (r, g, b) = (r, g, b)
        if r < 0.03, g < 0.03, b < 0.03 {
            let mean = (r + g + b) / 3
            (r, g, b) = (mean, mean, mean)
        }

        let strokeLum = relativeLuminance(r: strokeR, g: strokeG, b: strokeB)
        let ownLum = relativeLuminance(r: r, g: g, b: b)

        // ② 够对比就别动。
        if contrastRatio(strokeLum, ownLum) >= minContrast { return (r, g, b) }

        // ③ 解析出两侧的目标相对亮度:比描边亮要到 upper,比描边暗要到 lower。
        //    (L+0.05)/(S+0.05) = minContrast → L = (S+0.05)*minContrast - 0.05
        let upper = (strokeLum + 0.05) * minContrast - 0.05
        let lower = (strokeLum + 0.05) / minContrast - 0.05

        // 优先往"自己本来就在的那一侧"走,动得最少;那一侧够不到(比如描边是纯白,
        // 再亮也不可能比它亮 3 倍)才换另一侧。两侧都够不到时取端点里更好的那个。
        let canGoUp = upper <= 1.0
        let canGoDown = lower >= 0.0
        let preferUp = ownLum >= strokeLum
        if preferUp, canGoUp {
            return blendToLuminance(r: r, g: g, b: b, target: upper, towardWhite: true)
        }
        if !preferUp, canGoDown {
            return blendToLuminance(r: r, g: g, b: b, target: lower, towardWhite: false)
        }

        // 优先方向差一点点够不到边界时(如浅色封面上纯白对比度接近达标):
        // 贴边界已接近目标(>=80% 且 >=3.0)时优先使用贴边界端点，避免极值翻转产生突兀黑字。
        let closeEnoughFloor = 3.0
        let closeEnoughRatio = 0.80
        if preferUp, !canGoUp {
            let clamped = contrastRatio(strokeLum, 1)
            if clamped >= closeEnoughFloor, clamped >= minContrast * closeEnoughRatio {
                return blendToLuminance(r: r, g: g, b: b, target: 1.0, towardWhite: true)
            }
        }
        if !preferUp, !canGoDown {
            let clamped = contrastRatio(strokeLum, 0)
            if clamped >= closeEnoughFloor, clamped >= minContrast * closeEnoughRatio {
                return blendToLuminance(r: r, g: g, b: b, target: 0.0, towardWhite: false)
            }
        }

        if canGoUp {
            return blendToLuminance(r: r, g: g, b: b, target: upper, towardWhite: true)
        }
        if canGoDown {
            return blendToLuminance(r: r, g: g, b: b, target: lower, towardWhite: false)
        }
        // 两侧都够不到 —— 取黑/白里对比更好的那个端点,别返回一个"差一点点"的中间值。
        //
        // ⚠️ 默认的 minContrast = 3.0 走不到这里:两侧都够不到要同时满足
        // strokeLum < 0.05(mc−1) 和 strokeLum > 1.05/mc − 0.05,有解的条件是
        // mc > √21 ≈ 4.58。这条分支是给传更严目标的调用方留的,不是死代码,
        // selftest 里用 7.0 显式覆盖它。
        return contrastRatio(strokeLum, 0) >= contrastRatio(strokeLum, 1)
            ? (0, 0, 0) : (1, 1, 1)
    }

    /// WCAG 相对亮度:先把 sRGB 分量线性化,再按 Rec.709 加权。
    nonisolated public static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            let c = min(1, max(0, c))
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG 对比度,恒 ≥ 1。参数顺序无关。
    nonisolated public static func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        let hi = max(l1, l2), lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// 沿"朝白"或"朝黑"的方向混合，直到相对亮度达到 target。二分求混合比例。
    ///
    /// 朝白 = 线性插值到 (1,1,1)(提亮同时天然降饱和);朝黑 = RGB 整体乘系数
    /// (等价于线性插值到 (0,0,0),保色相保饱和)。两者沿方向都是单调的,二分成立。
    nonisolated private static func blendToLuminance(
        r: Double, g: Double, b: Double, target: Double, towardWhite: Bool
    ) -> (r: Double, g: Double, b: Double) {
        func at(_ t: Double) -> (Double, Double, Double) {
            towardWhite
                ? (r + t * (1 - r), g + t * (1 - g), b + t * (1 - b))
                : (r * (1 - t), g * (1 - t), b * (1 - t))
        }
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 24 {
            let mid = (lo + hi) / 2
            let c = at(mid)
            let lum = relativeLuminance(r: c.0, g: c.1, b: c.2)
            // 朝白亮度递增、朝黑亮度递减 —— 两种方向下"还没到 target"的判据正好相反。
            if towardWhite ? (lum < target) : (lum > target) { lo = mid } else { hi = mid }
        }
        let c = at(hi)
        return (c.0, c.1, c.2)
    }

    /// 色相(0~1)。maxC==minC(灰)时色相无意义,返回 0。
    nonisolated private static func hueOf(
        r: Double, g: Double, b: Double, maxC: Double, minC: Double
    ) -> Double {
        let delta = maxC - minC
        guard delta > 0 else { return 0 }
        let h: Double
        switch maxC {
        case r: h = (g - b) / delta + (g < b ? 6 : 0)
        case g: h = (b - r) / delta + 2
        default: h = (r - g) / delta + 4
        }
        return h / 6
    }

    nonisolated private static func hsbToRGB(
        hue: Double, saturation: Double, brightness: Double
    ) -> (r: Double, g: Double, b: Double) {
        guard saturation > 0 else { return (brightness, brightness, brightness) }
        let sector = (hue - hue.rounded(.down)) * 6
        let i = Int(sector)
        let f = sector - Double(i)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch i % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}
