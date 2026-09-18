import SwiftUI
import Combine
import LyrimuseCore

/// 悬浮歌词的窄订阅代理：仅转发悬浮窗需要的状态，对值类型使用 removeDuplicates 减少重算。
/// anchor 与 currentLyricsOffsetMs 由 TimelineView 按帧直读，不进 Combine 管道。
@MainActor
private final class OverlayPlayback: ObservableObject {
    /// lyricsCard 的水平内边距。
    static let cardHorizontalPadding: CGFloat = 20

    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var currentLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?
    @Published private(set) var nextLineSide: LyricDuet.Side?
    @Published private(set) var isPlayingNow = false
    /// 当前是否有曲目在播（含广告插播态）。
    @Published private(set) var hasTrack = false
    @Published private(set) var isFavorited: Bool?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    /// 电台口白状态。
    @Published private(set) var isRadioTalkBreak = false
    @Published private(set) var currentLineFillSettled = true
    /// 悬浮歌词前景色。
    @Published private(set) var displayForegroundColor: Color = .white
    // ---- 来自 AppSettings ----
    @Published private(set) var lockPosition = false
    @Published private(set) var fadeOnHover = false
    @Published private(set) var placementMode: OverlayPlacementMode = .free
    @Published private(set) var showRomanization = true
    @Published private(set) var showTranslation = false
    @Published private(set) var showNextLinePreview = true
    @Published private(set) var duetAlignmentOverride: OverlayDuetAlignmentOverride = .automatic
    @Published private(set) var mainFont: Font = .system(size: 20, weight: .bold)
    @Published private(set) var romanizationFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var translationFont: Font = .system(size: 14, weight: .regular)
    @Published private(set) var previewFont: Font = .system(size: 14, weight: .medium)
    @Published private(set) var textStrokeEnabled = false
    @Published private(set) var textStrokeColor: Color = .black.opacity(0.65)
    @Published private(set) var backgroundIsVisible = false
    @Published private(set) var backgroundColor: Color = .clear
    @Published private(set) var backgroundGlass = false
    /// 对唱行两侧留白的基准量。
    @Published private(set) var duetInsetUnit: CGFloat = 0
    /// 对唱舞台两侧缩进量。
    @Published private(set) var duetStageInset: CGFloat = 0
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            // 「卡拉OK效果」关着时把行压成整行(`SyncedLyricLine.lineLevel`,2026-09-06):这一面的
            // 逐字填色、逐词罗马音标注都在下游按 `line.words` / `line.wordGroups` 走,压成整行之后
            // 它们自然走"这首歌没有逐字数据"那条路,渲染分支一处不用改。开关翻面也会重新发一次
            // 当前行,所以正在显示的那句当场变(不用等换行)。歌词窗口不经这里、始终逐字。
            Publishers.CombineLatest(p.$currentLine, s.$overlayLyricsKaraoke)
                .map { line, karaoke in karaoke ? line : line?.lineLevel }
                .removeDuplicates()
                .sink { [weak self] in self?.currentLine = $0 },
            p.$nextLineText.removeDuplicates().sink { [weak self] in self?.nextLineText = $0 },
            p.$nextLineSide.removeDuplicates().sink { [weak self] in self?.nextLineSide = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            // CombineLatest3 而不是三个独立 sink:三个输入要**同时**拿到才能算,独立 sink 里另两个
            // 只能回头读存储属性 —— 正是本文件头注说的 willSet 旧值坑(灵动岛那份同款写法)。
            Publishers.CombineLatest3(p.$title, p.$artist, p.$isCurrentTrackAdBreak)
                .map { title, artist, isAd in !title.isEmpty || !artist.isEmpty || isAd }
                .removeDuplicates()
                .sink { [weak self] in self?.hasTrack = $0 },
            p.$isFavorited.removeDuplicates().sink { [weak self] in self?.isFavorited = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$isRadioTalkBreak.removeDuplicates().sink { [weak self] in self?.isRadioTalkBreak = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            Publishers.CombineLatest3(p.$artworkAccentColor, s.$followsCoverArt, s.$foregroundColor)
                .map { accent, follows, fg in (follows ? accent : nil) ?? fg }
                .removeDuplicates()
                .sink { [weak self] in self?.displayForegroundColor = $0 },
            s.$lockPosition.removeDuplicates().sink { [weak self] in self?.lockPosition = $0 },
            s.$overlayFadeOnHover.removeDuplicates().sink { [weak self] in self?.fadeOnHover = $0 },
            s.$overlayPlacementMode.removeDuplicates().sink { [weak self] in self?.placementMode = $0 },
            s.$showRomanization.removeDuplicates().sink { [weak self] in self?.showRomanization = $0 },
            s.$showTranslation.removeDuplicates().sink { [weak self] in self?.showTranslation = $0 },
            s.$showNextLinePreview.removeDuplicates().sink { [weak self] in self?.showNextLinePreview = $0 },
            s.$overlayDuetAlignmentOverride.removeDuplicates().sink { [weak self] in self?.duetAlignmentOverride = $0 },
            s.$mainFont.removeDuplicates().sink { [weak self] in self?.mainFont = $0 },
            s.$romanizationFont.removeDuplicates().sink { [weak self] in self?.romanizationFont = $0 },
            s.$translationFont.removeDuplicates().sink { [weak self] in self?.translationFont = $0 },
            s.$previewFont.removeDuplicates().sink { [weak self] in self?.previewFont = $0 },
            s.$textStrokeEnabled.removeDuplicates().sink { [weak self] in self?.textStrokeEnabled = $0 },
            s.$textStrokeColor.removeDuplicates().sink { [weak self] in self?.textStrokeColor = $0 },
            s.$backgroundIsVisible.removeDuplicates().sink { [weak self] in self?.backgroundIsVisible = $0 },
            s.$backgroundColor.removeDuplicates().sink { [weak self] in self?.backgroundColor = $0 },
            s.$overlayBackgroundGlass.removeDuplicates().sink { [weak self] in self?.backgroundGlass = $0 },
            // 内缩基准:可用宽度 = 窗宽 − 两侧 20pt 内边距(见 lyricsCard 的 padding)。
            s.$overlayWidth.combineLatest(s.$fontSize)
                .map { width, font in
                    LyricDuetLayout.insets(
                        for: .leading,
                        availableWidth: CGFloat(width) - Self.cardHorizontalPadding * 2,
                        fontSize: CGFloat(font)
                    ).trailing
                }
                .removeDuplicates()
                .sink { [weak self] in self?.duetInsetUnit = $0 },
            // 对唱舞台:同一份可用宽度和字号,算舞台在卡片里居中后两侧各让出多少。
            s.$overlayWidth.combineLatest(s.$fontSize)
                .map { width, font in
                    OverlayCardGeometry.duetStageInset(
                        availableWidth: CGFloat(width) - Self.cardHorizontalPadding * 2,
                        fontSize: CGFloat(font))
                }
                .removeDuplicates()
                .sink { [weak self] in self?.duetStageInset = $0 },
        ]
    }
}

// 悬浮窗内容:逐字高亮时用渐变扫过效果(近似网页版 CSS 渐变裁字的视觉,不追求逐像素
// 还原),否则整行高亮;罗马音在上、译文在下,都是可选的小字。
//
// 换行不做任何动画(纯属性跳变,不经过 SwiftUI 动画事务),逐字填色用 TimelineView
// 按渲染帧频直接从播放位置现算 fillFraction(不经过 Timer 采样+插值)——两者都是为了
// 尽可能流畅、开销尽可能小,具体机制见下面 mainLine/wordText 的注释。
/// `LyricsOverlayView` 宿主状态协议：供真实悬浮窗与设置页编辑台复用。
@MainActor
protocol OverlayChromeSource: ObservableObject {
    /// 指针位于歌词或控制排上方。
    var isHoveringForControls: Bool { get }
    /// 指针位于歌词文字上方（用于悬停避让）。
    var isHoveringLyrics: Bool { get }
    /// 指针位于控制排上方（用于锁定横向落点）。
    var isHoveringControlPill: Bool { get }
    /// 当前悬停的按钮标识。
    var hoveredControl: OverlayControlID? { get }
    /// 长按拖拽准备就绪状态。
    var isDragArmed: Bool { get }
    /// 解锁提示手势显隐。
    var showDragHint: Bool { get }
    /// 通用瞬态提示文字（如全局快捷键反馈）。
    var transientHint: String? { get }
    /// 预设固定模式下拒绝拖动提示。
    var placementLockNotice: String? { get }
    /// 拒绝拖动时的抖动计数。
    var placementLockShakeTick: Int { get }
    /// 控制排显示回调。
    func controlsDidBecomeVisible()
}

/// 设置页预览示例行，真窗口恒传 nil。
struct OverlayPreviewLine {
    var line: SyncedLyricLine
    var nextLineText: String?
}

/// 对唱声部指示（圆点 + 竖线）几何尺寸。
private enum OverlaySpeakerIndicator {
    static let barHeight: CGFloat = 12
    static let width: CGFloat = 6 + 7 + 2 + 7
}

/// 控制排横向落点声部状态：悬停按钮排期间冻结声部，避免切行时按钮横向移位导致误触。
private enum OverlayControlsSidePin: Equatable {
    case free
    case pinned(LyricDuet.Side?)
}

struct LyricsOverlayView<Chrome: OverlayChromeSource>: View {
    // 不直接 @ObservedObject 整个 PlaybackCoordinator/AppSettings —— 见 OverlayPlayback
    // 的注释,那两个单例上与悬浮窗无关的高频写入会打醒整个 body。
    @StateObject private var playback = OverlayPlayback()
    /// 逐字行文字实际矩形的旁路,见 WrapContentRectSink。@State 保证视图重建时是同一个实例。
    @State private var wrapContentSink = WrapContentRectSink()
    // 悬停展示控制按钮/长按拖动这套手势整个搬到了 WindowController 用全局鼠标监听器
    // 实现(背景常年点击穿透,原生 .onHover 收不到事件),这里只读它算出来的结果
    // (isHoveringForControls/isDragArmed)展示对应视觉效果,不再自己维护 @State。
    //
    // 故意不写成 "= LyricsOverlayWindowController.shared" 默认值——这个 View 正是在
    // LyricsOverlayWindowController 自己的 init() 里被构造出来的(装进 NSHostingView),
    // 这时候 .shared 这个 static let 的一次性初始化(dispatch_once)还没跑完,任何在这个
    // 构造过程中对 .shared 的再次访问都会在同一线程递归触发同一个 dispatch_once,被
    // 系统直接判定成非法重入而 SIGTRAP 崩溃(实测坐实:EXC_BREAKPOINT,栈顶正是
    // _dispatch_once_wait 卡在这个默认值上)。改成必填参数,由外部显式传入当时已经
    // 拿到手的 self,不再经过 .shared 这层。
    // 不加 private——需要在另一个文件(LyricsOverlayWindowController.swift)里通过
    // 编译器合成的 memberwise init 传入,标 private 会让那个 init 的访问级别一并降到
    // private,导致跨文件调不到。
    // 类型是**协议**而不是那个具体类(2026-08-30):设置页编辑台要渲染同一份视图,
    // 而它绝不能碰 .shared —— 见 OverlayChromeSource 顶部那条⚠️。真窗口那唯一一个
    // 构造点靠类型推导拿到 Chrome == LyricsOverlayWindowController,一个字都不用改。
    @ObservedObject var overlayController: Chrome
    /// 只给按钮悬停高亮用(见 `iconButton`):辅助功能开了「减弱动态效果」就不补间,但高亮
    /// **照画** —— 它回答的是"指针现在在哪颗按钮上",是功能反馈,不是装饰(同灵动岛那批
    /// `reduceMotion ? nil : .spring(...)` 的取舍)。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 悬浮窗高度跟着内容动态变化(见 LyricsOverlayWindowController.updateHeight)——这里
    // 汇报"这次渲染实际需要多高",不需要就什么都不做(默认空闭包,方便预览/测试构造)。
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    // 播放控制按钮胶囊的实际屏幕矩形,汇报给 WindowController 当作"点击穿透的例外热区"
    // ——只有落在这个矩形里的鼠标事件才会被窗口正常接收,其它任何地方(包括歌词文字
    // 本身)永远穿透。按钮没显示时(锁定/未悬停)报 .zero。
    var onControlsFrameChange: (CGRect) -> Void = { _ in }
    /// 胶囊里每个按钮各自的矩形(overlayContent 命名坐标空间)。窗口常年点击穿透,
    /// SwiftUI 收不到鼠标事件,点击由控制器按这些矩形自己分发 —— 见
    /// LyricsOverlayWindowController.performControlAction。
    var onControlRectsChange: ([OverlayControlID: CGRect]) -> Void = { _ in }
    /// 歌词**文字**实际占据的矩形(overlayContent 命名坐标空间,多元素并集)。
    /// 给「指针划过时让开」当命中判据 —— 见 LyricsTextRectPreferenceKey。
    var onLyricsTextRectChange: (CGRect) -> Void = { _ in }
    /// 要不要画调试 HUD 那个 fps 角标(隐藏开关 np:debugHUD)。设置页预览传 false ——
    /// 那块画的是"这扇窗在桌面上长什么样",角标既不属于窗口,开着还会让 frameProbe
    /// 每帧 tick 一次。
    var showsDebugHUD: Bool = true
    /// 设置页预览的示例行,真窗口恒为 nil —— 见 OverlayPreviewLine。
    var previewLine: OverlayPreviewLine? = nil

    // 固定值,不是设置项——加一个圆角纯粹是给"背景颜色"这个设置配套的实现细节,免得
    // 用户一开背景色看到的是个生硬的直角矩形;两个参考的开源实现里圆角都不是用户可调项。
    private let overlayBackgroundCornerRadius: CGFloat = 16
    private let overlayCoordSpaceName = "overlayContent"
    /// 调试 HUD 的帧率探针。@State 而不是 @StateObject:它是纯值类型,而且**只在 HUD 开着
    /// 时**才被 tick —— 关着的时候这里恒为初始值,不产生任何开销。
    @State private var frameProbe = FrameRateProbe()
    @State private var debugFPS: Double?
    /// 控制排横向落点的"冻结"状态,见 `OverlayControlsSidePin`。
    @State private var controlsSidePin: OverlayControlsSidePin = .free

    // 播放控制排该不该显示:悬停中、且没锁定位置。抽成计算属性是因为下面有三处要用同一个
    // 判断(可见性、是否接受点击、热区要不要上报),散开写容易改漏其中一处。
    private var controlsVisible: Bool {
        overlayController.isHoveringForControls && !playback.lockPosition
    }

    /// 「指针划过时让开」的当前不透明度。
    ///
    /// 做成淡到 15% 而不是整窗 orderOut:orderOut 会打断 `updateActualVisibility` 那套
    /// 状态机(它同时被"暂停时隐藏""截屏时隐藏""手动开关"三方驱动),而这里要的只是
    /// "临时看一眼下面",不该跟那三个真正的可见性来源抢同一个开关。留 15% 也让用户知道
    /// 窗口还在那儿、不是消失了。
    private var hoverFadeOpacity: Double {
        playback.fadeOnHover && overlayController.isHoveringLyrics ? 0.15 : 1
    }

    /// 这一屏实际要画的那一行。真窗口恒等于 `playback.currentLine`(`previewLine` 是 nil),
    /// 排版逐像素不变;设置页预览在没有真实行时退到示例行。
    ///
    /// ⚠️ 收在这**一个**计算属性里,而不是只在 `mainLine` 里挑一次:译文、罗马音、逐词
    /// 分组、对唱声部、换行缓存 key 读的都得是同一行,漏掉任何一处就会变成"示例句显示
    /// 出来了、译文却按空行算"。
    private var line: SyncedLyricLine? { playback.currentLine ?? previewLine?.line }

    /// 这一屏画的是不是示例行。
    private var showingPreviewLine: Bool { playback.currentLine == nil && previewLine != nil }

    /// 下一句预览的文字。示例行在场时用示例那句 —— 它不在 `line` 里,真窗口那边同样是从
    /// 协调器单取的一条(见 `OverlayPlayback.nextLineText`)。
    private var nextLineText: String? {
        showingPreviewLine ? previewLine?.nextLineText : playback.nextLineText
    }

    var body: some View {
        // 按钮排常驻槽位，避免显隐时推挤歌词高度。顶部居中预设下槽位置于卡片下方以贴近菜单栏。
        VStack(spacing: 0) {
            if !controlsSlotBelow { controlsSlot }
            lyricsCard
            if controlsSlotBelow { controlsSlot }
        }
        .coordinateSpace(name: overlayCoordSpaceName)
        // 纯测量用,不影响视觉——把这次渲染真正需要的高度(按钮槽位+歌词卡片)报给窗口控制器
        // 去调整窗口高度,长歌词换行到第二行时窗口跟着变高,而不是被原来写死的高度裁掉。
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightPreferenceKey.self) { onContentHeightChange($0) }
        .onPreferenceChange(ControlsFramePreferenceKey.self) { onControlsFrameChange($0) }
        .onPreferenceChange(ControlRectsPreferenceKey.self) { onControlRectsChange($0) }
        .onPreferenceChange(LyricsTextRectPreferenceKey.self) { onLyricsTextRectChange($0) }
        .animation(.easeOut(duration: 0.16), value: controlsVisible)
        .animation(.easeOut(duration: 0.3), value: overlayController.showDragHint)
        .animation(.easeOut(duration: 0.2), value: overlayController.transientHint)
        .animation(.easeOut(duration: 0.2), value: overlayController.placementLockNotice)
        // 「指针划过时让开」。挂在**测量之后** —— opacity 不改布局,所以放哪一层都不影响上面
        // 那三条 preference 报出去的高度/热区;放这里只是让它和上面两条动画归在一起看得清。
        // 淡出比淡入慢一点(0.18 vs 0.12):指针扫过去要立刻让开才有用,回来时慢一点更从容。
        .opacity(hoverFadeOpacity)
        .animation(.easeOut(duration: hoverFadeOpacity < 1 ? 0.12 : 0.18), value: hoverFadeOpacity)
        // 调试 HUD(隐藏开关 np:debugHUD,不进设置界面)。挂 overlay 而不是塞进 VStack:
        // 它绝不能改变布局 —— 上面三条 preference 报出去的高度/热区是窗口几何的输入,
        // HUD 一旦占位就会把窗口撑高,量到的就不是原来那套渲染了。
        .overlay(alignment: .topTrailing) {
            if showsDebugHUD, AppSettings.shared.debugHUDEnabled {
                Text(debugFPS.map { String(format: "%.0f fps", $0) } ?? "-- fps")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // 控制排每次露出来时重读一次"喜欢"状态。这条状态不跟着 2 秒轮询走(每次读要起一个
        // osascript 子进程,为一个几乎不变的布尔值那么干不值当),换歌时刷一次之外,就靠这里
        // ——正好覆盖"用户刚在 Music.app 里自己点了心、回头来看悬浮窗"这种情况。
        //
        // 走 chrome 的回调而不是直接打 PlaybackCoordinator:设置页编辑台渲染的是同一份视图,
        // 那边必须能把这条副作用空实现掉(见 OverlayChromeSource.controlsDidBecomeVisible)。
        .onChange(of: controlsVisible) { _, visible in
            if visible { overlayController.controlsDidBecomeVisible() }
        }
        // 指针压上按钮排的那一刻把横向落点冻住,离开立刻解冻 —— 理由(以及为什么判据是
        // "压在按钮排上"而不是"控制排显示着")见 OverlayControlsSidePin。
        .onChange(of: overlayController.isHoveringControlPill) { _, onPill in
            controlsSidePin = onPill ? .pinned(line?.side) : .free
        }
        // 第二道闸:指针离开整扇窗时控制排本来就藏起来了,不该再留着一份陈旧快照。控制器
        // 在"窗口隐藏/锁定/卸掉监听器"几处也会顺手清掉 isHoveringControlPill,但那是四个
        // 分散的赋值点,漏一个就会冻死;这里只认"整窗悬停"这一个总闸,漏不掉。
        .onChange(of: overlayController.isHoveringForControls) { _, hovering in
            if !hovering { controlsSidePin = .free }
        }
        // 内容必须紧贴窗口锚边（「底部居中」贴底，其余贴顶），避免高度变化时垂直居中导致文字上下抖动。
        // 必须置于所有 background/测量修饰符之后，避免高度测量 GeometryReader 读取到窗口最大高度。
        .frame(maxHeight: .infinity, alignment: playback.placementMode.anchorsBottom ? .bottom : .top)
    }

    /// 控制排槽位放在歌词卡片下方（「顶部居中」预设），其余模式在上方。
    private var controlsSlotBelow: Bool { playback.placementMode == .topCenter }

    /// 播放控制排 / 锁定态解锁提示 / 位置已固定提示 共用槽位（常驻等高，透明度切换，避免歌词跳动）。
    private var controlsSlot: some View {
        Group {
            // 预设模式下拖拽被拒提示胶囊
            if let notice = overlayController.placementLockNotice {
                placementLockPill(notice)
            } else if playback.lockPosition {
                unlockPill
                    .opacity(unlockPillVisible ? 1 : 0)
                    .allowsHitTesting(unlockPillVisible)
                    .animation(.easeOut(duration: 0.16), value: unlockPillVisible)
            } else {
                playbackControls
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
                    // 汇报按钮真实矩形作为点击穿透例外热区；可见性由控制器端判定，避免子树默认值冲掉位置。
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ControlsFramePreferenceKey.self,
                                value: proxy.frame(in: .named(overlayCoordSpaceName))
                            )
                        }
                    )
            }
        }
        // 槽位外边距：挂在 Group 外确保各状态等高，避免状态切换时内容抖动。
        .padding(controlsSlotBelow ? .bottom : .top, 4)
        .padding(controlsSlotBelow ? .top : .bottom, 4)
        // 横向内缩对齐歌词块（OverlayCardGeometry.controlsInsets），不加动画以避免换行时热区上报中间态导致错位点击。
        .padding(.leading, controlsInsets.leading)
        .padding(.trailing, controlsInsets.trailing)
        .frame(maxWidth: .infinity, alignment: controlsFrameAlignment)
    }

    /// 对唱歌词的左右分栏(见 LyricDuet)——这是**对齐方向**用的值,已经套过设置页的
    /// 「对齐方式」覆盖(见 OverlayDuetAlignmentOverride):自动模式下等价于旧行为
    /// (nil = 没有演唱者标记的普通歌,兜底居中);非自动模式下**每一行**(不管有没有
    /// 真实声部信息)都固定成用户选的那个方向。
    ///
    /// ⚠️ 不要把这个值传进 withSpeakerIndicator/speakerIndicatorInset/duetInsets——
    /// 那三处要的是"要不要展示对唱装饰",跟"往哪边对齐"是两件事,非自动模式下前者必须
    /// 保持关闭(见 duetDecorationSide)。
    private var duetSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveAlignmentSide(realSide: line?.side)
    }

    /// 下一句预览摆放对齐方向：独立于当前行声部，支持交替演唱分栏预览。
    private var nextLineDuetSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveAlignmentSide(realSide: playback.nextLineSide)
    }

    /// 对唱装饰（两侧内缩与声部圆点）有效声部。覆盖对齐时禁用以保证位置稳定。
    private var duetDecorationSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveDecorationSide(realSide: line?.side) ?? .center
    }
    private var nextLineDecorationSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveDecorationSide(realSide: playback.nextLineSide) ?? .center
    }

    /// 控制排算横向落点时用的原始声部（悬停交互期间由 OverlayControlsSidePin 冻结）。
    private var controlsRealSide: LyricDuet.Side? {
        if case .pinned(let side) = controlsSidePin { return side }
        return line?.side
    }

    /// 控制排贴靠方向。
    private var controlsFrameAlignment: Alignment {
        frameAlignment(for: playback.duetAlignmentOverride.effectiveAlignmentSide(realSide: controlsRealSide))
    }

    /// 控制排留白：卡片内缩 + 卡片水平内边距（OverlayCardGeometry.controlsInsets）。
    private var controlsInsets: (leading: CGFloat, trailing: CGFloat) {
        OverlayCardGeometry.controlsInsets(
            for: playback.duetAlignmentOverride.effectiveDecorationSide(realSide: controlsRealSide),
            unit: playback.duetInsetUnit,
            stageInset: playback.duetStageInset,
            cardHorizontalPadding: OverlayPlayback.cardHorizontalPadding)
    }

    /// 下一句预览字号：在对唱换人演唱时（且未覆盖对齐）提前使用主字号预告排版变化，其余情况保持预览字号。
    private var nextLinePreviewFont: Font {
        guard playback.duetAlignmentOverride == .automatic,
              let nextSide = playback.nextLineSide, nextSide != line?.side
        else {
            return playback.previewFont
        }
        return playback.mainFont
    }

    private func horizontalAlignment(for side: LyricDuet.Side) -> HorizontalAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private func textAlignment(for side: LyricDuet.Side) -> TextAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private func frameAlignment(for side: LyricDuet.Side) -> Alignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var duetAlignment: HorizontalAlignment { horizontalAlignment(for: duetSide) }

    private var duetTextAlignment: TextAlignment { textAlignment(for: duetSide) }

    /// 对唱声部指示：在贴边侧叠加同色圆点与细竖线标记。
    /// 给罗马音/译文补齐相同留白量，确保多行文字左/右边缘严格对齐。
    private func speakerIndicatorInset(side: LyricDuet.Side) -> (leading: CGFloat, trailing: CGFloat) {
        switch side {
        case .leading: return (OverlaySpeakerIndicator.width, 0)
        case .trailing: return (0, OverlaySpeakerIndicator.width)
        case .center: return (0, 0)
        }
    }

    @ViewBuilder
    private func withSpeakerIndicator<V: View>(side: LyricDuet.Side, color: Color, @ViewBuilder content: () -> V) -> some View {
        if side != .center {
            let dot = Circle().fill(color).frame(width: 6, height: 6)
            let bar = Capsule().fill(color.opacity(0.55)).frame(width: 2, height: OverlaySpeakerIndicator.barHeight)
            HStack(spacing: 7) {
                if side == .leading {
                    dot
                    bar
                    content()
                } else {
                    content()
                    bar
                    dot
                }
            }
        } else {
            content()
        }
    }

    /// 二维外框对齐方式。
    private var duetFrameAlignment: Alignment { frameAlignment(for: duetSide) }

    /// 把这个视图的 frame 报进歌词文字矩形的并集(见 LyricsTextRectPreferenceKey)。
    private func reportingTextRect<V: View>(_ v: V) -> some View {
        v.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LyricsTextRectPreferenceKey.self,
                    value: proxy.frame(in: .named(overlayCoordSpaceName)))
            })
    }

    /// 主歌词文字矩形上报：逐字行结合 WrapLayout 实际内容矩形修正有效区域。
    private func reportingMainLineRect<V: View>(_ v: V) -> some View {
        v.background(
            GeometryReader { proxy in
                let f = proxy.frame(in: .named(overlayCoordSpaceName))
                let local = wrapContentSink.rect
                let rect = local == .zero
                    ? f
                    : CGRect(x: f.minX + local.minX, y: f.minY + local.minY,
                             width: local.width, height: local.height)
                return Color.clear.preference(key: LyricsTextRectPreferenceKey.self, value: rect)
            })
    }

    /// 按声部计算两侧留白内边距。
    private func duetInsets(for side: LyricDuet.Side?) -> (leading: CGFloat, trailing: CGFloat) {
        OverlayCardGeometry.cardInsets(for: side, unit: playback.duetInsetUnit,
                                       stageInset: playback.duetStageInset)
    }

    private var duetInsets: (leading: CGFloat, trailing: CGFloat) {
        duetInsets(for: playback.duetAlignmentOverride.effectiveDecorationSide(realSide: line?.side))
    }

    /// 下一句预览内边距差值补偿：使预览行与当前卡片缩进叠加后精确匹配其独立声部排版。
    private var nextLineInsetsDelta: (leading: CGFloat, trailing: CGFloat) {
        let override = playback.duetAlignmentOverride
        let current = duetInsets(for: override.effectiveDecorationSide(realSide: line?.side))
        let next = duetInsets(for: override.effectiveDecorationSide(realSide: playback.nextLineSide))
        return (next.leading - current.leading, next.trailing - current.trailing)
    }

    private var duetRowAlignment: WrapLayout.RowAlignment {
        switch duetSide {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var lyricsCard: some View {
        VStack(alignment: duetAlignment, spacing: 4) {
            withSpeakerIndicator(side: duetDecorationSide, color: playback.displayForegroundColor) {
                reportingMainLineRect(mainLine)
            }
            // 罗马音在**歌词下面、译文上面**。2026-08-17 从歌词上面挪下来 —— 歌词窗口
            // (LyricsWindowView)早就是这个顺序了,这里是漏改的那一处,同一首歌只要解析不出
            // 词组就会跳到上面显示,四种组合里唯一的异类。
            //
            // 为什么是下面(调研结论):这里标的是**罗马字/音译**,不是注音。注音(furigana、
            // 拼音)是给"认得这套字、只是不确定读音"的读者用的,绑到单个字符,惯例在上方
            // (CSS ruby-position 默认 over);而音译是给"根本不认得这套字"的人跟着唱的,
            // 是一条跟译文并列的平行文本行,惯例在下方 —— 维基百科 Furigana 条目里唯一提到
            // 罗马字位置的例子(西武铁道站牌)也是把罗马字放在汉字下面。
            //
            // 四种语言统一放下面,不按语言分叉:① 韩文压根没有 ruby 传统(W3C 那份 ruby 文档
            // 从头到尾没提韩文 —— 谚文本身表音,韩国读者不需要注音),没有"上方"惯例可继承;
            // ② 中文拼音**作为注音**惯例确实在上方,但这里是音译,不是注音;③ K-pop 中日韩英
            // 混唱很常见,位置随语言变会让同一屏内上下不一致。
            //
            // 有逐词标注(perWordRomanization)时,读音已经标在每个词的正下方了,这一整行
            // 就不再重复一遍。
            if playback.showRomanization, !usesPerWordRomanization,
                let roma = line?.romanization
            {
                reportingTextRect(
                    Text(roma)
                        .font(playback.romanizationFont)
                        .foregroundStyle(playback.displayForegroundColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true) // 允许换行时如实撑高,不被裁掉
                        .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor))
                    // 补主歌词那边圆点+竖线占掉的宽度,理由见 speakerIndicatorInset 的注释。
                    .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                    .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
            }
            if playback.showTranslation, let tr = line?.translation {
                reportingTextRect(
                    Text(tr)
                        .font(playback.translationFont)
                        .foregroundStyle(playback.displayForegroundColor.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor))
                    // 同上。
                    .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                    .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
            }
            if playback.showNextLinePreview, let next = nextLineText {
                // 分栏按**下一句自己的** side 算,不继承外层 VStack 的 duetAlignment
                // (那个绑的是当前行)——.frame/.multilineTextAlignment 挂在
                // reportingTextRect(...) 的返回值上、而不是塞进它的参数里,是为了不
                // 打乱 reportingTextRect 量出来的文字矩形(它要量的是文字本身的紧凑
                // 边界,不是撑满整行之后的边界,见 reportingMainLineRect 同一处理由)。
                withSpeakerIndicator(side: nextLineDecorationSide, color: playback.displayForegroundColor.opacity(0.4)) {
                    reportingTextRect(
                        Text(next)
                            .font(nextLinePreviewFont)
                            .foregroundStyle(playback.displayForegroundColor.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                            .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    )
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment(for: nextLineDuetSide))
                .multilineTextAlignment(textAlignment(for: nextLineDuetSide))
                // 补偿到"下一句自己真正的" insets,理由见 nextLineInsetsDelta 的注释——
                // 不这样做的话,下一句只是在当前行的缩进基础上尽量靠边,换演唱者时轮到它
                // 变成当前行的那一刻,缩进会重新按它自己的声部算,位置就会跳一下。
                .padding(.leading, nextLineInsetsDelta.leading)
                .padding(.trailing, nextLineInsetsDelta.trailing)
            }
            // 2026-08-02 补上——第一次解锁「锁定位置」时短暂弹一次的手势提示,4 秒后
            // 自动消失,只弹一次(见 LyricsOverlayWindowController.hasShownDragHintKey
            // 处的注释)。放在播放控制按钮上面同一个位置,不额外占用固定空间。
            // 2026-08-31:同一个位置现在还兼做全局快捷键的操作回声(见 transientHint)。
            // 在这之前,只开桌面悬浮歌词的用户按「歌词提前/延后」是**完全没有反馈**的
            // —— 那条提示只有灵动岛渲染,而这两个键恰恰是最需要看到累计值的。
            if let hint = overlayController.transientHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.8))
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    .transition(.opacity)
            } else if overlayController.showDragHint {
                Text(AppSettings.shared.overlayDragNeedsLongPress
                        ? L10n.t("长按即可拖动位置")
                        : L10n.t("按住歌词即可拖动位置"))
                    .font(.caption)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.8))
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    .transition(.opacity)
            }
        }
        // 对唱行的两侧留白 —— 让左右真的读成两栏,而不是只靠字的落点(见 LyricDuetLayout)。
        // 没有对唱信息的行(普通歌的每一行)insets 恒为 0,排版逐像素不变。
        .padding(.leading, duetInsets.leading)
        .padding(.trailing, duetInsets.trailing)
        .padding(.horizontal, OverlayPlayback.cardHorizontalPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: duetFrameAlignment)
        .background(overlayBackground)
        // 长按拖动"武装"后的视觉提示——一圈跟前景色同色的高亮描边,松手/取消立刻淡出。
        .overlay(
            RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                .stroke(playback.displayForegroundColor.opacity(overlayController.isDragArmed ? 0.6 : 0), lineWidth: 2)
        )
        // 预设模式下想拖被拒:整张卡左右抖三下(2026-09-11,照 macOS 密码框输错那一下的语义),
        // 配合槽位里那条「已固定」胶囊。tick 每次 +1,GeometryEffect 里 sin 走整数个周期、静止位
        // 精确归零。「减弱动态效果」开着时不抖(胶囊照样给)。纯位移、不改布局,热区/高度上报不受影响。
        .modifier(OverlayRejectShake(
            travel: reduceMotion ? 0 : CGFloat(overlayController.placementLockShakeTick)))
        .animation(reduceMotion ? nil : .linear(duration: 0.45), value: overlayController.placementLockShakeTick)
        // 对唱歌词按演唱者分左右(2026-08-14)。不带标记的歌 duetSide 恒为 .center,
        // 跟原来完全一致——除非「对齐方式」覆盖生效(2026-08-29,issue #2),那时
        // duetSide 会固定成用户选的方向,不带标记的普通歌也会跟着一起改对齐。
        .multilineTextAlignment(duetTextAlignment)
    }

    /// 锁定态 hover 时是否露出"解锁"提示——跟 `controlsVisible`(未锁定时播放控制排的
    /// 显示条件)完全对称,只是把 `!lockPosition` 换成 `lockPosition`。
    private var unlockPillVisible: Bool {
        overlayController.isHoveringForControls && playback.lockPosition
    }

    /// 锁定态悬停展示的解锁按钮：与未锁定控制排复用尺寸及热区上报。
    private var unlockPill: some View {
        iconButton(.unlockPill, "lock.fill", primary: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            // 玻璃材质跟随可见性开关，避免隐藏时毛玻璃穿透。
            .overlayCapsuleBackground(visible: unlockPillVisible)
            .transition(.opacity)
    }

    private var playbackControls: some View {
        HStack(spacing: 5) {
            iconButton(.previous, "backward.fill")
            iconButton(.playPause, playback.isPlayingNow ? "pause.fill" : "play.fill", primary: true)
            iconButton(.next, "forward.fill")
            // 「喜欢」：仅在 Apple Music 且具备权限时展示
            if let favorited = playback.isFavorited {
                iconButton(.favorite, favorited ? "heart.fill" : "heart")
                    .foregroundStyle(favorited ? Color.red : Color.white)
            }
            // 分组竖线
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 12)
            iconButton(.expandToLyricsWindow, "arrow.up.left.and.arrow.down.right")
            iconButton(.settingsMenu, "gearshape.fill")
            iconButton(.lock, "lock.open.fill")
            iconButton(.closeOverlay, "xmark")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .overlayCapsuleBackground(visible: controlsVisible)
    }

    /// 预设固定模式下拒绝拖拽提示胶囊。
    private func placementLockPill(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlayCapsuleBackground(visible: true)
        .transition(.opacity)
        .accessibilityLabel(text)
    }

    /// 控制排图标：由控制器统一进行命中测试与点击分发，此处渲染悬停动效与外层坐标上报。
    private func iconButton(_ id: OverlayControlID, _ systemName: String,
                            primary: Bool = false) -> some View {
        let hovered = overlayController.hoveredControl == id
        return Image(systemName: systemName)
            .font(.system(size: primary ? 12 : 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .scaleEffect(hovered ? 1.16 : 1)
            .frame(width: primary ? 22 : 19, height: primary ? 22 : 19)
            .background {
                Circle()
                    .fill(Color.white.opacity(hovered ? 0.18 : 0))
                    .scaleEffect(hovered ? 1 : 0.55)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72),
                       value: hovered)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ControlRectsPreferenceKey.self,
                        value: [id: proxy.frame(in: .named(overlayCoordSpaceName))])
                }
            )
    }

    // "没在播放"要不要隐藏,完全交给 hideWhenNotPlaying 那个开关(见
    // LyricsOverlayWindowController)决定——这里不重复处理,否则两条路径同时生效会分不清
    // 究竟是谁在起作用,看起来像开关失灵。
    @ViewBuilder
    private var overlayBackground: some View {
        if playback.backgroundGlass {
            // 毛玻璃(2026-09-02):系统材质垫底,用户的背景色叠在上面当着色——背景色全透明
            // 就是纯玻璃,alpha 越高越接近下面那档纯色卡片。材质用 .regularMaterial 而不是
            // .thickMaterial(灵动岛那档):悬浮歌词压在壁纸/别的窗口上,厚材质几乎把底下盖成
            // 一块灰板,失去"透出壁纸"的意义;也不用 .ultraThin,浅色壁纸上白字会不够清楚。
            // 材质在这扇 isOpaque=false、backgroundColor=.clear 的 NSPanel 里能直接渲染,
            // NotchLyricsWindow 用 .thickMaterial 是同一条路。系统「减少透明度」开着时材质
            // 自动退成近乎不透明的底色,不用特判。
            ZStack {
                RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                    .fill(playback.backgroundColor)
            }
        } else if playback.backgroundIsVisible {
            RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                .fill(playback.backgroundColor)
        } else {
            // 未开启背景色(默认状态)时保留原来近乎透明的拖拽捕获层——纯透明区域有时候
            // 完全接不到拖拽手势,这里给个极淡的背景让 isMovableByWindowBackground 在
            // 整块区域都能生效。
            Color.black.opacity(0.001)
        }
    }

    @ViewBuilder
    private var mainLine: some View {
        if let words = line?.words {
            // 逐字填色采用 TimelineView 直接从 anchor 外推位置（30Hz），避免动画插值矢量叠加卡顿。
            // 当 currentLineFillSettled 为 true 或暂停时停表，消除纯色静态帧的无谓重绘。
            TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                    paused: !playback.isPlayingNow || playback.currentLineFillSettled)) { context in
                let currentMs = (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: context.date)
                    ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
                    + PlaybackCoordinator.shared.currentLyricsOffsetMs
                karaokeLineContent(words: words, atMs: currentMs)
                    .onChange(of: context.date) { _, date in
                        guard showsDebugHUD, AppSettings.shared.debugHUDEnabled else { return }
                        frameProbe.tick(at: date)
                        debugFPS = frameProbe.fps
                    }
            }
            .font(playback.mainFont)
            // 描边采用静态副本作为 Canvas symbol，仅随文字/换行重建，避免高频逐字填色引发重算。
            .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor) {
                karaokeLineContent(words: words, atMs: nil)
                    .font(playback.mainFont)
            }
        } else if let text = line?.mainText {
            Text(text)
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor)
                .fixedSize(horizontal: false, vertical: true)
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if !playback.hasTrack {
            // 无曲目播放时展示品牌占位符
            (Text(Image(systemName: "music.note")) + Text(verbatim: " Lyrimuse"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.7))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isCurrentTrackAdBreak {
            // 广告插播期间优先展示广告标记
            Text(L10n.t("广告中"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isRadioTalkBreak {
            // 电台口白期间优先展示口白标记
            Text(L10n.t("口白"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isCurrentTrackInstrumental {
            // 确认为纯音乐曲目
            Text(L10n.t("纯音乐"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.currentTrackHasNoLyrics {
            // 明确未检索到歌词
            Text(L10n.t("暂无歌词"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.collectorNetworkDown && !playback.hasLyricsContent {
            // 网络离线且无缓存
            Text(L10n.t("网络连接失败"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isPlayingNow && !playback.hasLyricsContent {
            // 播放中后台查询歌词
            Text(L10n.t("搜索歌词中…"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else {
            Text("♪")
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.3))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        }
    }

    /// 这一行是否满足逐词标注罗马音条件。
    private var usesPerWordRomanization: Bool {
        playback.showRomanization && line?.wordGroups?.isEmpty == false
    }

    /// 逐字行的内容本体,mainLine 的两个消费方共用同一份排版:
    /// - `atMs` 非 nil:正常展示路径,按播放位置给每个词/组算填色渐变(TimelineView 每帧调);
    /// - `atMs` 为 nil:描边剪影的**静态副本**(同字体/同排版/同换行,纯色填充)——mask 只
    ///   消费 alpha 剪影,用它当 Canvas symbol,描边层就不再被每帧的渐变变化整行重算,
    ///   见 mainLine 里 lyricsTextStroke(maskSource:) 那段注释。
    @ViewBuilder
    private func karaokeLineContent(words: [SyncedLyricWord], atMs currentMs: Int?) -> some View {
        // 渐变素材每帧每行只取一次(纯色词跨帧复用同一实例,见 WordKaraokeGradient.Palette
        // 注释;2026-08-20 性能审计:原来逐词现造 LinearGradient+AnyShapeStyle,~95% 纯色词
        // 每帧被迫重走样式失效)。currentMs == nil 是描边剪影副本,不需要素材。
        let palette = currentMs != nil
            ? WordKaraokeGradient.palette(fg: playback.displayForegroundColor) : nil
        let romaPalette = (currentMs != nil && usesPerWordRomanization)
            ? WordKaraokeGradient.palette(fg: playback.displayForegroundColor.opacity(0.75)) : nil
        // 会自动换行的 WrapLayout——HStack(spacing: 0) 从不换行,一行装不下所有字时会把
        // 每个 Text 压缩到自己出省略号,长的逐字歌词行会直接"消失"变成一串"…"。
        // 见文件底部 WrapLayout 定义。contentKey:行身份+字体+罗马音开关 —— 都没变就跳过
        // 逐词重新测宽(见 WrapLayout.Cache 的守卫注释)。
        WrapLayout(rowAlignment: duetRowAlignment,
                   contentKey: overlayLineLayoutKey,
                   contentRectSink: wrapContentSink) {
            if let groups = line?.wordGroups, usesPerWordRomanization {
                // 一组一列:上面是这一组的字(各自逐字填色),下面是这一组的罗马音
                // (跟着整组的进度填)。列宽由 VStack 取"上下两行里更宽的那个",
                // 主文字之间的间距因此会被下面的罗马音撑开 —— Apple 那边也是这样。
                ForEach(groups) { g in
                    // 组内左对齐,跟歌词窗口/Apple Music 一致
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            // indices 而不是 Array(enumerated()):后者每帧物化一个新数组
                            // 纯为当 id,Range 零分配,下标当 id 与原 offset 语义一致。
                            ForEach(g.words.indices, id: \.self) { i in
                                wordText(g.words[i], atMs: currentMs, palette: palette)
                            }
                        }
                        if let roma = g.romanization {
                            romaText(roma, group: g, atMs: currentMs, palette: romaPalette)
                        }
                    }
                }
            } else {
                ForEach(words.indices, id: \.self) { i in
                    wordText(words[i], atMs: currentMs, palette: palette)
                }
            }
        }
    }

    /// WrapLayout 的内容身份:这些输入不变,行内每个 Text 的固有尺寸就不变,布局缓存可以
    /// 跳过整行重新测宽。⚠️ 必须含**完整**字体身份(family/size/weight 都在 mainFont/
    /// romanizationFont 里)和罗马音开关 —— 漏一样就会拿陈旧尺寸错误换行。填色渐变/描边
    /// 不影响固有尺寸,刻意不进 key。
    private var overlayLineLayoutKey: AnyHashable {
        AnyHashable(OverlayLineKey(
            text: line?.plainText,
            roma: usesPerWordRomanization,
            mainFont: playback.mainFont,
            romaFont: playback.romanizationFont))
    }

    private struct OverlayLineKey: Hashable {
        let text: String?
        let roma: Bool
        let mainFont: Font
        let romaFont: Font
    }

    /// 一组的罗马音。填色进度按**整组**算,不跟着组里单个字跳 —— 一组常常只对应一个读音
    /// (「いつか」是一个词),按字跳会让下面这行一顿一顿的。currentMs 为 nil 时是描边
    /// 剪影副本,纯色即可(mask 只取 alpha),见 karaokeLineContent。
    private func romaText(
        _ roma: String, group: SyncedLyricWordGroup, atMs currentMs: Int?,
        palette: WordKaraokeGradient.Palette?
    ) -> some View {
        let style: AnyShapeStyle
        if let currentMs, let palette {
            // 裸起止版 fillFraction:别再每帧现造一个纯为传参的伪 SyncedLyricWord。
            let fraction = KaraokeFill.fillFraction(
                startMs: group.startMs, durationMs: max(1, group.endMs - group.startMs),
                atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand
            style = palette.style(left: fraction - band, right: fraction + band)
        } else {
            // 不透明黑保证任何前景色/透明度设置下剪影都完整(过 alphaThreshold)。
            style = AnyShapeStyle(Color.black)
        }
        return Text(roma)
            .font(playback.romanizationFont)
            .foregroundStyle(style)
            .lineLimit(1)
            .fixedSize()
            // 左右各留一点,免得相邻两组的罗马音贴在一起分不清词界
            .padding(.horizontal, 2)
    }

    private func wordText(
        _ w: SyncedLyricWord, atMs currentMs: Int?, palette: WordKaraokeGradient.Palette?
    ) -> some View {
        let style: AnyShapeStyle
        if let currentMs, let palette {
            let fraction = WordKaraokeGradient.fillFraction(for: w, atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand
            style = palette.style(left: fraction - band, right: fraction + band)
        } else {
            // 描边剪影副本 —— 理由见 romaText 同款分支。
            style = AnyShapeStyle(Color.black)
        }
        return Text(w.text)
            .foregroundStyle(style)
            // 故意不再包 .animation(...)——TimelineView(.animation) 已经在按渲染帧频
            // 重算真值,这里再叠一层 SwiftUI Animation 补间只会重新引入 mainLine 注释里
            // 那套矢量叠加问题。也故意不在这里单独套描边——描边统一挂在 mainLine 里
            // TimelineView 外层的 .lyricsTextStroke(maskSource:),见那边注释。
    }
}

// 悬浮窗背景透明、文字直接叠在桌面内容上,颜色/内容对不上时容易糊在一起——加一圈描边
// 提高辨识度,是字幕类悬浮显示的常见做法。
//
// 描边参考 katagaki/DJDX(View Modifiers/TextStroke.swift)的做法:content 先
// .blur(radius:) 让字形轮廓往外"胀"开一圈,Canvas 里用 .addFilter(.alphaThreshold(min:))
// 把这层模糊的 alpha 通道硬切成非 0 即 1,拿这个剪影当 mask 盖一层纯色矩形垫在原始文字
// (不模糊、保留自己的渐变/颜色)下面当描边。这个技术只需要文字的"形状"(alpha 通道),
// 不关心文字本身画的是纯色还是渐变,所以能像阴影一样整体套在 mainLine 外面一次搞定,
// 不需要对每个字分别处理;开销是固定的"整体渲染一遍 + 一次模糊 + 一次阈值",不随描边
// 粗细变化。备选的"N 个方向各偏移一份内容再叠加"写法更简单,但每多一个方向就多渲染一份
// 完整内容,用在这里(mainLine 是 60fps 逐字填色的热路径)会造成 N 倍重复开销,故未采用。
// maskSource(2026-08-19 性能审计落地):剪影 mask 的自定义静态源,nil = 直接用 content
// 本身。静态文本(罗马音/译文/占位符/整行高亮)的 content 本来就不逐帧变,自身当 symbol
// 没有任何浪费;但逐字填色路径的 content 里活跃词的渐变每 tick 都在变 —— content 值一变
// Canvas symbol 就失效,整行位图被二次合成并重跑高斯模糊 + alphaThreshold,而 mask 只
// 消费 alpha 剪影,剪影在一行存续期内根本不变。那条路径改传一份同排版的纯色副本,
// 描边层就只随换行/字体/宽度变化重建。
private struct OptionalTextStroke<MaskSource: View>: ViewModifier {
    let enabled: Bool
    let color: Color
    let maskSource: MaskSource?
    // 固定常量,不做成 Settings 可调项——只给颜色选择器,粗细留在代码里,保持克制
    // (同类实现普遍也只开颜色)。1.2pt 在这个项目常用的歌词字号下是一圈清晰但不臃肿的细描边。
    private let width: CGFloat = 1.2
    private let symbolID = "np-lyrics-stroke"

    init(enabled: Bool, color: Color, maskSource: MaskSource?) {
        self.enabled = enabled
        self.color = color
        self.maskSource = maskSource
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                // 模糊会让内容的可见范围往外"胀"出原本的 frame,这里预留出对应的空间,
                // 不然 Canvas 会把胀出来的部分裁掉,描边看起来缺一圈。描边通常只有一两个
                // 点粗,这圈额外留白很小,不会明显改变歌词行之间的间距。
                .padding(width * 2)
                .background(
                    Rectangle()
                        .foregroundStyle(color)
                        .mask {
                            Canvas { context, size in
                                context.addFilter(.alphaThreshold(min: 0.01))
                                context.drawLayer { ctx in
                                    if let resolved = context.resolveSymbol(id: symbolID) {
                                        ctx.draw(resolved, at: CGPoint(x: size.width / 2, y: size.height / 2))
                                    }
                                }
                            } symbols: {
                                // ⚠️ 这里的 .padding 必须跟上面 content 那道**一模一样**。
                                //
                                // Canvas 把剪影按居中绘制,只有"剪影与 content 在 canvas 里
                                // 占据同一块矩形"时才逐点对齐。content 是 `.padding(width*2)`
                                // 之后才被 background 包住的,所以 canvas 的尺寸 = 正文 + 这圈
                                // padding;而 symbols 拿到的提议宽度是 canvas 的**整宽**。
                                //
                                // 对普通 Text 无所谓 —— 它按自然宽度收缩,剪影比 canvas 窄一圈
                                // padding,居中绘制正好补回来。但逐字行是 WrapLayout,它**撑满
                                // 被提议的宽度**:content 撑满的是 padding 内的宽度、剪影撑满的
                                // 是 canvas 整宽,两者相差正好一圈 padding。
                                //
                                // 居中对齐时(非对唱歌)两边各差一半、正好抵消,看不出来;一旦
                                // 按 leading/trailing 靠边(对唱歌的左右声部),文字就分别贴在
                                // 各自矩形的边上 —— 偏移 width*2 = 2.4pt,而描边本身只有 1.2pt,
                                // 于是整圈描边甩到一侧。2026-08-23 用户报的「对唱歌词描边偏了」
                                // 就是这个。
                                symbolSource(content: content)
                                    .padding(width * 2)
                                    .tag(symbolID)
                                    .blur(radius: width)
                            }
                        }
                )
        } else {
            content
        }
    }

    // 剪影源:有静态副本用副本,没有就用 content 本身。副本跟 content 同排版同字体,
    // 自然尺寸一致,Canvas 居中绘制后跟被描边的内容逐点对齐。
    @ViewBuilder
    private func symbolSource(content: Content) -> some View {
        if let maskSource {
            maskSource
        } else {
            content
        }
    }
}

// internal(而不是 private):设置页顶部的实时预览要用同一个描边实现渲染同一段歌词 ——
// 预览和真窗口各写一份描边最终一定会漂,而描边是这一页最难凭想象判断效果的一项。
extension View {
    func lyricsTextStroke(_ enabled: Bool, color: Color) -> some View {
        modifier(OptionalTextStroke<EmptyView>(enabled: enabled, color: color, maskSource: nil))
    }

    /// 带静态剪影源的版本,给逐字填色这类 content 逐帧变化的热路径用 —— 见
    /// OptionalTextStroke 顶部 maskSource 的注释。
    func lyricsTextStroke<M: View>(
        _ enabled: Bool, color: Color, @ViewBuilder maskSource: () -> M
    ) -> some View {
        modifier(OptionalTextStroke(enabled: enabled, color: color, maskSource: maskSource()))
    }

    /// 悬浮窗控制胶囊的材质(2026-08-29,用户在几套视觉方案里选了"液态玻璃 + 纯色兜底"):
    /// 有液态玻璃的系统(macOS 26+)用 `.glassEffect`,没有就退回纯色深底胶囊——跟
    /// SettingsDesignSystem.swift 的 `settingsCardBackground` 同一个取舍(`#available`
    /// 门控,旧系统不模拟液态玻璃,直接用改版前的样子)。`playbackControls`/`unlockPill`
    /// 共用这一份实现——视觉上是"同一片材质"在两种内容之间切换,不能各自写一份、观感对不上。
    ///
    /// 两个分支都补一条发丝描边,理由跟 `settingsCardBackground` 那条⚠️一致、而且更必要:
    /// 液态玻璃的可见度完全取决于它背后有什么,而这个胶囊背后是**任意桌面壁纸**(比设置页
    /// 卡片背后固定的系统窗口背景变化更大得多),描边是"胶囊边界一定看得见"的唯一保证。
    ///
    /// 液态玻璃调成深色调(`.tint(.black.opacity(...))`):胶囊里的图标固定是白色(这个
    /// 悬浮窗常年叠在任意桌面内容之上,不能像设置页卡片那样让系统默认的浅色玻璃质感决定
    /// 明暗),不调深的话亮壁纸背景下白色图标会读不清楚。不用 `.interactive()`——这扇
    /// 窗口常年 `ignoresMouseEvents`,SwiftUI 收不到真实的指针/点击事件,interactive
    /// 玻璃的悬停/按压响应永远不会触发,加了只是死代码。
    ///
    /// ⚠️ `visible` 不是"要不要好看"的开关,是**正确性**要求(2026-08-30 实测坐实):
    /// 玻璃这一层**必须跟着可见性一起关掉**,不能只靠调用方在外面套 `.opacity(0)` 把它藏起来。
    /// `GlassEffectContainer` 会把它内部**所有**带 `.glassEffect` 的子树收拢进容器自己那一趟
    /// 玻璃渲染里(容器存在的意义就是让多块玻璃共享采样、靠近时互相融合),而容器和玻璃视图
    /// **之间**那一层 `.opacity` 在这趟渲染里不生效 —— 连玻璃托着的内容(这排图标)一起原样
    /// 画出来。真悬浮窗没有容器,所以一直是对的;而设置页的编辑台渲染的是同一份视图,
    /// `SettingsPage` 又把整页内容包在 `SettingsGlassContainer` 里(见 SettingsDesignSystem),
    /// 于是「预览里凭空多出一排点不动的播放控制按钮」。
    /// 复现与证据见 docs/features/04-desktop-overlay.md「编辑台改造」第九步。
    ///
    /// 只有**玻璃那一档**需要这个参数。纯色兜底那一档(旧系统)不进任何玻璃容器,外面
    /// 那句 `.opacity(0)` 本来就藏得住它,原样不动。可见时这条修饰符链跟改动前逐字一致 ——
    /// 真悬浮窗的观感一个像素都没变。
    ///
    /// (`glassEffect(_:in:isEnabled:)` 这台机器的 SDK 上没有,只能用分支;代价是切换那一下
    /// 玻璃层换了视图身份 —— 落在 body 那条 `.animation(_:value: controlsVisible)` 的事务里,
    /// SwiftUI 给它默认的淡入淡出,跟图标那半边同一档时长,观感上仍是一起淡进淡出。)
    @ViewBuilder
    func overlayCapsuleBackground(visible: Bool = true) -> some View {
        let shape = Capsule()
        if #available(macOS 26.0, *) {
            if visible {
                glassEffect(.regular.tint(.black.opacity(0.32)), in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            } else {
                // 不套玻璃 = 不被玻璃容器收走,外面那句 .opacity(0) 才藏得住这块胶囊。
                // 玻璃和描边都不参与布局,省掉它们不改变槽位尺寸,歌词位置照旧不跳。
                self
            }
        } else {
            background(.black.opacity(0.55), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
    }
}

/// 歌词**文字**实际占据的矩形(悬浮窗坐标空间),多行/多元素取并集。
///
/// 给「指针划过时让开」用:原来的判据是整个窗口矩形,而窗口比文字大得多 —— 上下有卡片
/// 内边距和播放控制槽位、左右是 WrapLayout 撑满留下的空白,于是指针在歌词**附近**就触发
/// 了淡出(2026-08-23 用户报的正是这个)。
///
/// reduce 必须**合并**、且跳过零矩形:树里没设过这个 key 的分支(测高度那些 Color.clear)
/// 会贡献 .zero,覆盖式写法会把真实矩形冲掉 —— 同 ControlRectsPreferenceKey 那个坑。
private struct LyricsTextRectPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard next != .zero, next.width > 0, next.height > 0 else { return }
        value = value == .zero ? next : value.union(next)
    }
}

/// 这次渲染需要多高(按钮槽位 + 歌词卡片)。真窗口拿它调窗高(updateHeight),编辑台拿它
/// 定卡高(OverlayEditorStage.cardHeight)。
///
/// ⚠️ reduce 必须取**最大值**,不能无脑 `value = nextValue()` —— 跟
/// `ControlsFramePreferenceKey` / `ControlRectsPreferenceKey` 那两条是同一个坑的第三例:
/// 全树只有一处真的设过这个 key(上面那个测高度的 `GeometryReader`),**其余每一个分支都在
/// 贡献 `defaultValue`(0)**;覆盖式写法的结果取决于"谁排在最后",一旦 0 排在后面,真实
/// 高度就被冲掉,消费方收到的恒为 0。
///
/// 2026-08-30 实测坐实(编辑台第十一步,单变量对照,四个宿主一致):同一次渲染里
/// `GeometryReader` 明明量到 206.2,`onPreferenceChange` 收到的却是 **0.0**;把这一行从
/// `value = nextValue()` 换成 `max` —— 别的一个字不改 —— 四个宿主立刻全部收到 206.2。
/// 编辑台的后果最刺眼:卡高被 `max(120, ceil(0))` 摁在 120pt 的地板上,`.clipped()` 把译文
/// 和下一句预览整个裁掉,看起来就像"编辑台不画译文"(用户报的正是这个)。
/// ⚠️ 第九步那条"探针进程里 onPreferenceChange 恒收到 0、是精简启动路径的产物"的结论**是
/// 错的**,别再照着它把这类现象当环境噪声放过 —— 病根一直在这三行里。
///
/// 取 max 而不是"跳过零值再覆盖":本 key 只有一个写入方,`max` 与"那唯一一次写入的值"恒等
/// (其余分支都是 0),内容变矮时也照样报得下去(每一趟布局都从 defaultValue 重新归约,
/// 不会记住上一趟的旧值)。
private struct ContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 每个按钮各自的矩形。
///
/// ⚠️ reduce 必须**合并**、而且**跳过零矩形**,不能无脑 value = nextValue():
/// 树里没设过这个 key 的分支(外层测高度的 background 里那个 Color.clear)会贡献
/// defaultValue,覆盖式写法会把真实矩形冲掉 —— 这个坑 2026-08-07 在
/// ControlsFramePreferenceKey 上实测踩过一次,见它的注释。
private struct ControlRectsPreferenceKey: PreferenceKey {
    static let defaultValue: [OverlayControlID: CGRect] = [:]
    static func reduce(value: inout [OverlayControlID: CGRect],
                       nextValue: () -> [OverlayControlID: CGRect]) {
        for (id, rect) in nextValue() where rect != .zero { value[id] = rect }
    }
}

private struct ControlsFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    // 保留最后一个**非零**报告,而不是无脑 value = nextValue()。树里没设过这个 key 的分支
    // (比如外层测高度的 background 里那个 Color.clear)会贡献 defaultValue(.zero),按原来的
    // 写法排在后面就会把真正报上来的矩形冲掉 —— 2026-08-07 实测就是这么坏的。
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// WrapLayout 排版后文字实际占据的相对矩形。
/// 供鼠标事件命中测试直接读取，避免在高频动画中引入 GeometryReader 引起重构。
final class WrapContentRectSink: @unchecked Sendable {
    /// 相对 WrapLayout bounds 原点的矩形。`.zero` = 尚未排版或无内容。
    var rect: CGRect = .zero
}

struct AnySendableHashable: Hashable, @unchecked Sendable {
    let base: AnyHashable
    init(_ base: AnyHashable) {
        self.base = base
    }
}

/// 自动换行布局：将逐字歌词按行宽折行，核心几何由 WrapLayoutMath 计算。
struct WrapLayout: Layout {
    typealias RowAlignment = WrapLayoutMath.RowAlignment

    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 2
    var rowAlignment: RowAlignment = .center
    /// 内容身份 key：内容或字号未变化时跳过重测，避免逐帧重复排版开销。
    var contentKey: AnySendableHashable? = nil
    /// 可选：输出文字实际占用矩形给鼠标命中判定。
    var contentRectSink: WrapContentRectSink? = nil

    init(
        horizontalSpacing: CGFloat = 0,
        verticalSpacing: CGFloat = 2,
        rowAlignment: RowAlignment = .center,
        contentKey: AnyHashable? = nil,
        contentRectSink: WrapContentRectSink? = nil
    ) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.rowAlignment = rowAlignment
        self.contentKey = contentKey.map(AnySendableHashable.init)
        self.contentRectSink = contentRectSink
    }

    /// 布局测量缓存结构体。
    struct Cache {
        var sizes: [CGSize]
        var contentKey: AnySendableHashable?
        var subviewCount: Int
        // rows 缓存:随 sizes 重测**必须**同步失效(sizes 新 rows 旧会摆放越界/重叠),
        // key 是 (maxWidth, horizontalSpacing)——placeSubviews 的 bounds.width 偶尔不等于
        // 最后一次提案宽度,miss 了重算就是,安全。
        var rows: [WrapLayoutMath.Row]?
        var rowsWidth: CGFloat = .nan
        var rowsSpacing: CGFloat = .nan
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) },
              contentKey: contentKey, subviewCount: subviews.count)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        if let key = contentKey, key == cache.contentKey, subviews.count == cache.subviewCount {
            return // 内容身份没变:字体/文本都没变,尺寸和 rows 缓存照用
        }
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.contentKey = contentKey
        cache.subviewCount = subviews.count
        cache.rows = nil
        cache.rowsWidth = .nan
        cache.rowsSpacing = .nan
    }

    private func cachedRows(_ cache: inout Cache, maxWidth: CGFloat) -> [WrapLayoutMath.Row] {
        if let rows = cache.rows, cache.rowsWidth == maxWidth, cache.rowsSpacing == horizontalSpacing {
            return rows
        }
        let rows = WrapLayoutMath.rows(
            sizes: cache.sizes, maxWidth: maxWidth, horizontalSpacing: horizontalSpacing)
        cache.rows = rows
        cache.rowsWidth = maxWidth
        cache.rowsSpacing = horizontalSpacing
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let maxWidth = proposal.width, maxWidth.isFinite else {
            // 没有宽度限制:理论上不会走到——调用方(mainLine)所在的 VStack 总会有一个
            // 有限宽度的提案(悬浮窗宽度固定)。兜底铺成一行,不换行。
            return WrapLayoutMath.unconstrainedSize(
                sizes: cache.sizes, horizontalSpacing: horizontalSpacing)
        }
        return WrapLayoutMath.totalSize(
            rows: cachedRows(&cache, maxWidth: maxWidth),
            maxWidth: maxWidth, verticalSpacing: verticalSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rows = cachedRows(&cache, maxWidth: bounds.width)
        if let sink = contentRectSink {
            // 记的是**相对 bounds 原点**的矩形:bounds 的绝对位置取决于父容器,而调用方
            // (LyricsOverlayView)另有一条 GeometryReader 报 WrapLayout 自己在悬浮窗坐标
            // 空间里的位置,两者在控制器侧相加。
            let local = WrapLayoutMath.contentBounds(
                rows: rows, bounds: CGRect(origin: .zero, size: bounds.size),
                verticalSpacing: verticalSpacing, rowAlignment: rowAlignment)
            sink.rect = local
        }
        for p in WrapLayoutMath.placements(
            rows: rows,
            sizes: cache.sizes, bounds: bounds,
            horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing,
            rowAlignment: rowAlignment)
        {
            subviews[p.index].place(
                at: p.origin, anchor: .topLeading, proposal: ProposedViewSize(p.size))
        }
    }
}

/// 「拒绝」抖动(2026-09-11):水平位移 = amplitude · sin(2π · cycles · travel)。`travel` 每次 +1
/// (整数),sin 在整数处恰为 0,所以静止位精确归零、不会累积出半像素偏移;动画过程中走完
/// `cycles` 个完整周期。纯 GeometryEffect 位移,不参与布局 —— 上报给控制器的热区矩形和内容高度
/// 都不受影响(它们量的是布局,不是投影)。
private struct OverlayRejectShake: GeometryEffect {
    var travel: CGFloat
    var amplitude: CGFloat = 7
    var cycles: CGFloat = 3

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = amplitude * sin(travel * .pi * 2 * cycles)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}
