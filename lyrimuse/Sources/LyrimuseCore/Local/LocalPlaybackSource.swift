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
    /// YouTube Music 网页广告插播序号及总数(例如 1/2)。
    /// 仅由 YouTubeMusicAdProbe 解析页面广告徽章获取；不支持或未获取时为 nil。
    /// 与 `isCurrentTrackAdBreak` 状态绑定，广告结束时清空。
    @Published public private(set) var currentAdSlot: YouTubeMusicAdProbe.AdSlot? = nil
    /// 当前曲目实际生效的总偏移（毫秒）= 全局基准 + 本曲微调，直接同步 syncEngine.offsetMs 权威值。
    @Published public private(set) var currentLyricsOffsetMs: Int = 0
    /// 总偏移中仅属于当前曲目的微调值（不含全局基准），供重置按钮与菜单指示使用。
    @Published public private(set) var trackLyricsOffsetMs: Int = 0
    /// 歌词窗口背景用的模糊封面原始图片数据 (JPEG/PNG)。
    /// 由 LyrimuseCore 在曲目切换时异步拉取一次，交付 AppKit/SwiftUI 视图层按需解码。
    @Published public private(set) var artworkData: Data?
    /// 从封面图片计算的未经调整的原始均值色（十六进制 #RRGGBBAA）。
    /// 由 PlaybackCoordinator 根据具体展示表面（灵动岛深底或桌面悬浮歌词）决定提亮或压暗处理。
    @Published public private(set) var artworkAverageHex: String?
    /// Spotify 原生客户端在图床上的封面地址(AppleScript `artwork url` 640 档)，
    /// 由 `SpotifyPositionProbe` 在开播后拉取验证。Spotify 网页版由 BrowserPositionProbe 获取；
    /// 供 `PlaybackCoordinator.refreshSpotifyOriginalCover` 执行高清封面替换。
    @Published public private(set) var spotifyArtworkURL: URL?
    /// 暂停时的播放位置（毫秒）。暂停态 media-control / AppleScript 的 elapsedTime 为精确冻结位置，
    /// 供进度条在暂停时展示固定进度而不是依赖外推。播放中恒为 nil。
    @Published public private(set) var pausedPositionMs: Int?
    /// 当前曲目时长（毫秒）。暂停时 anchor 为 nil，需单独发布供冻结进度条计算比例。
    @Published public private(set) var currentDurationMs: Int?
    /// 电台专用:当前这首歌已经越过真曲长(= 进了口白那一段)。收歌词看它,见 fastTick()。
    private var radioTrackFinished = false
    /// 电台口白插播状态。展示面在口白期间展示台卡与口白占位符。
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

    /// 引擎始终保留逐字数据，各展示表面通过独立配置决定是否按行级压平（见 AppSettings.overlayLyricsKaraoke）。
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

    // ---- 播放位置平滑与伺服校正 --------------------
    //
    // 部分播放器缺少 AppleScript 支持，其 elapsedTime 依赖系统外推读数，单次采样存在抖动。
    // 仅在发生真实不连续事件（换歌、暂停/恢复、或读数超出外推预测容差）时重新锚定；
    // 稳定播放期间按墙钟经过时间递增外推，避免逐次读数抖动造成歌词高亮跳变。
    private var trackPosSeconds: Double = 0
    private var posTrackingKey = ""
    private var posWasPlaying = false
    private var posPrevWall: Date?
    // 上一轮的报告值 —— 冻结检测(isFrozenReport)用它计算报告值前进量。
    // 每次 resolvePositionSeconds 退出时统一更新(defer)，换歌/暂停恢复路径由当轮读数直接覆盖。
    private var posPrevReported: Double?
    // 读数与外推值偏差的指数滑动平均 (EMA)。播种、跳变或校正后重置为 0。
    private var posErrEMA: Double = 0
    private static let seekJumpToleranceSecs = 2.0

    /// 地板量化源的前向棘轮阈值。
    /// 部分播放器（如 QQ 音乐）上报给 MediaRemote 的位置为整秒向下取整，
    /// 取整意味着报告值理论上始终落后或等于真实播放进度。
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

    /// bundleID → 数据源画像。纯函数，selftest 直接覆盖。
    public nonisolated static func positionSourceTier(forBundleID bundleID: String?) -> PositionSourceTier {
        if bundleID == PlaybackPlayer.appleMusic.bundleIdentifier { return .precise }
        // 默认采用 cleanExtrapolated：大门槛与前向棘轮仅适用于明确整秒量化的源（如 QQ 音乐、网易云）。
        // 其他 media-control 数据源具备连续外推特性，若默认使用 noisyFloored 会导致 1.0s 以内的固定偏差无法收敛。
        // 未提供 bundleID 时同样走保守的连续外推策略，避免误加前向棘轮。
        if bundleID == PlaybackPlayer.qqMusic.bundleIdentifier
            || bundleID == PlaybackPlayer.netease.bundleIdentifier {
            return .noisyFloored
        }
        return .cleanExtrapolated
    }

    /// 见 flooredForwardSnapEpsilonSecs。纯函数，selftest 直接覆盖。
    ///
    /// 浏览器探针一次性地面真值的重锚门槛。
    /// 探针消除地板量化后残差在均匀分布范围内，门槛设为 0.30s 既可吸收小幅跳变，
    /// 又能捕获系统性偏差并触发重锚。
    public static let groundTruthSnapToleranceSecs: Double = 0.30

    /// 只对地板量化源(noisyFloored)生效：前向棘轮依赖 reported <= 真实位置 的不等式前提。
    /// 对于连续外推源，应用棘轮会导致位置被锁定在抖动上包络。
    public nonisolated static func shouldRatchetForward(
        reported: Double, predicted: Double, tier: PositionSourceTier
    ) -> Bool {
        tier == .noisyFloored && reported - predicted > flooredForwardSnapEpsilonSecs
    }

    // 播放位置偏差 EMA 伺服：
    // 持续同号的系统性偏差会驱动 EMA 收敛到偏差值本身，超过阈值时一次性校正（snap）并重锚；
    // 零均值的高频读数噪声在 EMA 累加中相互抵消，维持抗抖动平滑效果。
    //
    // 三档画像参数配置：
    // - precise (Apple Music): alpha 0.5, threshold 0.15s。
    // - cleanExtrapolated (Spotify / 酷狗): alpha 0.3, threshold 0.4s。
    // - noisyFloored (QQ 音乐 / 网易云): alpha 0.3, threshold 1.0s。
    public nonisolated static func servoDecision(errEMA: Double, error: Double, tier: PositionSourceTier) -> (newEMA: Double, snap: Bool) {
        let alpha: Double, threshold: Double
        switch tier {
        case .precise: (alpha, threshold) = (0.5, 0.15)
        case .cleanExtrapolated: (alpha, threshold) = (0.3, 0.4)
        case .noisyFloored: (alpha, threshold) = (0.3, 1.0)
        }
        // cleanExtrapolated 单样本限幅：限制首拍突发异常的最大影响（限幅在 ±0.75 内），
        // 避免单次异常偏差立即越过门槛引起歌词回弹。
        let clamped = tier == .cleanExtrapolated ? max(-0.75, min(0.75, error)) : error
        let newEMA = errEMA * (1 - alpha) + clamped * alpha
        return (newEMA, abs(newEMA) > threshold)
    }

    /// 冻结检测：当播放器在曲目/广告末尾暂停更新 MediaRemote 锚点时，
    /// 墙钟虽然走过时间 gap 但报告进度几乎停滞，判定该读数已冻结并维持墙钟外推。
    /// 仅对 cleanExtrapolated 生效；纯函数，selftest 直接覆盖。
    public nonisolated static func isFrozenReport(
        reportedAdvance: Double, gap: Double, rate: Double, tier: PositionSourceTier
    ) -> Bool {
        tier == .cleanExtrapolated && gap >= 0.75
            && abs(reportedAdvance) < max(0.1, 0.15 * gap * rate)
    }

    // ---- Spotify 自然切歌(gapless)锚点超前校正 --------------------------
    //
    // 在无缝切歌时，播放器可能提前数拍发布新曲元数据与起始锚点(elapsedTime=0)，
    // 导致新曲播放头恒定超前真实音频输出。由于稳态下读数与外推步调一致，
    // 偏差 EMA 无法通过差分发现此类恒定系统偏置。
    // 因此在换曲观察点，以旧曲连续外推跨过其曲长的溢出量(overrun)作为新曲真值，
    // 计算出新曲锚点超前偏置并从后续每拍读数中扣除。
    /// 换歌观察点允许的最大连续外推差距；超出则视为手动切歌或外推基准失效，不执行校正。
    public nonisolated static let naturalAdvanceWindowSecs = 4.0
    /// 锚点超前量的可信区间。下限过滤测量噪声，上限排除陈旧残留读数。
    public nonisolated static let naturalAdvanceMaxBiasSecs = 2.5
    public nonisolated static let naturalAdvanceMinBiasSecs = 0.05

    /// 自然切歌锚点偏置估计。纯函数，selftest 直接覆盖。
    /// - reported: 新曲首拍原始读数(elapsedTimeNow，未扣除偏置)
    /// - overrun: 观察到换歌时旧曲外推位置 - 旧曲曲长（负值表示旧曲音频尚未播放完毕）
    /// - 返回 (seed, bias): seed 为新曲播种位置，bias 为后续读数需扣除的超前量；nil 表示超出窗口或不可信。
    public nonisolated static func naturalAdvanceCorrection(
        reported: Double, overrun: Double
    ) -> (seed: Double, bias: Double)? {
        guard abs(overrun) <= naturalAdvanceWindowSecs else { return nil }
        let bias = reported - overrun
        guard bias > naturalAdvanceMinBiasSecs, bias <= naturalAdvanceMaxBiasSecs else { return nil }
        return (overrun, bias)
    }

    /// 当前曲目 MediaRemote 锚点相对音频的偏差(秒)——resolvePositionSeconds 对每笔原始读数先扣掉它。
    /// 仅对 cleanExtrapolated 非零；正值表示锚点超前真声，负值表示锚点落后真声。
    private var posReportedBiasSecs: Double = 0
    /// 这份偏置是对着哪个锚点量的(那一刻快照的原始 anchorElapsedTime)。偏置只对这个锚点成立,
    /// 锚点一换就作废,见 biasSurvivesAnchor。偏置为 0 时恒为 nil。
    private var posBiasAnchorElapsed: Double?

    private func setReportedBias(_ bias: Double, anchorElapsed: Double?, fromProbe: Bool = false) {
        posReportedBiasSecs = bias
        posBiasAnchorElapsed = bias == 0 ? nil : anchorElapsed
        posBiasFromProbe = bias != 0 && fromProbe
        }
    /// 当前偏置是否由探针测得；仅探针偏置参与输出路由领先量学习。
    private var posBiasFromProbe = false

    // ---- Spotify 探针钟领先量（按默认音频输出设备分别记录）----
    // AppleScript `player position` 领先于蓝牙/系统音频链路的实际输出，需扣除输出延迟。
    // 每次暂停时通过对比外推位置与 Spotify 冻结锚点在线学习残差，按音频输出设备 UID 持久化；
    // 切换输出设备时自动切换校准值，并按传输类型提供合理先验（蓝牙 0.5s、内建 0.1s）。
    private static let probeLeadByDeviceDefaultsKey = "np:spotifyProbeLeadByDevice"
    private static let legacyProbeLeadDefaultsKey = "np:spotifyProbeLeadSecs"
    private nonisolated static let probeLeadLearnAlpha = 0.5
    private nonisolated static let probeLeadMaxResidualSecs = 1.5

    /// 默认音频传输类型的先验延迟。纯函数，selftest 直接覆盖。
    public nonisolated static func probeLeadPrior(for transport: AudioOutputRoute.Transport) -> Double {
        switch transport {
        case .bluetooth: return 0.5
        case .builtIn: return 0.1
        case .airPlay, .display, .usb, .other: return 0
        }
    }

    /// 暂停时在线学习设备音频延迟残差并更新领先量。纯函数，selftest 直接覆盖。
    public nonisolated static func learnedProbeLead(current: Double, residual: Double, hasPrior: Bool) -> Double {
        guard abs(residual) <= probeLeadMaxResidualSecs else { return current }
        guard hasPrior else { return current + residual }
        return current + residual * probeLeadLearnAlpha
    }

    /// 按设备 UID 学到的领先量表。从 UserDefaults 读取并兼容迁移旧格式单值键。
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

    /// 默认输出设备发生变化：更新当前输出设备领先量，若正在播放 Spotify 且依赖探针偏置，
    /// 则重新请求确认以使用新领先量校准。
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

    /// 将当前偏置同步至 collector（供外部外推进程消费）。
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

    /// 判定偏置是否仍适用于当前锚点。纯函数，selftest 直接覆盖。
    /// 偏置仅属于测量时对应的特定锚点；若播放器重新发布了对齐音频的新锚点（如暂停冻结或拖动后），
    /// 则旧偏置失效。
    public nonisolated static func biasSurvivesAnchor(anchorElapsedTime: Double?, measuredAgainst: Double? = nil) -> Bool {
        guard let anchorElapsedTime else { return true }
        guard let measuredAgainst else { return anchorElapsedTime <= 0.001 }
        return abs(anchorElapsedTime - measuredAgainst) <= 0.001
    }

    /// 播放时钟的只读快照，供诊断信息导出使用。
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
    /// 上一轮快照是否来自 cleanExtrapolated 源，确保自然切歌跨曲校正基准一致。
    private var posPrevTierCleanExtrapolated = false
    /// 暂停期间上一轮的原始冻结读数。检测暂停期间用户手动拖动进度条使旧偏置失效。
    private var posPausedRawSecs: Double?

    /// 换曲时判定当前曲目是否为广告插播。纯函数，selftest 直接覆盖。
    /// - YouTube Music: 页面广告徽章判定为广告时生效。
    /// - Spotify Web: 仅采信页面广告探针明确结论。
    /// - Spotify 原生: 基于元数据启发式与 AppleScript 异步复核。
    /// - 其他播放器: 默认非广告。
    public static func adBreakByFields(
        isSpotifyNative: Bool, title: String, artist: String, album: String,
        youTubeMusicVerdict: YouTubeMusicAdProbe.Verdict?, spotifyWebVerdict: SpotifyWebAdProbe.Verdict?
    ) -> Bool {
        if YouTubeMusicAdProbe.showsAdBadge(verdict: youTubeMusicVerdict) { return true }
        if spotifyWebVerdict == .ad { return true }
        return isSpotifyNative && !title.isEmpty && (album.isEmpty || artist.isEmpty || title == "—")
    }

    /// Determines the next state for the track ad break indicator:
    /// - On track change, initialize from immediate field/page verdict (`adByFields`).
    /// - During the same track, ratchets to `true` if fields/page indicate an ad (Spotify ad metadata can fluctuate).
    /// - Falls back to `false` if page explicitly reports `.song` (handles YouTube Music video playback where
    ///   pre-roll ads share MediaSession metadata with the music video, transitioning from ad to song under the same key).
    /// - Otherwise preserves previous state (nil page verdict preserves existing status without overwriting).
    /// Spotify AppleScript verification asynchronously sets `isCurrentTrackAdBreak = true` independently.
    public static func nextAdBreakState(
        previous: Bool, isNewTrack: Bool, adByFields: Bool, pageVerdict: YouTubeMusicAdProbe.Verdict?
    ) -> Bool {
        if isNewTrack { return adByFields }
        if adByFields { return true }
        if pageVerdict == .song { return false }
        return previous
    }

    /// Evaluates ad status on track change for native Spotify playback:
    /// Checks distributed notification hint (`SpotifyNotificationHint`), matching title/artist against current snapshot.
    /// If positive, sets ad break state immediately without spawning an AppleScript subprocess.
    /// If hint is absent or mismatched, falls back to AppleScript verification (`verifySpotifyAdViaAppleScript`).
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

    /// Authoritative ad check for native Spotify: AppleScript query for `spotify url of current track` returns "spotify:ad:...".
    /// Executes asynchronously on track change; on completion, verifies track key matches to avoid applying stale status.
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

    /// 核心位置解析函数。仅在播放中被调用。
    /// - isGroundTruthSeed: 该读数是否来自外部探针权威真值（如浏览器 DOM 或 Spotify 探针）；
    /// - anchorElapsedTime: 快照原始锚点 elapsedTime；
    /// - streamRaw: 探针该拍系统流原始读数。
    private func resolvePositionSeconds(reported rawReported: Double, rate: Double, key: String, now: Date, tier: PositionSourceTier, isGroundTruthSeed: Bool = false, anchorElapsedTime: Double? = nil, streamRaw: Double? = nil) -> (seconds: Double, didReanchor: Bool) {
        if tier != .cleanExtrapolated, posReportedBiasSecs != 0 {
            // 同 key 跨播放器切换时，旧播放器的锚点偏置作废并重置为 0。
            setReportedBias(0, anchorElapsed: nil)
        }
        let reported = rawReported - posReportedBiasSecs
        // 冻结检测计算上一轮报告差值。探针样本不计入，避免产生假倒退影响冻结守卫。
        let reportedAdvance = rawReported - (posPrevReported ?? rawReported)
        defer { if !isGroundTruthSeed { posPrevReported = rawReported } }
        // 用户主动 seek 后的一小段时间内，播放器可能尚未跟进新进度，
        // 若报告值更接近 seek 前的旧位置，则丢弃陈旧读数并保持外推。
        // 仅在曲内生效，换曲边界不丢弃首拍。
        if key == posTrackingKey,
           let target = lastSeekTargetSecs, let prev = lastSeekPrevSecs, let at = lastSeekAt,
           Self.shouldRejectStalePositionAfterSeek(
               reported: reported, target: target, previous: prev, elapsedSinceSeek: now.timeIntervalSince(at)
           ) {
            return (trackPosSeconds, false)
        }
        guard key == posTrackingKey, posWasPlaying, let prevWall = posPrevWall else {
            if key != posTrackingKey {
                // 换歌：针对 gapless 自然切歌，若旧曲外推已接近曲尾，则基于连续性播种并估算新曲锚点超前偏置；
                // 否则（手动点播或非连续源）直接采纳首拍读数并清零偏置。
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
        // 探针权威真值重锚：
        // 探针作为单曲单次获取的地面真值，若偏差超出容差门槛直接触发重锚，
        // 不经过 EMA 慢速收敛。采纳后稳态精度交还连续外推。
        // 针对 cleanExtrapolated 源，将差值记录进锚点偏置，避免后续流读数将进度拉回。
        if isGroundTruthSeed {
            let delta = reported - predicted
            guard abs(delta) > Self.groundTruthSnapToleranceSecs else {
                if tier == .cleanExtrapolated {
                    trackPosSeconds = predicted
                    return (trackPosSeconds, false)
                }
                return resolveSteadyState(reported: reported, predicted: predicted, key: key, tier: tier)
            }
            if tier == .cleanExtrapolated, let streamRaw {
                // 偏置 = 本轮系统流读数 - 探针真值，表示系统流相对真实播放进度的偏移。
                setReportedBias(streamRaw - reported, anchorElapsed: anchorElapsedTime, fromProbe: true)
            }
            logger.notice("browser probe reanchor: reported=\(reported, format: .fixed(precision: 3)) predicted=\(predicted, format: .fixed(precision: 3)) delta=\(delta, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3))")
            trackPosSeconds = reported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        // 冻结守卫：必须在 seek 判断之前执行。
        // 当播放器在尾部冻结锚点时，读数滞后会逐渐增大；若放到 seek 之后会被误判为跳变导致进度回退。
        if Self.isFrozenReport(reportedAdvance: reportedAdvance, gap: gap, rate: rate, tier: tier) {
            trackPosSeconds = predicted
            return (trackPosSeconds, false)
        }
        // 单曲循环 (repeat-one) gapless 回绕处理：
        // 曲目标识不变但外推已越过时长且读数回到曲首，按自然切歌相同机制校正新一轮播种。
        if tier == .cleanExtrapolated, posPrevDurationSecs > 0,
           let corr = Self.naturalAdvanceCorrection(reported: rawReported, overrun: predicted - posPrevDurationSecs) {
            logger.notice("repeat-one wrap: seed \(corr.seed, format: .fixed(precision: 3))s, anchor leads audio by \(corr.bias, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
            setReportedBias(corr.bias, anchorElapsed: anchorElapsedTime)
            trackPosSeconds = corr.seed
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        if abs(reported - predicted) > Self.seekJumpToleranceSecs {
            // 真实 seek 跳变：重锚至新读数，并清除旧的自然切歌偏置。
            setReportedBias(0, anchorElapsed: nil)
            trackPosSeconds = rawReported
            posErrEMA = 0
            // 原生客户端在 seek 后向探针请求确认，核实新锚点真实性。
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

    /// Music.app playerInfo distributed notification observer (see `startObservingPlayerInfoNotification()`).
    private var playerInfoObserver: NSObjectProtocol?
    private var spotifyInfoObserver: NSObjectProtocol?
    /// Spotify Track ID / title / artist hints from PlaybackStateChanged notifications used for ad classification.
    private var spotifyNotificationHint: SpotifyNotificationHint?
    /// media-control event stream watcher for players without distributed notifications.
    private var streamWatcher: MediaControlStreamWatcher?
    /// Debounced poll task scheduled after player notifications (cancelled and rescheduled on rapid events).
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

    // Music.app / Spotify 分布式通知中心订阅。
    //
    // 通知仅作为提前触发 poll() 的事件信号，不直接使用 notification.userInfo 驱动状态机更新，
    // 确保所有状态变更均收敛在 apply() 统一路径，受世代号防乱序保护。
    // 针对 Spotify 通知，解析 Track ID 前缀用于广告分类。
    private func startObservingPlayerInfoNotification() {
        startStreamWatcher()
        // Spotify 位置探针顺带带回的图床地址落到 spotifyArtworkURL(核对同一曲目后采纳)。
        SpotifyPositionProbe.shared.setArtworkSink { [weak self] key, url in
            Task { @MainActor [weak self] in self?.noteSpotifyArtwork(url: url, forKey: key) }
        }
        // Spotify 网页版位置探针获取的图床封面地址同样交付该通道。
        BrowserPositionProbe.shared.setArtworkSink { [weak self] key, url in
            Task { @MainActor [weak self] in self?.noteSpotifyArtwork(url: url, forKey: key) }
        }
        // 探针结果就绪后立即补查一次播放状态，无需等待下一个固定轮询周期。
        SpotifyPositionProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // 广告检测探针结果就绪后立即补查，消除边界感知延迟。
        YouTubeMusicAdProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        SpotifyWebAdProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // 默认输出设备切换时同步更新领先量校准值。
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
        spotifyInfoObserver = center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main) { [weak self] note in
                let hint = SpotifyNotificationHint(userInfo: note.userInfo)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let hint, self.spotifyNotificationHint != hint { self.spotifyNotificationHint = hint }
                    self.handlePlayerInfoChanged()
                }
            }
    }

    // media-control 事件流与系统分布式通知共享去抖动补查路径。
    private func startStreamWatcher() {
        guard streamWatcher == nil else { return }
        let watcher = MediaControlStreamWatcher { [weak self] in
            MainActor.assumeIsolated { self?.handlePlayerInfoChanged() }
        }
        streamWatcher = watcher
        watcher.start()
    }

    // 通知到达去抖动补查：
    // 用户操作（如暂停/切歌）常伴随连续通知触发，且首拍通知或播放器底层状态未完全稳定。
    // 采用 250ms 去抖动等待状态稳定后再执行 poll()，避免读取到过渡态快照。
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

    /// 收到播放状态变更通知后，在查询到确定新状态前将位置外推冻结（rate=0）。
    /// 防止在等待去抖查询完成期间外推继续前进，导致随后切到暂停冻结位置时发生可见的向后回跳。
    private func freezeExtrapolationUntilNextPoll() {
        guard let current = anchor, current.rate > 0 else { return }
        let now = Date()
        anchor = ProgressAnchor(
            durationMs: current.durationMs,
            progressMs: current.extrapolatedPositionMs(now: now),
            rate: 0,
            progressTs: nil,
            baseAgeMs: nil,
            fetchedAt: now,
            fresh: current.fresh)
    }

    /// 轮询间隔分档：播放中 2s，暂停 6s，空闲 10s。
    /// 结合系统事件通知与媒体流事件实现亚秒级状态响应，降低无音频播放时的后台开销。
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

    /// Cleans up playback and track metadata when playback ceases entirely (nil snapshot or non-targeted player).
    ///
    /// Distinct from the paused state (where snapshots continue reporting track info with `playing = false`),
    /// stopped playback must fully clear track metadata, lines, artwork, and color palettes so all UI surfaces
    /// transition synchronously into an idle state rather than leaving stale text or placeholders.
    ///
    /// Invalidating `lastReloadSnapshot` and resetting `lastKey` ensures that if playback resumes on the same track,
    /// `reloadCurrentLyrics` and artwork fetching are not skipped by content equivalence gates.
    /// Position smoothing and gapless tracking states are also reset to prevent false bias detection.
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
            if !title.isEmpty { title = "" }
            if !artist.isEmpty { artist = "" }
            if !album.isEmpty { album = "" }
            if hasLyricsContent { hasLyricsContent = false }
            if isCurrentTrackInstrumental { isCurrentTrackInstrumental = false }
            if currentTrackHasNoLyrics { currentTrackHasNoLyrics = false }
            if isCurrentTrackAdBreak { isCurrentTrackAdBreak = false }
            // Invalidate reload snapshot and lastKey so resuming the same track reloads lyrics and artwork.
            lastReloadSnapshot = nil
            lastKey = ""
            // Disconnect position tracking state to prevent false gapless bias detection on subsequent tracks.
            posWasPlaying = false
            posPrevWall = nil
            posPrevDurationSecs = 0
            setReportedBias(0, anchorElapsed: nil)
            stopFastTimer()
        }
    }

    /// Monotonic generation counter protecting against out-of-order completion across asynchronous `poll()` tasks.
    ///
    /// Background subshell queries can vary in execution time; if an older task finishes after a newer one,
    /// its snapshot must not overwrite newer state in `apply()` / `clearIfWasPlaying()`.
    /// When asynchronous results return, they are discarded if `generation != pollGeneration`.
    private var pollGeneration = 0

    /// Streak counter for consecutive nil snapshots, used to rate-limit diagnostic logging.
    /// Logs on initial failure transition and periodically every ~5 minutes during extended idle periods.
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
                // A nil snapshot indicates either no active player, Music.app stopped (rather than paused),
                // or missing automation permission. Clear playback state and reset cadence.
                self.consecutiveNilSnapshots += 1
                if self.consecutiveNilSnapshots == 1 || self.consecutiveNilSnapshots % 30 == 0 {
                    let streakSuffix = self.consecutiveNilSnapshots > 1
                        ? " streak=\(self.consecutiveNilSnapshots)" : ""
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
        // Radio duration normalization:
        // The system-reported duration for radio streams covers the entire multi-hour program, whereas
        // playback position is normalized to the track scale via `RadioTrackClock`.
        // If cached track duration exists in EnrichCacheReader, override snapshot duration with the track duration.
        // If not yet cached, retain snapshot duration (> 0) to allow progress clamping without pinning position to 0.
        var snapshot = rawSnapshot
        if rawSnapshot.isRadio == true,
           let cached = EnrichCacheReader.trackDurationSecs(
               artist: rawSnapshot.artist ?? "", title: rawSnapshot.title ?? "", album: rawSnapshot.album ?? ""),
           cached > 0, cached != rawSnapshot.duration {
            snapshot = rawSnapshot.withDuration(cached)
        }
        // Radio station card:
        // On initial station start, the system emits an intro payload with empty artist and title set to the station name.
        // Captures station identity and branding (see RadioStationCardFile).
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
        // Track completion detection for radio streams:
        // Uses un-clamped elapsed position to detect if the track has finished (RadioTrackClock.passedTrackEnd).
        // Station card periods and talk breaks are marked as non-song breaks, suppressing lyrics search and
        // displaying station branding.
        let finished = stationCardName != nil || RadioTrackClock.passedTrackEnd(
            position: snapshot.isRadio == true ? (snapshot.elapsedTime ?? 0) : 0,
            durationSecs: snapshot.isRadio == true ? snapshot.duration : nil)
        // Current radio station tracking for per-station lyrics offsets (LyricsOffsetStore.radioOffsets).
        if currentStationHash != stationHash { currentStationHash = stationHash }
        let station = RadioStationCardFile.card(radioStationCard, forStation: stationHash)
        if station?.name != radioStationName { radioStationName = station?.name }
        if station?.artwork != radioStationArtwork { radioStationArtwork = station?.artwork }
        if finished != isRadioTalkBreak { isRadioTalkBreak = finished }
        if finished != radioTrackFinished {
            radioTrackFinished = finished
            logger.notice("radio track finished=\(finished) card=\(stationCardName != nil) pos=\(snapshot.elapsedTime ?? -1, format: .fixed(precision: 1)) dur=\(snapshot.duration ?? -1, format: .fixed(precision: 1))")
        }
        lastSnapshot = snapshot
        // Update @Published properties only when values change to avoid triggering unnecessary Combine view re-evaluations.
        let newTitle = snapshot.title ?? ""
        if newTitle != title { title = newTitle }
        let newArtist = snapshot.artist ?? ""
        if newArtist != artist { artist = newArtist }
        let newAlbum = snapshot.album ?? ""
        if newAlbum != album { album = newAlbum }
        let newIsPlayingNow = snapshot.playing == true
        if newIsPlayingNow != isPlayingNow { isPlayingNow = newIsPlayingNow }
        // Persist last active player bundle ID across stopped transitions for idle welcome views.
        let bid = snapshot.bundleIdentifier ?? ""
        if !bid.isEmpty, !newTitle.isEmpty, bid != lastPersistedPlayerBundleID {
            UserDefaults.standard.set(bid, forKey: "np:lastPlayerBundleID")
            lastPersistedPlayerBundleID = bid
        }
        // Ad break evaluation before persisting np:lastTrack*: ad breaks should not be stored as previous song history.
        let isSpotifyNative = snapshot.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier
        let resolvedBundleID = BrowserPositionProbe.probeTargetBundleID(forReported: snapshot.bundleIdentifier)
        let isSpotifyWeb = BrowserPositionProbe.shared.isPaired(bundleID: resolvedBundleID, platformID: "spotifyWeb")
        // YouTube Music web ads typically have channel name as artist and empty album, indistinguishable by field heuristics;
        // verified against DOM probe verdict cache.
        let youTubeMusicAdKey = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        // Badge-level verdict: only affirmative badge indicators flag ad status, preventing timeouts from falsely tagging tracks.
        let youTubeMusicVerdict = YouTubeMusicAdProbe.shared.cachedBadgeVerdict(forKey: youTubeMusicAdKey)
        // Spotify Web evaluates affirmative DOM probe verdicts rather than native heuristics to prevent misclassification
        // of album-less music videos in multi-paired browsers.
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
            UserDefaults.standard.set(newAlbum, forKey: "np:lastTrackAlbum")
            lastPersistedTrackTitle = newTitle
        }
        // Ad break state machine and verification:
        // Evaluates ad status via field heuristics (empty album/artist or dash title), browser DOM probes
        // (`YouTubeMusicAdProbe`, `SpotifyWebAdProbe`), and native Spotify AppleScript checks.
        // Ratchets to true during the track; YouTube Music MV playback allows dropping to false when DOM reports .song.
        let nextAd = Self.nextAdBreakState(
            previous: isCurrentTrackAdBreak, isNewTrack: snapshot.trackKey != lastKey,
            adByFields: adByFields, pageVerdict: isSpotifyNative ? nil : youTubeMusicVerdict)
        if isCurrentTrackAdBreak != nextAd { isCurrentTrackAdBreak = nextAd }
        // Ad slot tracking: extracted from cached reading alongside badge verdict.
        let nextAdSlot = nextAd
            ? YouTubeMusicAdProbe.shared.cachedReading(forKey: youTubeMusicAdKey)?.adSlot
            : nil
        if currentAdSlot != nextAdSlot { currentAdSlot = nextAdSlot }
        // While ad break is active during browser playback, query YouTube Music DOM probe to observe transition to song.
        if nextAd, !isSpotifyNative, spotifyWebVerdict != .ad {
            YouTubeMusicAdProbe.shared.kickIfNeeded(
                bundleIdentifier: snapshot.bundleIdentifier, key: youTubeMusicAdKey)
        }
        // Authoritative verification for native Spotify: notification track ID or osascript query.
        if snapshot.trackKey != lastKey, isSpotifyNative, !adByFields {
            spotifyNativeAdCheckForNewTrack(snapshot: snapshot)
        }

        let key = snapshot.trackKey
        let trackChanged = key != lastKey
        // Retain previous key before updating lastKey to differentiate fresh track transitions from reconnects after idle.
        let previousKey = lastKey
        // Periodic check for collector background enrichments (translations, lyric upgrades, or rescored lyrics).
        let networkDown = CollectorStatus.networkLooksDown
        if networkDown != collectorNetworkDown { collectorNetworkDown = networkDown }

        // Advance reader version; trigger reload based on decoded content version rather than filesystem mtime.
        EnrichCacheReader.refreshIfNeeded()
        let enrichMTime = EnrichCacheReader.decodedContentVersion
        if enrichContentVersion != enrichMTime { enrichContentVersion = enrichMTime }
        if trackChanged || !syncEngine.hasContent || enrichMTime != lastEnrichMTime {
            if trackChanged {
                logger.info("track changed: \(snapshot.artist ?? "", privacy: .public) - \(snapshot.title ?? "", privacy: .public)")
                if spotifyArtworkURL != nil { spotifyArtworkURL = nil }
            }
            lastKey = key
            lastEnrichMTime = enrichMTime
            reloadCurrentLyrics()
        }
        // Recalculate offsets when active player changes without a track transition to apply player-specific offsets.
        let bundleID = snapshot.bundleIdentifier
        if bundleID != lastAppliedBundleID {
            lastAppliedBundleID = bundleID
            if !trackChanged, syncEngine.hasContent { applyOffsets() }
        }

        if trackChanged {
            // Retain previous artwork until new artwork is ready or confirmed absent; schedule stale timeout safeguard.
            scheduleArtworkStaleTimeout(forKey: key)
            fetchArtworkForCurrentTrack(expectedKey: key)
        }

        let now = Date()
        let playing = snapshot.playing == true
        var pauseShownMs: Int?
        var pauseAnchorWasFrozenByEvent = false
        // Anchor bias invalidation: bias measured at track start or via probe belongs only to the anchor it was measured against.
        // If the player republishes an anchor (pause/resume/seek with altered anchorElapsedTime), invalidate the bias.
        if isSpotifyNative, key == posTrackingKey, posReportedBiasSecs != 0,
           !Self.biasSurvivesAnchor(anchorElapsedTime: snapshot.anchorElapsedTime, measuredAgainst: posBiasAnchorElapsed) {
            logger.notice("anchor bias dropped: player republished anchor elapsed=\(snapshot.anchorElapsedTime ?? -1, format: .fixed(precision: 3)) measuredAgainst=\(self.posBiasAnchorElapsed ?? -1, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3)) playing=\(playing)")
            if !playing, posBiasFromProbe, let frozen = snapshot.anchorElapsedTime {
                let oursMs = anchor == nil ? pausedPositionMs : anchor?.extrapolatedPositionMs(now: now)
                if let oursMs {
                    learnProbeLead(residual: Double(oursMs) / 1000 - frozen)
                }
            }
            setReportedBias(0, anchorElapsed: nil)
            if playing {
                SpotifyPositionProbe.shared.requestConfirmation(forKey: key)
            }
        }
        if playing, let duration = snapshot.duration, duration > 0 {
            // Normalize transient playbackRate=0 to 1 during track switches to prevent false seek detections.
            var rate = snapshot.playbackRate ?? 1
            if rate <= 0 { rate = 1 }
            // Position source tier classification (precise, cleanExtrapolated, noisyFloored).
            let tier = Self.positionSourceTier(forBundleID: snapshot.bundleIdentifier)
            if trackChanged {
                BrowserPositionProbe.shared.trackChanged(from: previousKey, to: key)
                SpotifyPositionProbe.shared.trackChanged(to: key, isSpotifyNative: isSpotifyNative)
            }
            // `expectedDuration` verifies browser tab matches current track in DOM probe.
            BrowserPositionProbe.shared.kickIfNeeded(
                bundleIdentifier: snapshot.bundleIdentifier, key: key, expectedDuration: duration)
            let rawReportedForResolve: Double
            let effectiveTier: PositionSourceTier
            var usedBrowserProbe = false
            // Consume single-use ground truth seed from browser or Spotify probe.
            // Credibility checks are handled inside probe implementations (active tab matching track and duration).
            if let probed = BrowserPositionProbe.shared.consumeCorrection(forKey: key, rate: rate, now: now) {
                rawReportedForResolve = probed
                effectiveTier = .noisyFloored
                usedBrowserProbe = true
            } else if posWasPlaying, key == posTrackingKey,
                      let probed = SpotifyPositionProbe.shared.consumeCorrection(forKey: key, rate: rate, now: now) {
                rawReportedForResolve = probed - probeLeadSecs
                effectiveTier = tier
                usedBrowserProbe = true
            } else {
                rawReportedForResolve = snapshot.elapsedTime ?? 0
                effectiveTier = tier
            }
            let (positionSeconds, didReanchor) = resolvePositionSeconds(
                reported: rawReportedForResolve, rate: rate, key: key, now: now,
                tier: effectiveTier, isGroundTruthSeed: usedBrowserProbe,
                anchorElapsedTime: snapshot.anchorElapsedTime, streamRaw: snapshot.elapsedTime)
            if !posWasPlaying, key == posTrackingKey, let prevPaused = pausedPositionMs {
                logger.notice("resume transition: paused=\(Double(prevPaused) / 1000, format: .fixed(precision: 3)) resumed=\(positionSeconds, format: .fixed(precision: 3)) raw=\(rawReportedForResolve, format: .fixed(precision: 3)) delta=\(positionSeconds - Double(prevPaused) / 1000, format: .fixed(precision: 3)) rate=\(snapshot.playbackRate ?? -1, format: .fixed(precision: 2))")
            }
            // Reconstruct progress anchor only on real discontinuities, track changes, or rate/duration changes.
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
        // Radio offset adjustments apply strictly to the specific radio station and track combination (see LyricsOffsetStore.radioOffsets).
        let radioKey = currentRadioOffsetKey
        if !radioKey.isEmpty {
            LyricsOffsetStore.shared.nudgeRadio(by: deltaMs, forKey: radioKey)
        } else {
            LyricsOffsetStore.shared.nudge(by: deltaMs, forKey: currentOffsetKey, pinKey: currentPinKey)
        }
        applyOffsets()
        return trackLyricsOffsetMs
    }

    public func resetLyricsOffset() {
        guard lastSnapshot != nil else { return }
        let radioKey = currentRadioOffsetKey
        if !radioKey.isEmpty {
            LyricsOffsetStore.shared.setRadioOffset(0, forKey: radioKey)
        } else {
            LyricsOffsetStore.shared.reset(forKey: currentOffsetKey, pinKey: currentPinKey)
        }
        applyOffsets()
    }

    /// Updates global lyrics offset baseline.
    public func setGlobalLyricsOffset(_ ms: Int) {
        LyricsOffsetStore.shared.setGlobalOffset(ms)
        guard lastSnapshot != nil else { return }
        applyOffsets()
    }

    /// Updates the offset tier for a specific player bundle identifier.
    /// Immediately recalculates effective offsets if the modified player matches the currently active player.
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

    /// Version timestamp of the currently decoded enrich cache (`EnrichCacheReader.decodedContentVersion`).
    /// Published so downstream subscribers (such as high-res cover refresh in `PlaybackCoordinator`)
    /// can re-query artwork asynchronously once the collector finishes writing new metadata to disk.
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
        // Plain text fallback lyrics included in equivalence gate to ensure manual adoptions trigger reload.
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
        // Sticky flag tracking whether Chinese lyrics have been seen, using shared `ChineseVariant.affects`.
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
        // Content equivalence gate: avoids re-executing script conversions, lyric engine parsing,
        // and window line reconstruction when the enrich cache file timestamp changes due to writes for other tracks.
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
        // Japanese kanji repair (`JapaneseKanjiRepair`): restores simplified kanji introduced by lyric sources
        // back to traditional Japanese forms before applying user Chinese variant conversion preferences.
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

    /// Computes the single average color from raw artwork data using CIAreaAverage.
    ///
    /// Computes raw pixel mean without brightness adjustments; individual surfaces apply
    /// brightness or contrast adjustments (e.g. `accentForDarkBackdrop`, `accentAgainstStroke`) independently.
    /// Pure nonisolated function safe to invoke from background tasks.
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
    nonisolated private static let averageHexContext =
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

    /// Adjusts artwork average color to ensure sufficient brightness when used as text color.
    ///
    /// Exclusively serves permanently dark surfaces (such as the notch/Dynamic Island).
    /// Uses HSB space rather than RGB multiplier:
    /// - Deep black near-zero inputs fall back to neutral gray to prevent JPEG compression noise artifacts.
    /// - Reduces saturation proportionally as brightness is raised to maintain natural perceptual appearance.
    /// Pure HSB transformation avoids introducing AppKit dependencies into LyrimuseCore.
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
