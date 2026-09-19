import Foundation
import LyrimuseCore
import SwiftUI
import AppKit

// Visual styles for the Notch lyrics card:
// - `.coverArt`: Background blurs and dims current track artwork, while foreground elements
//   (titles, lyrics, controls, waveform) adapt to the artwork's dominant accent color.
//   Falls back to `.darkGradient` when artwork is unavailable.
// - `.solidBlack`, `.frostedGlass`, `.darkGradient`: Foreground text and icons render in white.
enum NotchCardStyle: String, Codable, Hashable, CaseIterable {
    case solidBlack
    case frostedGlass
    case darkGradient
    case coverArt
}

/// Content displayed in the left and right ear modules of the Notch lyrics card in steady/expanded states.
///
/// In collapsed state (minimal pill), layout is fixed to artwork and equalizer bars (`NotchMetrics.collapsedEarWidth` = 34pt).
/// Equalizer bars anchor to the outer edge of the right ear unless `.controls` is selected, in which case playback controls
/// replace the waveform. Ear modules (`.artwork`, `.controls`) are scaled to ear height (`contentTopInset - 10`, ~23pt).
enum NotchEarModule: String, Codable, Hashable, CaseIterable {
    case title
    case artist
    case album
    /// Album artwork thumbnail scaled to ear height (~23pt). Clicking opens the lyrics window.
    case artwork
    /// Playback controls (previous / play-pause / next). Suppresses right-ear equalizer bars when active.
    case controls
    /// Elapsed playback time.
    case elapsed
    /// Remaining playback time (with leading minus).
    case remaining
    case none
}

/// Outer ear placement for the playback equalizer bars (left or right).
enum NotchEqualizerEar: String, Codable, Hashable, CaseIterable {
    case left
    case right
}

/// Horizontal placement (left or right) of the artwork thumbnail in the Notch lyrics row.
enum NotchLyricRowArtworkPosition: String, Codable, Hashable, CaseIterable {
    case left, right
}

// Layout width mode for menu bar lyrics:
// - `.fixed`: Retains the configured slot width for short lines to prevent adjacent status item shifting.
// - `.adaptive`: Reserves the current song’s measured width, capped by the configured maximum.
enum MenuBarLyricsWidthMode: String, Codable, Hashable, CaseIterable {
    case fixed
    case adaptive
}

// Placement of the progress icon badge relative to menu bar lyrics text:
// Displayed only while lyrics are active, rendering track progress across the icon template.
enum MenuBarLyricsIconPosition: String, Codable, Hashable, CaseIterable {
    case off
    case leading
    case trailing
}

// Resting alignment for lyric lines that fit within the available slot width:
// Shared by Menu Bar lyrics and Notch lyrics row (`LyricsAlignmentSegmentedControl`).
// - `.automatic`: Resolves alignment based on duet vocal side (`SyncedLyricLine.side`; Notch only).
// - `.leading`, `.center`, `.trailing`: Static alignments when surplus width exists.
enum LyricsRestingAlignment: String, Codable, Hashable, CaseIterable {
    /// Dynamic alignment based on vocal part / duet side (Notch only).
    case automatic
    case leading
    case center
    case trailing
}

extension LyricsRestingAlignment {
    /// 灵动岛「对齐方式」给的选项:「自动」排最前(跟悬浮歌词那个控件一样,"智能的那一档"打头),
    /// 后面三档保持原来的顺序。
    static var notchOptions: [LyricsRestingAlignment] { [.automatic, .leading, .center, .trailing] }
    /// 菜单栏「对齐方式」给的选项:没有「自动」——那一格里的一行字目前不跟对唱声部走(要给的话
    /// 得把 `compactLine.side` 一路传进 `MenuBarScrollingLabel.present`,不是这一轮的事)。
    static var menuBarOptions: [LyricsRestingAlignment] { [.leading, .center, .trailing] }

    /// 把「自动」按这一句的声部落成一个确定的方向;非自动原样返回。**永远返回非 automatic**,
    /// 三个消费点(主行 / 副行 / 展开态「下一句」)要的是一个确定的方向。
    /// 兜底 `.leading` 的理由见类型头注。
    func resolved(duetSide: LyricDuet.Side?) -> LyricsRestingAlignment {
        guard self == .automatic else { return self }
        switch duetSide {
        case .leading?: return .leading
        case .trailing?: return .trailing
        case .center?: return .center
        case nil: return .leading
        }
    }

    /// SwiftUI 侧的对齐值。灵动岛两处消费方(`MarqueeText.restingAlignment` 和展开态
    /// 「下一句」那一行的 `.frame(alignment:)`)都用它,**一份映射两处读** —— 这个仓库为
    /// "同一个视觉属性有两条路径各写一份"付过代价(悬浮歌词的「对齐方式」当年在预览条上
    /// 静默失效,根因就是补对齐时只改了静态文本那一条、逐字填色那条漏了,见
    /// `OverlayStyleSettingsRows` 顶部注释)。
    ///
    /// 菜单栏不走这里:那一侧是 CALayer 手排(`MenuBarScrollingLabel` 直接算
    /// `contentLayer.position.x`),没有 SwiftUI 对齐值可用。
    var swiftUIAlignment: Alignment {
        switch self {
        // ⚠️ `.automatic` 不该走到这里 —— 消费点先过 `resolved(duetSide:)` 再取这个值
        // (`NotchPlayback.mainLyricAlignment` 那三个)。真走到了给左对齐,跟没有声部信息时的兜底一致。
        case .leading, .automatic: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// UserDefaults 支撑的设置存储。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        /// Obsolete: global karaoke toggle split into independent display surfaces (`overlayLyricsKaraoke`, `notchLyricsKaraoke`).
        /// Retained for migration in `init()`, registered in `ConfigPortability.obsoleteDefaultsKeys`.
        static let preferWordLevelKaraoke = "np:preferWordLevelKaraoke"
        /// Independent karaoke toggles for overlay and notch surfaces; menu bar uses `menuBarLyricsKaraoke`.
        static let overlayLyricsKaraoke = "np:overlayLyricsKaraoke"
        static let notchLyricsKaraoke = "np:notchLyricsKaraoke"
        static let lyricsChineseVariant = "np:lyricsChineseVariant"
        static let hasSeenChineseLyrics = "np:hasSeenChineseLyrics"
        static let hasShownMenuBarPositionHint = "np:hasShownMenuBarPositionHint"
        static let showRomanization = "np:showRomanization"
        static let romanizationScripts = "np:romanizationScripts"
        static let showTranslation = "np:showTranslation"
        static let launchAtLoginEnabled = "np:launchAtLoginEnabled"
        /// 布尔年代的旧键,只在 init() 里读一次做迁移(已登记进 ConfigPortability.obsoleteDefaultsKeys)。
        static let launchMusicOnLyrimuseOpen = "np:launchMusicOnLyrimuseOpen"
        static let launchPlayersOnLyrimuseOpen = "np:launchPlayersOnLyrimuseOpen"
        static let quitWithPlayers = "np:quitWithPlayers"
        static let collectorServiceEnabled = "np:collectorServiceEnabled"
        static let showInDock = "np:showInDock"
        static let showNextLinePreview = "np:showNextLinePreview"
        static let overlayDuetAlignmentOverride = "np:overlayDuetAlignmentOverride"
        static let showLyricsInMenuBar = "np:showLyricsInMenuBar"
        static let menuBarLyricsMaxChars = "np:menuBarLyricsMaxChars"
        static let menuBarLyricsWidth = "np:menuBarLyricsMaxWidth"
        static let menuBarLyricsWidthMode = "np:menuBarLyricsWidthMode"
        static let menuBarLyricsAlignment = "np:menuBarLyricsAlignment"
        static let menuBarLyricsKaraoke = "np:menuBarLyricsKaraoke"
        static let menuBarLyricsTextColorHex = "np:menuBarLyricsTextColorHex"
        static let menuBarLyricsFillColorHex = "np:menuBarLyricsFillColorHex"
        static let menuBarLyricsIconPosition = "np:menuBarLyricsIconPosition"
        static let menuBarLyricsFontWeight = "np:menuBarLyricsFontWeight"
        static let menuBarLyricsFontSize = "np:menuBarLyricsFontSize"
        static let menuBarSecondaryLine = "np:menuBarSecondaryLine"
        static let menuBarHoverShowsControls = "np:menuBarHoverShowsControls"
        static let menuBarShowsTitleWhenNoLyrics = "np:menuBarShowsTitleWhenNoLyrics"
        static let menuBarIconStyle = "np:menuBarIconStyle"
        static let menuBarIconAnimates = "np:menuBarIconAnimates"
        static let lyricsOffsetStepMs = "np:lyricsOffsetStepMs"
        static let manualPickLocksLyrics = "np:manualPickLocksLyrics"
        static let textStrokeEnabled = "np:textStrokeEnabled"
        static let textStrokeColorHex = "np:textStrokeColorHex"
        static let fontFamilyName = "np:fontFamilyName"
        static let fontSize = "np:fontSize"
        static let overlayFontWeight = "np:overlayFontWeight"
        static let overlayWidth = "np:overlayWidth"
        static let notchContentWidth = "np:notchContentWidth"
        // Maximum width of the Notch lyrics card when expanded on hover (`notchContentWidth` acts as floor).
        static let notchExpandedContentWidth = "np:notchExpandedContentWidth"
        static let foregroundColorHex = "np:foregroundColorHex"
        static let backgroundColorHex = "np:backgroundColorHex"
        // Desktop overlay background glass material.
        static let overlayBackgroundGlass = "np:overlayBackgroundGlass"
        // "Follow Artwork": Desktop overlay foreground color dynamically adapts to the current track cover art.
        // Applies exclusively to the desktop lyrics overlay; Notch lyrics card styling is governed by `notchCardStyle`.
        static let followsCoverArt = "np:followsCoverArt"
        static let lockPosition = "np:lockPosition"
        // Screen capture and inactive player visibility preferences for the desktop lyrics overlay.
        static let hideDuringScreenCapture = "np:hideDuringScreenCapture"
        static let hideWhenNotPlaying = "np:hideWhenNotPlaying"
        // Independent screen capture and inactive player visibility preferences for the Notch lyrics overlay.
        static let notchHideDuringScreenCapture = "np:notchHideDuringScreenCapture"
        static let notchHideWhenNotPlaying = "np:notchHideWhenNotPlaying"
        static let overlayFadeOnHover = "np:overlayFadeOnHover"
        static let overlayDragNeedsLongPress = "np:overlayDragNeedsLongPress"
        // Desktop overlay placement preset (see `OverlayPlacementMode`).
        static let overlayPlacementMode = "np:overlayPlacementMode"
        static let debugHUDEnabled = "np:debugHUD"
        // Synchronized with L10n language override key.
        static let appLanguage = "np:appLanguage"
        static let hasShownAutomationOnboarding = "np:hasShownAutomationOnboarding" // Legacy migration key
        static let hasCompletedOnboarding = "np:hasCompletedOnboarding"
        static let hasOfferedICloudImport = "np:hasOfferedICloudImport"
        static let overlayStyle = "np:overlayStyle" // Legacy migration key
        static let classicOverlayEnabled = "np:classicOverlayEnabled"
        static let notchOverlayEnabled = "np:notchOverlayEnabled"
        static let notchCardStyle = "np:notchCardStyle"
        static let notchShowLyrics = "np:notchShowLyrics"
        static let motionCoverEnabled = "np:motionCoverEnabled"
        static let notchCollapsesWhenPaused = "np:notchCollapsesWhenPaused"
        static let notchShowsEqualizer = "np:notchShowsEqualizer"
        static let notchEqualizerEar = "np:notchEqualizerEar"
        static let notchExpandedShowsNextLine = "np:notchExpandedShowsNextLine"
        static let notchExpandedShowsControls = "np:notchExpandedShowsControls"
        static let notchExpandedShowsLyricsOffset = "np:notchExpandedShowsLyricsOffset"
        static let notchExpandedShowsArtwork = "np:notchExpandedShowsArtwork"
        static let notchExpandedShowsTrackTitle = "np:notchExpandedShowsTrackTitle"
        static let notchExpandedShowsArtist = "np:notchExpandedShowsArtist"
        static let notchExpandedShowsAlbum = "np:notchExpandedShowsAlbum"
        static let notchExpandedShowsQuickActions = "np:notchExpandedShowsQuickActions"
        static let notchLyricRowShowsArtwork = "np:notchLyricRowShowsArtwork"
        static let notchLyricRowArtworkPosition = "np:notchLyricRowArtworkPosition"
        static let notchLyricsAlignment = "np:notchLyricsAlignment"
        static let notchSecondaryLine = "np:notchSecondaryLine"
        static let notchFontFamilyName = "np:notchFontFamilyName"
        static let notchFontWeight = "np:notchFontWeight"
        static let notchFontSize = "np:notchFontSize"
        static let notchLeftEar = "np:notchLeftEar"
        static let notchRightEar = "np:notchRightEar"
        static let notchScreenID = "np:notchScreenID"
        static let notchAllScreens = "np:notchAllScreens"
        // Legacy overlay visibility keys migrated once in `init()` and removed.
        static let legacyClassicOverlayVisible = "np:overlayVisible"
        static let legacyNotchOverlayVisible = "np:notchOverlayVisible"
        // Serialized JSON strings for complex settings structures.
        static let customColorThemesJSON = "np:customColorThemesJSON"
        static let browserPlatformPairsJSON = "np:browserPlatformPairsJSON"
        static let manualBrowserFamiliesJSON = "np:manualBrowserFamiliesJSON"
        static let browserJSVerifiedAtJSON = "np:browserJSVerifiedAtJSON"
        /// Machine-local preference to receive beta updates.
        static let receiveBetaUpdates = "np:receiveBetaUpdates"
    }

    // Default typography values:
    // Empty string indicates system font; see `fontFamilyName` and `FontFamilyPicker`.
    static let defaultFontFamilyName = ""
    static let defaultFontSize = 31.0
    /// Default font weight tier for the desktop overlay main lyric line.
    /// Drives derived tiers across secondary lines (see `OverlayFontWeight`).
    static let defaultOverlayFontWeight: OverlayFontWeight = .semibold

    /// Whether lyrics text follows the dominant color of the current album artwork.
    /// Default is `true` (see `ColorTheme.defaultTheme`). Shared between initial setup and style reset.
    static let defaultFollowsCoverArt = true

    // Notch Reset Defaults:
    // Values restored when clicking "Reset" in the Notch lyrics toolbar.
    // Restores visual styles, ear modules, screen selection, and content toggles,
    // omitting `notchOverlayEnabled` (master toggle) and `notchContentWidth` (structural width).
    static let defaultNotchCardStyle = NotchCardStyle.coverArt
    // Notch lyrics card width defaults: steady state (252pt) and expanded state (482pt).
    static let defaultNotchContentWidth: Double = 252
    static let defaultNotchExpandedContentWidth: Double = 482
    static let defaultNotchAllScreens = false
    static let defaultNotchScreenID = ""
    /// Default ear modules: left ear artwork, right ear empty (leaving room for equalizer bars).
    static let defaultNotchLeftEar = NotchEarModule.artwork
    static let defaultNotchRightEar = NotchEarModule.none
    /// Default auto-hide settings for Notch overlay (used exclusively for reset defaults).
    static let defaultNotchHideDuringScreenCapture = false
    static let defaultNotchHideWhenNotPlaying = false
    static let defaultNotchShowLyrics = true
    /// Motion artwork (animated covers) enabled by default.
    /// Gated by Low Power Mode (`PlaybackCoordinator.refreshMotionCover`), Reduced Motion accessibility,
    /// and active presentation in the lyrics window.
    static let defaultMotionCoverEnabled = true
    /// Whether Notch card collapses when paused.
    static let defaultNotchCollapsesWhenPaused = false
    static let defaultNotchShowsEqualizer = true
    static let defaultNotchEqualizerEar = NotchEqualizerEar.right
    static let defaultNotchExpandedShowsNextLine = true
    static let defaultNotchExpandedShowsControls = true
    /// Expanded card content switches.
    static let defaultNotchExpandedShowsLyricsOffset = true
    static let defaultNotchExpandedShowsArtwork = false
    static let defaultNotchExpandedShowsTrackTitle = true
    static let defaultNotchExpandedShowsArtist = true
    static let defaultNotchExpandedShowsAlbum = true
    static let defaultNotchExpandedShowsQuickActions = true
    /// Thumbnail artwork in lyric row (disabled by default when left ear already displays artwork).
    static let defaultNotchLyricRowShowsArtwork = false
    static let defaultNotchLyricRowArtworkPosition = NotchLyricRowArtworkPosition.right
    /// Resting alignment for Notch lyrics (defaults to `.automatic` for duet part positioning).
    static let defaultNotchLyricsAlignment = LyricsRestingAlignment.automatic
    /// Secondary lyric line default: next line preview.
    static let defaultNotchSecondaryLine = LyricSecondaryLine.nextLine
    /// Notch lyrics typography defaults.
    static let defaultNotchFontFamilyName = ""
    static let defaultNotchFontWeight: OverlayFontWeight = .semibold
    static let defaultNotchFontSize = Double(NotchLyricRowMetrics.defaultMainFontSize)

    // Menu Bar Lyrics Reset Defaults:
    // Restores width mode, karaoke fill, and custom text/fill colors.
    // Omits `menuBarLyricsWidth` and `showLyricsInMenuBar`.
    static let defaultMenuBarLyricsWidthMode = MenuBarLyricsWidthMode.adaptive
    static let defaultMenuBarLyricsAlignment = LyricsRestingAlignment.leading
    static let defaultMenuBarLyricsKaraoke = true
    /// Placement of the progress icon badge relative to menu bar lyrics.
    static let defaultMenuBarLyricsIconPosition = MenuBarLyricsIconPosition.leading
    /// Hover controls toggle for menu bar status item.
    static let defaultMenuBarHoverShowsControls = false
    /// Shows title placeholder when no lyrics are available.
    static let defaultMenuBarShowsTitleWhenNoLyrics = true
    static let defaultMenuBarLyricsTextColorHex = ""
    static let defaultMenuBarLyricsFillColorHex = ""
    /// Menu bar lyrics font weight (defaults to `.regular`, matching system bar items).
    static let defaultMenuBarLyricsFontWeight = OverlayFontWeight.regular
    /// Menu bar lyrics font size (0 indicates system menu bar font size; range: 10...16).
    static let defaultMenuBarLyricsFontSize: CGFloat = 0
    /// Menu bar secondary line (defaults to next line preview).
    static let defaultMenuBarSecondaryLine = LyricSecondaryLine.nextLine

    private let defaults = UserDefaults.standard

    /// Syllable-level karaoke highlighting enabled per presentation surface.
    /// When disabled, renders line-level active state (`SyncedLyricLine.lineLevel`).
    /// The lyrics window always uses syllable-level highlighting.
    @Published var overlayLyricsKaraoke: Bool {
        didSet { defaults.set(overlayLyricsKaraoke, forKey: Keys.overlayLyricsKaraoke) }
    }
    @Published var notchLyricsKaraoke: Bool {
        didSet { defaults.set(notchLyricsKaraoke, forKey: Keys.notchLyricsKaraoke) }
    }
    /// Sticky flag indicating whether Chinese lyrics have ever been encountered.
    /// Persisted across launches to preserve script conversion UI options.
    @Published var hasSeenChineseLyrics: Bool {
        didSet { defaults.set(hasSeenChineseLyrics, forKey: Keys.hasSeenChineseLyrics) }
    }
    /// One-time prompt indicating the ⌘-drag gesture to rearrange menu bar icons.
    @Published var hasShownMenuBarPositionHint: Bool {
        didSet { defaults.set(hasShownMenuBarPositionHint, forKey: Keys.hasShownMenuBarPositionHint) }
    }

    /// Beta update channel subscription preference.
    /// When enabled, Sparkle targets pre-release GitHub releases via dedicated appcast feeds.
    /// Preserved locally on the host machine (`ConfigPortability.machineLocalDefaultsKeys`).
    /// Invokes `SparkleUpdaterManager.shared.betaChannelPreferenceChanged(enabled:)` immediately upon change.
    @Published var receiveBetaUpdates: Bool {
        didSet {
            defaults.set(receiveBetaUpdates, forKey: Keys.receiveBetaUpdates)
            SparkleUpdaterManager.shared.betaChannelPreferenceChanged(enabled: receiveBetaUpdates)
        }
    }

    /// 这台机器的用户读不读中文 —— 用系统的**首选语言列表**判,不是只看 App 界面语言:
    /// 一个把系统语言设成英文、但语言列表里加了中文的用户,照样在听中文歌。
    /// 只在启动时算一次就够了(系统语言不会在 App 运行期间变)。
    static let userReadsChinese: Bool = Locale.preferredLanguages.contains {
        $0.lowercased().hasPrefix("zh")
    }

    /// Indicates whether the user's primary preferred language is Simplified Chinese.
    /// Used for initial onboarding ordering (`PlaybackPlayer.onboardingDisplayOrder`).
    /// Evaluates script prefix matching via `UILanguage.isTraditionalChineseTag`.
    static let userReadsSimplifiedChinese: Bool = {
        guard let first = Locale.preferredLanguages.first?.lowercased(), first.hasPrefix("zh") else { return false }
        return !UILanguage.isTraditionalChineseTag(first)
    }()

    /// 歌词正文显示成简体还是繁体。默认 .off:原样显示歌词源给的写法,不做任何转换。
    @Published var lyricsChineseVariant: ChineseVariant {
        didSet { defaults.set(lyricsChineseVariant.rawValue, forKey: Keys.lyricsChineseVariant) }
    }
    @Published var showRomanization: Bool {
        didSet { defaults.set(showRomanization, forKey: Keys.showRomanization) }
    }

    /// 要给哪几种文字标罗马音(日文/韩文/中文各自可开关)。存 OptionSet 的 rawValue。
    ///
    /// 跟 showRomanization 是两层:那个是"显不显示罗马音这一行"的总开关,这个决定
    /// **哪些语言**会产出罗马音。总开关关掉时这里的选择不起作用,但也不会被清掉。
    @Published var romanizationScripts: RomanizationScripts {
        didSet { defaults.set(romanizationScripts.rawValue, forKey: Keys.romanizationScripts) }
    }
    @Published var showTranslation: Bool {
        didSet { defaults.set(showTranslation, forKey: Keys.showTranslation) }
    }
    @Published var launchAtLoginEnabled: Bool {
        didSet {
            defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled)
            LoginItemManager.shared.setEnabled(launchAtLoginEnabled)
        }
    }
    // 打开 Lyrimuse 时顺带唤起 Apple Music——只在 AppDelegate.applicationDidFinishLaunching
    // 里读一次(见那边的调用点),不是"实时生效"的开关,didSet 只负责持久化,不需要额外
    // 触发什么。默认关闭:"自动启动另一个 App"这类有侵入性的行为,不该在用户没有主动
    /// Explicit set of players to launch concurrently when Lyrimuse launches.
    /// Stored as sorted rawValue array; automatic detection is excluded.
    @Published var launchPlayersOnLyrimuseOpen: Set<PlaybackPlayer> {
        didSet { defaults.set(launchPlayersOnLyrimuseOpen.map(\.rawValue).sorted(), forKey: Keys.launchPlayersOnLyrimuseOpen) }
    }
    /// Explicit set of players whose termination triggers Lyrimuse exit.
    /// Monitored by `PlayerQuitWatcher` via `PlayerLinkage`.
    @Published var quitWithPlayers: Set<PlaybackPlayer> {
        didSet { defaults.set(quitWithPlayers.map(\.rawValue).sorted(), forKey: Keys.quitWithPlayers) }
    }
    // collector 常驻服务的装/卸开关——跟 launchAtLoginEnabled 同样的写法，但默认值不能
    // 照抄成 true:首次启动必须走一遍引导页面里的"启用"按钮，让用户看到真实的安装+验证
    // 过程，不能在 init() 阶段就静默尝试装一个 LaunchAgent。
    @Published var collectorServiceEnabled: Bool {
        didSet {
            defaults.set(collectorServiceEnabled, forKey: Keys.collectorServiceEnabled)
            CollectorServiceManager.setEnabled(collectorServiceEnabled)
        }
    }
    // 是否在 Dock 里显示图标(以及连带出现在 Cmd-Tab 里),默认 true(见下面 init() 的
    // 兜底值)。跟 launchAtLoginEnabled 同样的写法,直接在 didSet 里调用生效(而不是像
    // classicOverlayEnabled 那样只负责持久化、把"生效"这一步挪到 View 层)——
    // NSApp.setActivationPolicy 是纯 AppKit 调用,不依赖任何其它单例,不存在
    // "AppSettings.init() 时那个单例还没构造好"的循环初始化风险,可以放心直接在这里调用。
    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: Keys.showInDock)
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        }
    }
    @Published var showNextLinePreview: Bool {
        didSet { defaults.set(showNextLinePreview, forKey: Keys.showNextLinePreview) }
    }
    /// Duet alignment override for the floating lyrics overlay (`LyricsOverlayView`).
    /// See `OverlayDuetAlignmentOverride` for role separation across consumer components.
    @Published var overlayDuetAlignmentOverride: OverlayDuetAlignmentOverride {
        didSet {
            defaults.set(overlayDuetAlignmentOverride.rawValue, forKey: Keys.overlayDuetAlignmentOverride)
        }
    }
    // 默认关闭:状态栏平时只是个不起眼的小图标,打开后会换成当前歌词行的文字,占用
    // 面积明显变大——不应该在谁都没主动选择的情况下就改变状态栏原有的观感。
    @Published var showLyricsInMenuBar: Bool {
        didSet { defaults.set(showLyricsInMenuBar, forKey: Keys.showLyricsInMenuBar) }
    }
    // 状态栏歌词行超过这个字数就截断+悬停 tooltip 补全,不超过就整行显示——做成可调的
    // 上限而不是写死一个数字。
    // ⚠️ 已经没有读取方了,只为兼容老配置文件保留(见下面 menuBarLyricsWidth)。
    @Published var menuBarLyricsMaxChars: Int {
        didSet { defaults.set(menuBarLyricsMaxChars, forKey: Keys.menuBarLyricsMaxChars) }
    }
    // Menu bar lyrics slot width (in points).
    // In fixed width mode, allocates a constant footprint across changing line lengths
    // to prevent jitter in adjacent status bar items.
    @Published var menuBarLyricsWidth: CGFloat {
        didSet { defaults.set(Double(menuBarLyricsWidth), forKey: Keys.menuBarLyricsWidth) }
    }
    /// Alignment for short lines fitting within the fixed slot width (see `LyricsRestingAlignment`).
    @Published var menuBarLyricsAlignment: LyricsRestingAlignment {
        didSet { defaults.set(menuBarLyricsAlignment.rawValue, forKey: Keys.menuBarLyricsAlignment) }
    }
    @Published var menuBarLyricsWidthMode: MenuBarLyricsWidthMode {
        didSet { defaults.set(menuBarLyricsWidthMode.rawValue, forKey: Keys.menuBarLyricsWidthMode) }
    }
    // Syllable-level karaoke highlighting in menu bar lyrics.
    // Active only for lyrics with syllable-level timing; plain LRC falls back to line-level highlighting.
    @Published var menuBarLyricsKaraoke: Bool {
        didSet { defaults.set(menuBarLyricsKaraoke, forKey: Keys.menuBarLyricsKaraoke) }
    }
    // Custom text and fill colors for menu bar lyrics (empty string follows system appearance).
    @Published var menuBarLyricsTextColorHex: String {
        didSet { defaults.set(menuBarLyricsTextColorHex, forKey: Keys.menuBarLyricsTextColorHex) }
    }
    @Published var menuBarLyricsFillColorHex: String {
        didSet { defaults.set(menuBarLyricsFillColorHex, forKey: Keys.menuBarLyricsFillColorHex) }
    }
    // Placement of the progress icon badge relative to menu bar lyrics (off = disabled).
    @Published var menuBarLyricsIconPosition: MenuBarLyricsIconPosition {
        didSet {
            defaults.set(menuBarLyricsIconPosition.rawValue, forKey: Keys.menuBarLyricsIconPosition)
        }
    }
    /// Menu bar lyrics font weight (see `defaultMenuBarLyricsFontWeight`).
    @Published var menuBarLyricsFontWeight: OverlayFontWeight {
        didSet { defaults.set(menuBarLyricsFontWeight.rawValue, forKey: Keys.menuBarLyricsFontWeight) }
    }
    /// Menu bar lyrics font size (0 indicates system menu bar font size).
    @Published var menuBarLyricsFontSize: CGFloat {
        didSet { defaults.set(Double(menuBarLyricsFontSize), forKey: Keys.menuBarLyricsFontSize) }
    }
    /// Secondary line displayed below main menu bar lyric line (see `LyricSecondaryLine`).
    @Published var menuBarSecondaryLine: LyricSecondaryLine {
        didSet { defaults.set(menuBarSecondaryLine.rawValue, forKey: Keys.menuBarSecondaryLine) }
    }
    /// Replaces lyrics with playback controls (previous / play-pause / next) when hovering over status item.
    @Published var menuBarHoverShowsControls: Bool {
        didSet { defaults.set(menuBarHoverShowsControls, forKey: Keys.menuBarHoverShowsControls) }
    }
    // Displays "♪ Track Title" placeholder in menu bar when no lyrics are available.
    // Governed by `MenuBarSlotPolicy.displayText` in LyrimuseCore.
    @Published var menuBarShowsTitleWhenNoLyrics: Bool {
        didSet { defaults.set(menuBarShowsTitleWhenNoLyrics, forKey: Keys.menuBarShowsTitleWhenNoLyrics) }
    }
    // 菜单栏那个图标长什么样。它只在**没在显示歌词**时出现(没在放歌、还没解析出这一句、
    // 或者菜单栏歌词整个关掉),所以它跟上面那些宽度设置是两回事,不受它们影响。
    @Published var menuBarIconStyle: MenuBarIconStyle {
        didSet { defaults.set(menuBarIconStyle.rawValue, forKey: Keys.menuBarIconStyle) }
    }
    // 播放时菜单栏图标是否律动(音条跳动/卡拉OK扫色/声波流动/其余轻微摇摆,见
    // MenuBarLiveIconView)。暂停/无播放永远静止,这个开关只管"播放时动不动"。
    @Published var menuBarIconAnimates: Bool {
        didSet { defaults.set(menuBarIconAnimates, forKey: Keys.menuBarIconAnimates) }
    }
    // 悬浮窗背景透明,文字直接叠在桌面内容上——桌面壁纸/其它窗口文字撞色时容易糊在一起,
    // 加个描边提高辨识度。纯展示开关,LyricsOverlayView 每次渲染都直接读这个值,不需要
    // 像 lockPosition/hideDuringScreenCapture 那样额外调用某个单例的方法"生效"。
    //
    // 描边(非模糊阴影)效果参考了 katagaki/DJDX 仓库的 Canvas+alphaThreshold+blur
    // 技术(见 LyricsOverlayView.swift 的 OptionalTextStroke)。UserDefaults key 没有
    // 保留旧名做迁移——本机单用户的本地设置,旧值语义已经对不上新的渲染方式,不如直接
    // 改名、重新走一遍默认值。
    @Published var textStrokeEnabled: Bool {
        didSet { defaults.set(textStrokeEnabled, forKey: Keys.textStrokeEnabled) }
    }
    // #RRGGBBAA。只让用户调"颜色"(含 alpha),描边粗细是代码里的固定常量
    // (OptionalTextStroke 的 width,1.2pt),不做成单独的滑杆——同类实现普遍也只开一个
    // 带 alpha 的取色器,保持这个克制的取舍。默认 #000000A6(黑色、
    // alpha≈0.65),没碰过这个设置的人从阴影切到描边后颜色不会跳变。
    @Published var textStrokeColorHex: String {
        didSet {
            defaults.set(textStrokeColorHex, forKey: Keys.textStrokeColorHex)
            textStrokeColor = Color(hexWithAlpha: textStrokeColorHex, fallback: .black.opacity(0.65))
        }
    }
    // 只负责持久化——不在这里连带调 LyricsOverlayWindowController.shared.setLocked(_:),
    // 那样会在 AppSettings 自己的 init() 里触发 didSet、顺带在其它单例还没构造完成时
    // 去访问它,有循环初始化风险。"生效"这一步挪到 SettingsView.swift 的 Toggle
    // Binding 里手动分两步调用。
    @Published var lockPosition: Bool {
        didSet { defaults.set(lockPosition, forKey: Keys.lockPosition) }
    }
    // Window sharing type mechanism: hides desktop overlay window during screen capture/recordings.
    // Applies exclusively to the desktop lyrics overlay; Notch overlay uses `notchHideDuringScreenCapture`.
    @Published var hideDuringScreenCapture: Bool {
        didSet { defaults.set(hideDuringScreenCapture, forKey: Keys.hideDuringScreenCapture) }
    }
    // Automatically hides the desktop overlay when playback is paused or inactive.
    // Applies exclusively to the desktop lyrics overlay; Notch overlay uses `notchHideWhenNotPlaying`.
    @Published var hideWhenNotPlaying: Bool {
        didSet { defaults.set(hideWhenNotPlaying, forKey: Keys.hideWhenNotPlaying) }
    }
    // Independent auto-hide preferences for the Notch lyrics overlay.
    @Published var notchHideDuringScreenCapture: Bool {
        didSet { defaults.set(notchHideDuringScreenCapture, forKey: Keys.notchHideDuringScreenCapture) }
    }
    @Published var notchHideWhenNotPlaying: Bool {
        didSet { defaults.set(notchHideWhenNotPlaying, forKey: Keys.notchHideWhenNotPlaying) }
    }
    // Fades the desktop lyrics overlay out when hovered by mouse pointer, fading back in upon exit.
    // Applies exclusively to the desktop lyrics overlay.
    @Published var overlayFadeOnHover: Bool {
        didSet { defaults.set(overlayFadeOnHover, forKey: Keys.overlayFadeOnHover) }
    }
    /// Whether moving the desktop overlay requires a 0.35s long press prior to dragging.
    /// When disabled, dragging initiates immediately upon clicking text while surrounding padding clicks pass through.
    @Published var overlayDragNeedsLongPress: Bool {
        didSet { defaults.set(overlayDragNeedsLongPress, forKey: Keys.overlayDragNeedsLongPress) }
    }
    /// Placement preset mode for desktop lyrics (see `OverlayPlacementMode`: free, top center, bottom center).
    @Published var overlayPlacementMode: OverlayPlacementMode {
        didSet { defaults.set(overlayPlacementMode.rawValue, forKey: Keys.overlayPlacementMode) }
    }
    // Diagnostic HUD displaying real-time rendering frame rate (FrameRateProbe).
    // Configured via user defaults: `defaults write me.yudaotor.lyrimuse np:debugHUD -bool true`.
    @Published var debugHUDEnabled: Bool {
        didSet { defaults.set(debugHUDEnabled, forKey: Keys.debugHUDEnabled) }
    }
    // App interface language override ("system", "zh-hans", "en").
    @Published var appLanguage: String {
        didSet { defaults.set(appLanguage, forKey: Keys.appLanguage) }
    }
    // Step size in milliseconds for manual lyric timing offset adjustments.
    @Published var lyricsOffsetStepMs: Int {
        didSet { defaults.set(lyricsOffsetStepMs, forKey: Keys.lyricsOffsetStepMs) }
    }
    // When enabled, adopting candidate lyrics marks the track as `manual_lyrics` to freeze it
    // against future automatic background refetches and rescording.
    // Toggling prompts retroactive application across existing cache entries (see `ManualPickLock`).
    @Published var manualPickLocksLyrics: Bool {
        didSet { defaults.set(manualPickLocksLyrics, forKey: Keys.manualPickLocksLyrics) }
    }
    // Tracks onboarding completion; set only when completing the full wizard flow.
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }
    // 首次启动时"在 iCloud 里发现一份配置,要导入吗"这一问只问一次。
    //
    // 必须有这个标记,否则会死循环:导入之后要重启才生效,而 hasCompletedOnboarding 是
    // 刻意不跟着导出走的(新机器本该自己走一遍引导,见 ConfigPortability 注释),重启后
    // 它仍然是 false、iCloud 里那份配置也仍然在,于是又弹一次同样的问题。
    //
    // 跟 hasCompletedOnboarding 同类:属于"这台机器的状态",所以同样被排除在导出之外。
    @Published var hasOfferedICloudImport: Bool {
        didSet { defaults.set(hasOfferedICloudImport, forKey: Keys.hasOfferedICloudImport) }
    }
    // 桌面悬浮歌词(经典悬浮窗)、灵动岛歌词各自独立开关,互不排斥——两者对应完全独立的
    // 窗口控制器(LyricsOverlayWindowController/NotchLyricsWindowController),可以
    // 同时开、同时关、或者只开一个(原来是互斥的单选"悬浮窗样式",迁移逻辑见下方
    // init())。只负责持久化,原因跟 lockPosition 等既有窗口相关设置一样——"生效"这
    // 一步(setVisible)挪到 SettingsView.swift 的 Toggle Binding.set 里手动调用,不在
    // 这里的 didSet 里连带触发,避免在 AppSettings.init() 给这两个属性赋初值时就去访问
    // 两个窗口控制器单例、有循环初始化风险。
    @Published var classicOverlayEnabled: Bool {
        didSet { defaults.set(classicOverlayEnabled, forKey: Keys.classicOverlayEnabled) }
    }
    @Published var notchOverlayEnabled: Bool {
        didSet { defaults.set(notchOverlayEnabled, forKey: Keys.notchOverlayEnabled) }
    }
    // 灵动岛卡片的视觉风格——默认磨砂玻璃。只负责持久化,纯展示用的设置,
    // NotchLyricsView 每次渲染直接读这个值,不需要像 classicOverlayEnabled 那样在
    // didSet 里连带调用某个单例的方法。
    /// 每块屏都显示一个灵动岛(默认关:绝大多数人只在眼前那块屏上看)。
    @Published var notchAllScreens: Bool {
        didSet { defaults.set(notchAllScreens, forKey: Keys.notchAllScreens) }
    }

    // Notch card visual style (defaults to `.coverArt`).
    @Published var notchCardStyle: NotchCardStyle {
        didSet { defaults.set(notchCardStyle.rawValue, forKey: Keys.notchCardStyle) }
    }
    /// Whether Notch card renders the lyric row.
    /// When disabled, the card collapses vertically to status bar height along the notch,
    /// while retaining hover expansion for playback controls, scrubber, and preview.
    /// Governed by `NotchChromeSource.showsLyrics` / `showsLyricRow`.
    @Published var notchShowLyrics: Bool {
        didSet { defaults.set(notchShowLyrics, forKey: Keys.notchShowLyrics) }
    }
    /// Enables animated motion artwork for albums with dynamic covers in the lyrics window artwork card.
    /// Gated by Low Power Mode (`PlaybackCoordinator.refreshMotionCover`) and Reduced Motion accessibility.
    @Published var motionCoverEnabled: Bool {
        didSet { defaults.set(motionCoverEnabled, forKey: Keys.motionCoverEnabled) }
    }
    /// Whether Notch card collapses to the minimal pill when paused or during ad breaks.
    /// When disabled, the card retains steady or expanded dimensions while paused.
    /// Governed by `NotchLyricsWindowController.isCollapsed`.
    @Published var notchCollapsesWhenPaused: Bool {
        didSet { defaults.set(notchCollapsesWhenPaused, forKey: Keys.notchCollapsesWhenPaused) }
    }
    /// Displays playback equalizer bars.
    @Published var notchShowsEqualizer: Bool {
        didSet { defaults.set(notchShowsEqualizer, forKey: Keys.notchShowsEqualizer) }
    }
    /// Outer ear placement for equalizer bars (left or right).
    @Published var notchEqualizerEar: NotchEqualizerEar {
        didSet { defaults.set(notchEqualizerEar.rawValue, forKey: Keys.notchEqualizerEar) }
    }

    // MARK: - Notch Expanded State

    /// Shows next-line lyric preview in expanded hover card.
    @Published var notchExpandedShowsNextLine: Bool {
        didSet { defaults.set(notchExpandedShowsNextLine, forKey: Keys.notchExpandedShowsNextLine) }
    }
    /// Shows playback control buttons (previous / play-pause / next) in expanded hover card.
    @Published var notchExpandedShowsControls: Bool {
        didSet { defaults.set(notchExpandedShowsControls, forKey: Keys.notchExpandedShowsControls) }
    }
    /// Shows lyric sync offset adjustment buttons within the time scrubber row.
    @Published var notchExpandedShowsLyricsOffset: Bool {
        didSet { defaults.set(notchExpandedShowsLyricsOffset, forKey: Keys.notchExpandedShowsLyricsOffset) }
    }
    /// Shows track artwork thumbnail in the expanded track info header.
    @Published var notchExpandedShowsArtwork: Bool {
        didSet { defaults.set(notchExpandedShowsArtwork, forKey: Keys.notchExpandedShowsArtwork) }
    }
    /// Shows track title in expanded track info header.
    @Published var notchExpandedShowsTrackTitle: Bool {
        didSet { defaults.set(notchExpandedShowsTrackTitle, forKey: Keys.notchExpandedShowsTrackTitle) }
    }
    /// Shows artist in expanded track info header.
    @Published var notchExpandedShowsArtist: Bool {
        didSet { defaults.set(notchExpandedShowsArtist, forKey: Keys.notchExpandedShowsArtist) }
    }
    /// Shows album in expanded track info header.
    @Published var notchExpandedShowsAlbum: Bool {
        didSet { defaults.set(notchExpandedShowsAlbum, forKey: Keys.notchExpandedShowsAlbum) }
    }
    /// Shows quick action buttons (search, display lyrics, settings, close) in expanded track info header.
    @Published var notchExpandedShowsQuickActions: Bool {
        didSet { defaults.set(notchExpandedShowsQuickActions, forKey: Keys.notchExpandedShowsQuickActions) }
    }

    /// Shows artwork thumbnail in the Notch lyrics row.
    @Published var notchLyricRowShowsArtwork: Bool {
        didSet { defaults.set(notchLyricRowShowsArtwork, forKey: Keys.notchLyricRowShowsArtwork) }
    }
    /// Horizontal placement (left or right) of the lyric row artwork thumbnail.
    @Published var notchLyricRowArtworkPosition: NotchLyricRowArtworkPosition {
        didSet { defaults.set(notchLyricRowArtworkPosition.rawValue, forKey: Keys.notchLyricRowArtworkPosition) }
    }
    /// Resting alignment for Notch lyric lines that fit within the available width (see `LyricsRestingAlignment`).
    @Published var notchLyricsAlignment: LyricsRestingAlignment {
        didSet { defaults.set(notchLyricsAlignment.rawValue, forKey: Keys.notchLyricsAlignment) }
    }
    /// Secondary line displayed beneath the main lyric line in Notch lyrics row (see `LyricSecondaryLine`).
    @Published var notchSecondaryLine: LyricSecondaryLine {
        didSet { defaults.set(notchSecondaryLine.rawValue, forKey: Keys.notchSecondaryLine) }
    }
    /// Notch lyrics typography settings (font family, weight tier, and font size).
    /// Applies to lyric text; ear modules, track info header, and buttons retain system styling.
    @Published var notchFontFamilyName: String {
        didSet {
            defaults.set(notchFontFamilyName, forKey: Keys.notchFontFamilyName)
            recomputeNotchFonts()
        }
    }
    @Published var notchFontWeight: OverlayFontWeight {
        didSet {
            defaults.set(notchFontWeight.rawValue, forKey: Keys.notchFontWeight)
            recomputeNotchFonts()
        }
    }
    /// Main line font size (in points). Clamped within `NotchLyricRowMetrics.mainFontSizeRange`.
    @Published var notchFontSize: Double {
        didSet {
            defaults.set(notchFontSize, forKey: Keys.notchFontSize)
            recomputeNotchFonts()
        }
    }

    @Published var notchLeftEar: NotchEarModule {
        didSet { defaults.set(notchLeftEar.rawValue, forKey: Keys.notchLeftEar) }
    }
    @Published var notchRightEar: NotchEarModule {
        didSet { defaults.set(notchRightEar.rawValue, forKey: Keys.notchRightEar) }
    }
    // Target display screen UUID for Notch overlay; empty string selects built-in notch display automatically.
    @Published var notchScreenID: String {
        didSet { defaults.set(notchScreenID, forKey: Keys.notchScreenID) }
    }
    // Typography settings for desktop lyrics overlay. Empty string indicates system font.
    @Published var fontFamilyName: String {
        didSet {
            defaults.set(fontFamilyName, forKey: Keys.fontFamilyName)
            recomputeFonts()
        }
    }
    // Main lyric line font size in points; secondary lines scale proportionally.
    @Published var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: Keys.fontSize)
            recomputeFonts()
        }
    }
    // Font weight tier for main lyric line (see `OverlayFontWeight`).
    @Published var overlayFontWeight: OverlayFontWeight {
        didSet {
            defaults.set(overlayFontWeight.rawValue, forKey: Keys.overlayFontWeight)
            recomputeFonts()
        }
    }
    // 悬浮窗宽度(pt)。字号已经能调到 36pt,宽度却一直写死 640——字号调大后长歌词行
    // 很快就得换行,这里加个滑块让宽度也能跟着字号/个人喜好调。只在 didSet 里通知
    // WindowController 实时应用,不在这个 model 层直接碰 NSWindow(跟 lockPosition 等
    // 既有窗口相关设置同一个模式,由 SettingsView 里的 Binding.set 显式调用)。
    @Published var overlayWidth: Double {
        didSet { defaults.set(overlayWidth, forKey: Keys.overlayWidth) }
    }
    // 灵动岛歌词的固定宽度(pt)——同一个模式:只在 didSet 里持久化,不在这个 model 层
    // 直接碰 NSWindow,实时应用交给 SettingsView 的 Binding.set 显式调
    // NotchLyricsWindowController.shared.applyContentWidthSetting()。灵动岛宽度不跟着
    // 歌词内容变化,保持固定。
    @Published var notchContentWidth: Double {
        didSet { defaults.set(notchContentWidth, forKey: Keys.notchContentWidth) }
    }
    /// Notch card width when hovered / expanded (points).
    /// Bound by `NotchWidthBounds` (expanded ≥ steady). Applied dynamically via
    /// `NotchLyricsWindowController.shared.applyContentWidthSetting()`.
    @Published var notchExpandedContentWidth: Double {
        didSet { defaults.set(notchExpandedContentWidth, forKey: Keys.notchExpandedContentWidth) }
    }
    /// Foreground text color hex (#RRGGBBAA). Default derived from `ColorTheme.defaultTheme`.
    @Published var foregroundColorHex: String {
        didSet {
            defaults.set(foregroundColorHex, forKey: Keys.foregroundColorHex)
            foregroundColor = Color(hexWithAlpha: foregroundColorHex, fallback: .white)
        }
    }
    // #RRGGBBAA。默认 alpha=0(全透明),保留"没有背景、文字直接浮在桌面上"的原有观感——
    // 没主动去设置面板改过的人,悬浮窗外观应该跟改动前逐像素一致。
    @Published var backgroundColorHex: String {
        didSet {
            defaults.set(backgroundColorHex, forKey: Keys.backgroundColorHex)
            backgroundColor = Color(hexWithAlpha: backgroundColorHex, fallback: .clear)
            backgroundIsVisible = Self.backgroundVisible(hex: backgroundColorHex, glass: overlayBackgroundGlass)
        }
    }
    /// Background system blur material (`.regularMaterial`) under the lyrics card.
    /// When enabled, `backgroundColorHex` tints over the glass material.
    @Published var overlayBackgroundGlass: Bool {
        didSet {
            defaults.set(overlayBackgroundGlass, forKey: Keys.overlayBackgroundGlass)
            backgroundIsVisible = Self.backgroundVisible(hex: backgroundColorHex, glass: overlayBackgroundGlass)
        }
    }
    /// 「背景可见」= 背景色 alpha > 0.02 **或**毛玻璃开着。三处联动都读它:窗口阴影
    /// (LyricsOverlayWindowController)、拖拽捕获层(LyricsOverlayView.overlayBackground)、
    /// 编辑台的虚线边界(OverlayEditorStage)。玻璃是一块实打实的卡片,阴影和边界的语义跟纯色一致。
    static func backgroundVisible(hex: String, glass: Bool) -> Bool {
        glass || (NSColor(hexStringWithAlpha: hex)?.alphaComponent ?? 0) > 0.02
    }
    // 见 Keys.followsCoverArt 注释。纯持久化,不在这里连带计算任何缓存值——实际生效
    // 靠 PlaybackCoordinator.displayForegroundColor 读取这个开关+按曲目算出的动态色,
    // 跟 foregroundColorHex/backgroundColorHex 那种"存 hex→didSet 里转 Color 缓存"的
    // 模式不一样,因为这个开关本身不是一个颜色值。
    @Published var followsCoverArt: Bool {
        didSet { defaults.set(followsCoverArt, forKey: Keys.followsCoverArt) }
    }
    // 用户在"外观"设置里"把当前配色存为新主题"存下的自定义配色主题列表(ColorTheme.swift)——
    // 跟内置预设(ColorTheme.builtInPresets,不持久化、每次都是同一份字面量)分开存放,
    // 这里只放用户自己存的那些。JSON 编码成字符串持久化的理由见 Keys.customColorThemesJSON
    // 注释。
    @Published var customColorThemes: [ColorTheme] {
        didSet {
            let json = (try? JSONEncoder().encode(customColorThemes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            defaults.set(json, forKey: Keys.customColorThemesJSON)
        }
    }
    // 设置页"浏览器歌词同步"卡片:哪个网页音乐平台(BrowserPositionProbe.supportedPlatforms
    // 的 id)配对了哪些浏览器(FeatureSettingsStore.trustedPlayers 的 bundle id)。只是
    // AppSettings 这边的持久化——真正让探针生效要靠 SettingsView 双写进
    // BrowserPositionProbe.shared.platformBrowserPairs(跟 romanizationScripts 同一个模式,
    // 见那边注释),这个属性本身不会被 LyrimuseCore 直接读到。
    @Published var browserPlatformPairs: [String: Set<String>] {
        didSet {
            let json = (try? JSONEncoder().encode(browserPlatformPairs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            defaults.set(json, forKey: Keys.browserPlatformPairsJSON)
        }
    }

    /// Manually added browser bundle identifiers mapped to their detected engine family rawValue.
    /// Avoids repeated bundle inspection on application launch; validated against `isInstalled`.
    /// Synced to `BrowserAutomationPermission.manuallyAddedFamilies`.
    @Published var manualBrowserFamilies: [String: String] {
        didSet {
            let json = (try? JSONEncoder().encode(manualBrowserFamilies)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            defaults.set(json, forKey: Keys.manualBrowserFamiliesJSON)
        }
    }

    /// Timestamp when browser JavaScript automation permissions were last successfully verified per bundle ID.
    /// Chromium-based browsers store permission state in user profile `Preferences` requiring Full Disk Access to inspect directly.
    /// To avoid ambiguous state without invasive disk permissions, verification timestamps record point-in-time validation.
    /// The UI reflects this verification time rather than asserting persistent real-time state, allowing manual re-verification.
    @Published var browserJSVerifiedAt: [String: Date] {
        didSet {
            let json = (try? JSONEncoder().encode(browserJSVerifiedAt)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            defaults.set(json, forKey: Keys.browserJSVerifiedAtJSON)
        }
    }

    // 缓存值——LyricsOverlayView.body 随 poller.currentLine 每 50ms 重跑一次(逐字填色
    // 需要),不应该每次渲染都重新解析 hex 字符串/重新查 NSFontManager(会在换行瞬间跟
    // 换行动画的重新挂载撞在同一帧、造成卡顿感)。只在真正的输入(字体/字号/颜色四个
    // 字段)变化时的 didSet 里重算一次,渲染路径只读这些已经算好的值。
    @Published private(set) var foregroundColor: Color = .white
    @Published private(set) var backgroundColor: Color = .clear
    @Published private(set) var backgroundIsVisible: Bool = false
    @Published private(set) var textStrokeColor: Color = .black.opacity(0.65)
    @Published private(set) var mainFont: Font = .system(size: 20, weight: .bold)
    @Published private(set) var romanizationFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var translationFont: Font = .system(size: 14, weight: .regular)
    @Published private(set) var previewFont: Font = .system(size: 14, weight: .medium)
    /// Derived typography for notch lyrics display: main line, detail countdown, and secondary preview.
    /// Recomputed whenever notch typography settings change.
    @Published private(set) var notchMainFont: Font = .system(size: 13, weight: .semibold)
    @Published private(set) var notchMainDetailFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var notchSecondaryFont: Font = .system(size: 11, weight: .medium)

    /// Derives overlay font weights across primary, romanization, translation, and preview lines.
    private func recomputeFonts() {
        let weight = overlayFontWeight
        mainFont = .overlayFont(
            familyName: fontFamilyName, size: CGFloat(fontSize), weight: weight)
        romanizationFont = .overlayFont(
            familyName: fontFamilyName, size: CGFloat(fontSize) * 0.65,
            weight: weight.lighter(by: OverlayFontWeight.romanizationSteps))
        translationFont = .overlayFont(
            familyName: fontFamilyName, size: CGFloat(fontSize) * 0.7,
            weight: weight.lighter(by: OverlayFontWeight.translationSteps))
        previewFont = .overlayFont(
            familyName: fontFamilyName, size: CGFloat(fontSize) * 0.7,
            weight: weight.lighter(by: OverlayFontWeight.nextLinePreviewSteps))
    }

    /// Derives notch typography for primary, detail, and secondary tiers with bounds clamping.
    private func recomputeNotchFonts() {
        let family = notchFontFamilyName
        let size = NotchLyricRowMetrics.clampedMainFontSize(CGFloat(notchFontSize))
        let weight = notchFontWeight
        let lighter = weight.lighter(by: OverlayFontWeight.notchSecondarySteps)
        notchMainFont = .overlayFont(familyName: family, size: size, weight: weight)
        notchMainDetailFont = .overlayFont(familyName: family, size: size, weight: lighter)
        notchSecondaryFont = .overlayFont(
            familyName: family, size: NotchLyricRowMetrics.secondaryFontSize, weight: lighter)
    }

    private init() {
        // One-time migration: split global karaoke toggle into overlay and notch toggles.
        // If legacy global toggle was disabled, retain disabled state for both surfaces.
        // Persist immediately since property assignment within init() bypasses didSet observers.
        let legacyKaraoke = defaults.object(forKey: Keys.preferWordLevelKaraoke) as? Bool
        let overlayKaraoke = (defaults.object(forKey: Keys.overlayLyricsKaraoke) as? Bool) ?? legacyKaraoke ?? true
        let notchKaraoke = (defaults.object(forKey: Keys.notchLyricsKaraoke) as? Bool) ?? legacyKaraoke ?? true
        overlayLyricsKaraoke = overlayKaraoke
        notchLyricsKaraoke = notchKaraoke
        if legacyKaraoke != nil {
            defaults.set(overlayKaraoke, forKey: Keys.overlayLyricsKaraoke)
            defaults.set(notchKaraoke, forKey: Keys.notchLyricsKaraoke)
        }
        lyricsChineseVariant = defaults.string(forKey: Keys.lyricsChineseVariant)
            .flatMap(ChineseVariant.init(rawValue:)) ?? .off
        hasSeenChineseLyrics = defaults.bool(forKey: Keys.hasSeenChineseLyrics)
        hasShownMenuBarPositionHint = defaults.bool(forKey: Keys.hasShownMenuBarPositionHint)
        showRomanization = (defaults.object(forKey: Keys.showRomanization) as? Bool) ?? true
        // Defaults to `.default` (all romanization scripts enabled).
        romanizationScripts = (defaults.object(forKey: Keys.romanizationScripts) as? Int)
            .map(RomanizationScripts.init(rawValue:)) ?? .default
        // Default translation state links to preferred interface language: enabled if user reads Chinese.
        // Chinese lyrics sources (Netease, QQ Music) provide Chinese translations.
        showTranslation = (defaults.object(forKey: Keys.showTranslation) as? Bool) ?? Self.userReadsChinese
        // Default enabled. Registered with login items in AppDelegate.applicationDidFinishLaunching.
        launchAtLoginEnabled = (defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool) ?? true
        receiveBetaUpdates = (defaults.object(forKey: Keys.receiveBetaUpdates) as? Bool) ?? false
        if let raw = defaults.array(forKey: Keys.launchPlayersOnLyrimuseOpen) as? [String] {
            launchPlayersOnLyrimuseOpen = Set(raw.compactMap(PlaybackPlayer.init(rawValue:)))
        } else {
            // One-time migration from legacy single-player boolean toggle to player set.
            let legacy = (defaults.object(forKey: Keys.launchMusicOnLyrimuseOpen) as? Bool) ?? false
            launchPlayersOnLyrimuseOpen = PlayerLinkage.migratedLaunchSet(
                legacyEnabled: legacy, selectedPlayers: PlaybackPlayerPreference.selected, requiresSole: true)
        }
        quitWithPlayers = Set(((defaults.array(forKey: Keys.quitWithPlayers) as? [String]) ?? [])
            .compactMap(PlaybackPlayer.init(rawValue:)))
        collectorServiceEnabled = (defaults.object(forKey: Keys.collectorServiceEnabled) as? Bool) ?? false
        showInDock = (defaults.object(forKey: Keys.showInDock) as? Bool) ?? true
        // 默认开。多显示一句下文对跟读几乎总是有用的,而这一项本身不占额外窗口高度。
        showNextLinePreview = (defaults.object(forKey: Keys.showNextLinePreview) as? Bool) ?? true
        overlayDuetAlignmentOverride = defaults.string(forKey: Keys.overlayDuetAlignmentOverride)
            .flatMap(OverlayDuetAlignmentOverride.init(rawValue:)) ?? .automatic
        showLyricsInMenuBar = (defaults.object(forKey: Keys.showLyricsInMenuBar) as? Bool) ?? false
        menuBarLyricsMaxChars = (defaults.object(forKey: Keys.menuBarLyricsMaxChars) as? Int) ?? 60
        // Default 250pt: preserves menu bar balance without crowding adjacent items.
        // Excluded from toolbar reset to preserve user-specified layout dimensions.
        menuBarLyricsWidth = CGFloat(
            (defaults.object(forKey: Keys.menuBarLyricsWidth) as? Double) ?? 250)
        menuBarLyricsWidthMode = defaults.string(forKey: Keys.menuBarLyricsWidthMode)
            .flatMap(MenuBarLyricsWidthMode.init(rawValue:)) ?? Self.defaultMenuBarLyricsWidthMode
        menuBarLyricsAlignment = defaults.string(forKey: Keys.menuBarLyricsAlignment)
            .flatMap(LyricsRestingAlignment.init(rawValue:)) ?? Self.defaultMenuBarLyricsAlignment
        // Defaults to enabled if karaoke data is available.
        menuBarLyricsKaraoke = (defaults.object(forKey: Keys.menuBarLyricsKaraoke) as? Bool) ?? Self.defaultMenuBarLyricsKaraoke
        // Legacy migration: retain disabled state if legacy global toggle was explicitly disabled.
        if legacyKaraoke == false {
            menuBarLyricsKaraoke = false
            defaults.set(false, forKey: Keys.menuBarLyricsKaraoke)
        }
        menuBarLyricsTextColorHex = defaults.string(forKey: Keys.menuBarLyricsTextColorHex) ?? Self.defaultMenuBarLyricsTextColorHex
        menuBarLyricsFillColorHex = defaults.string(forKey: Keys.menuBarLyricsFillColorHex) ?? Self.defaultMenuBarLyricsFillColorHex
        menuBarLyricsIconPosition = defaults.string(forKey: Keys.menuBarLyricsIconPosition)
            .flatMap(MenuBarLyricsIconPosition.init(rawValue:)) ?? Self.defaultMenuBarLyricsIconPosition
        menuBarLyricsFontWeight = defaults.string(forKey: Keys.menuBarLyricsFontWeight)
            .flatMap(OverlayFontWeight.init(rawValue:)) ?? Self.defaultMenuBarLyricsFontWeight
        menuBarLyricsFontSize = CGFloat(
            (defaults.object(forKey: Keys.menuBarLyricsFontSize) as? Double) ?? Double(Self.defaultMenuBarLyricsFontSize))
        menuBarSecondaryLine = defaults.string(forKey: Keys.menuBarSecondaryLine)
            .flatMap(LyricSecondaryLine.init(rawValue:)) ?? Self.defaultMenuBarSecondaryLine
        menuBarHoverShowsControls = (defaults.object(forKey: Keys.menuBarHoverShowsControls) as? Bool)
            ?? Self.defaultMenuBarHoverShowsControls
        menuBarShowsTitleWhenNoLyrics = (defaults.object(forKey: Keys.menuBarShowsTitleWhenNoLyrics) as? Bool)
            ?? Self.defaultMenuBarShowsTitleWhenNoLyrics
        menuBarIconStyle = defaults.string(forKey: Keys.menuBarIconStyle)
            .flatMap(MenuBarIconStyle.init(rawValue:)) ?? .default
        menuBarIconAnimates = (defaults.object(forKey: Keys.menuBarIconAnimates) as? Bool) ?? true
        lyricsOffsetStepMs = (defaults.object(forKey: Keys.lyricsOffsetStepMs) as? Int) ?? 200
        manualPickLocksLyrics = (defaults.object(forKey: Keys.manualPickLocksLyrics) as? Bool) ?? false
        textStrokeEnabled = (defaults.object(forKey: Keys.textStrokeEnabled) as? Bool) ?? ColorTheme.defaultTheme.textStrokeEnabled
        overlayBackgroundGlass = (defaults.object(forKey: Keys.overlayBackgroundGlass) as? Bool) ?? false
        textStrokeColorHex = defaults.string(forKey: Keys.textStrokeColorHex) ?? ColorTheme.defaultTheme.textStrokeColorHex
        lockPosition = (defaults.object(forKey: Keys.lockPosition) as? Bool) ?? false
        overlayFadeOnHover = (defaults.object(forKey: Keys.overlayFadeOnHover) as? Bool) ?? false
        overlayDragNeedsLongPress =
            (defaults.object(forKey: Keys.overlayDragNeedsLongPress) as? Bool) ?? false
        overlayPlacementMode = defaults.string(forKey: Keys.overlayPlacementMode)
            .flatMap(OverlayPlacementMode.init(rawValue:)) ?? .free
        debugHUDEnabled = (defaults.object(forKey: Keys.debugHUDEnabled) as? Bool) ?? false
        // Notch screen capture and idle visibility fallback to overlay preferences
        // to preserve user privacy expectations during migration.
        let legacyHideDuringCapture = (defaults.object(forKey: Keys.hideDuringScreenCapture) as? Bool) ?? false
        let legacyHideWhenNotPlaying = (defaults.object(forKey: Keys.hideWhenNotPlaying) as? Bool) ?? false
        hideDuringScreenCapture = legacyHideDuringCapture
        hideWhenNotPlaying = legacyHideWhenNotPlaying
        notchHideDuringScreenCapture =
            (defaults.object(forKey: Keys.notchHideDuringScreenCapture) as? Bool) ?? legacyHideDuringCapture
        notchHideWhenNotPlaying =
            (defaults.object(forKey: Keys.notchHideWhenNotPlaying) as? Bool) ?? legacyHideWhenNotPlaying
        appLanguage = defaults.string(forKey: Keys.appLanguage) ?? "system"
        hasCompletedOnboarding = (defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool)
            ?? (defaults.object(forKey: Keys.hasShownAutomationOnboarding) as? Bool) ?? false
        hasOfferedICloudImport =
            (defaults.object(forKey: Keys.hasOfferedICloudImport) as? Bool) ?? false
        // 一次性迁移:互斥的"悬浮窗样式"拆成两个独立开关之前,只可能同时生效一个——
        // 用旧值原样映射过来,保留用户当下已经在看的那个,不强行帮用户多打开另一个
        // (想同时开两个,拆开之后自己在设置里再手动开)。旧 key 只读不删,留着无害。
        //
        // 两个开关先算进局部变量、最后才一次性赋给属性:下面第二段迁移需要读到"算到目前为止
        // 是什么值",而在 init() 里所有存储属性都赋值完成之前读 self 的属性是编译错误
        // ('self' used in property access before all stored properties are initialized)。
        var classicOn: Bool
        var notchOn: Bool
        if let legacyStyle = defaults.string(forKey: Keys.overlayStyle) {
            classicOn = (defaults.object(forKey: Keys.classicOverlayEnabled) as? Bool) ?? (legacyStyle != "notch")
            notchOn = (defaults.object(forKey: Keys.notchOverlayEnabled) as? Bool) ?? (legacyStyle == "notch")
        } else {
            classicOn = (defaults.object(forKey: Keys.classicOverlayEnabled) as? Bool) ?? true
            notchOn = (defaults.object(forKey: Keys.notchOverlayEnabled) as? Bool) ?? false
        }
        // One-time migration: merge legacy menu bar visibility toggles into overlay enabled states.
        // Uses logical AND to avoid resurrecting windows explicitly hidden by the user.
        // Persisted directly to UserDefaults to handle assignment within init().
        if let legacyVisible = defaults.object(forKey: Keys.legacyClassicOverlayVisible) as? Bool {
            if !legacyVisible { classicOn = false }
            defaults.set(classicOn, forKey: Keys.classicOverlayEnabled)
            defaults.removeObject(forKey: Keys.legacyClassicOverlayVisible)
        }
        if let legacyVisible = defaults.object(forKey: Keys.legacyNotchOverlayVisible) as? Bool {
            if !legacyVisible { notchOn = false }
            defaults.set(notchOn, forKey: Keys.notchOverlayEnabled)
            defaults.removeObject(forKey: Keys.legacyNotchOverlayVisible)
        }
        classicOverlayEnabled = classicOn
        notchOverlayEnabled = notchOn
        notchCardStyle = defaults.string(forKey: Keys.notchCardStyle)
            .flatMap(NotchCardStyle.init(rawValue:)) ?? Self.defaultNotchCardStyle
        notchShowLyrics = (defaults.object(forKey: Keys.notchShowLyrics) as? Bool) ?? Self.defaultNotchShowLyrics
        motionCoverEnabled = (defaults.object(forKey: Keys.motionCoverEnabled) as? Bool) ?? Self.defaultMotionCoverEnabled
        notchCollapsesWhenPaused = (defaults.object(forKey: Keys.notchCollapsesWhenPaused) as? Bool)
            ?? Self.defaultNotchCollapsesWhenPaused
        notchShowsEqualizer = (defaults.object(forKey: Keys.notchShowsEqualizer) as? Bool) ?? Self.defaultNotchShowsEqualizer
        notchEqualizerEar = defaults.string(forKey: Keys.notchEqualizerEar)
            .flatMap(NotchEqualizerEar.init(rawValue:)) ?? Self.defaultNotchEqualizerEar
        notchExpandedShowsNextLine = (defaults.object(forKey: Keys.notchExpandedShowsNextLine) as? Bool)
            ?? Self.defaultNotchExpandedShowsNextLine
        notchExpandedShowsControls = (defaults.object(forKey: Keys.notchExpandedShowsControls) as? Bool)
            ?? Self.defaultNotchExpandedShowsControls
        notchExpandedShowsLyricsOffset = (defaults.object(forKey: Keys.notchExpandedShowsLyricsOffset) as? Bool)
            ?? Self.defaultNotchExpandedShowsLyricsOffset
        notchExpandedShowsArtwork = (defaults.object(forKey: Keys.notchExpandedShowsArtwork) as? Bool)
            ?? Self.defaultNotchExpandedShowsArtwork
        notchExpandedShowsTrackTitle = (defaults.object(forKey: Keys.notchExpandedShowsTrackTitle) as? Bool)
            ?? Self.defaultNotchExpandedShowsTrackTitle
        notchExpandedShowsArtist = (defaults.object(forKey: Keys.notchExpandedShowsArtist) as? Bool)
            ?? Self.defaultNotchExpandedShowsArtist
        notchExpandedShowsAlbum = (defaults.object(forKey: Keys.notchExpandedShowsAlbum) as? Bool)
            ?? Self.defaultNotchExpandedShowsAlbum
        notchExpandedShowsQuickActions = (defaults.object(forKey: Keys.notchExpandedShowsQuickActions) as? Bool)
            ?? Self.defaultNotchExpandedShowsQuickActions
        notchLyricRowShowsArtwork = (defaults.object(forKey: Keys.notchLyricRowShowsArtwork) as? Bool)
            ?? Self.defaultNotchLyricRowShowsArtwork
        notchLyricRowArtworkPosition = defaults.string(forKey: Keys.notchLyricRowArtworkPosition)
            .flatMap(NotchLyricRowArtworkPosition.init(rawValue:)) ?? Self.defaultNotchLyricRowArtworkPosition
        notchLyricsAlignment = defaults.string(forKey: Keys.notchLyricsAlignment)
            .flatMap(LyricsRestingAlignment.init(rawValue:)) ?? Self.defaultNotchLyricsAlignment
        notchSecondaryLine = defaults.string(forKey: Keys.notchSecondaryLine)
            .flatMap(LyricSecondaryLine.init(rawValue:)) ?? Self.defaultNotchSecondaryLine
        // Notch typography defaults and fallback validation.
        notchFontFamilyName = defaults.string(forKey: Keys.notchFontFamilyName) ?? Self.defaultNotchFontFamilyName
        notchFontWeight = defaults.string(forKey: Keys.notchFontWeight)
            .flatMap(OverlayFontWeight.init(rawValue:)) ?? Self.defaultNotchFontWeight
        notchFontSize = (defaults.object(forKey: Keys.notchFontSize) as? Double) ?? Self.defaultNotchFontSize
        notchLeftEar = defaults.string(forKey: Keys.notchLeftEar)
            .flatMap(NotchEarModule.init(rawValue:)) ?? Self.defaultNotchLeftEar
        notchRightEar = defaults.string(forKey: Keys.notchRightEar)
            .flatMap(NotchEarModule.init(rawValue:)) ?? Self.defaultNotchRightEar
        notchAllScreens = (defaults.object(forKey: Keys.notchAllScreens) as? Bool) ?? Self.defaultNotchAllScreens
        notchScreenID = defaults.string(forKey: Keys.notchScreenID) ?? Self.defaultNotchScreenID
        fontFamilyName = defaults.string(forKey: Keys.fontFamilyName) ?? Self.defaultFontFamilyName
        fontSize = (defaults.object(forKey: Keys.fontSize) as? Double) ?? Self.defaultFontSize
        // Defaults to `Self.defaultOverlayFontWeight` (.semibold).
        overlayFontWeight = defaults.string(forKey: Keys.overlayFontWeight)
            .flatMap(OverlayFontWeight.init(rawValue:)) ?? Self.defaultOverlayFontWeight
        // Default 488pt. Excluded from style reset to preserve user layout preferences.
        overlayWidth = (defaults.object(forKey: Keys.overlayWidth) as? Double) ?? 488
        notchContentWidth = (defaults.object(forKey: Keys.notchContentWidth) as? Double) ?? Self.defaultNotchContentWidth
        // Defaults to `Self.defaultNotchExpandedContentWidth`.
        notchExpandedContentWidth = (defaults.object(forKey: Keys.notchExpandedContentWidth) as? Double) ?? Self.defaultNotchExpandedContentWidth
        foregroundColorHex = defaults.string(forKey: Keys.foregroundColorHex) ?? ColorTheme.defaultTheme.foregroundColorHex
        backgroundColorHex = defaults.string(forKey: Keys.backgroundColorHex) ?? ColorTheme.defaultTheme.backgroundColorHex
        followsCoverArt = (defaults.object(forKey: Keys.followsCoverArt) as? Bool) ?? Self.defaultFollowsCoverArt
        if let json = defaults.string(forKey: Keys.customColorThemesJSON),
           let data = json.data(using: .utf8),
           let themes = try? JSONDecoder().decode([ColorTheme].self, from: data) {
            customColorThemes = themes
        } else {
            customColorThemes = []
        }
        if let json = defaults.string(forKey: Keys.browserPlatformPairsJSON),
           let data = json.data(using: .utf8),
           let pairs = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            browserPlatformPairs = pairs
        } else {
            browserPlatformPairs = [:]
        }
        if let json = defaults.string(forKey: Keys.manualBrowserFamiliesJSON),
           let data = json.data(using: .utf8),
           let families = try? JSONDecoder().decode([String: String].self, from: data) {
            manualBrowserFamilies = families
        } else {
            manualBrowserFamilies = [:]
        }
        if let json = defaults.string(forKey: Keys.browserJSVerifiedAtJSON),
           let data = json.data(using: .utf8),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            browserJSVerifiedAt = map
        } else {
            browserJSVerifiedAt = [:]
        }
        // didSet 对属性在自己 init() 里的这次赋值不会触发(Swift 语义:属性观察者不响应
        // "首次赋初值"这一步),不能赌它会连带把上面 7 个缓存值填对——显式调一次,幂等、
        // 无副作用。
        recomputeFonts()
        recomputeNotchFonts()
        foregroundColor = Color(hexWithAlpha: foregroundColorHex, fallback: .white)
        backgroundColor = Color(hexWithAlpha: backgroundColorHex, fallback: .clear)
        backgroundIsVisible = Self.backgroundVisible(hex: backgroundColorHex, glass: overlayBackgroundGlass)
        textStrokeColor = Color(hexWithAlpha: textStrokeColorHex, fallback: .black.opacity(0.65))
        // 顺手把功能改名/删除之后遗留下来的死键清掉(名单和理由见
        // ConfigPortability.obsoleteDefaultsKeys)。放在最后:上面那些读取全部完成之后再动
        // UserDefaults,不会影响本次启动读到的任何值。
        ConfigPortability.pruneObsoleteDefaults()
    }

    // 把 lyricsOffsetStepMs(毫秒)格式成"0.2"/"0.05"/"1.0"这种干净的秒数文案——
    // %.2f 统一先出两位小数,再把没意义的尾随 0 收掉,但至少留一位小数(不退化成"1"这种
    // 看着像别的数字类型的裸整数)。设置面板的 Stepper 标题、菜单里的"提前/延后 X 秒"
    // 共用这一份格式化,两处数字风格保持一致。
    static func formattedSeconds(ms: Int) -> String {
        var text = String(format: "%.2f", Double(ms) / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text += "0" }
        return text
    }

    /// 带符号的秒数文案("+0.5" / "-0.2" / "0.0")。给"这个值是提前还是延后"这类双向
    /// 调整的地方用 —— formattedSeconds 只管把数字格式干净,正负号由调用方决定要不要带。
    static func signedSeconds(ms: Int) -> String {
        guard ms != 0 else { return formattedSeconds(ms: 0) }
        return (ms > 0 ? "+" : "-") + formattedSeconds(ms: abs(ms))
    }
}
