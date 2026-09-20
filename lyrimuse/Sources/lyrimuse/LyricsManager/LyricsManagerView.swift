import SwiftUI
import Combine
import LyrimuseCore

@MainActor
final class AppLanguageObserver: ObservableObject {
    static let shared = AppLanguageObserver()
    @Published private(set) var appLanguage = ""
    private var sub: AnyCancellable?
    private init() {

        sub = AppSettings.shared.$appLanguage.removeDuplicates()
            .sink { [weak self] in self?.appLanguage = $0 }
    }
}

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

    case plainTextOnly = "仅纯文本"
    var id: String { rawValue }
}

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

    case evidenceAscending = "应答源最少"

    var id: String { rawValue }

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

    func sorted(_ items: [EnrichCacheStore.Summary]) -> [EnrichCacheStore.Summary] {
        let order = coreOrder
        return items
            .map { (key: $0.lyricsSortKey, item: $0) }
            .sorted { order.less($0.key, $1.key) }
            .map(\.item)
    }
}

extension EnrichCacheStore.Summary {

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

func primaryArtist(_ full: String) -> String {
    let seps = CharacterSet(charactersIn: "/、&,，")
    let first = full.components(separatedBy: seps).first ?? full
    return first.trimmingCharacters(in: .whitespaces)
}

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

func sourceColor(_ source: String) -> Color {
    switch source {
    case "netease": return .red
    case "qq": return .green
    case "kugou": return .cyan
    case "musixmatch": return .indigo
    case "lrclib": return .purple
    case "amll": return .orange

    case "lyricfind": return .pink

    case "kuwo": return .brown
    case "migu": return .mint
    case "deezer": return .teal
    default: return .secondary
    }
}

func sourceDisplayName(_ source: String) -> String {
    switch source {
    case "netease": return L10n.t("网易云音乐")
    case "qq": return L10n.t("QQ音乐")
    case "kugou": return L10n.t("酷狗音乐")
    case "musixmatch": return "Musixmatch"
    case "lrclib": return "LRCLIB"
    case "amll": return "AMLL"

    case "lyricfind": return "LyricFind"
    case "kuwo": return L10n.t("酷我音乐")
    case "migu": return L10n.t("咪咕音乐")

    case "deezer": return "Deezer"
    case "": return L10n.t("无来源")
    default: return source
    }
}

private enum LyricsColumnHeaderSpace {
    static let name = "lyricsColumnHeader"
}

private struct RowContentBounds: Equatable {
    var minX: CGFloat
    var maxX: CGFloat
}

private struct RowContentBoundsKey: PreferenceKey {
    static let defaultValue: RowContentBounds? = nil

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

            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(LyricsColumnHeaderSpace.name))
                    .onChanged { onDrag($0.location.x - $0.startLocation.x) }
                    .onEnded { _ in onDragEnd() }
            )
            .onTapGesture(count: 2, perform: onDoubleClick)
    }
}

@MainActor
private final class LyricsManagerWindowFramePersistence: ObservableObject {
    private static let frameKey = "np:lyricsManagerWindowFrame"
    private static let screenKey = "np:lyricsManagerWindowScreenID"

    private weak var window: NSWindow?
    private var frameObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var persistFrameTask: Task<Void, Never>?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window

        restorePersistedFrame(window)

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

        let persist: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePersistFrame() }
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main, using: persist)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main, using: persist)
    }

    private func schedulePersistFrame() {
        persistFrameTask?.cancel()
        persistFrameTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistFrame()
        }
    }

    private func persistFrame() {

        guard let window, window.isVisible else { return }
        let defaults = UserDefaults.standard
        defaults.set(NSStringFromRect(window.frame), forKey: Self.frameKey)

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

        guard let id = defaults.string(forKey: Self.screenKey),
              let screen = ScreenIdentity.screen(withID: id) else { return false }

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

struct LyricsManagerView: View {
    @ObservedObject private var store = EnrichCacheStore.shared
    @StateObject private var windowFrame = LyricsManagerWindowFramePersistence()
    @ObservedObject private var languageSettings = AppLanguageObserver.shared
    @StateObject private var nowPlaying = LyricsManagerNowPlayingObserver()

    @State private var searchText = ""
    @State private var committedSearchText = ""

    @FocusState private var searchFieldFocused: Bool

    @State private var selectedKeys: Set<String> = []

    @State private var pendingDeleteKeys: [String] = []
    @State private var showBatchDeleteConfirm = false

    @State private var showDeletedFeedback = false
    @State private var editedLyrics = ""

    @State private var editedLyricsBody = ""
    @State private var lyricsBodyEdit = LyricsBodyEdit(lyrics: "")
    @State private var editedTr = ""
    @State private var editedRoma = ""

    @State private var editedOffsetSeconds = ""
    @State private var persistedLyricsForOffset = ""
    @State private var persistedYRCForOffset = ""

    @ObservedObject private var columnWidths = LyricsColumnWidthsStore.shared

    @ObservedObject private var offsets = LyricsOffsetStore.shared

    @ObservedObject private var pins = LyricsPinStore.shared

    @State private var dragStartWidths: LyricsColumnWidths?

    @State private var rowContentBounds: RowContentBounds?
    @State private var showSearchSheet = false

    @State private var rematchRunningKey: String?
    @State private var rematchDone = 0
    @State private var rematchTotal = 0
    @State private var rematchResult: RematchOutcome?

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

    @State private var decisionTarget: DecisionSheetTarget?

    @State private var showSaveEditFeedback = false

    @State private var showCopyLyricsFeedback = false
    @State private var sourceFilter: SourceFilter = .all
    @State private var timingFilter: TimingFilter = .all
    @State private var manualOnly = false
    @State private var missingLyricsOnly = false
    @State private var instrumentalOnly = false

    @State private var thinEvidenceOnly = false

    @State private var fillSweepStatus: LyricsFillSweep.Info?
    @State private var artistFilter: String?
    @State private var albumFilter: String?
    @State private var sortOption: LyricsSortOption = .defaultOrder

    @State private var showRefreshedFeedback = false
    @State private var showClearAllConfirm = false
    @State private var showClearOffsetsConfirm = false
    @State private var showClearRadioOffsetsConfirm = false
    @State private var pendingRestoreSnapshot: LyricsBackupStore.Snapshot?
    @State private var showRestoreSnapshotConfirm = false
    @State private var restoreSnapshotResult: String?

    @State private var pendingAutoFocus = true

    @State private var placeholderSummary: EnrichCacheStore.Summary?

    private var hasActiveFilters: Bool {
        sourceFilter != .all || timingFilter != .all || manualOnly || missingLyricsOnly
            || instrumentalOnly || thinEvidenceOnly || artistFilter != nil || albumFilter != nil
    }

    private func albumDisplay(_ album: String) -> String {
        store.albumDisplayMap[toSimplified(album).lowercased()] ?? album
    }

    private final class FilteredCache {
        var token = "\u{0}"
        var generation = -1
        var result: [EnrichCacheStore.Summary] = []
    }
    @State private var filteredCache = FilteredCache()

    private var filtered: [EnrichCacheStore.Summary] {

        let generation = store.summariesGeneration
        let token = filterToken
        if filteredCache.token == token, filteredCache.generation == generation {
            return filteredCache.result
        }

        let q = committedSearchText.lowercased()
        let af = artistFilter.map { toSimplified($0).lowercased() }
        let bf = albumFilter.map { toSimplified($0).lowercased() }

        let base = placeholderSummary.map { store.summaries + [$0] } ?? store.summaries
        let result = base.filter { s in
            if !q.isEmpty {

                guard s.searchArtistLower.contains(q)
                    || s.searchDisplayArtistLower.contains(q)
                    || s.searchTitleLower.contains(q)
                    || s.searchAlbumLower.contains(q) else { return false }
            }

            if let af, s.normPrimaryArtist != af { return false }
            if let bf, s.normAlbum != bf { return false }
            guard sourceFilter.matches(s.lyricsSource) else { return false }
            switch timingFilter {
            case .all: break
            case .wordTiming: guard s.hasWordTiming else { return false }

            case .lineOnly: guard s.hasLyrics && !s.hasWordTiming else { return false }
            case .plainTextOnly: guard s.hasPlainTextFallback else { return false }
            }

            if manualOnly && !s.isManual && !pins.isPinned(s.key) { return false }

            if missingLyricsOnly && (s.hasLyrics || s.isInstrumental || s.hasPlainTextFallback) { return false }

            if instrumentalOnly && !s.isInstrumental { return false }

            if thinEvidenceOnly && !s.thinEvidence { return false }
            return true
        }
        filteredCache.token = token
        filteredCache.generation = generation
        filteredCache.result = result
        return result
    }

    private var sortedFiltered: [EnrichCacheStore.Summary] {
        sortOption.sorted(filtered)
    }

    private var singleSelectedKey: String? {
        selectedKeys.count == 1 ? selectedKeys.first : nil
    }

    private var filterToken: String {
        let sep = "\u{1F}"
        return [
            committedSearchText, sourceFilter.id, timingFilter.rawValue,
            String(manualOnly), String(missingLyricsOnly), String(instrumentalOnly),
            String(thinEvidenceOnly),
            artistFilter ?? "", albumFilter ?? "",

            placeholderSummary?.key ?? "",
        ].joined(separator: sep)
    }

    private func orderedVisibleKeys(_ keys: Set<String>) -> [String] {

        sortedFiltered.compactMap { !$0.isSearching && keys.contains($0.key) ? $0.key : nil }
    }

    private var selectedVisibleKeys: [String] { orderedVisibleKeys(selectedKeys) }

    private var selectableFiltered: [EnrichCacheStore.Summary] { filtered.filter { !$0.isSearching } }

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

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

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

                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(searchFieldFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                            lineWidth: searchFieldFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: searchFieldFocused)
            .frame(maxWidth: .infinity)

            Button(action: commitSearch) {
                Image(systemName: "magnifyingglass")
            }
            .disabled(searchText == committedSearchText)
        }
        .font(.callout)

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

                Picker(L10n.t("排序"), selection: $sortOption) {
                    ForEach(LyricsSortOption.allCases) { option in
                        Text(L10n.t(option.rawValue)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 170)

                Spacer()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterControlsGroup
                    Spacer(minLength: 12)
                    selectionAndFilterActions
                }

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

        .toggleStyle(PillChipToggleStyle())
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

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

    private var selectionAndFilterActions: some View {
        HStack(spacing: 12) {

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

        .lineLimit(1)

        .frame(width: 280, alignment: .trailing)
    }

    private struct PillChipToggleStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                configuration.label

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

        .frame(width: columnAreaWidth > 0 ? columnAreaWidth : nil, alignment: .leading)
        .padding(.leading, headerLeading)
        .padding(.trailing, columnAreaWidth > 0 ? 0 : Self.fallbackHPadding)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(L10n.t("重置列宽")) { columnWidths.reset() }
        }
    }

    private static let fallbackHPadding: CGFloat = 12

    private var headerLeading: CGFloat { rowContentBounds?.minX ?? Self.fallbackHPadding }

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

    private func resetDivider(_ index: Int) {
        let d = LyricsColumnWidths.defaults
        var w = columnWidths.widths
        switch index {
        case 0: w.artist = d.artist
        case 1: w.artist = d.artist; w.album = d.album
        default: w.album = d.album; w.source = d.source
        }
        columnWidths.widths = w
    }

    var body: some View {
        NavigationSplitView {

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

                        LyricsManagerRow(summary: summary, artistDisplayName: summary.artist, albumDisplayName: albumDisplay(summary.album), widths: shownWidths, offsetColumnWidth: Self.offsetColumnWidth,
                                         onShowDecision: summary.hasDecision ? { decisionTarget = DecisionSheetTarget(id: summary.key) } : nil)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))

                    .sheet(item: $decisionTarget) { target in
                        let latest = store.decodedDecision(for: target.id)
                        let applied = store.decodedAppliedDecision(for: target.id)

                        if let s = store.summaries.first(where: { $0.key == target.id }),
                           latest != nil || applied != nil {
                            LyricsDecisionSheet(summary: s, latest: latest, applied: applied)
                        }
                    }

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
                    }
                }

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

                    Text(String(format: L10n.t("这会删除当前全部 %d 条本地记录,包括你手动编辑、联网搜索采纳过的内容,已导出到本地的歌词文件也会一并删除。清空之前会自动备份一份,能从这个菜单里的「从自动备份恢复」找回来。下次播放会重新走一遍匹配解析"), store.summaries.count))
                }

                .onChange(of: nowPlaying.trackSignature) { _, _ in

                    refreshPlaceholder()
                    focusCurrentlyPlaying(scrollProxy: scrollProxy)
                }

                .task {
                    while !Task.isCancelled {

                        try? await Task.sleep(for: .seconds(fillSweepStatus?.running == true ? 2 : 5))
                        guard !Task.isCancelled else { continue }

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

                    placeholderDetailView(placeholder)
                } else if selectedKeys.count > 1 {
                    batchSelectionPanel
                } else {
                    ContentUnavailableView(L10n.t("选择左侧一首歌"), systemImage: "text.quote")
                }
            }

            .navigationTitle("")
        }
        .frame(minWidth: 780, idealWidth: 1040, minHeight: 540, idealHeight: 640)

        .background(LyricsManagerWindowCapture(controller: windowFrame).frame(width: 0, height: 0))

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

        .confirmationDialog(
            L10n.t("确定要从这份备份恢复歌词库吗?"),
            isPresented: $showRestoreSnapshotConfirm,
            titleVisibility: .visible
        ) {

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

        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }

        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in

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

    private var batchSelectionPanel: some View {
        let victims = Set(selectedVisibleKeys)
        let picked = store.summaries.filter { victims.contains($0.key) }
        let manual = picked.filter(\.isManual).count
        let wordTiming = picked.filter(\.hasWordTiming).count

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
    }

    private var cacheSizeText: String {
        EnrichCacheStore.byteText(store.totalSizeBytes)
    }

    private static func snapshotDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func byteText(_ bytes: Int) -> String {
        EnrichCacheStore.byteText(Int64(bytes))
    }

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

    private func focusCurrentlyPlaying(scrollProxy: ScrollViewProxy, animated: Bool = true) {
        let playback = PlaybackCoordinator.shared

        let normalizedKey = EnrichCacheKeys.normalizedKey(
            artist: playback.artist, title: playback.title, album: playback.album)
        let rawKey = "\(playback.artist)|\(playback.title)|\(playback.album)"

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

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        scrollProxy.scrollTo(key, anchor: .center)
                    }
                }
            } else {
                scrollProxy.scrollTo(key, anchor: .center)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    scrollProxy.scrollTo(key, anchor: .center)
                }
            }
        }
    }

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

                rematchStatusRow(key: key, summary: summary)
                infoStrip(summary)
                offsetSection(summary)

                if summary.hasWordTiming {
                    wordTimingHint
                }

                editorSection(title: L10n.t("歌词(LRC)"), icon: "text.alignleft", text: $editedLyricsBody, minHeight: 220, monospaced: true, disabled: summary.hasWordTiming, showCopyButton: true)

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

            if rematchRunningKey != nil {
                rematchGeneration += 1
                rematchRunningKey = nil
                LyricsSearchService.shared.cancelRunning()
            }
            rematchResult = nil
        }
        .sheet(isPresented: $showDecisionSheet) {

            let latest = store.decodedDecision(for: key)
            let applied = store.decodedAppliedDecision(for: key)
            if latest != nil || applied != nil {
                LyricsDecisionSheet(summary: summary, latest: latest, applied: applied)
            }
        }
        .sheet(isPresented: $showSearchSheet) {

            LyricsSearchSheet(
                artist: summary.artist, title: summary.title, album: summary.album,
                currentSource: summary.lyricsSource,

                currentFingerprint: EnrichCacheReader.lookup(artist: summary.artist, title: summary.title, album: summary.album)
                    .map { ManualPickLock.fingerprint(lyrics: $0.lyrics) }.flatMap { $0.isEmpty ? nil : $0 },
                durationSecs: summary.durationSecs
            ) { candidate in

                guard !candidate.isPlainTextOnly else {
                    let saved = await store.savePlainTextEdit(
                        key: key, plainLyrics: candidate.lyrics, source: candidate.source)
                    if saved { flashSaveEditFeedback() }
                    return saved
                }
                editedLyrics = candidate.lyrics
                editedTr = candidate.lyricsTr
                editedRoma = candidate.lyricsRoma

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

    private func flashSaveEditFeedback() {
        Task {
            withAnimation { showSaveEditFeedback = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showSaveEditFeedback = false }
        }
    }

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
                       disabled: rematchRunningKey != nil) {
                showSearchSheet = true
            }

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
                       destructive: true) {
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

        if pins.isPinned(summary.key) {
            Text(L10n.t("已校准的歌不再自动更换歌词源:后台一换歌词内容,这个校正值就会失效。把偏移改回 0 即解除"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        }

        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.06)))
    }

    private var wordTimingHint: some View {
        Label(

            L10n.t("播放用的是逐字时间轴,改「歌词(LRC)」不生效。要手改主歌词,先用「联网搜索候选歌词」换一份不带逐字的;译文/罗马音不受影响"),
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.18)))
    }

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

                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
        }
    }

    private func actionsRow(key: String, summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await store.saveEdit(key: key, lyrics: editedLyrics, tr: editedTr, roma: editedRoma)

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

            Spacer()
        }
    }

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

    private func runRematch(key: String, summary: EnrichCacheStore.Summary) async {
        rematchGeneration += 1
        let generation = rematchGeneration
        rematchRunningKey = key
        rematchResult = nil
        rematchDone = 0
        rematchTotal = 0

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

            if update.instrumental {

                await store.markInstrumental(key: key)
                done(.empty, L10n.t("有源明确说这首是纯音乐，没有可用的歌词候选"))
            } else if !summary.hasPlainTextFallback,
                      let plain = update.candidates.first(where: { $0.isPlainTextOnly }) {

                await store.savePlainTextEdit(key: key, plainLyrics: plain.lyrics, source: plain.source)
                done(.empty, L10n.t("没有找到带时间戳的版本，已自动采纳一份纯文本兜底"))
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

        var decision: [String: Any]?
        if let data = pick.decisionJSON.data(using: .utf8),
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            obj["applied"] = true
            decision = obj
        }
        editedLyrics = winner.lyrics
        editedTr = winner.lyricsTr
        editedRoma = winner.lyricsRoma
        await store.saveEdit(
            key: key, lyrics: winner.lyrics, tr: winner.lyricsTr, roma: winner.lyricsRoma,
            yrc: winner.lyricsYRC, source: winner.source, markManual: false,

            sourceChoice: "",
            score: pick.winnerScore, scoringVersion: pick.scoringVersion,
            resolvedDurationSecs: pick.resolvedDurationSecs,
            sourcesSeen: pick.sourcesSeen, sourcesResponded: pick.sourcesResponded,
            decision: decision
        )
        refreshOffsetState(artist: summary.artist, title: summary.title,
                           lyrics: winner.lyrics, yrc: winner.lyricsYRC)
        guard store.lastError == nil else {

            rematchResult = nil
            return
        }
        if winner.source == summary.lyricsSource {

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

        guard let seconds = Double(editedOffsetSeconds.trimmingCharacters(in: .whitespaces)) else {
            editedOffsetSeconds = AppSettings.formattedSeconds(ms: LyricsOffsetStore.shared.offset(forKey: currentOffsetKey(summary)))
            return
        }
        let ms = Int((seconds * 1000).rounded())

        LyricsOffsetStore.shared.setOffset(ms, forKey: currentOffsetKey(summary), pinKey: summary.key)
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: ms)
        PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()

        store.rebuildSummaries()
    }

    private func resetOffsetEdit(_ summary: EnrichCacheStore.Summary) {
        LyricsOffsetStore.shared.reset(forKey: currentOffsetKey(summary), pinKey: summary.key)
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: 0)
        PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
        store.rebuildSummaries()
    }
}

private struct SourceBadge: View {
    let source: String

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

private struct ActionTile: View {

    static let size = CGSize(width: 92, height: 54)

    let icon: String
    let title: String
    var help: String? = nil
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
        .help(help ?? "")
    }
}

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

    let artistDisplayName: String
    let albumDisplayName: String

    let widths: LyricsColumnWidths

    let offsetColumnWidth: CGFloat

    var onShowDecision: (() -> Void)?

    private static let badgeIconWidth: CGFloat = 16

    @ViewBuilder
    private func badge(_ systemName: String, tint: Color, on: Bool, help: String,
                       forceLatinIcon: Bool = false) -> some View {
        Image(systemName: systemName)

            .environment(\.locale, forceLatinIcon ? Locale(identifier: "en") : .current)
            .foregroundStyle(tint)
            .font(.caption2)
            .frame(width: Self.badgeIconWidth)
            .opacity(on ? 1 : 0)

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

                    Spacer(minLength: 8)

                    if !summary.isSearching {
                        badge("pencil.circle.fill", tint: .orange, on: summary.isManual,
                              help: L10n.t("人工修正过"))

                        badge("pin.circle.fill", tint: .indigo, on: !summary.sourceChoice.isEmpty,
                              help: String(format: L10n.t("来源已选定：%@"),
                                           sourceDisplayName(summary.sourceChoice)))

                        badge(summary.hasWordTiming ? "text.word.spacing" : "text.alignleft",
                              tint: summary.hasWordTiming ? .blue : .secondary, on: summary.hasLyrics,
                              help: summary.hasWordTiming ? L10n.t("逐字时间戳") : L10n.t("整行时间戳"))

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

                    if summary.isInstrumental {
                        Text(L10n.t("纯音乐")).font(.caption2).foregroundStyle(.secondary)
                    } else if summary.hasPlainTextFallback {

                        Text(L10n.t("仅纯文本")).font(.caption2).foregroundStyle(.orange)
                    } else if summary.lastRoundHadNoResponder {

                        Text(L10n.t("无源应答")).font(.caption2).foregroundStyle(.secondary)
                            .help(L10n.t("最近一轮解析时一个歌词源都没有应答（多半是那一刻网络不通），不是「这首歌没有词」。会自动重搜，也可以用工具栏「重试无歌词」立刻重来"))
                    } else if summary.knownOnSources {

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

            if summary.isSearching {
                Color.clear.frame(width: widths.source, alignment: .leading)
                Color.clear.frame(width: offsetColumnWidth, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    SourceBadge(source: summary.lyricsSource)

                    if summary.thinEvidence {
                        let total = LyricsSource.allCases.count
                        Text("\(summary.sourcesRespondedCount)/\(total)")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .foregroundStyle(.orange)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                            .onTapGesture { onShowDecision?() }

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

                Text(AppSettings.signedSeconds(ms: summary.offsetMs))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: offsetColumnWidth, alignment: .leading)
            }
        }
        .padding(.vertical, 3)

        .contentShape(Rectangle())

        .background(
            GeometryReader { g in
                let f = g.frame(in: .named(LyricsColumnHeaderSpace.name))
                Color.clear.preference(key: RowContentBoundsKey.self,
                                       value: RowContentBounds(minX: f.minX, maxX: f.maxX))
            }
        )
    }
}
