import SwiftUI
import Combine
import LyrimuseCore

/// Narrow observer that relays only `appLanguage` changes from AppSettings.
/// Prevents full view re-renders triggered by unrelated settings mutations (e.g. font size or color adjustments).
@MainActor
final class AppLanguageObserver: ObservableObject {
    static let shared = AppLanguageObserver()
    @Published private(set) var appLanguage = ""
    private var sub: AnyCancellable?
    private init() {
        // sink uses received parameter rather than querying source property on willSet.
        sub = AppSettings.shared.$appLanguage.removeDuplicates()
            .sink { [weak self] in self?.appLanguage = $0 }
    }
}

/// Narrow observer that relays track transitions (artist, title, album) from PlaybackCoordinator.
/// Avoids observing high-frequency 20Hz playback tick properties directly while allowing
/// the manager window to follow track changes automatically.
@MainActor
final class LyricsManagerNowPlayingObserver: ObservableObject {
    @Published private(set) var trackSignature = ""
    private var sub: AnyCancellable?
    init() {
        let p = PlaybackCoordinator.shared
        sub = Publishers.CombineLatest3(p.$artist, p.$title, p.$album)
            .map { artist, title, album in "\(artist)|\(title)|\(album)" }
            .removeDuplicates()
            .sink { [weak self] in self?.trackSignature = $0 }
    }
}

// Filters lyrics by candidate source.
private enum SourceFilter: Hashable, Identifiable {
    case all
    case named(String)
    case none

    static let all_: [SourceFilter] = [.all, .named("amll"), .named("netease"), .named("qq"), .named("kugou"), .named("musixmatch"), .named("lrclib"), .named("lyricfind"), .none]

    var id: String { label }
    var label: String {
        switch self {
        case .all: return L10n.t("全部来源")
        case .none: return L10n.t("无来源")
        case .named(let s): return sourceDisplayName(s)
        }
    }

    func matches(_ source: String) -> Bool {
        switch self {
        case .all: return true
        case .none: return source.isEmpty
        case .named(let s): return source == s
        }
    }
}

private enum TimingFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case wordTiming = "仅逐字"
    case lineOnly = "仅整行"
    // Non-timestamped plain text fallback, distinguished from line-synced lyrics (see Summary.hasPlainTextFallback).
    case plainTextOnly = "仅纯文本"
    var id: String { rawValue }
}

/// Sorting criteria for lyrics manager list items.
/// Defaults to canonical ordering (artist, album, title).
/// Modification-time sorting relies on exported lyrics file modification dates (see `Summary.lyricsUpdatedAt`).
/// Target for decision analysis sheet displayed from row badges.
private struct DecisionSheetTarget: Identifiable {
    let id: String
}

private enum LyricsSortOption: String, CaseIterable, Identifiable {
    case defaultOrder = "默认排序"
    case titleAscending = "歌名 A→Z"
    case titleDescending = "歌名 Z→A"
    case artistAscending = "歌手 A→Z"
    case artistDescending = "歌手 Z→A"
    case albumAscending = "专辑 A→Z"
    case albumDescending = "专辑 Z→A"
    case sourceAscending = "来源 A→Z"
    case sourceDescending = "来源 Z→A"
    case updatedDescending = "更新时间 新→旧"
    case updatedAscending = "更新时间 旧→新"
    // Sorts items with the fewest responding sources first to highlight sparse resolutions.
    case evidenceAscending = "应答源最少"

    var id: String { rawValue }

    /// Maps to pure sorting rules defined in LyrimuseCore `LyricsSortOrder`.
    var coreOrder: LyricsSortOrder {
        switch self {
        case .defaultOrder: return .defaultOrder
        case .titleAscending: return .title(ascending: true)
        case .titleDescending: return .title(ascending: false)
        case .artistAscending: return .artist(ascending: true)
        case .artistDescending: return .artist(ascending: false)
        case .albumAscending: return .album(ascending: true)
        case .albumDescending: return .album(ascending: false)
        case .sourceAscending: return .source(ascending: true)
        case .sourceDescending: return .source(ascending: false)
        case .updatedAscending: return .updated(ascending: true)
        case .updatedDescending: return .updated(ascending: false)
        case .evidenceAscending: return .evidence(ascending: true)
        }
    }

    /// Sorts a filtered list of summaries using pre-computed sort keys to avoid repeat L10n lookups during O(N log N) comparisons.
    func sorted(_ items: [EnrichCacheStore.Summary]) -> [EnrichCacheStore.Summary] {
        let order = coreOrder
        return items
            .map { (key: $0.lyricsSortKey, item: $0) }
            .sorted { order.less($0.key, $1.key) }
            .map(\.item)
    }
}

extension EnrichCacheStore.Summary {
    /// Maps to a sorting key using normalized values (`normPrimaryArtist`, `normAlbum`) to ensure consistent grouping across script variants.
    var lyricsSortKey: LyricsSortKey {
        LyricsSortKey(
            normPrimaryArtist: normPrimaryArtist,
            normAlbum: normAlbum,
            title: title,
            searchTitleLower: searchTitleLower,
            sourceDisplayName: sourceDisplayName(lyricsSource),
            hasSource: !lyricsSource.isEmpty,
            lyricsUpdatedAt: lyricsUpdatedAt,
            resolvedAt: resolvedAt,
            sourcesRespondedCount: sourcesRespondedCount
        )
    }
}

// Extracts the primary artist from collaborative credits (separated by '/', '&', or commas) for consistent grouping.
func primaryArtist(_ full: String) -> String {
    let seps = CharacterSet(charactersIn: "/、&,，")
    let first = full.components(separatedBy: seps).first ?? full
    return first.trimmingCharacters(in: .whitespaces)
}

// Normalizes Traditional Chinese to Simplified Chinese using ICU transform for canonical equivalence checks.
// Results are memoized to avoid redundant ICU transform overhead in sorting and filtering pipelines.
private let toSimplifiedCacheLock = NSLock()
nonisolated(unsafe) private var toSimplifiedCache: [String: String] = [:]

func toSimplified(_ s: String) -> String {
    toSimplifiedCacheLock.lock()
    let hit = toSimplifiedCache[s]
    toSimplifiedCacheLock.unlock()
    if let hit { return hit }
    let mutable = NSMutableString(string: s) as CFMutableString
    CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
    let result = mutable as String
    toSimplifiedCacheLock.lock()
    toSimplifiedCache[s] = result
    toSimplifiedCacheLock.unlock()
    return result
}

// 每个歌词源一个固定色,列表/详情页共用,方便肉眼快速扫源(不是随手配的——网易云红、
// QQ音乐绿、酷狗蓝、LRCLIB紫,分别贴近各自品牌主色,"无来源"用中性灰)。
//
// internal 而非 private——"歌词"设置分类里的来源启用/优先级排序 UI(FeatureSettingsStore.swift
// 的 LyricsSource 枚举)复用同一套名字/颜色,避免两处各维护一份 switch 导致漂移。
func sourceColor(_ source: String) -> Color {
    switch source {
    case "netease": return .red
    case "qq": return .green
    case "kugou": return .cyan
    case "musixmatch": return .indigo
    case "lrclib": return .purple
    case "amll": return .orange
    // LyricFind (queried via YouTube Music when candidate metadata matches LyricFind,
    // see collector/ytmusic.go). Uses pink as an unoccupied accent color.
    case "lyricfind": return .pink
    // Kuwo Music (see collector/kuwo.go). Uses brown as an unoccupied accent color.
    case "kuwo": return .brown
    case "migu": return .mint
    case "deezer": return .teal
    default: return .secondary
    }
}

// 歌词来源展示名——网易云音乐/QQ音乐/酷狗音乐是国内用户认得出的中文写法;Musixmatch/
// LRCLIB 都是纯西方的歌词库(品牌),没有约定俗成的中文名,保留英文原名,不强行硬翻
// 一个不存在的中文名。
func sourceDisplayName(_ source: String) -> String {
    switch source {
    case "netease": return L10n.t("网易云音乐")
    case "qq": return L10n.t("QQ音乐")
    case "kugou": return L10n.t("酷狗音乐")
    case "musixmatch": return "Musixmatch"
    case "lrclib": return "LRCLIB"
    case "amll": return "AMLL"
    // LyricFind: displayed as LyricFind (retrieval pipeline routes via YouTube Music).
    case "lyricfind": return "LyricFind"
    case "kuwo": return L10n.t("酷我音乐")
    case "migu": return L10n.t("咪咕音乐")
    // Deezer: separate transport pipeline for LyricFind content.
    case "deezer": return "Deezer"
    case "": return L10n.t("无来源")
    default: return source
    }
}

// Tooltip for lyrics source badges. Clarifies transport pipeline (e.g. YouTube Music pipeline for LyricFind).
func sourceHelpText(_ source: String) -> String {
    switch source {
    case "lyricfind": return L10n.t("LyricFind（经由 YouTube Music 检索）")
    default: return sourceDisplayName(source)
    }
}

// 歌名/歌手/专辑/来源四列表头和每一行列表项共用同一组列宽——歌名是主列、拿剩余空间,
// 后三列固定宽度+单行截断,这样表头文字和每行内容的起始位置对得上。
// 列宽拖拽手柄:1pt 的细线 + 9pt 的命中区(线本身太细,按 HIG 可拖拽目标不该小于 8pt)。
// 单独抽成一个 View 是为了让 hover 光标的 push/pop 有地方存状态自己配平——onHover 的退出
// 事件在拖拽中/窗口切走时可能丢,无条件 pop 会把别人压进去的光标弹掉,连续 push 又会让
// 双箭头光标一直卡住不还原。
// 列宽拖拽 + 行内容边界测量共用的命名坐标空间。挂在侧栏最外层的 VStack 上(不是表头上):
// 表头的拖拽手势和列表里每一行都要在**同一个**空间里报坐标才能互相对齐。这个 VStack
// 不随列宽变化而移动,所以也是拖拽位移的可靠参照系。
private enum LyricsColumnHeaderSpace {
    static let name = "lyricsColumnHeader"
}

// Measured horizontal content bounds of rows within List(.inset) to align header dividers with AppKit system insets.
private struct RowContentBounds: Equatable {
    var minX: CGFloat
    var maxX: CGFloat
}

private struct RowContentBoundsKey: PreferenceKey {
    static let defaultValue: RowContentBounds? = nil
    // 取第一个上报的即可——所有行的左右边界都一样,没必要合并。
    static func reduce(value: inout RowContentBounds?, nextValue: () -> RowContentBounds?) {
        if value == nil { value = nextValue() }
    }
}

private struct ColumnDividerHandle: View {
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void
    let onDoubleClick: () -> Void
    @State private var pushedCursor = false

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.28))
            .frame(width: 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, !pushedCursor { NSCursor.resizeLeftRight.push(); pushedCursor = true }
                if !inside, pushedCursor { NSCursor.pop(); pushedCursor = false }
            }
            .onDisappear { if pushedCursor { NSCursor.pop(); pushedCursor = false } }
            // minimumDistance: 1 ensures double-tap gestures are not swallowed by zero-distance drags.
            // Coordinate translation is evaluated within the fixed named space of the column header container
            // rather than relative view coordinates to prevent feedback distortion during dynamic width expansion.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(LyricsColumnHeaderSpace.name))
                    .onChanged { onDrag($0.location.x - $0.startLocation.x) }
                    .onEnded { _ in onDragEnd() }
            )
            .onTapGesture(count: 2, perform: onDoubleClick)
    }
}

// Persists lyrics manager window frame and associated display identifier.
// Validates display existence before restoring coordinates, falling back to system placement
// if the target monitor is disconnected or resolution altered.
@MainActor
private final class LyricsManagerWindowFramePersistence: ObservableObject {
    private static let frameKey = "np:lyricsManagerWindowFrame"
    private static let screenKey = "np:lyricsManagerWindowScreenID"

    private weak var window: NSWindow?
    private var frameObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var persistFrameTask: Task<Void, Never>?

    /// 首次(以及每次 SwiftUI 重新求值 NSViewRepresentable 时)调用,只在真的换了一个
    /// 窗口实例时才重新挂观察者——同一扇窗口重复 attach 是空操作。
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // 先恢复再挂观察者:顺序反过来的话,恢复这一次 setFrame 会立刻触发 didMove/
        // didResize、把刚读出来的值原样再写一遍(无害但没意义),更糟的是恢复失败
        // (屏幕不在了)时会把系统摆的那个默认位置当成用户意图存下来。
        restorePersistedFrame(window)
        // Manually registers window in NSApp Windows menu to ensure Dock representation across spaces and minimized states.
        window.isExcludedFromWindowsMenu = false
        NSApp.addWindowsItem(window, title: window.title, filename: false)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { note in
            if let win = note.object as? NSWindow { NSApp.removeWindowsItem(win) }
        }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        // didMove 和 didResize 合用一个回调:两者要存的东西完全一样,而拖动窗口边角同时
        // 产生这两个通知,分开挂只会写两遍。
        let persist: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePersistFrame() }
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main, using: persist)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main, using: persist)
    }

    /// Persists window frame after dragging or resizing stops with a debounce delay to avoid per-frame writes.
    private func schedulePersistFrame() {
        persistFrameTask?.cancel()
        persistFrameTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistFrame()
        }
    }

    private func persistFrame() {
        // 窗口还没真正上屏时 frame 可能是 SwiftUI 给的中间值,不足为据。
        guard let window, window.isVisible else { return }
        let defaults = UserDefaults.standard
        defaults.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
        // 屏幕认不出来(极少数情况 window.screen 为 nil)时把旧值清掉,而不是留一个跟
        // 这次 frame 对不上的屏幕 ID——下次恢复会拿错屏幕做校验。
        if let screen = window.screen, let id = ScreenIdentity.id(of: screen) {
            defaults.set(id, forKey: Self.screenKey)
        } else {
            defaults.removeObject(forKey: Self.screenKey)
        }
    }

    @discardableResult
    private func restorePersistedFrame(_ window: NSWindow) -> Bool {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: Self.frameKey) else { return false }
        let saved = NSRectFromString(raw)
        guard saved.width > 0, saved.height > 0 else { return false }
        // 认屏幕:存过 ID 就必须那块屏还在。不在 = 用户换了显示器配置,旧坐标没有
        // 任何意义。
        guard let id = defaults.string(forKey: Self.screenKey),
              let screen = ScreenIdentity.screen(withID: id) else { return false }
        // 夹进那块屏的可见区。存的时候屏幕分辨率可能跟现在不同(接同一块屏但改了缩放),
        // 不夹的话窗口会有一部分挂在屏幕外。
        let visible = screen.visibleFrame
        var frame = saved
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
        return true
    }

    deinit {
        persistFrameTask?.cancel()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }
}

/// 用一个零尺寸的 NSView 拿到真实 NSWindow 交给 controller——跟 LyricsWindowView.swift
/// 的 LyricsWindowCapture 同一个套路。
private struct LyricsManagerWindowCapture: NSViewRepresentable {
    let controller: LyricsManagerWindowFramePersistence

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { controller.attach(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { controller.attach(window) }
    }
}

// Lyrics manager window: displays cached lyrics, sources, manual corrections,
// candidate search, and deletions with persistent updates.
struct LyricsManagerView: View {
    @ObservedObject private var store = EnrichCacheStore.shared
    @StateObject private var windowFrame = LyricsManagerWindowFramePersistence()
    @ObservedObject private var languageSettings = AppLanguageObserver.shared
    @StateObject private var nowPlaying = LyricsManagerNowPlayingObserver()
    // `searchText` holds live user input, while `committedSearchText` filters the list upon Enter or submission.
    @State private var searchText = ""
    @State private var committedSearchText = ""
    // Focus state for search bar border highlight.
    @FocusState private var searchFieldFocused: Bool
    // Multi-selection state. 0 = placeholder, 1 = single detail view, >= 2 = batch action panel.
    @State private var selectedKeys: Set<String> = []
    // Snapshot of keys to delete, captured before presenting confirmation dialog.
    @State private var pendingDeleteKeys: [String] = []
    @State private var showBatchDeleteConfirm = false
    // Transient visual feedback after completing deletion.
    @State private var showDeletedFeedback = false
    @State private var editedLyrics = ""
    // Plain body text displayed in editor without metadata tags.
    @State private var editedLyricsBody = ""
    @State private var lyricsBodyEdit = LyricsBodyEdit(lyrics: "")
    @State private var editedTr = ""
    @State private var editedRoma = ""
    // 单曲歌词时间轴偏移——输入框显示/编辑的秒数字符串。跟下面两个"persisted"字段
    // 分开存,是因为算 LyricsOffsetStore 的 key 必须用磁盘上实际持久化的歌词内容,不能
    // 用 editedLyrics(用户可能正在编辑框里改还没点"保存修改",这时候的文本还没生效到
    // 播放端,拿它算出来的 key 会跟真正播放时用的 key 对不上)。
    @State private var editedOffsetSeconds = ""
    @State private var persistedLyricsForOffset = ""
    @State private var persistedYRCForOffset = ""
    // 列宽(可拖拽调节 + 持久化,见 LyricsColumnWidthsStore)。
    @ObservedObject private var columnWidths = LyricsColumnWidthsStore.shared
    // 单曲时间轴校正值:工具栏那个「已校准 N 首 / 清空」要跟着实时变(整对象订阅是安全的
    // —— 它只在用户动作时发布,不在播放热路径上,见 LyricsOffsetStore.trackOffsetCount)。
    @ObservedObject private var offsets = LyricsOffsetStore.shared
    // 已校准名单:详情页那颗「已校准」徽章和它下面那句说明认它(见 LyricsPinStore)。
    @ObservedObject private var pins = LyricsPinStore.shared
    // 一次拖拽开始那一刻的列宽快照——必须按"起点 + 累计位移"算,不能每次 onChanged 都在
    // 当前值上叠加增量:DragGesture 的 translation 是相对手势起点的累计值,不是帧间增量,
    // 叠加会让列宽以平方速度飞出去。
    @State private var dragStartWidths: LyricsColumnWidths?
    // List 里一行内容的实际左右边界(由行自己通过 preference 上报,见 RowContentBoundsKey)。
    @State private var rowContentBounds: RowContentBounds?
    @State private var showSearchSheet = false

    // MARK: - Automatic Rematch
    //
    // Unlike manual online search which prompts user selection, automatic rematch applies
    // the collector's resolution rules directly (search-lyrics -pick) according to user preferences.
    //
    // State properties are keyed per track so that results are bound strictly to the selected song.
    @State private var rematchRunningKey: String?
    @State private var rematchDone = 0
    @State private var rematchTotal = 0
    @State private var rematchResult: RematchOutcome?
    /// 单调换代:回调和收尾都 guard 它,防"上一轮的收尾把新一轮的进行中状态关掉"
    /// (照抄 LyricsSearchSheet.load 里 searchGeneration 那套)。
    @State private var rematchGeneration = 0

    private struct RematchOutcome {
        enum Kind { case changed, unchanged, kept, empty, failed }
        let key: String
        let kind: Kind
        let text: String

        var icon: String {
            switch kind {
            case .changed: return "checkmark.circle.fill"
            case .unchanged: return "equal.circle"
            case .kept: return "hand.raised.fill"
            case .empty: return "text.badge.xmark"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch kind {
            case .changed: return .green
            case .unchanged: return .secondary
            case .kept, .empty, .failed: return .orange
            }
        }
    }
    @State private var showDecisionSheet = false
    // Sheet target for decision analysis sheet displayed from row badges.
    @State private var decisionTarget: DecisionSheetTarget?
    // Transient feedback state after saving edits.
    @State private var showSaveEditFeedback = false
    // Transient feedback state after copying lyrics.
    @State private var showCopyLyricsFeedback = false
    @State private var sourceFilter: SourceFilter = .all
    @State private var timingFilter: TimingFilter = .all
    @State private var manualOnly = false
    @State private var missingLyricsOnly = false
    @State private var instrumentalOnly = false
    // Filter for tracks resolved with sparse evidence.
    @State private var thinEvidenceOnly = false
    // Progress snapshot for background lyrics fill sweeps.
    @State private var fillSweepStatus: LyricsFillSweep.Info?
    @State private var artistFilter: String?
    @State private var albumFilter: String?
    @State private var sortOption: LyricsSortOption = .defaultOrder
    // Transient feedback state after manual refresh.
    @State private var showRefreshedFeedback = false
    @State private var showClearAllConfirm = false
    @State private var showClearOffsetsConfirm = false
    @State private var showClearRadioOffsetsConfirm = false
    @State private var pendingRestoreSnapshot: LyricsBackupStore.Snapshot?
    @State private var showRestoreSnapshotConfirm = false
    @State private var restoreSnapshotResult: String?
    // Tracks whether now-playing auto-focus has run for current session. Reset on window disappear.
    @State private var pendingAutoFocus = true

    /// Placeholder row displayed while a track is being searched and unresolved by the collector.
    @State private var placeholderSummary: EnrichCacheStore.Summary?

    private var hasActiveFilters: Bool {
        sourceFilter != .all || timingFilter != .all || manualOnly || missingLyricsOnly
            || instrumentalOnly || thinEvidenceOnly || artistFilter != nil || albumFilter != nil
    }

    // Display name lookup dictionaries (artist/album display names, filter dropdown items) are cached in EnrichCacheStore
    // and rebuilt alongside summaries to avoid O(N) ICU normalization transforms on every row evaluation.

    private func albumDisplay(_ album: String) -> String {
        store.albumDisplayMap[toSimplified(album).lowercased()] ?? album
    }

    /// filtered 的缓存盒。@State 里包一个引用类型,让下面的计算属性能在 body 求值过程中
    /// 写缓存(View struct 本身不可变)—— filtered 在一次 body 构建里被独立求值 4~5 处
    /// (List 数据源/副标题计数/全选按钮/删除禁用/批量面板),不缓存就是 4~5 遍全量过滤。
    private final class FilteredCache {
        var token = "\u{0}"
        var generation = -1
        var result: [EnrichCacheStore.Summary] = []
    }
    @State private var filteredCache = FilteredCache()

    private var filtered: [EnrichCacheStore.Summary] {
        // 缓存键 = 全部筛选状态(filterToken,本来就为 onChange 拼好了)+ summaries 代数。
        let generation = store.summariesGeneration
        let token = filterToken
        if filteredCache.token == token, filteredCache.generation == generation {
            return filteredCache.result
        }
        // 循环不变量提到过滤循环外算一次(原来写在逐行闭包里,每行各付一遍);逐行侧
        // 全部用 Summary 的预计算归一化键,谓词只剩字符串比较。
        let q = committedSearchText.lowercased()
        let af = artistFilter.map { toSimplified($0).lowercased() }
        let bf = albumFilter.map { toSimplified($0).lowercased() }
        // 「正在搜索」占位行(见 refreshPlaceholder)并进同一份基础列表——刻意不给它开
        // 特例绕过下面这套筛选谓词:它没歌词/没来源/不是人工修正,该被"仅人工修正"筛掉
        // 就该被筛掉,跟真实条目一视同仁,不需要另外维护一套"占位行永远显示"的逻辑。
        let base = placeholderSummary.map { store.summaries + [$0] } ?? store.summaries
        let result = base.filter { s in
            if !q.isEmpty {
                // Search matches against raw artist, normalized display artist, song title, and album name.
                guard s.searchArtistLower.contains(q)
                    || s.searchDisplayArtistLower.contains(q)
                    || s.searchTitleLower.contains(q)
                    || s.searchAlbumLower.contains(q) else { return false }
            }
            // Case- and script-insensitive comparison using normalized keys.
            if let af, s.normPrimaryArtist != af { return false }
            if let bf, s.normAlbum != bf { return false }
            guard sourceFilter.matches(s.lyricsSource) else { return false }
            switch timingFilter {
            case .all: break
            case .wordTiming: guard s.hasWordTiming else { return false }
            // Line-only filter requires valid lyrics without word-by-word timing; entries without lyrics
            // or with plain-text fallback are excluded.
            case .lineOnly: guard s.hasLyrics && !s.hasWordTiming else { return false }
            case .plainTextOnly: guard s.hasPlainTextFallback else { return false }
            }
            // "Manual edit only" includes manually calibrated timeline offsets (LyricsPinStore).
            if manualOnly && !s.isManual && !pins.isPinned(s.key) { return false }
            // Missing lyrics filter targets songs lacking lyrics that are neither instrumental nor plain-text fallback.
            if missingLyricsOnly && (s.hasLyrics || s.isInstrumental || s.hasPlainTextFallback) { return false }
            // Instrumental-only filter matches confirmed pure instrumental tracks.
            if instrumentalOnly && !s.isInstrumental { return false }
            // Thin-evidence filter identifies songs resolved with few candidate sources (<4 responses).
            if thinEvidenceOnly && !s.thinEvidence { return false }
            return true
        }
        filteredCache.token = token
        filteredCache.generation = generation
        filteredCache.result = result
        return result
    }

    /// `filtered` 按当前排序方式排好的版本——List 的数据源、以及一切"顺序对用户可见"的
    /// 地方(比如 orderedVisibleKeys 那份删除计划)都该用这个,而不是 `filtered` 本身。
    ///
    /// 不另外包一层缓存盒:`filtered` 那份缓存是为了避开"每行现算一次 ICU 归并"这个
    /// 真正昂贵的操作(见 FilteredCache 声明处的注释),这里排序比较的全是预算好的
    /// normPrimaryArtist/normAlbum/searchTitleLower 字段,是廉价的字符串/元组比较,
    /// 一次 body 里被求值 2~3 遍(List 数据源 + orderedVisibleKeys)的成本可以忽略——
    /// 为它单独维护一套 token/generation 缓存盒反而是这次改动里最不值得的复杂度。
    private var sortedFiltered: [EnrichCacheStore.Summary] {
        sortOption.sorted(filtered)
    }

    // 只有恰好选中一条时才显示单曲详情页——detail 侧整条链(编辑缓冲区、offset 输入框、
    // 联网搜索 sheet)都建立在"当前就这一条"上,不能把多选硬塞进去。
    private var singleSelectedKey: String? {
        selectedKeys.count == 1 ? selectedKeys.first : nil
    }

    // 把全部筛选状态拼成一个字符串,只为了给 onChange 当变化信号用——否则要给七个 @State
    // 各挂一个 onChange 做同一件事(收敛选中项)。
    //
    // 分隔符用 U+001F(ASCII 单元分隔符)而不是 "|":searchText、歌手名、专辑名里都可能出现
    // "|",那样两个不同的筛选状态理论上能拼出同一个 token,onChange 就不会触发、选中项不会
    // 被收敛(而这个收敛正是防误删的那道防线)。虽然要真撞上得刻意构造,但换个用户输入里
    // 不可能出现的控制字符是零成本的,不用去论证"实际撞不上"。
    private var filterToken: String {
        let sep = "\u{1F}"
        return [
            committedSearchText, sourceFilter.id, timingFilter.rawValue,
            String(manualOnly), String(missingLyricsOnly), String(instrumentalOnly),
            String(thinEvidenceOnly),
            artistFilter ?? "", albumFilter ?? "",
            // 占位行的 key 也要算进去——它的出现/消失/换成另一首歌不会让
            // store.summariesGeneration 变(那条代数只跟 raw/真实条目有关),漏了这一项
            // filtered 的缓存盒就会在占位行刚补上/刚被真实条目顶替的那一刻还显示旧结果。
            placeholderSummary?.key ?? "",
        ].joined(separator: sep)
    }

    // 选中集合里"当前筛选结果中真的看得见"的那些,按列表显示顺序返回。
    //
    // ⚠️ 这是防误删的关键一道:filtered 是计算属性,selectedKeys 是独立 @State,行从筛选
    // 结果里消失后 SwiftUI 不保证替你把 key 从 selection 里剪掉。真实误操作路径:搜
    // "Jackson" 多选 8 条 → 清空搜索框 → 点删除,此时那 8 条一条也看不见,弹窗却写着 8 条,
    // 删完用户完全不知道删了什么,而这个删除是不可逆的(连 lyrics/ 下导出文件一起删)。
    // Returns selected keys visible in the current filter, matching sortedFiltered display order
    // to keep deletion targets consistent with the user-visible list.
    private func orderedVisibleKeys(_ keys: Set<String>) -> [String] {
        // Ephemeral placeholder row is excluded from bulk operations.
        sortedFiltered.compactMap { !$0.isSearching && keys.contains($0.key) ? $0.key : nil }
    }

    private var selectedVisibleKeys: [String] { orderedVisibleKeys(selectedKeys) }

    // Count shared between "Select All" button and subtitle count.
    private var selectableFiltered: [EnrichCacheStore.Summary] { filtered.filter { !$0.isSearching } }

    // Snapshots target keys before presenting batch deletion confirmation dialog.
    private func requestDelete(_ keys: Set<String>) {
        let victims = orderedVisibleKeys(keys)
        guard !victims.isEmpty else { return }
        pendingDeleteKeys = victims
        showBatchDeleteConfirm = true
    }

    private func commitSearch() {
        committedSearchText = searchText
    }

    private func resetFilters() {
        sourceFilter = .all
        timingFilter = .all
        manualOnly = false
        missingLyricsOnly = false
        instrumentalOnly = false
        thinEvidenceOnly = false
        artistFilter = nil
        albumFilter = nil
    }

    // Sidebar brand header displaying the music note list icon and view title above searchBar.
    private var brandHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "music.note.list")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            Text(L10n.t("歌词管理"))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // Custom search bar TextField placed above filterBar.
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                // Standard TextField .onSubmit reliably handles return key presses in this layout.
                TextField(L10n.t("搜索歌手/歌名/专辑"), text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .onSubmit(commitSearch)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                // Focused stroke outline indicates active keyboard focus.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(searchFieldFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                            lineWidth: searchFieldFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: searchFieldFocused)
            .frame(maxWidth: .infinity)

            // Search button triggers search explicitly alongside the Enter key.
            Button(action: commitSearch) {
                Image(systemName: "magnifyingglass")
            }
            .help(L10n.t("搜索(或在搜索框按回车)"))
            .disabled(searchText == committedSearchText)
        }
        .font(.callout)
        // 搜索词一清空就立刻回到全量列表,不需要等按钮/回车——这个方向零过滤开销,
        // 理由见 committedSearchText 声明处的注释。
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty && !committedSearchText.isEmpty {
                committedSearchText = ""
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)

                Picker(L10n.t("歌手"), selection: $artistFilter) {
                    Text(L10n.t("全部歌手")).tag(String?.none)
                    ForEach(store.distinctArtists, id: \.self) { a in Text(a).tag(String?.some(a)) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 140)

                Picker(L10n.t("专辑"), selection: $albumFilter) {
                    Text(L10n.t("全部专辑")).tag(String?.none)
                    ForEach(store.distinctAlbums, id: \.self) { a in Text(a).tag(String?.some(a)) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 140)

                // Sort picker width accommodates longest localized labels ("专辑 A→Z" / "Default Order") plus margin.
                Picker(L10n.t("排序"), selection: $sortOption) {
                    ForEach(LyricsSortOption.allCases) { option in
                        Text(L10n.t(option.rawValue)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 170)

                Spacer()
            }

            // Fixed-width horizontal layout with ViewThatFits fallback to prevent control jumping on selection changes:
            // 1. Pickers use fixed width instead of maxWidth to prevent compression.
            // 2. Filter pill chips enforce single-line layout.
            // 3. Trailing action slot uses a fixed width (280pt).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterControlsGroup
                    Spacer(minLength: 12)
                    selectionAndFilterActions
                }
                // When compressed, wraps actions onto a second trailing-aligned row.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        filterControlsGroup
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        selectionAndFilterActions
                    }
                }
            }
        }
        // Custom PillChipToggleStyle for filter switches.
        .toggleStyle(PillChipToggleStyle())
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    /// Filter controls group (source and timing pickers, toggle chips). Uses fixed widths.
    @ViewBuilder
    private var filterControlsGroup: some View {
        Picker(L10n.t("来源"), selection: $sourceFilter) {
            ForEach(SourceFilter.all_) { f in Text(f.label).tag(f) }
        }
        .pickerStyle(.menu)
        .frame(width: 150)

        Picker(L10n.t("时间轴"), selection: $timingFilter) {
            ForEach(TimingFilter.allCases) { f in Text(L10n.t(f.rawValue)).tag(f) }
        }
        .pickerStyle(.menu)
        .frame(width: 175)

        Divider().frame(height: 14)

        Toggle(L10n.t("仅人工修正"), isOn: $manualOnly)
        Toggle(L10n.t("仅无歌词"), isOn: $missingLyricsOnly)
        Toggle(L10n.t("仅纯音乐"), isOn: $instrumentalOnly)
        Toggle(L10n.t("仅证据薄"), isOn: $thinEvidenceOnly)
            .help(L10n.t("当初只有 1~3 个歌词源应答就定下了这份歌词。想换一份就逐条点「重新自动匹配」"))
    }

    /// Selection status and filter reset actions in a fixed-width container (280pt).
    private var selectionAndFilterActions: some View {
        HStack(spacing: 12) {
            // 「全选筛选结果」给一个显式按钮,不能只靠 ⌘A:这个窗口的核心动线正是"在筛选
            // 栏勾出一批 → 立刻想全选删掉",此时焦点大概率还在上面那个原生搜索框上,⌘A
            // 会变成"全选搜索框里的文字"。按钮上带的数字跟标题栏副标题「N / 852 首」左边
            // 那个数完全一致,用户一眼能对上"我选的就是筛出来的这批"。
            if selectedKeys.isEmpty {
                if !selectableFiltered.isEmpty {
                    Button(String(format: L10n.t("全选 %@ 首"), "\(selectableFiltered.count)")) {
                        selectedKeys = Set(selectableFiltered.map(\.key))
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                Text(String(format: L10n.t("已选 %@ 首"), "\(selectedVisibleKeys.count)"))
                    .foregroundStyle(.secondary)
                Button(L10n.t("取消选择")) { selectedKeys.removeAll() }
                    .foregroundStyle(.secondary)
            }

            if hasActiveFilters {
                Divider().frame(height: 14)
                Button(L10n.t("清除筛选"), action: resetFilters)
                    .foregroundStyle(.secondary)
            }
        }
        // 单行,不许因为数字变长(852 → 2572)而换行。
        .lineLimit(1)
        // 固定槽位 + 右对齐:内容少的时候空在左边,右缘永远咬着同一条线。
        .frame(width: 280, alignment: .trailing)
    }

    // 胶囊筛选 chip：未选中=描边+次要色文字，选中=强调色浅底+强调色文字（贴方案A细化稿）。
    // 用 Button 而不是原生 Toggle 的默认渲染——ToggleStyle 协议本来就是"给同一份
    // isOn/label 换一套画法"，这是它的标准用法，不是绕开 SwiftUI。
    private struct PillChipToggleStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                configuration.label
                    // Enforces single-line display and intrinsic sizing to prevent badge height shifts.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(configuration.isOn
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        Capsule().stroke(configuration.isOn
                            ? Color.accentColor.opacity(0.45)
                            : Color.primary.opacity(0.12))
                    )
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // Header displaying song title, artist, album, and source column names matching LyricsManagerRow widths.
    private var listColumnHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.t("歌名")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.t("歌手")).frame(width: shownWidths.artist, alignment: .leading)
                .overlay(alignment: .leading) { columnDivider(0) }
            Text(L10n.t("专辑")).frame(width: shownWidths.album, alignment: .leading)
                .overlay(alignment: .leading) { columnDivider(1) }
            Text(L10n.t("来源")).frame(width: shownWidths.source, alignment: .leading)
                .overlay(alignment: .leading) { columnDivider(2) }
            Text(L10n.t("偏移")).frame(width: Self.offsetColumnWidth, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        // Matches horizontal boundaries [minX, maxX] reported by list row content via RowContentBoundsKey.
        // Uses fixed width with leading padding to align headers with AppKit NSTableView insets without extra geometry passes.
        .frame(width: columnAreaWidth > 0 ? columnAreaWidth : nil, alignment: .leading)
        .padding(.leading, headerLeading)
        .padding(.trailing, columnAreaWidth > 0 ? 0 : Self.fallbackHPadding)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(L10n.t("重置列宽")) { columnWidths.reset() }
        }
    }

    // Fallback horizontal padding when row boundaries are not yet measured.
    private static let fallbackHPadding: CGFloat = 12

    private var headerLeading: CGFloat { rowContentBounds?.minX ?? Self.fallbackHPadding }

    // Total horizontal space for columns derived from row content bounds via PreferenceKey.
    // PreferenceKey updates reliably on layout passes unlike GeometryReader onChange handlers.
    private var columnAreaWidth: CGFloat {
        guard let b = rowContentBounds else { return 0 }
        return max(0, b.maxX - b.minX)
    }
    private static let offsetColumnWidth: CGFloat = 56

    private var headerChrome: CGFloat { 8 * 4 + Self.offsetColumnWidth }

    private var shownWidths: LyricsColumnWidths {
        LyricsColumnWidths.fitted(columnWidths.widths, totalWidth: columnAreaWidth, chrome: headerChrome)
    }

    private func columnDivider(_ index: Int) -> some View {
        ColumnDividerHandle(
            onDrag: { dx in
                if dragStartWidths == nil {
                    dragStartWidths = columnWidths.widths
                    // Column resizing updates in-memory widths during dragging; persistent storage writes occur on drag end.
                    columnWidths.beginDragging()
                }
                guard let start = dragStartWidths else { return }
                columnWidths.widths = LyricsColumnWidths.dragged(
                    from: start, divider: index, dx: dx,
                    totalWidth: columnAreaWidth, chrome: headerChrome
                )
            },
            onDragEnd: {
                dragStartWidths = nil
                columnWidths.endDragging()
            },
            onDoubleClick: { resetDivider(index) }
        )
        .offset(x: -8.5)
    }

    // 双击某条分隔条 = 把这条边界两侧的列恢复默认宽度(不是全部三列——只动用户正在操作的
    // 那条边界更符合预期;要整体恢复用表头右键菜单里的「重置列宽」)。
    private func resetDivider(_ index: Int) {
        let d = LyricsColumnWidths.defaults
        var w = columnWidths.widths
        switch index {
        case 0: w.artist = d.artist                       // 左边是弹性的歌名列,只需复位歌手
        case 1: w.artist = d.artist; w.album = d.album
        default: w.album = d.album; w.source = d.source
        }
        columnWidths.widths = w
    }

    var body: some View {
        NavigationSplitView {
            // ScrollViewReader 包住整个侧栏(而不是只包 List)——工具栏的"回到当前播放"
            // 按钮跟 List 是 VStack 里的兄弟节点、跟 .toolbar 修饰符也不在同一层,要让
            // scrollProxy 在这两者共同的外层作用域里可见,闭包需要整个包住 VStack+.toolbar。
            // ScrollViewReader 只是个透明包装,不影响布局。
            ScrollViewReader { scrollProxy in
                VStack(spacing: 0) {
                    brandHeader
                    Divider()
                    searchBar
                    filterBar
                    Divider()
                    listColumnHeader
                    Divider()
                    List(sortedFiltered, selection: $selectedKeys) { summary in
                        // 使用 summary.artist 原始名称而非统一官方 displayArtist 展示，
                        // 筛选/排序按统一名归并，但列表列如实展示每条记录的原始歌手名，
                        // 便于用户区分因原始标签差异拆分为多条记录的同名曲目。
                        LyricsManagerRow(summary: summary, artistDisplayName: summary.artist, albumDisplayName: albumDisplay(summary.album), widths: shownWidths, offsetColumnWidth: Self.offsetColumnWidth,
                                         onShowDecision: summary.hasDecision ? { decisionTarget = DecisionSheetTarget(id: summary.key) } : nil)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    // 行内「N/9」徽章点开的决策弹窗。跟详情页那颗 ActionTile 打开的是同一个
                    // LyricsDecisionSheet、同一套懒解码(只在打开这一刻按 key 解两槽),
                    // 只是入口在列表行上 —— 那个数字的完整展开正是弹窗第一行「本轮应答的源」。
                    .sheet(item: $decisionTarget) { target in
                        let latest = store.decodedDecision(for: target.id)
                        let applied = store.decodedAppliedDecision(for: target.id)
                        // summaries 是数组,这里 O(n) 查一次 —— 只在打开弹窗时跑,不在 body 热路径上。
                        if let s = store.summaries.first(where: { $0.key == target.id }),
                           latest != nil || applied != nil {
                            LyricsDecisionSheet(summary: s, latest: latest, applied: applied)
                        }
                    }
                    // 首次开窗、summaries 还没任何内容时叠一个"正在加载"提示,不让空 List
                    // Loading overlay displayed during initial cache load without removing the underlying List view.
                    .overlay {
                        if store.isLoading {
                            VStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L10n.t("正在加载…"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contextMenu(forSelectionType: String.self) { keys in
                        let deletable = orderedVisibleKeys(keys)
                        if !deletable.isEmpty {
                            Button(role: .destructive) {
                                requestDelete(keys)
                            } label: {
                                Text(deletable.count == 1
                                    ? L10n.t("删除本地记录")
                                    : String(format: L10n.t("删除选中的 %@ 条"), "\(deletable.count)"))
                            }
                        }
                    }
                    .onChange(of: filterToken) { _, _ in
                        selectedKeys.formIntersection(Set(filtered.map(\.key)))
                    }
                    .confirmationDialog(
                        batchDeleteTitle,
                        isPresented: $showBatchDeleteConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(
                            pendingDeleteKeys.count == 1
                                ? L10n.t("删除")
                                : String(format: L10n.t("删除 %@ 条"), "\(pendingDeleteKeys.count)"),
                            role: .destructive
                        ) {
                            performPendingDelete()
                        }
                        Button(L10n.t("取消"), role: .cancel) {}
                    } message: {
                        Text(batchDeleteMessage)
                    }
                    .onAppear {
                        Task {
                            await store.reload()
                            refreshPlaceholder()
                            guard pendingAutoFocus else { return }
                            pendingAutoFocus = false
                            focusCurrentlyPlaying(scrollProxy: scrollProxy, animated: false)
                        }
                    }

                    if let error = store.lastError {
                        Divider()
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial)
                    }
                }
                .coordinateSpace(.named(LyricsColumnHeaderSpace.name))
                .onPreferenceChange(RowContentBoundsKey.self) { bounds in
                    if let bounds { rowContentBounds = bounds }
                }
                .navigationTitle(L10n.t("歌词管理"))
                .navigationSubtitle(String(format: L10n.t("%@ / %@ 首"), "\(selectableFiltered.count)", "\(store.summaries.count)"))
                .toolbar {
                    ToolbarItem {
                        Button(action: refreshWithFeedback) {
                            Label(showRefreshedFeedback ? L10n.t("已刷新") : L10n.t("刷新"),
                                  systemImage: showRefreshedFeedback ? "checkmark" : "arrow.clockwise")
                        }
                    }
                    ToolbarItem {
                        Button {
                            focusCurrentlyPlaying(scrollProxy: scrollProxy)
                        } label: {
                            Label(L10n.t("回到当前播放"), systemImage: "location.fill")
                        }
                    }
                    ToolbarItem {
                        Button {
                            requestDelete(selectedKeys)
                        } label: {
                            Label(showDeletedFeedback ? L10n.t("已删除") : L10n.t("删除记录"),
                                  systemImage: showDeletedFeedback ? "checkmark" : "trash")
                        }
                        .disabled(selectedVisibleKeys.isEmpty)
                        .keyboardShortcut(.delete, modifiers: .command)
                    }
                    ToolbarItem {
                        fillSweepToolbarMenu
                    }
                    ToolbarItem {
                        // Disk cache size indicator and clear-all action menu.
                        // Uses .titleAndIcon label style so toolbar menu button renders both disk icon and cache size text.
                        Menu {
                            Section {
                                Button(role: .destructive) {
                                    showClearAllConfirm = true
                                } label: {
                                    Label(L10n.t("清空全部缓存"), systemImage: "trash")
                                }
                            } header: {
                                Text(String(format: L10n.t("共 %d 条，占用 %@"),
                                            store.summaries.count, cacheSizeText))
                            }
                            Section {
                                Button(role: .destructive) {
                                    showClearOffsetsConfirm = true
                                } label: {
                                    Label(L10n.t("清空全部时间轴校正"), systemImage: "timer")
                                }
                                .disabled(offsets.trackOffsetCount == 0)
                            } header: {
                                Text(String(format: L10n.t("已校准 %d 首歌的歌词时间轴"),
                                            offsets.trackOffsetCount))
                            }
                            // Radio station timeline offsets tracked separately from standard song offsets.
                            if offsets.radioOffsetCount > 0 {
                                Section {
                                    Button(role: .destructive) {
                                        showClearRadioOffsetsConfirm = true
                                    } label: {
                                        Label(L10n.t("清空全部电台校正"), systemImage: "dot.radiowaves.left.and.right")
                                    }
                                } header: {
                                    Text(String(format: L10n.t("已校正 %d 首歌在电台上的时间轴"),
                                                offsets.radioOffsetCount))
                                }
                            }
                            let snapshots = LyricsBackupStore.autoSnapshots()
                            if !snapshots.isEmpty {
                                Section {
                                    ForEach(snapshots) { snapshot in
                                        Button {
                                            pendingRestoreSnapshot = snapshot
                                            showRestoreSnapshotConfirm = true
                                        } label: {
                                            Label("\(Self.snapshotDateText(snapshot.date))（\(Self.byteText(snapshot.bytes))）",
                                                  systemImage: "clock.arrow.circlepath")
                                        }
                                    }
                                } header: {
                                    Text(L10n.t("从自动备份恢复"))
                                }
                            }
                        } label: {
                            Label(cacheSizeText, systemImage: "internaldrive")
                                .labelStyle(.titleAndIcon)
                        }
                        .help(L10n.t("歌词缓存文件，加上已导出的 .lrc 歌词文件夹，合计占用的磁盘空间"))
                    }
                }
                // Removes automatic sidebar toggle button; both columns represent list and detail of the same workspace.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 480, ideal: 630, max: 900)
                .confirmationDialog(
                    L10n.t("确定要清空全部歌词缓存吗?"),
                    isPresented: $showClearAllConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L10n.t("清空全部缓存"), role: .destructive) {
                        Task {
                            await store.clearAll()
                            selectedKeys.removeAll()
                        }
                    }
                    Button(L10n.t("取消"), role: .cancel) {}
                } message: {
                    // Auto-snapshot is created prior to clearing cache (EnrichCacheStore.clearAll).
                    Text(String(format: L10n.t("这会删除当前全部 %d 条本地记录,包括你手动编辑、联网搜索采纳过的内容,已导出到本地的歌词文件也会一并删除。清空之前会自动备份一份,能从这个菜单里的「从自动备份恢复」找回来。下次播放会重新走一遍匹配解析"), store.summaries.count))
                }
                // 窗口开着期间换歌就跟着重新定位——不然停留在"开窗那一刻播的那首",见
                // LyricsManagerNowPlayingObserver 类头注。首次挂载时 trackSignature 已经是
                // 当前播放那首(CombineLatest3 订阅即发一次),不会跟 pendingAutoFocus 那次
                // 开窗定位重复触发;这里只在**后续**换歌时才会再跑一次。挂在这里(还在
                // ScrollViewReader 的 scrollProxy 作用域内)而不是外层 NavigationSplitView
                // 的修饰符链上——那边已经出了 scrollProxy 的可见范围。
                .onChange(of: nowPlaying.trackSignature) { _, _ in
                    // 必须先刷占位行再定位——focusCurrentlyPlaying 里"占位行也能被定位到"
                    // 那道判断读的是 placeholderSummary,换歌那一刻它还是上一首的,先刷新
                    // 才能让新歌(如果也在搜索中)被正确定位到。
                    refreshPlaceholder()
                    focusCurrentlyPlaying(scrollProxy: scrollProxy)
                }
                // 占位行等 collector 写完缓存才能自动"顶替"成真实条目——但换歌/reload 都
                // 不会在"同一首歌搜索完成"这一刻自动发生,得有个人主动再问一次磁盘。5 秒
                // 轮询一次(跟 PendingListensPanel 的 mtime 轮询同一个量级),reload
                // (onlyIfChanged: true) 本身很便宜——文件没变时只是一次 stat,只有真的
                // 搜完、文件真的变了才会有那一次解析开销。窗口关掉这个 .task 自动取消,
                // 不会有常驻计时器漏在后台。
                .task {
                    while !Task.isCancelled {
                        // 补空扫描跑着的时候加密到 2 秒:每条搜完 collector 都会改缓存文件、
                        // 也会推进进度文件,列表和工具栏那颗按钮都该跟着动;没在跑就维持 5 秒。
                        try? await Task.sleep(for: .seconds(fillSweepStatus?.running == true ? 2 : 5))
                        guard !Task.isCancelled else { continue }
                        // 进度文件按 mtime 读(LyricsFillSweep.current 内部缓存),Equatable
                        // 没变就不赋值——不制造无意义的重渲染。
                        let sweep = LyricsFillSweep.current
                        if sweep != fillSweepStatus { fillSweepStatus = sweep }
                        guard placeholderSummary != nil || sweep?.running == true else { continue }
                        await store.reload(onlyIfChanged: true)
                        refreshPlaceholder()
                    }
                }
            }
        } detail: {
            Group {
                if let key = singleSelectedKey, let summary = store.summaries.first(where: { $0.key == key }) {
                    detailView(key: key, summary: summary)
                } else if let placeholder = placeholderSummary, singleSelectedKey == placeholder.key {
                    // 占位行没有对应的 raw 条目,不能走 detailView 那整套编辑/删除/重新自动匹配——
                    // 那些操作全部直接读写 raw[key],喂一个不存在的 key 进去没有意义。给一个
                    // 干净的只读说明就够了,等 collector 写完缓存,下一次 reload 会让这一行自然
                    // 变成真的一行,到时候点开就是正常的 detailView。
                    placeholderDetailView(placeholder)
                } else if selectedKeys.count > 1 {
                    batchSelectionPanel
                } else {
                    ContentUnavailableView(L10n.t("选择左侧一首歌"), systemImage: "text.quote")
                }
            }
            // NavigationSplitView 在 macOS 上会将侧栏的 .navigationTitle 继承渲染在
            // detail 分栏顶部（独立于原生标题栏渲染）。为 detail 分支单独设置空标题，
            // 消除重复标题层，同时保持侧栏 .navigationTitle 对真实窗口标题栏的控制。
            .navigationTitle("")
        }
        .frame(minWidth: 780, idealWidth: 1040, minHeight: 540, idealHeight: 640)
        // 零尺寸探针拿真实 NSWindow 交给 windowFrame——放哪一层都行(只借视图树把
        // NSView 挂进窗口,不参与布局),挂在这里离上面 .frame 最近,读起来是同一件事。
        .background(LyricsManagerWindowCapture(controller: windowFrame).frame(width: 0, height: 0))
        // 刻意挂在最外层 NavigationSplitView 上 —— 跟侧栏那条链上的「清空全部缓存」、
        // List 上的「删除」分处三个不同层级。同一条修饰符链上叠多个呈现修饰符历史上有
        // 互相顶掉的问题(见那两处各自的注释),分层挂就不用去论证"这个版本会不会冲突"。
        .confirmationDialog(
            L10n.t("确定要清空全部歌词时间轴校正吗?"),
            isPresented: $showClearOffsetsConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("清空全部时间轴校正"), role: .destructive) {
                LyricsOffsetStore.shared.clearAllTrackOffsets()
                PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(String(format: L10n.t("这会清掉你为 %d 首歌手动调出来的歌词时间轴校正值,无法撤销。歌词内容本身不受影响;设置里的全局偏移和按播放器补偿也不会被清掉。清掉之后,这些歌会重新交给后台自动更新歌词源"), offsets.trackOffsetCount))
        }
        // 电台校准的清空确认。同样单独挂一层,理由见上面那条。
        .confirmationDialog(
            L10n.t("确定要清空全部电台校正吗?"),
            isPresented: $showClearRadioOffsetsConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("清空全部电台校正"), role: .destructive) {
                LyricsOffsetStore.shared.clearAllRadioOffsets()
                PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(String(format: L10n.t("这会清掉你在电台上为 %d 首歌调出来的时间轴校正,无法撤销。这些校正只在放电台时生效,清掉不影响你正常播放这些歌时的歌词"), offsets.radioOffsetCount))
        }
        // 恢复确认。跟上面两个确认弹窗一样各挂各的层级,不叠在同一条修饰符链上。
        .confirmationDialog(
            L10n.t("确定要从这份备份恢复歌词库吗?"),
            isPresented: $showRestoreSnapshotConfirm,
            titleVisibility: .visible
        ) {
            // key 用「从备份恢复」而不是复用已有的「恢复」—— 那条的英文是 "Reset"
            // (「恢复默认」语境),这里是 restore,复用直接翻错。
            Button(L10n.t("从备份恢复")) {
                guard let snapshot = pendingRestoreSnapshot else { return }
                Task {
                    restoreSnapshotResult = await store.restoreFromAutoSnapshot(snapshot)
                        ?? L10n.t("这份备份读不出来")
                    pendingRestoreSnapshot = nil
                }
            }
            Button(L10n.t("取消"), role: .cancel) { pendingRestoreSnapshot = nil }
        } message: {
            // 说清楚它**不是**"回到那一刻的状态":铺文件是覆盖+新增,不删除备份里没有的
            // 条目(restore 走的是 LyricsBackupArchive.plan,只有 added/overwritten 两类)。
            // 用户以为是整体回滚、结果发现之后新解析的歌还在,那是另一种惊吓。
            Text(L10n.t("备份里的歌词文件会铺回歌词文件夹：同名的覆盖，缺的补上；备份之后新解析出来的歌不会被删掉。恢复完 collector 会重启一次，把它们重新读进缓存"))
        }
        .alert(L10n.t("恢复歌词库"), isPresented: Binding(
            get: { restoreSnapshotResult != nil },
            set: { if !$0 { restoreSnapshotResult = nil } }
        )) {
            Button(L10n.t("好")) { restoreSnapshotResult = nil }
        } message: {
            Text(restoreSnapshotResult ?? "")
        }
        // 见 AuxiliaryWindowActivation 注释——.accessory 策略下临时借一个 Dock 图标。
        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }
        // 切回 App 时重新读一次盘。
        //
        // 列表是**开窗那一刻的快照**,而 collector 在窗口开着期间会持续往同一个文件写:新歌
        // 是新增条目,给已有歌补机翻译文/逐字时间轴则是原地更新。不刷新的话,一首刚补上译文
        // 的歌在列表里始终不亮绿色的译文标记 —— 用户的原话是"这首歌明明有翻译,但没有译文
        // 的 tag",而歌词本身在悬浮窗里是正常显示的(那条路径读的是实时数据)。
        //
        // 挑"App 重新激活"当触发点,而不是上文件监听:典型用法就是切出去听歌、过一阵切回来,
        // 这个时机覆盖得住,而且 reload() 会把读盘+解析(缓存大了要 30ms 以上)放后台线程,
        // 不像 FSEvent 那样需要自己做防抖。窗口一直摆在副屏、人从不切走的情况仍然要靠工具栏
        // 的「刷新」—— 那颗按钮本来就在。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Reloads cache on app activation only if file modification time has changed.
            Task { await store.reload(onlyIfChanged: true) }
        }
        .onDisappear {
            AuxiliaryWindowActivation.windowDidDisappear()
            pendingAutoFocus = true
        }
    }

    private func refreshWithFeedback() {
        Task {
            await store.reload()
            selectedKeys.formIntersection(Set(store.summaries.map(\.key)))
            withAnimation { showRefreshedFeedback = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showRefreshedFeedback = false }
        }
    }

    private var batchDeleteTitle: String {
        if pendingDeleteKeys.count == 1,
           let summary = store.summaries.first(where: { $0.key == pendingDeleteKeys[0] }) {
            return String(format: L10n.t("确定要删除「%@ - %@」的本地记录吗?"), summary.artist, summary.title)
        }
        return String(format: L10n.t("确定要删除选中的 %@ 条本地记录吗?"), "\(pendingDeleteKeys.count)")
    }

    private var batchDeleteMessage: String {
        if pendingDeleteKeys.count == 1 {
            return L10n.t("已导出到本地的歌词文件也会一并删除,下次播放这首歌会重新走一遍匹配解析,不保证一定能找到一样的歌词")
        }
        let pending = Set(pendingDeleteKeys)
        let manual = store.summaries.filter { pending.contains($0.key) && $0.isManual }.count
        if manual > 0 {
            return String(format: L10n.t("其中 %@ 条是你手动修正过的,删掉之后找不回来。已导出到本地的歌词文件也会一并删除,且无法撤销。下次播放这些歌会重新走一遍匹配解析,不保证能找到一样的歌词"), "\(manual)")
        }
        return L10n.t("已导出到本地的歌词文件也会一并删除,且无法撤销。下次播放这些歌会重新走一遍匹配解析,不保证能找到一样的歌词")
    }

    private func performPendingDelete() {
        let victims = Set(pendingDeleteKeys)
        guard !victims.isEmpty else { return }
        Task {
            await store.delete(keys: victims)
            selectedKeys.subtract(victims)
            guard store.lastError == nil else { return }
            withAnimation { showDeletedFeedback = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showDeletedFeedback = false }
        }
    }

    // Detail view shown when multiple items are selected.
    private var batchSelectionPanel: some View {
        let victims = Set(selectedVisibleKeys)
        let picked = store.summaries.filter { victims.contains($0.key) }
        let manual = picked.filter(\.isManual).count
        let wordTiming = picked.filter(\.hasWordTiming).count
        // Filter out confirmed pure instrumental and plain-text fallback entries from missing lyrics count.
        let noLyrics = picked.filter { !$0.hasLyrics && !$0.isInstrumental && !$0.hasPlainTextFallback }
        let noResponder = noLyrics.filter(\.lastRoundHadNoResponder).count
        let indexed = noLyrics.filter { !$0.lastRoundHadNoResponder && $0.knownOnSources }.count
        let missing = noLyrics.count - indexed - noResponder
        let retryable = picked.filter(EnrichCacheStore.isFillSweepRetryable).map(\.key)
        return VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(String(format: L10n.t("已选择 %@ 首"), "\(picked.count)"))
                .font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                if manual > 0 {
                    InfoChip(icon: "pencil.circle.fill", text: String(format: L10n.t("人工修正 %@ 首"), "\(manual)"), tint: .orange)
                }
                if wordTiming > 0 {
                    InfoChip(icon: "text.word.spacing", text: String(format: L10n.t("逐字时间轴 %@ 首"), "\(wordTiming)"), tint: .blue)
                }
                if missing > 0 {
                    InfoChip(icon: "text.badge.xmark", text: String(format: L10n.t("无歌词 %@ 首"), "\(missing)"), tint: .red)
                }
                if noResponder > 0 {
                    InfoChip(icon: "antenna.radiowaves.left.and.right.slash",
                             text: String(format: L10n.t("无源应答 %@ 首"), "\(noResponder)"), tint: .secondary)
                }
                if indexed > 0 {
                    InfoChip(icon: "music.note", text: String(format: L10n.t("源里有歌、无词 %@ 首"), "\(indexed)"), tint: .secondary)
                }
            }
            if manual > 0 {
                Text(L10n.t("人工修正过的歌词删掉之后找不回来"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Batch retry action for items without lyrics via LyricsFillSweep.
            if !retryable.isEmpty {
                Button {
                    LyricsFillSweep.request(keys: retryable)
                } label: {
                    Label(String(format: L10n.t("重试选中的无歌词 %@ 条"), "\(retryable.count)"),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(fillSweepStatus?.running == true)
            }
            Button(role: .destructive) {
                requestDelete(selectedKeys)
            } label: {
                Label(String(format: L10n.t("删除选中的 %@ 条"), "\(picked.count)"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            Button(L10n.t("取消选择")) { selectedKeys.removeAll() }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// 工具栏无歌词重试菜单：支持重试全部或当前筛选出的无歌词曲目，显示运行进度或上一轮结果。
    private var fillSweepToolbarMenu: some View {
        let status = fillSweepStatus
        let running = status?.running == true
        let retryableAll = store.summaries.filter(EnrichCacheStore.isFillSweepRetryable).map(\.key)
        let retryableVisible = sortedFiltered.filter(EnrichCacheStore.isFillSweepRetryable).map(\.key)
        return Menu {
            if let status, running {
                Section {
                    Button(role: .destructive) {
                        LyricsFillSweep.requestCancel()
                    } label: {
                        Label(L10n.t("停止重试"), systemImage: "stop.circle")
                    }
                } header: {
                    // 菜单里只放"正在搜哪一首":总进度已经在按钮标题上。key 是
                    // "歌手|歌名|专辑",直接显示够认。
                    Text(status.current.map { String(format: L10n.t("正在搜：%@"), $0) }
                         ?? L10n.t("正在重试无歌词条目…"))
                }
            } else {
                Section {
                    Button {
                        LyricsFillSweep.request(keys: [])
                    } label: {
                        Label(String(format: L10n.t("重试全部无歌词条目（%@ 首）"), "\(retryableAll.count)"),
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(retryableAll.isEmpty)
                    if hasActiveFilters && retryableVisible.count != retryableAll.count {
                        Button {
                            LyricsFillSweep.request(keys: retryableVisible)
                        } label: {
                            Label(String(format: L10n.t("重试当前筛选出的无歌词条目（%@ 首）"), "\(retryableVisible.count)"),
                                  systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .disabled(retryableVisible.isEmpty)
                    }
                } header: {
                    Text(L10n.t("逐首联网重搜，每首间隔 15 秒；纯音乐与人工修正过的不碰"))
                }
                if let status, status.finishedAt != nil {
                    Section {
                        // 纯展示的一行,不可点。cancelled 时另说一句,免得"搜了 12 首"被当成全部。
                        Text(String(format: L10n.t("上次：搜了 %1$@ 首，补出 %2$@ 首"), "\(status.done)", "\(status.filled)"))
                        if status.cancelled == true {
                            Text(L10n.t("上次被手动停止"))
                        }
                    } header: {
                        Text(L10n.t("上一轮"))
                    }
                }
            }
        } label: {
            if let status, running {
                // 不用 Label:工具栏会把 Label 缩成只剩图标。自己拼一个 HStack,圆环就是图标位,
                // 「3/82」紧跟着——两个都是进度,少了哪个都不完整。total 兜到 ≥1,免得 0/0 的
                // 那一瞬间(状态文件刚写出、候选还没数完)让 ProgressView 拿到 NaN。
                HStack(spacing: 4) {
                    ProgressView(value: Double(status.done), total: Double(max(status.total, 1)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text("\(status.done)/\(status.total)")
                        .font(.caption)
                        .monospacedDigit()
                }
                .accessibilityLabel(String(format: L10n.t("重试中 %1$@/%2$@"), "\(status.done)", "\(status.total)"))
            } else {
                Label(L10n.t("重试无歌词"), systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon)
            }
        }
        .help(running
              ? String(format: L10n.t("重试中 %1$@/%2$@"), "\(status?.done ?? 0)", "\(status?.total ?? 0)")
              : L10n.t("让采集服务现在就把没有歌词的条目重新搜一遍，不用等每首歌再次播放"))
    }

    // 口径本体挪到 EnrichCacheStore.byteText —— 设置页「歌词库」那一行是第三处要显示同一个
    // 字节数的地方,再各自 new 一个 ByteCountFormatter 迟早分叉(见那边的头注)。
    private var cacheSizeText: String {
        EnrichCacheStore.byteText(store.totalSizeBytes)
    }

    // 自动备份那一行的两段文字。static 是因为它们在 Menu 的 ForEach 里被调,不碰任何
    // 实例状态;跟 cacheSizeText 同一套 ByteCountFormatter 口径,免得同一个菜单里两种写法。
    //
    // 日期用 .short + .short:这几份快照全是"刚刚/今天"的量级(只留 3 份),用户要分辨的是
    // "哪一次操作",精确到分钟就够,写全年月日反而把菜单撑宽。
    private static func snapshotDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func byteText(_ bytes: Int) -> String {
        EnrichCacheStore.byteText(Int64(bytes))
    }

    // Ephemeral placeholder row synthesized for songs currently undergoing first-time lyrics search.
    // Preserves data store integrity by avoiding premature writes to disk while allowing search, filter, and focus.
    private func refreshPlaceholder() {
        let playback = PlaybackCoordinator.shared
        guard !playback.artist.isEmpty, !playback.title.isEmpty else {
            placeholderSummary = nil
            return
        }
        let key = EnrichCacheKeys.normalizedKey(
            artist: playback.artist, title: playback.title, album: playback.album)
        guard !store.hasEntry(forKey: key) else {
            if placeholderSummary?.key == key { placeholderSummary = nil }
            return
        }
        guard placeholderSummary?.key != key else { return }
        let display = playback.artist
        placeholderSummary = EnrichCacheStore.Summary(
            key: key,
            artist: playback.artist,
            canonicalArtist: "",
            durationSecs: Double(playback.currentDurationMs ?? 0) / 1000,
            title: playback.title,
            album: playback.album,
            lyricsSource: "",
            hasWordTiming: false,
            isManual: false,
            sourceChoice: "",
            offsetMs: 0,
            lyricsTrSource: "",
            hasTranslation: false,
            hasRomanization: false,
            hasLyrics: false,
            isInstrumental: false,
            hasPlainTextFallback: false,
            knownOnSources: false,
            lastRoundHadNoResponder: false,
            sourcesRespondedCount: 0,
            isSearching: true,
            hasDecision: false,
            lyricsUpdatedAt: nil,
            resolvedAt: nil,
            normPrimaryArtist: toSimplified(primaryArtist(display)).lowercased(),
            normAlbum: toSimplified(playback.album).lowercased(),
            searchArtistLower: playback.artist.lowercased(),
            searchDisplayArtistLower: display.lowercased(),
            searchTitleLower: playback.title.lowercased(),
            searchAlbumLower: playback.album.lowercased()
        )
    }

    // Selects and scrolls to the currently playing song in the list.
    private func focusCurrentlyPlaying(scrollProxy: ScrollViewProxy, animated: Bool = true) {
        let playback = PlaybackCoordinator.shared
        // Normalizes track search key via EnrichCacheKeys.normalizedKey, stripping subtitle variants to match cache keys.
        let normalizedKey = EnrichCacheKeys.normalizedKey(
            artist: playback.artist, title: playback.title, album: playback.album)
        let rawKey = "\(playback.artist)|\(playback.title)|\(playback.album)"
        // Falls back to loose matching (lowercase, whitespace-stripped, simplified Chinese) if exact key match misses.
        let candidates = normalizedKey == rawKey ? [normalizedKey] : [normalizedKey, rawKey]
        let key: String
        if let exact = candidates.first(where: { candidate in
            store.summaries.contains(where: { $0.key == candidate }) || placeholderSummary?.key == candidate
        }) {
            key = exact
        } else {
            let looseWanted = Set(candidates.map(EnrichCacheKeys.looseKey))
            guard let match = store.summaries.first(where: {
                looseWanted.contains(EnrichCacheKeys.looseKey($0.key))
            })?.key else { return }
            key = match
        }
        selectedKeys = [key]
        DispatchQueue.main.async {
            if animated {
                withAnimation { scrollProxy.scrollTo(key, anchor: .center) }
                // Re-applies scroll position after initial layout pass to correct for lazy row height measurement.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        scrollProxy.scrollTo(key, anchor: .center)
                    }
                }
            } else {
                scrollProxy.scrollTo(key, anchor: .center)
                // Re-applies scroll position after initial appearance to account for estimated row heights settling to actual heights.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    scrollProxy.scrollTo(key, anchor: .center)
                }
            }
        }
    }

    // Detail view for in-progress search placeholder with cancellation option.
    private func placeholderDetailView(_ summary: EnrichCacheStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            headerTitleBlock(summary)
            ContentUnavailableView {
                Label(L10n.t("正在搜索歌词…"), systemImage: "magnifyingglass")
            } description: {
                Text(L10n.t("这首歌第一次播放，正在联网搜索歌词，完成后会自动显示，不需要手动刷新。"))
            } actions: {
                Button(L10n.t("停止搜索")) { cancelPlaceholderSearch() }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Writes cancellation token to signal collector to abort pending network searches for this track.
    /// The collector marks the record as "no lyrics" in cache, which subsequent store reload detects.
    private func cancelPlaceholderSearch() {
        guard let key = placeholderSummary?.key else { return }
        let url = LyrimusePaths.configFile("lyrimuse-enrich-cancel-request.txt")
        try? key.write(to: url, atomically: true, encoding: .utf8)
    }

    @ViewBuilder
    private func detailView(key: String, summary: EnrichCacheStore.Summary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(summary)
                // 故意**不**放进 header 里的 actionTileGrid 那组方块:header 用的是
                // ViewThatFits(in: .horizontal),而它比的是理想宽度 —— 混进一句长文案会把
                // "标题和方块同一行"那个候选的理想宽度撑爆,方块组从此永久掉到第二行,而且
                // 转圈出现/消失会让整个顶部跳一下。放在 header 外面只影响竖向高度。
                rematchStatusRow(key: key, summary: summary)
                infoStrip(summary)
                offsetSection(summary)

                if summary.hasWordTiming {
                    wordTimingHint
                }

                editorSection(title: L10n.t("歌词(LRC)"), icon: "text.alignleft", text: $editedLyricsBody, minHeight: 220, monospaced: true, disabled: summary.hasWordTiming, showCopyButton: true)
                    // 两条 onChange 互不打圈,理由见 LyricsBodyEdit 头注:外部写进来的 editedLyrics(换曲 / 采纳候选 /
                    // 重新匹配)才重算正文;编辑框自己拼回去的那次(值恰好等于 reassembled)跳过,不然用户敲的回车会被归一化吃掉。
                    .onChange(of: editedLyrics, initial: true) { _, raw in
                        if raw == lyricsBodyEdit.reassembled(body: editedLyricsBody) { return }
                        lyricsBodyEdit = LyricsBodyEdit(lyrics: raw, title: summary.title, artist: summary.artist)
                        editedLyricsBody = lyricsBodyEdit.body
                    }
                    .onChange(of: editedLyricsBody) { _, newBody in
                        let full = lyricsBodyEdit.reassembled(body: newBody)
                        if full != editedLyrics { editedLyrics = full }
                    }
                editorSection(title: L10n.t("译文"), icon: "character.book.closed", text: $editedTr, minHeight: 70, monospaced: false)
                editorSection(title: L10n.t("罗马音"), icon: "textformat.abc", text: $editedRoma, minHeight: 70, monospaced: false, latinIcon: true)

                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                actionsRow(key: key, summary: summary)
            }
            .padding(20)
        }
        .onAppear { loadDetail(key: key) }
        .onChange(of: key) { _, newKey in
            loadDetail(key: newKey)
            // 换歌就把上一首的进行中/结果状态收掉,并把子进程停掉(它的结果已经没人要了)。
            // rematchGeneration 换代顺带让在飞的那一轮的回调和收尾全部失效。
            if rematchRunningKey != nil {
                rematchGeneration += 1
                rematchRunningKey = nil
                LyricsSearchService.shared.cancelRunning()
            }
            rematchResult = nil
        }
        .sheet(isPresented: $showDecisionSheet) {
            // 按钮只在 hasDecision 时出现；完整结构懒解码 —— 仅在打开弹窗时按 key
            // 解码（避免 rebuild 阶段急切计算）。两槽都解：latest=最近一次评估，applied=当前歌词出处
            // （老条目只有前者，弹窗 init 中自动退化处理）。
            let latest = store.decodedDecision(for: key)
            let applied = store.decodedAppliedDecision(for: key)
            if latest != nil || applied != nil {
                LyricsDecisionSheet(summary: summary, latest: latest, applied: applied)
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            // 采纳候选直接保存,不需要再手动点"保存修改"——避免让人误以为选了就已经
            // 存上了,结果只是填进了编辑框,还得再点一下保存才真正落盘。
            LyricsSearchSheet(
                artist: summary.artist, title: summary.title, album: summary.album,
                currentSource: summary.lyricsSource,
                // 「当前使用」双判据所需的歌词正文指纹。经 EnrichCacheReader.lookup 提取，保证与其它入口指纹口径一致。
                currentFingerprint: EnrichCacheReader.lookup(artist: summary.artist, title: summary.title, album: summary.album)
                    .map { ManualPickLock.fingerprint(lyrics: $0.lyrics) }.flatMap { $0.isEmpty ? nil : $0 },
                durationSecs: summary.durationSecs
            ) { candidate in
                // 纯文本候选走独立路径处理：不写入 editedLyrics/editedTr/editedRoma（避免
                // 与 LRC 格式混淆导致无效 offset 调节），不触发 refreshOffsetState（offset
                // 机制依赖时间戳内容哈希），跳过 markManual 等时间戳专属字段。详情参见 EnrichCacheStore.savePlainTextEdit。
                guard !candidate.isPlainTextOnly else {
                    let saved = await store.savePlainTextEdit(
                        key: key, plainLyrics: candidate.lyrics, source: candidate.source)
                    if saved { flashSaveEditFeedback() }
                    return saved
                }
                editedLyrics = candidate.lyrics
                editedTr = candidate.lyricsTr
                editedRoma = candidate.lyricsRoma
                // When manualPickLocksLyrics is enabled, locks the selection as manual lyrics.
                let saved = await store.saveEdit(key: key, lyrics: candidate.lyrics, tr: candidate.lyricsTr,
                                                 roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC,
                                                 source: candidate.source, markManual: AppSettings.shared.manualPickLocksLyrics,
                                                 sourceChoice: "", fromManualPick: true)
                refreshOffsetState(artist: summary.artist, title: summary.title, lyrics: candidate.lyrics, yrc: candidate.lyricsYRC)
                if saved { flashSaveEditFeedback() }
                return saved
            }
        }
    }

    /// Flashes save confirmation feedback.
    private func flashSaveEditFeedback() {
        Task {
            withAnimation { showSaveEditFeedback = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showSaveEditFeedback = false }
        }
    }

    /// Header layout with fixed-size 2x2 action tile grid (`actionTileGrid`), adapting to single or two-line layout.
    private func header(_ summary: EnrichCacheStore.Summary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                headerTitleBlock(summary)
                Spacer(minLength: 12)
                actionTileGrid(summary)
            }
            VStack(alignment: .leading, spacing: 10) {
                headerTitleBlock(summary)
                actionTileGrid(summary)
            }
        }
    }

    private func headerTitleBlock(_ summary: EnrichCacheStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.title).font(.title2.weight(.bold)).lineLimit(3)
            Text(summary.artist).font(.title3).foregroundStyle(.secondary).lineLimit(2)
            if !summary.album.isEmpty {
                Text(albumDisplay(summary.album)).font(.callout).foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    /// Fixed-size 2x2 grid for detail view actions.
    private func actionTileGrid(_ summary: EnrichCacheStore.Summary) -> some View {
        LazyVGrid(
            columns: [GridItem(.fixed(ActionTile.size.width), spacing: 8),
                      GridItem(.fixed(ActionTile.size.width), spacing: 8)],
            spacing: 8
        ) {
            if summary.hasDecision {
                ActionTile(icon: "list.number", title: L10n.t("解析决策"),
                           help: L10n.t("当初为什么选了这份歌词：当时的候选、得分与拒绝原因")) {
                    showDecisionSheet = true
                }
            }
            ActionTile(icon: "wand.and.stars", title: L10n.t("重新自动匹配"),
                       help: L10n.t("重新联网跑一遍匹配，直接采用算法选出的那一份，不用自己挑；跟设置里的「匹配算法」一致"),
                       disabled: rematchRunningKey != nil) {
                Task { await runRematch(key: summary.key, summary: summary) }
            }
            ActionTile(icon: "magnifyingglass", title: L10n.t("联网搜索候选歌词"),
                       help: L10n.t("联网搜索候选歌词"), disabled: rematchRunningKey != nil) {
                showSearchSheet = true
            }
            // Manual instrumental toggle for songs without lyrics (intros, interludes, speech).
            if !summary.hasLyrics {
                if summary.isInstrumental {
                    ActionTile(icon: "waveform.slash", title: L10n.t("取消纯音乐标记"),
                               help: L10n.t("撤回「纯音乐」结论，这首歌重新回到自动补搜歌词的队列")) {
                        Task { await store.setInstrumental(key: summary.key, false) }
                    }
                } else {
                    ActionTile(icon: "waveform", title: L10n.t("标为纯音乐"),
                               help: L10n.t("这首本来就没有歌词（口白、过场、纯乐器）：标上之后不再显示为「无歌词」，采集服务也不再反复重搜")) {
                        Task { await store.setInstrumental(key: summary.key, true) }
                    }
                }
            }
            ActionTile(icon: "trash", title: L10n.t("删除本地记录"),
                       help: L10n.t("删除本地记录"), destructive: true) {
                requestDelete([summary.key])
            }
        }
        .fixedSize()
    }

    private func infoStrip(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 8) {
            InfoChip(
                icon: "arrow.down.circle",
                text: sourceDisplayName(summary.lyricsSource),
                tint: sourceColor(summary.lyricsSource)
            )
            if summary.hasLyrics {
                InfoChip(
                    icon: summary.hasWordTiming ? "text.word.spacing" : "text.alignleft",
                    text: summary.hasWordTiming ? L10n.t("逐字时间轴") : L10n.t("整行歌词"),
                    tint: summary.hasWordTiming ? .blue : .secondary
                )
            }
            if summary.isManual {
                InfoChip(icon: "pencil.circle.fill", text: L10n.t("人工修正"), tint: .orange)
            }
            // Legacy source choice indicator for manually pinned lyrics sources.
            if !summary.sourceChoice.isEmpty {
                InfoChip(icon: "pin.circle.fill",
                         text: String(format: L10n.t("来源已选定：%@"),
                                      sourceDisplayName(summary.sourceChoice)),
                         tint: .indigo)
            }
            if pins.isPinned(summary.key) {
                InfoChip(icon: "timer", text: L10n.t("已校准"), tint: .teal)
            }
            if summary.hasTranslation
                && summary.lyricsTrSource == LyricsTranslationSource.machineSentinel {
                InfoChip(icon: "character.book.closed", text: L10n.t("机器翻译"), tint: .purple)
            }
            if !summary.hasLyrics {
                if summary.isInstrumental {
                    InfoChip(icon: "waveform", text: L10n.t("纯音乐"), tint: .secondary)
                } else if summary.hasPlainTextFallback {
                    InfoChip(icon: "text.quote", text: L10n.t("仅纯文本"), tint: .orange)
                } else if summary.lastRoundHadNoResponder {
                    InfoChip(icon: "antenna.radiowaves.left.and.right.slash",
                             text: L10n.t("这一轮没有源应答"), tint: .secondary)
                } else if summary.knownOnSources {
                    InfoChip(icon: "music.note", text: L10n.t("源里有歌、无词"), tint: .secondary)
                } else {
                    InfoChip(icon: "text.badge.xmark", text: L10n.t("无歌词"), tint: .red)
                }
            }
            Spacer()
        }
    }

    // 单曲歌词时间轴偏移——跟菜单栏"歌词时间轴"(边听边点着调)是同一份数据
    // (LyricsOffsetStore),这里是给想直接敲一个精确数值的场景用的输入框,不用先听
    // 一遍再一点点试。回车或点"应用"才真正写入+让当前播放立刻生效,不是敲一个字符
    // 就实时应用(半个数字、负号打到一半时不该被当成有效值提交)。
    private func offsetSection(_ summary: EnrichCacheStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            Label(L10n.t("歌词时间轴偏移"), systemImage: "timer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("0.0", text: $editedOffsetSeconds)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .onSubmit { applyOffsetEdit(summary) }
            Text(L10n.t("秒"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(L10n.t("应用")) { applyOffsetEdit(summary) }
            if LyricsOffsetStore.shared.offset(forKey: currentOffsetKey(summary)) != 0 {
                Button(L10n.t("重置")) { resetOffsetEdit(summary) }
            }
            Spacer()
            Text(L10n.t("正数=提前显示,负数=延后显示"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        // 校准过之后行为会变,就在动手的地方说清楚 —— 别让用户事后去猜。
        if pins.isPinned(summary.key) {
            Text(L10n.t("已校准的歌不再自动更换歌词源:后台一换歌词内容,这个校正值就会失效。把偏移改回 0 即解除"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        }
        // 卡片化布局：使用 RoundedRectangle 背景与描边包裹控件与说明，与相邻的 infoStrip 徽章和 wordTimingHint 提示条保持视觉语言一致。
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.06)))
    }

    private var wordTimingHint: some View {
        Label(
            // 提示用户若需手动修改主歌词，需先通过候选搜索替换为不含逐字时间轴的版本；译文与罗马音不受逐字时间轴限制。
            L10n.t("播放用的是逐字时间轴,改「歌词(LRC)」不生效。要手改主歌词,先用「联网搜索候选歌词」换一份不带逐字的;译文/罗马音不受影响"),
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        // 添加细边框描边，增强浅色模式下提示卡片与背景的对比度与边界清晰度。
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.18)))
    }

    /// latinIcon:图标必须画成拉丁字母才说得通(「罗马音」),理由见 LatinIconLabel。
    private func editorSection(title: String, icon: String, text: Binding<String>, minHeight: CGFloat, monospaced: Bool, disabled: Bool = false, latinIcon: Bool = false, showCopyButton: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Group {
                    if latinIcon {
                        LatinIconLabel(title, systemImage: icon)
                    } else {
                        Label(title, systemImage: icon)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                if showCopyButton {
                    Spacer()
                    // 文案跟着「解析决策」弹窗那个"拷贝"按钮统一(LyricsDecisionSheet),
                    // 全 App 只有这一个词表达"复制到剪贴板",不再多出一个"复制"当同义词。
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text.wrappedValue, forType: .string)
                        withAnimation { showCopyLyricsFeedback = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            withAnimation { showCopyLyricsFeedback = false }
                        }
                    } label: {
                        Label(showCopyLyricsFeedback ? L10n.t("已拷贝") : L10n.t("拷贝"),
                              systemImage: showCopyLyricsFeedback ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .disabled(text.wrappedValue.isEmpty)
                }
            }
            TextEditor(text: text)
                .font(monospaced ? .system(.body, design: .monospaced) : .system(.body))
                .frame(minHeight: minHeight)
                .padding(8)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                // 带逐字时间轴的歌曲禁用主歌词文本编辑，配合降低透明度提供明确的不可编辑反馈（需先通过搜索切换为无逐字候选方可编辑主歌词）。
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
        }
    }

    private func actionsRow(key: String, summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await store.saveEdit(key: key, lyrics: editedLyrics, tr: editedTr, roma: editedRoma)
                    // 歌词(LRC)内容可能改了,offset 的 key(内容指纹)也跟着变——重新
                    // 从磁盘读一遍权威内容(而不是假设"这条路径不碰 yrc 所以沿用旧值"),
                    // 保证跟真正持久化下来的内容一致。
                    let d = store.detail(for: key)
                    refreshOffsetState(artist: summary.artist, title: summary.title, lyrics: d.lyrics, yrc: d.yrc)
                    withAnimation { showSaveEditFeedback = true }
                    try? await Task.sleep(for: .seconds(1))
                    withAnimation { showSaveEditFeedback = false }
                }
            } label: {
                Label(showSaveEditFeedback ? L10n.t("已保存") : L10n.t("保存修改"),
                      systemImage: showSaveEditFeedback ? "checkmark" : "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)

            // 逐字时间轴具有最高打分权重。若需替换歌词，建议通过「联网搜索候选歌词」选择其它候选。EnrichCacheStore.removeWordTiming 保留用于底层维护。

            Spacer()
        }
    }

    // MARK: - 「重新自动匹配」实现

    @ViewBuilder
    private func rematchStatusRow(key: String, summary: EnrichCacheStore.Summary) -> some View {
        if rematchRunningKey == key {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(rematchTotal > 0
                     ? String(format: L10n.t("正在重新匹配…（%1$@/%2$@）"), "\(rematchDone)", "\(rematchTotal)")
                     : L10n.t("正在重新匹配…"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let result = rematchResult, result.key == key {
            Label(result.text, systemImage: result.icon)
                .font(.caption)
                .foregroundStyle(result.tint)
        }
    }

    /// 跑一轮"按自动解析规则重选"。冠军由 collector 算(-pick),这里只负责:决定要不要采纳、
    /// 采纳时把 collector 自动路径会写的那一整套字段一起写、以及如实告诉用户发生了什么。
    private func runRematch(key: String, summary: EnrichCacheStore.Summary) async {
        rematchGeneration += 1
        let generation = rematchGeneration
        rematchRunningKey = key
        rematchResult = nil
        rematchDone = 0
        rematchTotal = 0
        // 歌词评分算法对播放时长高度敏感（时长匹配奖励 +100~300 / 超长惩罚 -700，作为源内筛选的关键特征）。
        // 优先使用实际播放时长，缺失时回退到 resolved 时长。
        let duration = summary.durationSecs > 0 ? summary.durationSecs : store.resolvedDurationSecs(for: key)
        var last: LyricsSearchService.SearchUpdate?
        do {
            try await LyricsSearchService.shared.search(
                artist: summary.artist, title: summary.title, album: summary.album,
                durationSecs: duration, pickWinner: true, currentSource: summary.lyricsSource
            ) { update in
                guard generation == rematchGeneration else { return }
                last = update
                rematchDone = update.sourcesDone
                rematchTotal = update.sourcesTotal
            }
        } catch {
            guard generation == rematchGeneration else { return }
            rematchRunningKey = nil
            rematchResult = RematchOutcome(key: key, kind: .failed, text: error.localizedDescription)
            return
        }
        guard generation == rematchGeneration else { return }
        rematchRunningKey = nil
        await finishRematch(key: key, summary: summary, update: last)
    }

    private func finishRematch(key: String, summary: EnrichCacheStore.Summary,
                               update: LyricsSearchService.SearchUpdate?) async {
        func done(_ kind: RematchOutcome.Kind, _ text: String) {
            rematchResult = RematchOutcome(key: key, kind: kind, text: text)
        }
        guard let update, let pick = update.pick else {
            done(.failed, L10n.t("这一轮没拿到结论，可以再点一次"))
            return
        }
        let currentName = sourceDisplayName(summary.lyricsSource)
        let winner = update.candidates.first(where: { $0.source == pick.winner })
        let detail = store.detail(for: key)
        // 五条分支的判定全在 LyrimuseCore.LyricsRematchDecision(纯函数,selftest 覆盖)——
        // 其中"不可判"和"逐字保护"两条是**不该动**的分支,它们失效时的表现是"用户看得见的
        // 东西被悄悄弄没了"、不是报错,靠反复点按钮碰运气验证不了。
        let outcome = LyricsRematchDecision.decide(
            decidable: pick.decidable,
            winnerSource: winner == nil ? "" : pick.winner,
            currentHasWordTiming: summary.hasWordTiming,
            winnerHasWordTiming: !(winner?.lyricsYRC.isEmpty ?? true),
            sameSource: winner?.source == summary.lyricsSource,
            sameLyrics: winner?.lyrics == detail.lyrics,
            sameWordTiming: winner?.lyricsYRC == detail.yrc
        )
        switch outcome {
        case .keptNotDecidable:
            done(.kept, String(format: L10n.t("这一轮「%@」没应答，没有换（避免误降级），可以再点一次"), currentName))
            return
        case .keptNoCandidate:
            // 三种成因分别处理。
            if update.instrumental {
                // 若各源明确判定为纯音乐，将 instrumental 状态写回缓存，避免列表误标为无歌词。详情参见 markInstrumental。
                await store.markInstrumental(key: key)
                done(.empty, L10n.t("有源明确说这首是纯音乐，没有可用的歌词候选"))
            } else if !summary.hasPlainTextFallback,
                      let plain = update.candidates.first(where: { $0.isPlainTextOnly }) {
                // 当无有效时间戳候选且存在纯文本候选时，自动采纳纯文本兜底，规则与后台解析保持一致：
                // 仅在当前无词时填入，不覆盖已有歌词。
                await store.savePlainTextEdit(key: key, plainLyrics: plain.lyrics, source: plain.source)
                done(.empty, L10n.t("没有找到带时间戳的版本，已自动采纳一份纯文本兜底（可在「歌词窗口」里查看）"))
            } else if update.networkLooksDown {
                done(.empty, L10n.t("网络似乎不通，这一轮没搜到任何候选"))
            } else {
                done(.empty, L10n.t("这一轮没有一个能用的候选，保留现有的"))
            }
            return
        case .keptWouldLoseWordTiming:
            done(.kept, String(format: L10n.t("这一轮没搜到逐字歌词，保留现有的「%@」（逐字）——换过去会丢掉逐字时间轴"), currentName))
            return
        case .unchanged:
            // 内容虽未改变，但评估记录仍需持久化归档。详情参见 EnrichCacheStore.recordUnchangedRematchDecision。
            await store.recordUnchangedRematchDecision(key: key, decisionJSON: pick.decisionJSON)
            done(.unchanged, String(format: L10n.t("已重新匹配：仍然是「%1$@」（%2$@ 分），没有更好的"),
                                    sourceDisplayName(pick.winner), "\(pick.winnerScore)"))
            return
        case .adopt:
            break
        }
        guard let winner else {
            done(.failed, L10n.t("这一轮没拿到结论，可以再点一次"))
            return
        }
        let winnerName = sourceDisplayName(winner.source)
        // 采纳。markManual: false 是这颗按钮跟「采纳候选」最本质的区别 —— 这是算法自己的选择,
        // 不该被标成人工修正、更不该因此把这首歌永久排除在后续自动升级之外(见 saveEdit 的
        // 参数注释)。打分留痕那几个字段照 collector rescoreLyrics 写的那一套一起写。
        var decision: [String: Any]?
        if let data = pick.decisionJSON.data(using: .utf8),
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // 覆写 applied：collector 侧无法获取本地缓存正文，仅以是否换源作为近似判定。
            // 当执行到采纳分支时确已完成实际采纳，在此显式置为 true 保持决策记录与界面显示口径一致。
            obj["applied"] = true
            decision = obj
        }
        editedLyrics = winner.lyrics
        editedTr = winner.lyricsTr
        editedRoma = winner.lyricsRoma
        await store.saveEdit(
            key: key, lyrics: winner.lyrics, tr: winner.lyricsTr, roma: winner.lyricsRoma,
            yrc: winner.lyricsYRC, source: winner.source, markManual: false,
            // 空字符串显式清除用户选定的源约束，完全恢复为算法全源决策管理，与 manual_lyrics 状态同步清除。
            sourceChoice: "",
            score: pick.winnerScore, scoringVersion: pick.scoringVersion,
            resolvedDurationSecs: pick.resolvedDurationSecs,
            sourcesSeen: pick.sourcesSeen, sourcesResponded: pick.sourcesResponded,
            decision: decision
        )
        refreshOffsetState(artist: summary.artist, title: summary.title,
                           lyrics: winner.lyrics, yrc: winner.lyricsYRC)
        guard store.lastError == nil else {
            // 落盘/重启失败不在这里重复报:store.lastError 那条红字横幅已经在说了。
            rematchResult = nil
            return
        }
        if winner.source == summary.lyricsSource {
            // 同一来源在不同检索轮次可能匹配到不同版本（如更新的歌词或带逐字的版本）。
            // 分别明确指出正文或逐字时间轴的变化，避免模糊提示。
            let textChanged = winner.lyrics != detail.lyrics
            let timingChanged = winner.lyricsYRC != detail.yrc
            let template: String
            if textChanged && timingChanged {
                template = L10n.t("已重新匹配：还是「%1$@」，但正文和逐字时间轴都跟原来那份不一样，已换成这一轮抓到的（%2$@ 分）")
            } else if timingChanged {
                template = L10n.t("已重新匹配：还是「%1$@」，但逐字时间轴跟原来那份不一样，已换成这一轮抓到的（%2$@ 分）")
            } else {
                template = L10n.t("已重新匹配：还是「%1$@」，但正文跟原来那份不一样，已换成这一轮抓到的（%2$@ 分）")
            }
            done(.changed, String(format: template, winnerName, "\(pick.winnerScore)"))
        } else {
            done(.changed, String(format: L10n.t("已换成「%1$@」（%2$@ 分），原来是「%3$@」"),
                                  winnerName, "\(pick.winnerScore)", currentName))
        }
    }

    private func loadDetail(key: String) {
        let d = store.detail(for: key)
        editedLyrics = d.lyrics
        editedTr = d.tr
        editedRoma = d.roma
        if let summary = store.summaries.first(where: { $0.key == key }) {
            refreshOffsetState(artist: summary.artist, title: summary.title, lyrics: d.lyrics, yrc: d.yrc)
        }
    }

    // 跟 loadDetail 共用——"保存修改"/采纳联网候选歌词之后也要重新调这个:磁盘上的
    // 歌词内容变了,LyricsOffsetStore 的 key(内容指纹的一部分)跟着变,输入框要显示
    // "新内容对应的偏移值"(通常是 0,内容变了旧的校正值自然对不上、查不到),而不是
    // 继续显示改之前那份内容的偏移值。
    private func refreshOffsetState(artist: String, title: String, lyrics: String, yrc: String) {
        persistedLyricsForOffset = lyrics
        persistedYRCForOffset = yrc
        let key = LyricsOffsetStore.trackKey(artist: artist, title: title, lyrics: lyrics, lyricsYRC: yrc)
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: LyricsOffsetStore.shared.offset(forKey: key))
    }

    private func currentOffsetKey(_ summary: EnrichCacheStore.Summary) -> String {
        LyricsOffsetStore.trackKey(artist: summary.artist, title: summary.title, lyrics: persistedLyricsForOffset, lyricsYRC: persistedYRCForOffset)
    }

    private func applyOffsetEdit(_ summary: EnrichCacheStore.Summary) {
        // 输入解析失败（如非法字符或格式错误）时不修改当前偏移，输入框回退显示当前实际生效值，
        // 避免误操作将既有校准值覆盖为零。
        guard let seconds = Double(editedOffsetSeconds.trimmingCharacters(in: .whitespaces)) else {
            editedOffsetSeconds = AppSettings.formattedSeconds(ms: LyricsOffsetStore.shared.offset(forKey: currentOffsetKey(summary)))
            return
        }
        let ms = Int((seconds * 1000).rounded())
        // pinKey 用 summary.key(缓存 key 本身,已归一化)—— 播放侧算的是
        // EnrichCacheKeys.normalizedKey,两边必须是同一个身份,否则在这里校准的歌跟播放时
        // 钉住的歌是两条记录(见 LocalPlaybackSource.currentPinKey 的注释)。
        LyricsOffsetStore.shared.setOffset(ms, forKey: currentOffsetKey(summary), pinKey: summary.key)
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: ms)
        PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
        // 偏移改在 LyricsOffsetStore 里,不是这里的 raw 字典——summaries 里预算好的
        // offsetMs 和「仅人工修正」筛选的已校准判定都不会自己跟着变,得显式重建一次。
        store.rebuildSummaries()
    }

    private func resetOffsetEdit(_ summary: EnrichCacheStore.Summary) {
        LyricsOffsetStore.shared.reset(forKey: currentOffsetKey(summary), pinKey: summary.key)
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: 0)
        PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
        store.rebuildSummaries()
    }
}

// 列表"来源"列的胶囊徽章视图。
private struct SourceBadge: View {
    let source: String
    // 当行被选中且背景高亮（backgroundProminence 为 .increased）时，前景色回退为系统 .primary，
    // 确保与系统选区高亮色保持充足对比度；未选中时采用各来源对应的品牌专色。
    @Environment(\.backgroundProminence) private var backgroundProminence
    private var dimmed: Bool { backgroundProminence == .increased }

    var body: some View {
        Text(sourceDisplayName(source))
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(dimmed ? .primary : sourceColor(source))
            .background(dimmed ? Color.primary.opacity(0.18) : sourceColor(source).opacity(0.12), in: Capsule())
    }
}

// 详情页操作方块按钮：固定尺寸（92x54），垂直排布图标与简短文字，文本超长截断并附带完整提示。
private struct ActionTile: View {
    // 尺寸挂在这个类型自己身上(而不是 LyricsManagerView 那边)：Swift 的 private 是
    // 按"所在声明"限定作用域,不是按文件——LyricsManagerView 里的 private 常量,这个
    // 同文件但不同类型的 struct 是拿不到的。actionTileGrid 那边要用同一个宽度算
    // GridItem,直接读 ActionTile.size。
    static let size = CGSize(width: 92, height: 54)

    let icon: String
    let title: String
    let help: String
    var destructive: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(destructive ? Color.red : Color.secondary)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(destructive ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(destructive ? Color.red.opacity(0.22) : Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
    }
}

// internal 而非 private——「解析决策」弹窗(LyricsDecisionSheet)复用同一个胶囊样式,
// 跟 sourceColor/sourceDisplayName 放开成 internal 是同一个理由。
struct InfoChip: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct LyricsManagerRow: View {
    let summary: EnrichCacheStore.Summary
    // 同一张专辑在不同条目里原始大小写可能不一致(见 LyricsManagerView.albumDisplayNames
    // 的注释),这里传入调用方算好的统一展示文案,而不是自己再拿 summary.album 原样显示。
    // 跟 albumDisplayName 同一个道理:展示用的歌手名由外面算好传进来(优先 canonical),
    // 行视图自己不重复那套判断。
    let artistDisplayName: String
    let albumDisplayName: String
    // 列宽由调用方传入(而不是各自读单例):表头和每一行必须拿到**同一组**值才对得齐,
    // 而调用方那份已经过 fitted 收敛(窗口变窄时的临时等比缩放),行这边不能绕过它。
    let widths: LyricsColumnWidths
    // 「偏移」列固定宽度、不进 LyricsColumnWidths(见 LyricsManagerView.offsetColumnWidth
    // 的注释),但表头和行仍然要用同一个值才对得齐,所以照样由调用方传入。
    let offsetColumnWidth: CGFloat
    /// 点「N/9」徽章要做的事;nil = 这条没有决策存档,徽章退回纯展示(不可点、不换光标)。
    /// 由调用方按 `summary.hasDecision` 决定传不传 —— 判断留在外面,行视图只管渲染。
    var onShowDecision: (() -> Void)?

    // 每个标记一个固定宽度的槽位，没有对应状态时放透明占位以保持行间对齐。
    // 固定槽位宽度（16pt），配合 Spacer 推至列尾，保证各行状态徽章纵向严格对齐。
    private static let badgeIconWidth: CGFloat = 16

    // 状态徽章与搜索弹窗及详情页统一视觉语言（蓝=逐字、绿=自带译文、紫=罗马音/机译、橙=人工修正）。
    @ViewBuilder
    private func badge(_ systemName: String, tint: Color, on: Bool, help: String,
                       forceLatinIcon: Bool = false) -> some View {
        Image(systemName: systemName)
            // textformat.abc 会跟着 locale 变成"甲乙丙"(中文)/"あいう"(日文),用在
            // 罗马音上正好跟含义相反 —— 钉成拉丁变体,理由见 LatinIconLabel。
            .environment(\.locale, forceLatinIcon ? Locale(identifier: "en") : .current)
            .foregroundStyle(tint)
            .font(.caption2)
            .frame(width: Self.badgeIconWidth)
            .opacity(on ? 1 : 0)
            // 没这个状态时连提示也别弹,否则鼠标划过一片透明占位会冒出一堆解释
            .help(on ? help : "")
            .accessibilityHidden(!on)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(summary.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    // 把标记整组顶到歌名列的尾部 —— 这一步才是"几行之间对得齐"的关键。
                    // minLength 留 8pt,标题长到顶格时也不会跟标记挤在一起。
                    Spacer(minLength: 8)
                    // 搜索中占位行不显示徽章，避免默认初始状态与真实查无结果混淆。
                    if !summary.isSearching {
                        badge("pencil.circle.fill", tint: .orange, on: summary.isManual,
                              help: L10n.t("人工修正过"))
                        // 「来源已选定」：指示用户已固定该曲目所使用的歌词来源（自动重选仅在该来源内进行）。
                        badge("pin.circle.fill", tint: .indigo, on: !summary.sourceChoice.isEmpty,
                              help: String(format: L10n.t("来源已选定：%@"),
                                           sourceDisplayName(summary.sourceChoice)))
                        // on 根据 hasLyrics 判定正文存在性，避免无词条目显示为时间戳图标。
                        badge(summary.hasWordTiming ? "text.word.spacing" : "text.alignleft",
                              tint: summary.hasWordTiming ? .blue : .secondary, on: summary.hasLyrics,
                              help: summary.hasWordTiming ? L10n.t("逐字时间戳") : L10n.t("整行时间戳"))
                        // 区分机器翻译与歌词源自带译文配色（紫色为机器翻译，绿色为源自带译文），与详情页保持统一。
                        badge("character.book.closed",
                              tint: summary.lyricsTrSource == LyricsTranslationSource.machineSentinel ? .purple : .green,
                              on: summary.hasTranslation,
                              help: summary.lyricsTrSource == LyricsTranslationSource.machineSentinel
                                  ? L10n.t("译文(机器翻译)") : L10n.t("译文(歌词源自带)"))
                        badge("textformat.abc", tint: .purple, on: summary.hasRomanization,
                              help: L10n.t("罗马音"), forceLatinIcon: true)
                    }
                }
                if summary.isSearching {
                    Text(L10n.t("搜索歌词中…")).font(.caption2).foregroundStyle(.secondary)
                } else if !summary.hasLyrics {
                    // 确认纯音乐的曲目显示中性「纯音乐」标签而非红色警告。
                    if summary.isInstrumental {
                        Text(L10n.t("纯音乐")).font(.caption2).foregroundStyle(.secondary)
                    } else if summary.hasPlainTextFallback {
                        // 具备纯文本兜底歌词的曲目使用橙色标识，与无歌词状态区分。
                        Text(L10n.t("仅纯文本")).font(.caption2).foregroundStyle(.orange)
                    } else if summary.lastRoundHadNoResponder {
                        // 最近一轮解析中所有来源均未应答（如网络中断），先于 knownOnSources 判定，提示为无源应答。
                        Text(L10n.t("无源应答")).font(.caption2).foregroundStyle(.secondary)
                            .help(L10n.t("最近一轮解析时一个歌词源都没有应答（多半是那一刻网络不通），不是「这首歌没有词」。会自动重搜，也可以用工具栏「重试无歌词」立刻重来"))
                    } else if summary.knownOnSources {
                        // 来源存在曲目但未配歌词时显示中性状态提示。
                        Text(L10n.t("源里有歌、无词")).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.t("无歌词")).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(artistDisplayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: widths.artist, alignment: .leading)

            Text(albumDisplayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: widths.album, alignment: .leading)

            // 「来源」「偏移」两列在搜索中都还没有意义(没有来源、没有偏移可言)——留白
            // 而不是显示 SourceBadge("")/"0.0",那两种都会被误读成"已经查清楚了、结果
            // 就是空/零",跟"还没查完"是两个不同的结论。
            if summary.isSearching {
                Color.clear.frame(width: widths.source, alignment: .leading)
                Color.clear.frame(width: offsetColumnWidth, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    SourceBadge(source: summary.lyricsSource)
                    // 若应答来源较少（thinEvidence），显示如「3/9」的响应源比例徽章，分母动态取自 LyricsSource.allCases.count。
                    if summary.thinEvidence {
                        let total = LyricsSource.allCases.count
                        Text("\(summary.sourcesRespondedCount)/\(total)")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .foregroundStyle(.orange)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                            .onTapGesture { onShowDecision?() }
                            // 可点时换手型光标 —— 没有它,「能点」这件事在 macOS 上没有任何
                            // 视觉线索(第一版就是这么丢的)。不可点(没有决策存档)时不换。
                            .onHover { inside in
                                guard onShowDecision != nil else { return }
                                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                            .help(onShowDecision == nil
                                  ? String(format: L10n.t("这份歌词定下来时，%1$d 个歌词源里只有 %2$d 个给出了候选（老条目当年的源数可能少于 %1$d）"),
                                           total, summary.sourcesRespondedCount)
                                  : String(format: L10n.t("这份歌词定下来时，%1$d 个歌词源里只有 %2$d 个给出了候选（老条目当年的源数可能少于 %1$d）。点击查看是哪几个"),
                                           total, summary.sourcesRespondedCount))
                    }
                }
                .frame(width: widths.source, alignment: .leading)

                // 时间轴校正值,正数=提前显示、负数=延后显示(跟详情页「歌词时间轴偏移」
                // 输入框旁边那句说明同一个语义)。没调过/没歌词都会算成 0,展示上不特殊区分——
                // "0.0" 本身就如实说明了"没有偏移"。
                Text(AppSettings.signedSeconds(ms: summary.offsetMs))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: offsetColumnWidth, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
        // 让整行(含上下 3pt 内边距)都算命中这一行。不加的话在内边距上右键会被判成"点在
        // 空白处",而 contextMenu(forSelectionType:) 在空白处给的是空集 → 菜单不出现,
        // 表现成"右键有时候没反应"。
        .contentShape(Rectangle())
        // 把这一行内容的实际左右边界报给上层,表头照它对齐(见 RowContentBoundsKey 注释)。
        // 放在 .background 里,不影响布局。
        .background(
            GeometryReader { g in
                let f = g.frame(in: .named(LyricsColumnHeaderSpace.name))
                Color.clear.preference(key: RowContentBoundsKey.self,
                                       value: RowContentBounds(minX: f.minX, maxX: f.maxX))
            }
        )
    }
}
