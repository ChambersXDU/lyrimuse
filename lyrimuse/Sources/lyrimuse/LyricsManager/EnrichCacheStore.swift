import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-manager")

// 歌词管理窗口的数据层。跟 EnrichCacheReader(单条只读查询)不同,这里要读写整个缓存
// 文件——collector(Go)是这个文件的唯一真源,自己在内存里维护整个 map,每次存盘都是
// "把整个内存 map 序列化覆盖写"(collector/enrich.go 的 saveEnrichCache()),不是增量
// 合并。所以这里每次改完必须做两件事:①先把改动落盘;②立刻踢一脚重启 collector 让它
// 从磁盘重新加载——不这么做的话,只要用户还在听歌,collector 随时可能因为解析别的曲目
// 而触发一次自己的存盘,用内存里那份"没看到这次改动"的旧状态整个覆盖回磁盘,悄悄撤销
// 刚做的修改。代价是每次保存/删除都会让 collector 短暂重启一次,"现在播放"推送有个
// 小间隙——个人工具偶尔手动操作这个代价可以接受,换来的是不用给 collector 另开一个
// 常驻 HTTP/IPC 接口。
//
// 用 JSONSerialization 而不是 Codable 读写整个文件:enrichEntry(collector/enrich.go)
// 目前有十几个字段,如果 Swift 侧用一个只声明"我关心的几个字段"的 Codable 结构体去
// 解码整个文件、改完再编码回去,**每一条**(不只是被编辑的那条)都会被这个窄结构体
// 悄悄丢掉它没声明的字段——这是会破坏其它上百条数据的严重 bug,而且 Go 那边字段以后
// 还可能再加。改用 [String: [String: Any]] 原始字典,只对被编辑/删除的那一条 key 做
// 字典级别的增删改,其它条目、以及被编辑条目里没碰过的字段,原样保留、逐字节不变。
//
// 歌词部分(lyrics/lyrics_tr/lyrics_roma/lyrics_yrc/lyrics_source/manual_lyrics 这 6 个
// 字段)另有 ~/.config/lyrimuse/lyrics/ 下的纯文本文件族作为权威源
// (collector 启动时会读这个文件夹、覆盖对应字段,见 collector/lyricsimport.go)——
// saveEdit/delete 因此在 raw[key] 字典操作之外,还调用
// writeLyricsFiles 同步写/删对应文件,两边由同一次用户操作一起改,靠"改完立刻重启
// collector"这个机制保持最终一致。
@MainActor
public final class EnrichCacheStore: ObservableObject {
    public static let shared = EnrichCacheStore()

    public struct Summary: Identifiable {
        public var id: String { key }
        public let key: String
        public let artist: String
        /// Official canonical artist resolved by collector (verified across NetEase/QQ/MusicBrainz).
        /// Reconciles cross-script aliases (e.g. Romanized vs Chinese characters across tracks in an album).
        /// Empty for multi-artist duets/collaborations, where consumers fallback to `artist`.
        public let canonicalArtist: String
        /// Track duration in seconds recorded during collector resolution.
        /// Consumed by candidate search scoring where duration matching carries significant weight.
        public let durationSecs: Double
        public let title: String
        public let album: String
        public let lyricsSource: String
        public let hasWordTiming: Bool
        public let isManual: Bool
        /// 用户在「联网搜索候选歌词」里选定的源(collector 侧 `lyrics_source_choice`)。
        /// 空 = 没选过,由算法自由选。跟 `isManual` 是两件独立的事,详情页各显示各的徽章。
        public let sourceChoice: String
        /// 这份歌词当前的时间轴校正值(毫秒),权威源是 LyricsOffsetStore——这里存的是
        /// buildSummaries 那一刻按内容指纹查出来的快照,不是实时值(见该函数的
        /// offsetsSnapshot 参数注释)。内容一换查出来的指纹就变,自然会变回 0,不需要
        /// 显式失效。
        public let offsetMs: Int
        // 译文是机翻补的(见 collector 的 translate.go)还是歌词源自带的社区翻译。
        // 空 = 社区翻译(老条目没有这个字段,读成空正是事实)。
        public let lyricsTrSource: String
        public let hasTranslation: Bool
        // 有没有罗马音标注(lyrics_roma)。值一直存在缓存里,只是列表一直没显示 ——
        // 详情页有这一栏、"搜索候选歌词"弹窗也有对应徽章,唯独列表看不出来。
        public let hasRomanization: Bool
        public let hasLyrics: Bool
        /// Indicates confirmed instrumental tracks lacking lyrics (e.g. LRCLIB instrumental or NetEase pureMusic).
        /// Distinguishes confirmed non-lyric audio from missing lyric search failures.
        public let isInstrumental: Bool
        /// Indicates plain text fallback availability (`plain_lyrics`) lacking timestamps.
        /// Distinguishes un-timed text availability from complete lyric absence.
        public let hasPlainTextFallback: Bool
        /// Indicates song exists in source catalog (valid NetEase/QQ Music song ID) but lyrics are unpublished.
        /// Displayed as neutral state rather than missing lyrics error.
        public let knownOnSources: Bool
        /// Indicates all configured sources failed to respond during the most recent resolution round.
        /// Evaluated via `LyrimuseCore.EnrichSourcePresence.lastRoundHadNoResponder`.
        /// Evaluated before `knownOnSources` in UI triage order.
        public let lastRoundHadNoResponder: Bool
        /// Number of sources that responded during the initial resolution round.
        /// Zero indicates legacy entries lacking the `lyrics_sources_responded` field.
        public let sourcesRespondedCount: Int

        /// Indicates resolution based on limited evidence (1...3 responding sources).
        /// Zero represents legacy entries where responder count was unrecorded.
        public var thinEvidence: Bool { (1...3).contains(sourcesRespondedCount) }
        /// Placeholder flag indicating an active initial search before collector outputs resolution results.
        /// Does not map to a persistent raw cache key; editing/deletion operations are bypassed.
        public let isSearching: Bool
        /// Indicates presence of persisted candidate scoring decision (`lyrics_decision`).
        /// Decoded lazily via `decodedDecision(for:)` to avoid parsing overhead during batch list reload.
        let hasDecision: Bool
        /// Timestamp of the most recent lyrics file modification (`lyrics/` directory mtime).
        /// Export paths skip writes when contents are byte-identical, preserving accurate mtimes.
        let lyricsUpdatedAt: Date?
        /// Timestamp when the entry was last resolved by the collector (`ts`).
        /// Serves as a secondary tie-breaker in sorting for un-exported or sourceless entries.
        let resolvedAt: Date?
        // Precomputed normalized strings for hot-path sorting and filtering to avoid repeated ICU transforms.
        /// toSimplified(primaryArtist(展示歌手名)).lowercased() —— 歌手筛选/排序用。
        let normPrimaryArtist: String
        /// toSimplified(album).lowercased() —— 专辑筛选/排序/归并字典的键。
        let normAlbum: String
        /// 搜索谓词用的四个小写副本(搜索框每敲一键全量过滤一遍,别逐行现 lowercased)。
        let searchArtistLower: String
        let searchDisplayArtistLower: String
        let searchTitleLower: String
        let searchAlbumLower: String

        /// Display artist string for list rows, preferring raw track artist when distinct to differentiate variant releases.
        var displayArtist: String { canonicalArtist.isEmpty ? artist : canonicalArtist }
    }

    @Published public private(set) var summaries: [Summary] = []
    /// True during asynchronous cache reloads, driving the loading placeholder in the manager list.
    @Published public private(set) var isLoading = false
    /// summaries 每重建一次 +1 —— 给视图侧的 filtered 缓存当失效键(见 LyricsManagerView),
    /// 数组本身没做 Equatable,靠这个代数判断"列表内容换过了没有"。
    private(set) var summariesGeneration = 0
    /// Maps normalized album keys (simplified + lowercased) to first-seen display title.
    /// Rebuilt alongside summaries to avoid repeated ICU transforms during list rendering.
    @Published private(set) var albumDisplayMap: [String: String] = [:]
    /// 筛选下拉的候选集,同样随 summaries 重建一次,不再每次 body 现算。
    @Published private(set) var distinctArtists: [String] = []
    @Published private(set) var distinctAlbums: [String] = []
    @Published public private(set) var lastError: String?
    // 缓存 JSON 文件本身 + lyrics/ 权威源文件夹里所有文件的总大小——"歌词管理"工具栏
    // 展示用,让用户知道这个"解析一次永久保留"的缓存实际占了多少磁盘空间。跟 reload()
    // 同一次磁盘扫描顺带算出来,不为这一个数字单独再打开一轮文件 I/O。
    @Published public private(set) var totalSizeBytes: Int64 = 0

    /// 「占用空间」的**唯一**渲染口径。
    ///
    /// 同一个字节数现在有三处要显示(「歌词管理」工具栏、自动备份菜单里每份快照、设置页
    /// 「歌词库」那一行),各自 `ByteCountFormatter()` 的话迟早在单位或小数位上分叉 ——
    /// 同一个数在两扇窗口里写法不同,用户只会以为自己看错了。放在**发布这个数字的类型上**
    /// 而不是某个 View 里:数字和它的写法待在一起,下一处要用的人一眼就找得到。
    ///
    /// `.file` 而不是限定 `.useMB`:总量从几百 KB(刚起步)到几十 MB(用了很久)跨度很大,
    /// 让系统按量级自己挑单位,也顺带跟着用户的地区习惯走。
    static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 最近一次破坏性操作(清空/批量删除)之前打的那份自动快照落在哪。nil = 这次没打成
    /// (库本来就是空的,或者写盘失败)。UI 据此如实告诉用户"能不能撤回",绝不能默认
    /// 有备份 —— 那比没有备份更危险。
    @Published private(set) var lastAutoSnapshotURL: URL?

    private static let cacheURL = LyrimusePaths.configFile("lyrimuse-enrich-cache.json")
    // 读 FeatureSettingsStore 的计算属性,而不是编译期定死的 static let——用户可在
    // "歌词"设置分类里自定义文件夹位置,这里必须跟 collector 那边(main.go 读
    // features.LyricsDir)认的是同一个位置,否则存/删歌词文件的目录跟 collector 实际
    // 读取的目录对不上。
    private static var lyricsDir: URL { FeatureSettingsStore.shared.effectiveLyricsDir }

    private var raw: [String: [String: Any]] = [:]
    // Set of keys present on disk during the last synchronization. Used as a snapshot record
    // alongside locallyEditedKeys and locallyDeletedKeys to track persistent state.
    private var knownKeys: Set<String> = []
    // 自上次落盘以来,**用户在这个窗口里真正动过**的 key。
    //
    // persist() 靠它把"整份覆盖"改成"读-改-写":写盘前重新读一次磁盘,只把这两个集合里的
    // key 盖上去,其余一律以盘上为准。没有它的话,开窗那一刻的内存快照会把窗口开着期间
    // collector 新写进去的任何东西(机翻译文、逐字时间轴、封面)静默回滚掉。
    private var locallyEditedKeys: Set<String> = []
    private var locallyDeletedKeys: Set<String> = []
    // persist() 从盘上并回了本次快照没有的 key —— 调用方据此决定要不要重刷列表。
    private var lastPersistPulledInNewKeys = false

    private init() {}

    /// 记下"这个 key 的内容是用户在窗口里改出来的",persist() 据此决定它盖过盘上的版本。
    /// 同时撤销可能存在的删除意图 —— 编辑一个刚被删掉的 key 意味着它又回来了。
    private func markLocallyEdited(_ key: String) {
        locallyEditedKeys.insert(key)
        locallyDeletedKeys.remove(key)
    }

    // 缓存文件设计上永久不清理("解析一次永久保留"),攒到几百条、几 MB 后
    // JSONSerialization 解析整份文件要 30ms 以上——若直接在 MainActor 上同步做,开窗/点
    // "刷新"都会卡一下,且随缓存变大越来越慢。这里把读文件+解析挪到后台线程,只在算完
    // 之后回 MainActor 赋值。box 用 @unchecked Sendable 包一层,是因为 JSONSerialization
    // 解出来的 [String: [String: Any]] 含 Any,编译器没法证明它是 Sendable,但这里的跨
    // 线程访问本来就有明确的先后顺序(detached task 算完、await 完了才读 box),不是真的
    // 并发写。
    /// 上一次成功读盘时缓存文件的 (mtime, size) 指纹 —— onlyIfChanged 的门控依据。
    private var lastLoadedFingerprint: FileFingerprint?

    struct FileFingerprint: Equatable {
        var mtime: Date
        var size: Int64
    }

    private nonisolated static func fileFingerprint(_ url: URL) -> FileFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return FileFingerprint(mtime: mtime, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// - Parameter onlyIfChanged: If true, skips reloading when the cache file (mtime, size)
    ///   fingerprint has not changed. This avoids redundant disk read, JSON deserialization, and
    ///   List diffing during frequent app activation events. Explicit refresh calls pass false.
    public func reload(onlyIfChanged: Bool = false) async {
        let cacheURL = Self.cacheURL
        if onlyIfChanged,
           let fp = Self.fileFingerprint(cacheURL),
           fp == lastLoadedFingerprint {
            return
        }
        // Cache size calculation runs asynchronously via `refreshSizeBytes()` to avoid
        // blocking summaries generation with filesystem enumeration.
        refreshSizeBytes()
        isLoading = summaries.isEmpty
        defer { isLoading = false }
        final class ResultBox: @unchecked Sendable {
            var obj: [String: [String: Any]]?
            var bundle: SummariesBundle?
            var fingerprint: FileFingerprint?
            var errorMessage: String?
        }
        let box = ResultBox()
        // 在进 Task.detached 之前取快照:LyricsOffsetStore 是 @MainActor 单例,detached
        // 闭包跑在后台线程,不能在里面同步访问它——纯字典拷贝,提前拿一份传进去即可。
        let offsetsSnapshot = LyricsOffsetStore.shared.offsetsSnapshot
        // 同理:lyricsDir 读的是 FeatureSettingsStore.shared(MainActor),在这儿取好。
        // 真正的目录枚举(I/O)在 buildSummaries 里、也就是后台跑。
        let lyricsDir = Self.lyricsDir
        await Task.detached(priority: .userInitiated) {
            box.fingerprint = Self.fileFingerprint(cacheURL)
            guard let data = try? Data(contentsOf: cacheURL) else {
                box.errorMessage = L10n.t("读取本地记录文件失败")
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
                box.errorMessage = L10n.t("解析本地记录文件失败")
                return
            }
            box.obj = obj
            // Summary generation and initial sorting execute in background; main thread handles published state updates.
            box.bundle = Self.buildSummaries(from: obj, offsetsSnapshot: offsetsSnapshot, lyricsDir: lyricsDir)
        }.value
        if let obj = box.obj, let bundle = box.bundle {
            raw = obj
            knownKeys = Set(obj.keys)
            lastLoadedFingerprint = box.fingerprint
            // 这两个集合描述的是"相对上一份快照做了什么改动";快照整个换掉之后它们就失去
            // 参照,留着会让下一次 persist 拿旧意图去盖新内容。所有改动路径都是"改完立刻
            // persist",正常情况下它们此刻本来就是空的 —— 这里只是把不变量写死。
            locallyEditedKeys.removeAll()
            locallyDeletedKeys.removeAll()
            lastError = nil
            applySummaries(bundle)
        } else {
            raw = [:]
            lastLoadedFingerprint = nil
            lastError = box.errorMessage ?? L10n.t("读取本地记录文件失败")
            applySummaries(Self.buildSummaries(from: [:], offsetsSnapshot: offsetsSnapshot, lyricsDir: Self.lyricsDir))
        }
    }

    // nonisolated——从 reload() 里的 Task.detached 闭包(非 MainActor 上下文)调用,
    // 这两个纯函数只碰 FileManager/URL,不touch 任何 actor 隔离状态,标 nonisolated
    // 避免编译器在严格并发检查下要求这里额外 await。
    private nonisolated static func fileSizeBytes(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private nonisolated static func directorySizeBytes(_ dir: URL) -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return urls.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    // key 的拼法是 collector 那边的 "歌手|歌名|专辑"(见 collector/enrich.go:93)。
    // 只按前两个 "|" 分,专辑名里偶尔出现的 "|" 不会把切分打乱(艺人/歌名本身含 "|"
    // 这种更罕见的情况不额外处理)。
    /// 把缓存条目里的 lyrics_decision 子字典解回结构体。整个文件是 JSONSerialization
    /// 读进来的字典,这一个字段单独走一遍 JSONDecoder —— 结构嵌套了两层(候选表里还有
    /// 得分明细),手工逐键取值会写出一屏 as? 阶梯。解不出来(老条目没有/以后格式变了)
    /// 一律 nil,不影响其余字段。
    private static func decodeDecision(_ value: Any?) -> LyricsResolutionDecision? {
        guard let dict = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(LyricsResolutionDecision.self, from: data)
    }

    // nonisolated:纯字符串切分,buildSummaries 在后台构建线程也要调。
    private nonisolated static func splitKey(_ key: String) -> (artist: String, title: String, album: String)? {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// summaries 及其派生物(归并字典/筛选下拉候选)的一次性构建结果。
    private struct SummariesBundle {
        var summaries: [Summary]
        var albumDisplayMap: [String: String]
        var distinctArtists: [String]
        var distinctAlbums: [String]
    }

    /// 把一份构建结果发布出去。跟 buildSummaries 拆开:构建是纯函数(reload 时在后台跑,
    /// 保存/删除时在主线程同步跑 —— 预计算归一化键之后单次只剩字典取值+元组排序,几 ms),
    /// 发布必须在 MainActor。
    private func applySummaries(_ bundle: SummariesBundle) {
        summaries = bundle.summaries
        summariesGeneration &+= 1
        albumDisplayMap = bundle.albumDisplayMap
        distinctArtists = bundle.distinctArtists
        distinctAlbums = bundle.distinctAlbums
    }

    // public:「歌词管理」详情页调过/重置过时间轴偏移之后也要调这个——那份改动只落在
    // LyricsOffsetStore(不是这里的 raw 字典),summaries 里预算好的 offsetMs 不会自己
    // 跟着变,得靠调用方显式喊一次重建(见 LyricsManagerView.applyOffsetEdit)。
    public func rebuildSummaries() {
        applySummaries(Self.buildSummaries(from: raw, offsetsSnapshot: LyricsOffsetStore.shared.offsetsSnapshot,
                                           lyricsDir: Self.lyricsDir))
    }

    // Sorting keys must mirror display grouping rules to prevent identical albums/artists
    // with script differences (e.g. Traditional vs Simplified Chinese or Romanized aliases)
    // from splitting across the list. Normalized keys (`normPrimaryArtist`, `normAlbum`)
    // are precomputed on Summary construction so list comparator operations only evaluate tuple comparisons.
    //
    // Album grouping keys and display strings are decoupled: normalized keys drive grouping and sorting,
    // while `albumDisplayMap` tracks first-seen verbatim casing/scripting for display across components.
    /// - Parameter offsetsSnapshot: LyricsOffsetStore 整份字典的一次性快照(调用方在
    ///   MainActor 上下文取好再传进来,见两处调用点的注释)——这个函数本身要能在后台线程跑,
    ///   不能在这里同步访问那个 @MainActor 单例。
    /// Scans the lyrics directory and returns a map of folded base filenames to their latest file modification date.
    ///
    /// Uses single-pass directory enumeration with batch attribute queries to minimize filesystem syscalls.
    /// Evaluates all companion suffixes (.lrc, translation, romanization, word-timing) to capture recent updates.
    /// Keys are case-folded to support case-insensitive filesystem lookups.
    private nonisolated static func lyricsFileModificationDates(in dir: URL) -> [String: Date] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [:] }
        var dates: [String: Date] = [:]
        dates.reserveCapacity(entries.count)
        for url in entries {
            let name = url.lastPathComponent
            // 后缀要**从长到短**匹配:".tr.lrc" 也以 ".lrc" 结尾,先撞上 ".lrc" 会把基名
            // 切成 "xxx.tr",跟主文件分成两组、两边都算错。
            guard let suffix = Self.lyricsFileSuffixesLongestFirst.first(where: { name.hasSuffix($0) })
            else { continue }
            let base = String(name.dropLast(suffix.count)).lowercased()
            guard !base.isEmpty,
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate
            else { continue }
            if let known = dates[base], known >= date { continue }
            dates[base] = date
        }
        return dates
    }

    /// Suffixes matched longest-first to prevent premature matching (e.g. .tr.lrc before .lrc).
    nonisolated private static let lyricsFileSuffixesLongestFirst =
        EnrichCacheKeys.lyricsFileSuffixes.sorted { $0.count > $1.count }

    /// - Parameter lyricsDir: 歌词导出目录的一次性快照。跟 offsetsSnapshot 同一个理由 ——
    ///   它来自 `FeatureSettingsStore.shared`(MainActor),调用方在 MainActor 上取好传进来,
    ///   目录枚举这段 I/O 留在这个后台函数里跑。
    private nonisolated static func buildSummaries(
        from raw: [String: [String: Any]], offsetsSnapshot: [String: Int], lyricsDir: URL
    ) -> SummariesBundle {
        let lyricsFileDates = Self.lyricsFileModificationDates(in: lyricsDir)
        // `offsetsSnapshot` contains manually calibrated timing offsets, keyed by artist, title,
        // and full lyrics/YRC content SHA256 fingerprint. Calculating SHA256 fingerprints across
        // thousands of raw items is computationally expensive.
        // Extract the `artist|title` prefix from offset keys beforehand. Fast membership checks
        // avoid expensive SHA256 hashing for entries without configured offset overrides.
        let offsetPrefixes: Set<String> = Set(offsetsSnapshot.keys.compactMap { key in
            guard let sep = key.range(of: "|", options: .backwards) else { return nil }
            return String(key[..<sep.lowerBound])
        })
        var items = raw.keys.compactMap { key -> Summary? in
            guard let parts = Self.splitKey(key) else { return nil }
            let entry = raw[key] ?? [:]
            let lyrics = entry["lyrics"] as? String ?? ""
            let lyricsYRC = entry["lyrics_yrc"] as? String ?? ""
            let canonical = entry["canonical_artist"] as? String ?? ""
            let display = canonical.isEmpty ? parts.artist : canonical
            // trackKey 要用播放时真正生效的那份内容指纹,所以拿这条原始 artist/title(跟
            // 播放侧同一套归一化,见 LyricsOffsetStore.trackKey 内部的说明),不是展示名。
            let offsetPrefix = "\(EnrichCacheKeys.cleanTag(parts.artist))|\(EnrichCacheKeys.normalizedTitle(parts.title))"
            let offsetMs: Int
            if offsetPrefixes.contains(offsetPrefix) {
                let offsetKey = LyricsOffsetStore.trackKey(artist: parts.artist, title: parts.title,
                                                            lyrics: lyrics, lyricsYRC: lyricsYRC)
                offsetMs = offsetsSnapshot[offsetKey] ?? 0
            } else {
                offsetMs = 0
            }
            return Summary(
                key: key,
                artist: parts.artist,
                canonicalArtist: canonical,
                // Prefer `resolved_duration_secs` over `duration_secs`. `duration_secs` is only
                // written if zero on the collector side and may freeze incorrect audio durations.
                // In contrast, `resolved_duration_secs` refreshes on every automatic match with
                // verified timing. Fall back to `duration_secs` if resolved duration is absent, or 0.
                durationSecs: (entry["resolved_duration_secs"] as? Double).flatMap { $0 > 0 ? $0 : nil }
                    ?? entry["duration_secs"] as? Double ?? 0,
                title: parts.title,
                album: parts.album,
                lyricsSource: entry["lyrics_source"] as? String ?? "",
                hasWordTiming: !lyricsYRC.isEmpty,
                isManual: entry["manual_lyrics"] as? Bool ?? false,
                sourceChoice: entry["lyrics_source_choice"] as? String ?? "",
                offsetMs: offsetMs,
                lyricsTrSource: entry["lyrics_tr_source"] as? String ?? "",
                hasTranslation: !((entry["lyrics_tr"] as? String ?? "").isEmpty),
                hasRomanization: !((entry["lyrics_roma"] as? String ?? "").isEmpty),
                hasLyrics: !lyrics.isEmpty,
                isInstrumental: entry["instrumental"] as? Bool ?? false,
                hasPlainTextFallback: !((entry["plain_lyrics"] as? String ?? "").isEmpty),
                knownOnSources: Self.knownOnSources(entry),
                lastRoundHadNoResponder: Self.lastRoundHadNoResponder(entry),
                sourcesRespondedCount: (entry["lyrics_sources_responded"] as? [Any])?.count ?? 0,
                isSearching: false, // 这一条来自 raw,真实存在;占位行的构造点在 LyricsManagerView
                hasDecision: entry["lyrics_decision"] != nil || entry["lyrics_decision_applied"] != nil,
                // 两次 O(1) 查找:普通名、以及带哈希后缀的消歧名(见 exportBaseName —— 到底
                // 用哪个取决于有没有别的 key 折叠后同名,那个判断本身是 O(n),不能在这个
                // 逐条循环里做)。都查不到 = 磁盘上没有这条的歌词文件。
                lyricsUpdatedAt: lyricsFileDates[EnrichCacheKeys.sanitizeFilename(key).lowercased()]
                    ?? lyricsFileDates[EnrichCacheKeys.disambiguatedName(forKey: key).lowercased()],
                // `ts` 是 Unix 秒。JSONSerialization 对整数给的是 NSNumber,用 Double
                // 取一次就够(秒级精度远在 Double 的安全整数范围内);<=0 当没有。
                resolvedAt: {
                    let ts = (entry["ts"] as? Double) ?? 0
                    return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
                }(),
                normPrimaryArtist: toSimplified(primaryArtist(display)).lowercased(),
                normAlbum: toSimplified(parts.album).lowercased(),
                searchArtistLower: parts.artist.lowercased(),
                searchDisplayArtistLower: display.lowercased(),
                searchTitleLower: parts.title.lowercased(),
                searchAlbumLower: parts.album.lowercased()
            )
        }
        items.sort {
            ($0.normPrimaryArtist, $0.normAlbum, $0.title) < ($1.normPrimaryArtist, $1.normAlbum, $1.title)
        }
        // 归并展示名按排序后顺序首见 —— 跟原来"按 summaries 已有顺序取第一次出现"语义一致。
        var albumMap: [String: String] = [:]
        var artistMap: [String: String] = [:]
        for s in items {
            if !s.album.isEmpty, albumMap[s.normAlbum] == nil { albumMap[s.normAlbum] = s.album }
            let rawArtist = primaryArtist(s.displayArtist)
            if !rawArtist.isEmpty, artistMap[s.normPrimaryArtist] == nil {
                artistMap[s.normPrimaryArtist] = rawArtist
            }
        }
        return SummariesBundle(
            summaries: items,
            albumDisplayMap: albumMap,
            distinctArtists: Array(Set(artistMap.values)).sorted(),
            distinctAlbums: Array(Set(albumMap.values)).sorted()
        )
    }

    /// Track duration in seconds recorded during the most recent successful match (`resolved_duration_secs`).
    /// Serves as fallback for rematch workflows when explicit track duration is unavailable.
    public func resolvedDurationSecs(for key: String) -> Double {
        raw[key]?["resolved_duration_secs"] as? Double ?? 0
    }

    /// Checks whether an entry exists for the given key, supporting search placeholder dismissal.
    /// Performs an exact dictionary lookup first, falling back to loose key comparison (`EnrichCacheKeys.looseKey`)
    /// to reconcile Traditional vs Simplified Chinese variants in album or artist metadata reported by players.
    public func hasEntry(forKey key: String) -> Bool {
        if raw[key] != nil { return true }
        let loose = EnrichCacheKeys.looseKey(key)
        return raw.keys.contains { EnrichCacheKeys.looseKey($0) == loose }
    }

    /// 懒解码某条的解析决策记录 —— 只在打开「解析决策」弹窗那一刻按 key 解一条,
    /// 见 Summary.hasDecision 的注释。
    func decodedDecision(for key: String) -> LyricsResolutionDecision? {
        Self.decodeDecision(raw[key]?["lyrics_decision"])
    }

    /// Decodes the applied decision record (`lyrics_decision_applied`), representing the source and rationale
    /// behind the currently active lyrics (persisted separately from the latest evaluation in `lyrics_decision`).
    func decodedAppliedDecision(for key: String) -> LyricsResolutionDecision? {
        Self.decodeDecision(raw[key]?["lyrics_decision_applied"])
    }

    // 返回值含 yrc:「歌词管理」的单曲歌词时间轴偏移输入框需要跟 LocalPlaybackSource
    // 用同一份内容(lyrics+lyricsYRC)算出来的指纹去查/存 LyricsOffsetStore,不然算出来
    // 的 key 对不上真正播放时用的那个 key。
    public func detail(for key: String) -> (lyrics: String, tr: String, roma: String, yrc: String) {
        let entry = raw[key] ?? [:]
        return (
            entry["lyrics"] as? String ?? "",
            entry["lyrics_tr"] as? String ?? "",
            entry["lyrics_roma"] as? String ?? "",
            entry["lyrics_yrc"] as? String ?? ""
        )
    }

    // yrc defaults to nil: manual plaintext edits leave `lyrics_yrc` intact.
    // When adopting a candidate from online search, a non-nil value is passed to replace or clear
    // the word-by-word timestamp timeline so it matches the newly adopted lyrics content.
    //
    // Similarly, `source` defaults to nil: adopting candidates sets `source` to the candidate's provider.
    // Plaintext modifications clear the source field since manual edits are no longer pure provider copies,
    // reflecting the manual edit badge instead.
    /// - markManual: Default true (manual edits/adoptions set `manual_lyrics = true`). Rematch passes false.
    /// - score / scoringVersion: Must be passed in pairs to maintain baseline constraints in collector scoring.
    /// - sourcesSeen / sourcesResponded / resolvedDurationSecs / decision: Mirror collector `rescoreLyrics` attributes.
    /// - Parameter sourceChoice: Explicit user-selected source, cleared when empty string is passed.
    /// - Parameter fromManualPick: Sets content fingerprint `manual_pick_sha` for retroactive locking support.
    /// - Returns: True if modifications were persisted to disk.
    @discardableResult
    public func saveEdit(key: String, lyrics: String, tr: String, roma: String, yrc: String? = nil,
                         source: String? = nil, markManual: Bool = true,
                         sourceChoice: String? = nil, fromManualPick: Bool = false,
                         score: Int? = nil, scoringVersion: Int? = nil,
                         resolvedDurationSecs: Double? = nil,
                         sourcesSeen: [String]? = nil, sourcesResponded: [String]? = nil,
                         decision: [String: Any]? = nil) async -> Bool {
        var entry = raw[key] ?? [:]
        // When translation text changes, clear stale language tags (`lyrics_tr_lang`, `lyrics_tr_source`,
        // `translation_ts`, `translation_retry_count`) so collector re-evaluates translation requirements.
        let previousTr = raw[key]?["lyrics_tr"] as? String ?? ""
        if tr != previousTr {
            for stale in ["lyrics_tr_lang", "lyrics_tr_source",
                          "translation_ts", "translation_retry_count"] {
                entry.removeValue(forKey: stale)
            }
        }
        // When lyrics change but romanization is unmodified, clear stale romanization (`lyrics_roma`)
        // to prevent misaligned pronunciation display over modified lyrics text.
        let previousLyrics = raw[key]?["lyrics"] as? String ?? ""
        let previousRoma = raw[key]?["lyrics_roma"] as? String ?? ""
        let romaDescribesOldLyrics =
            !roma.isEmpty && lyrics != previousLyrics && roma == previousRoma
        let effectiveRoma = romaDescribesOldLyrics ? "" : roma
        entry["lyrics"] = lyrics
        entry["lyrics_tr"] = tr
        entry["lyrics_roma"] = effectiveRoma
        if markManual {
            entry["manual_lyrics"] = true
        } else {
            entry.removeValue(forKey: "manual_lyrics")
        }
        // 用户选定的源。**必须在 markManual 分支之外** —— 这条机制的整个要点就是
        // 「采纳一条候选」不再置 manual_lyrics(那会永久冻结这首歌),而是只记下选了哪个源,
        // 所以它恰恰是在 markManual == false 的那条路径上写的。写在 if 里面等于永远写不到。
        //
        // nil = 不动这个字段(普通的保存/编辑不该悄悄改它);空串 = 显式清掉(「交回算法」)。
        // 见 saveEdit 的参数注释与 collector 侧 enrichEntry.LyricsSourceChoice。
        if let sourceChoice {
            if sourceChoice.isEmpty {
                entry.removeValue(forKey: "lyrics_source_choice")
            } else {
                entry["lyrics_source_choice"] = sourceChoice
            }
        }
        // 打分留痕:成对写(理由见上面的参数注释)。传 nil 就一个都不动 —— 手动编辑改的是
        // 正文,旧分数虽然已经不描述新内容了,但那条路径靠 manual_lyrics 整个关掉了自愈,
        // 不会有人拿这个分数去做比较。
        if let score, let scoringVersion {
            entry["lyrics_score"] = score
            entry["lyrics_scoring_version"] = scoringVersion
        }
        if let resolvedDurationSecs, resolvedDurationSecs > 0 {
            entry["resolved_duration_secs"] = resolvedDurationSecs
        }
        if let sourcesSeen, !sourcesSeen.isEmpty { entry["lyrics_sources_seen"] = sourcesSeen }
        if let sourcesResponded, !sourcesResponded.isEmpty {
            entry["lyrics_sources_responded"] = sourcesResponded
        }
        // 两槽一起写:decision 只在「重新自动匹配」**采纳**那条路径传进来(finishRematch
        // 已把 applied 覆写成 true),采纳即"当前歌词的出处",跟 collector 侧三个自动
        // 写入站点的分槽规则一致(见 collector/decision.go 的两槽说明)。
        if let decision {
            entry["lyrics_decision"] = decision
            entry["lyrics_decision_applied"] = decision
        }
        if let yrc {
            if yrc.isEmpty {
                entry.removeValue(forKey: "lyrics_yrc")
            } else {
                entry["lyrics_yrc"] = yrc
            }
        }
        if let source, !source.isEmpty {
            entry["lyrics_source"] = source
        } else {
            entry.removeValue(forKey: "lyrics_source")
        }
        // 「这份内容是用户手动采纳的候选」的留痕。**纯记录,零行为影响** —— collector
        // 一个字节都不读它(grep manual_pick_sha 在 lyrimuse-collector/ 下应该零命中),
        // 它唯一的消费方是 applyManualPickLock:「手动选定歌词后锁定」开关被打开时,
        // 靠它找出"哪些歌是用户手动选的、而且当前这份内容还就是他选的那一份"。
        //
        // ⚠️ 存内容指纹而不是一个 bool,是这套机制成立的关键:关态下这首歌随时可能被自愈
        // 路径换成别的版本(那正是关态的语义),那之后再打开开关,锁住的就会是一份用户
        // **从没选过**的内容。指纹对不上 = 我选的那份已经不在了 = 不锁,这条判断是自证的,
        // 不依赖 collector 任何一处"换歌词时记得清标记"的配合(那种分散的清理点漏一处
        // 就错,而且错得无声)。
        //
        // 由 saveEdit 自己按刚写进去的正文算,不让调用方传 —— 调用方传的话就有"指纹算的
        // 是另一份内容"这种对不上的可能。非手动采纳的路径(手改正文/重新自动匹配)一律
        // 清掉:它们都重写了 lyrics,旧指纹既已失效也没有意义。
        // 指纹为空(正文只剩元数据标签、归一化后没有词)时同样按"没有留痕"处理 —— 写一个
        // 空字符串进去只会多一个永远匹配不上的字段。
        let pickSHA = fromManualPick ? ManualPickLock.fingerprint(lyrics: lyrics) : ""
        if pickSHA.isEmpty {
            entry.removeValue(forKey: "manual_pick_sha")
        } else {
            entry["manual_pick_sha"] = pickSHA
        }
        raw[key] = entry
        markLocallyEdited(key)
        writeLyricsFiles(
            key: key, lyrics: lyrics, tr: tr, roma: effectiveRoma,
            yrc: entry["lyrics_yrc"] as? String ?? "",
            source: entry["lyrics_source"] as? String ?? "",
            manual: markManual
        )
        // Update summaries immediately for UI responsiveness, followed by persistence and queued background restart.
        rebuildSummaries()
        guard await persist() else { return false }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
        return true
    }

    /// 开关翻面前后要告诉用户的那几个数。
    ///
    /// 光有"改了几首"不够 —— 0 首有两种完全不同的成因(从没手动选过 / 选过但内容已被自动
    /// 换掉),界面得能分开说,否则就只剩一个静默的"什么都没发生"。见 ManualPickLock.PickState。
    public struct ManualPickLockStats: Sendable {
        /// 有留痕的总数(不论内容还在不在)。
        public var picked = 0
        /// 其中内容仍是当初选定那一份的。
        public var stillOriginal = 0
        /// 这次真会被改动的(内容还在 + 锁定状态跟目标相反)。
        public var targets = 0
    }

    public func manualPickLockStats(locking: Bool) -> ManualPickLockStats {
        var stats = ManualPickLockStats()
        for entry in raw.values {
            let state = ManualPickLock.state(
                sha: entry["manual_pick_sha"] as? String,
                lyrics: entry["lyrics"] as? String ?? "")
            guard state != .neverPicked else { continue }
            stats.picked += 1
            guard state == .original else { continue }
            stats.stillOriginal += 1
            if ((entry["manual_lyrics"] as? Bool) ?? false) != locking { stats.targets += 1 }
        }
        return stats
    }

    /// 「手动选定歌词后锁定」开关翻面时,受影响的 key。判据本身是 ManualPickLock.shouldFlip
    /// (纯函数,摆在 LyrimuseCore 里好让 selftest 够得着,见那个文件的头注);这里只负责
    /// 把缓存条目的字段喂进去。
    public func manualPickLockTargets(locking: Bool) -> [String] {
        raw.compactMap { key, entry in
            ManualPickLock.shouldFlip(
                sha: entry["manual_pick_sha"] as? String,
                lyrics: entry["lyrics"] as? String ?? "",
                isLocked: (entry["manual_lyrics"] as? Bool) ?? false,
                locking: locking
            ) ? key : nil
        }
    }

    /// 把上面那批 key 的 `manual_lyrics` 批量翻成 `locking`,返回真正改动的条数。
    ///
    /// ⚠️ **必须连 .lrc 文件头一起重写**。导出的歌词文件头里那行 `[manual:1]` 是这个标记的
    /// 第二份存档,collector 启动时 importLyricsFromFiles 会拿文件头把缓存里的值改回去
    /// (saveEdit 的 markManual 注释里踩过同一个坑)。只改 JSON 的话,这次批量锁定/解锁
    /// 会在下次 collector 重启时被静默回滚 —— 而且回滚得毫无痕迹。
    @discardableResult
    public func applyManualPickLock(_ locking: Bool) async -> Int {
        let targets = manualPickLockTargets(locking: locking)
        guard !targets.isEmpty else { return 0 }
        for key in targets {
            guard var entry = raw[key] else { continue }
            if locking {
                entry["manual_lyrics"] = true
            } else {
                entry.removeValue(forKey: "manual_lyrics")
            }
            raw[key] = entry
            markLocallyEdited(key)
            writeLyricsFiles(
                key: key,
                lyrics: entry["lyrics"] as? String ?? "",
                tr: entry["lyrics_tr"] as? String ?? "",
                roma: entry["lyrics_roma"] as? String ?? "",
                yrc: entry["lyrics_yrc"] as? String ?? "",
                source: entry["lyrics_source"] as? String ?? "",
                manual: locking
            )
        }
        rebuildSummaries()
        guard await persist() else { return 0 }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
        return targets.count
    }

    /// Adopts a plain-text candidate (`plain_lyrics`) lacking timestamps.
    /// Preserves existing synced lyrics fields while enabling static text display in the lyrics window.
    /// Does not set `manual_lyrics` to allow automated background upgrades when synced lyrics become available.
    /// - Returns: True if modifications were persisted to disk.
    @discardableResult
    public func savePlainTextEdit(key: String, plainLyrics: String, source: String) async -> Bool {
        var entry = raw[key] ?? [:]
        entry["plain_lyrics"] = plainLyrics
        if source.isEmpty {
            entry.removeValue(forKey: "plain_lyrics_source")
        } else {
            entry["plain_lyrics_source"] = source
        }
        raw[key] = entry
        markLocallyEdited(key)
        rebuildSummaries()
        guard await persist() else { return false }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
        return true
    }

    /// Persists instrumental determination when candidate search reveals no lyrics but confirms instrumental status.
    /// Sets `instrumental = true` and updates `lyrics_decision` while preserving existing lyrics text.
    public func markInstrumental(key: String) async {
        await setInstrumental(key: key, true)
    }

    /// Manually flags or unflags track as instrumental in the cache.
    /// Prevents unnecessary automated search passes by collector (`needsLyricsFirstFill`).
    public func setInstrumental(key: String, _ value: Bool) async {
        var entry = raw[key] ?? [:]
        if value {
            entry["instrumental"] = true
        } else {
            entry.removeValue(forKey: "instrumental")
        }
        raw[key] = entry
        markLocallyEdited(key)
        rebuildSummaries()
        guard await persist() else { return }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
    }

    /// Determines whether an entry is eligible for fill sweep search retries.
    /// Requires absence of lyrics, instrumental status, manual overrides, and active searches.
    nonisolated static func isFillSweepRetryable(_ s: Summary) -> Bool {
        !s.hasLyrics && !s.isInstrumental && !s.isManual && !s.isSearching
    }

    /// 见 Summary.knownOnSources;判据本体在 LyrimuseCore.EnrichSourcePresence(selftest 覆盖)。
    /// nonisolated:buildSummaries 在后台跑(这个类是 @MainActor 的)。
    nonisolated static func knownOnSources(_ entry: [String: Any]) -> Bool {
        EnrichSourcePresence.knownOnSources(
            neteaseURL: entry["netease_url"] as? String,
            qqMusicURL: entry["qq_music_url"] as? String)
    }

    /// Evaluates if no sources responded during the previous resolution round using direct dictionary lookups.
    nonisolated static func lastRoundHadNoResponder(_ entry: [String: Any]) -> Bool {
        let last = entry["lyrics_decision"] as? [String: Any]
        return EnrichSourcePresence.lastRoundHadNoResponder(
            hasDecisionRecord: last != nil,
            respondedCount: (last?["sources_responded"] as? [Any])?.count ?? 0)
    }

    /// Records resolution decision when rematch evaluation confirms the incumbent lyrics remain optimal.
    /// Updates `lyrics_decision` and `lyrics_decision_applied` without modifying lyrics content.
    public func recordUnchangedRematchDecision(key: String, decisionJSON: String) async {
        guard let data = decisionJSON.data(using: .utf8),
              let decision = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var entry = raw[key] ?? [:]
        entry["lyrics_decision"] = decision
        entry["lyrics_decision_applied"] = decision
        raw[key] = entry
        markLocallyEdited(key)
        rebuildSummaries()
        guard await persist() else { return }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
    }

    // File deletion must precede persistence and collector restart.
    // Collector restarts re-import from lyrics files if files are still present on disk.
    // Performs memory and disk deletions first for immediate UI responsiveness,
    // followed by background serialization and non-blocking collector restart.
    public func delete(key: String) async {
        await delete(keys: [key])
    }

    // Batch deletion for multi-selected items in lyrics manager.
    // Executes summary rebuilding, JSON persistence, and disk cleanup in a single coordinated pass
    // to avoid UI hangs from repeated N-times serialization and sorting on MainActor.
    //
    // Sequence invariant: delete disk files -> update in-memory summaries -> persist JSON -> restart collector.
    // Files must be removed before collector restarts to prevent resurrection during importLyricsFromFiles.
    public func delete(keys: Set<String>) async {
        // Only target keys present in cache to avoid skewing deleted count metrics.
        let victims = EnrichCacheKeys.deletionPlan(selected: keys, existing: Set(raw.keys))
        guard !victims.isEmpty else { return }
        // Automatically creates a backup snapshot only when batch deletion exceeds the threshold,
        // avoiding compression overhead on single-item deletions. Single-item deletions rely on Trash fallback.
        if victims.count >= Self.autoSnapshotDeleteThreshold {
            lastAutoSnapshotURL = await LyricsBackupStore.writeAutoSnapshot(reason: "delete")
        }
        var removed: [String: [String: Any]] = [:]
        removed.reserveCapacity(victims.count)
        for key in victims {
            if let entry = raw.removeValue(forKey: key) { removed[key] = entry }
            locallyDeletedKeys.insert(key)
            locallyEditedKeys.remove(key)
            deleteExportedLyricsFile(forKey: key)
        }
        rebuildSummaries()
        guard await persist() else {
            // 写盘失败就把这一批全部放回去——不能让界面显示成"已删除"而磁盘上其实还在。
            // 已经删掉的导出文件不用管:collector 启动时会按缓存内容重新导出一遍。
            for (key, entry) in removed {
                raw[key] = entry
                locallyDeletedKeys.remove(key)
            }
            rebuildSummaries()
            return
        }
        // persist() 刚从盘上并回了窗口开着期间 collector 新写的条目 —— 列表得再刷一次才
        // 看得到它们。只在真有新增时才重刷:rebuildSummaries 是全量 compactMap + 排序,
        // 白跑一次在几百条规模上是肉眼可见的卡顿(见本函数上方那段注释)。
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        // 条目删了,「已校准」名单里对应那几条也该跟着走:留着的话,这首歌下次重新解析出来
        // 的新歌词会莫名其妙一上来就不许后台升级 —— 而它的校正值早就跟着旧内容作废了
        // (校正值 key 里含内容指纹,见 LyricsPinStore)。刻意放在 persist() 成功**之后**:
        // 上面写盘失败那条分支会把条目原样放回去,那种情况下 pin 也不该丢。
        LyricsPinStore.shared.remove(keys: Set(victims))
        scheduleCollectorRestart()
        refreshSizeBytes()
    }

    // "缓存占用查看 + 一键清空"里的清空动作——真删除,不是软标记:清空 JSON 侧的 raw
    // 字典、删掉 lyrics/ 权威源文件夹下的每一个文件(包括手动编辑/联网搜索采纳过的
    // 内容,这份缓存设计上没有"哪些是临时的、哪些是用户产出"的区分,清空就是全清)。
    // destructive 程度需要在 UI 侧用强提示词说清楚,这里只负责真正执行。
    public func clearAll() async {
        // ⚠️ 快照必须排在**最前面**,在 raw 被清空、文件被删掉之前 —— buildArchive 读的是
        // 磁盘上的 lyrics/ 文件族,晚一步就什么都读不到了。
        //
        // 为什么非要有这一层:docs/features/11 已知坑 7 那次「833 条手工修正丢失」,在此之前
        // 的代码上会一字不差地重演 —— 确认弹窗只是提示,落地动作(整份替换落盘 +
        // deleteAllLyricsFiles)没有任何可恢复层。清空还会连带 LyricsPinStore.removeAll(),
        // 用户一句句听出来的时间轴对应的 pin 也一起没,而快照里正好带着 pins。
        lastAutoSnapshotURL = await LyricsBackupStore.writeAutoSnapshot(reason: "clear")
        raw = [:]
        // 清空是用户明确要求的"全清",不能让 persist() 的读-改-写把刚清掉的东西从盘上并回来
        // ——「歌词管理」是可以一直开着的窗口,开窗之后 collector 每解析出一首新歌都会往盘上
        // Full purge: completely clears in-memory dictionary and deletes all exported files
        // matching known lyrics suffixes (`lyricsFileSuffixes`) in the configured lyrics directory.
        // Performs full replacement on disk rather than read-modify-write to prevent resurrecting cleared entries.
        deleteAllLyricsFiles()
        rebuildSummaries()
        totalSizeBytes = 0
        guard await persist(replacingEverything: true) else { return }

        // Verifies clear operation after collector restart, retrying once if concurrent collector writes repopulated cache.
        // Also clears pinned offset registrations in LyricsPinStore.
        LyricsPinStore.shared.removeAll()

        for attempt in 1...2 {
            _ = await CollectorControl.restartAndWaitAsync()
            PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
            if !cacheFileHasEntries() {
                return // 盘上确实是空的,清空成功
            }
            logger.notice("clearAll: cache came back after restart (attempt \(attempt, privacy: .public)), wiping again")
            raw = [:]
            knownKeys = []
            deleteAllLyricsFiles()
            guard await persist(replacingEverything: true) else { return }
            rebuildSummaries()
            totalSizeBytes = 0
        }
        if cacheFileHasEntries() {
            // 两轮都没清干净就如实报错,别让界面显示成"已清空"而磁盘上还在。
            lastError = L10n.t("清空没有完全生效，请稍后再试一次")
            await reload()
        }
    }

    /// 磁盘上那份缓存文件里还有没有条目。用来核实"清空"是不是真的落地了 ——
    /// 不看内存里的 raw:内存说空不算数,collector 可能在我们背后把它写回去了。
    private func cacheFileHasEntries() -> Bool {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false // 文件不在/解析不了,都不算"还有条目"
        }
        return !obj.isEmpty
    }

    /// 批量删除到几条起,值得先打一份自动快照。见 delete(keys:) 里那段注释。
    static let autoSnapshotDeleteThreshold = 5

    /// 从一份自动快照把歌词库铺回去,并让 collector 把它重新读进缓存。
    ///
    /// 顺序不能动:
    ///   1. 先铺文件 —— `lyrics/` 文件族是歌词六字段的**权威源**;
    ///   2. 再重启 collector —— 它启动时跑 `importLyricsFromFiles`(文件赢),照着刚铺回去的
    ///      文件重建缓存条目。这一步是恢复真正生效的地方,不是"顺手刷新一下";
    ///   3. 最后 reload 列表 + 让当前播放的那首重读歌词。
    /// 反过来先重启再铺文件的话,collector 读到的是还没恢复的目录,等于白铺。
    ///
    /// 返回给用户看的一句结果;nil 表示读不出这份快照。
    func restoreFromAutoSnapshot(_ snapshot: LyricsBackupStore.Snapshot) async -> String? {
        guard let result = await LyricsBackupStore.restoreAutoSnapshot(snapshot) else { return nil }
        _ = await CollectorControl.restartAndWaitAsync()
        await reload()
        PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
        refreshSizeBytes()
        return String(format: L10n.t("已恢复 %d 个歌词文件（新增 %d、覆盖 %d）"),
                      result.total, result.added, result.overwritten)
    }

    /// 删一个歌词文件。**走废纸篓,不是永久删。**
    ///
    /// 这些文件是 `lyrics/` 文件族 —— 歌词六字段的权威源,里面有用户手工修正过的内容,
    /// 而 `lyricsDir` 还是用户可以在设置里自己指定的目录。进废纸篓意味着"删错了还能捞
    /// 回来",代价只是用户偶尔要去清一下废纸篓。
    ///
    /// trashItem 失败时退回 removeItem:目标卷可能压根没有废纸篓(外置卷、网络卷、某些
    /// 同步盘),那时候仍然要把文件删掉 —— 否则残留文件会在 collector 下次启动
    /// `importLyricsFromFiles`(文件赢)时把刚删掉的条目整个复活回来,表现成"删了又回来"。
    /// 正确性优先于可恢复性,但只在拿不到废纸篓时才降级。
    private static func trashOrRemove(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 删掉 lyrics/ 目录下的歌词文件。按后缀白名单过滤,理由见 clearAll 里那段注释
    /// (这个目录是用户可以自己指定的,无差别删除会波及无关文件)。
    private func deleteAllLyricsFiles() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: Self.lyricsDir, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls where EnrichCacheKeys.lyricsFileSuffixes.contains(where: { url.lastPathComponent.hasSuffix($0) }) {
            Self.trashOrRemove(url)
        }
    }

    // 跟 collector/lyricsexport.go 的 sanitizeLyricsFilename 逐字对应的 Swift 版本——
    // 两边各自维护而不是让 Swift 调 Go 子进程,是因为这纯粹是确定性的字符替换("|"换成
    // " - "+转义文件系统不安全字符),没有会随时间演进的业务判断,不属于"两份实现容易
    // 走样"必须收敛成一份的那类逻辑(跟 search-lyrics 复用 scoredLyricCandidates 的
    // 场景不同,那边是真的检索/打分逻辑)。
    private static func sanitizeLyricsFilename(_ key: String) -> String {
        EnrichCacheKeys.sanitizeFilename(key)
    }

    // Base filename in the `lyrics/` directory for this key, matching collector conventions in
    // `collector/lyricsexport.go:105-141`.
    // Keys that collide under case-insensitive sanitization use a CRC32-disambiguated filename,
    // while non-colliding keys use the standard sanitized name. Writing the matching filename and
    // cleaning up alternate forms in `writeLyricsFiles` avoids duplicate file imports on collector restart.
    private func exportBaseName(forKey key: String) -> String {
        let fold = EnrichCacheKeys.sanitizeFilename(key).lowercased()
        let collides = raw.keys.contains { other in
            other != key && EnrichCacheKeys.sanitizeFilename(other).lowercased() == fold
        }
        return collides ? EnrichCacheKeys.disambiguatedName(forKey: key) : EnrichCacheKeys.sanitizeFilename(key)
    }

    // 找不到文件(比如这条从来没有译文/罗马音/逐字时间轴)是正常情况,静默忽略——这只是
    // 清理可能存在的归档副本,不是这次删除操作的主体,不值得为"文件本来就不存在"这种
    // 预期内的情况去污染 lastError(那个留给 persist/重启这些真正的主体操作失败用)。
    // lyricsFileSuffixes 全部 4 个后缀都试一遍,跟 writeLyricsFiles 对称——"删除"要
    // 清掉整个歌词文件族,不只是纯歌词那一份。
    private func deleteExportedLyricsFile(forKey key: String) {
        for name in EnrichCacheKeys.exportedFileNames(forKey: key) {
            let url = Self.lyricsDir.appendingPathComponent(name)
            // 文件不存在是常态(这条从来没有译文/罗马音/逐字),先看一眼再动手 —— 否则
            // trashItem 会对每一个不存在的路径抛一次错、白走一遍降级分支。
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            Self.trashOrRemove(url)
        }
    }

    // lyricsFileSuffixes 跟 collector/lyricsexport.go 的同名变量逐一对应。
    private static let lyricsFileSuffixes = EnrichCacheKeys.lyricsFileSuffixes

    // writeLyricsFiles 把 saveEdit 对 raw[key] 做的改动,同步写成 lyrics/ 文件夹下对应的
    // 文件,跟 collector/lyricsexport.go 的 exportLyricsFiles/lyricsFileHeader 是同一份
    // 头部格式的两处独立实现(理由同 sanitizeLyricsFilename——纯粹是确定性的字符串拼接,
    // 不属于必须收敛成一份的逻辑)。每个变体单独判断:有内容就写,没内容就删除对应
    // 文件,跟 Go 那边"该有就写、不该有就删"对应。这里不处理 Go 那边"检测大小写文件名
    // 碰撞、加哈希后缀消歧"那一步——每次调用后紧跟的落盘+排队重启会重启
    // collector,它启动时会重新跑一遍全量 exportLyricsFiles(),那一步本来就会处理好
    // 任何残留的文件名碰撞,不需要在 Swift 这边重复实现一遍。
    private func writeLyricsFiles(key: String, lyrics: String, tr: String, roma: String, yrc: String, source: String, manual: Bool) {
        guard let parts = Self.splitKey(key) else { return }
        let base = exportBaseName(forKey: key)
        // 先清掉"另一种形态"下可能残留的整族文件——不然同一个 key 会同时对应两组文件,
        // collector 导入时两组各写一次 enrichCache[key],生效哪一份取决于 Go map 的随机
        // 遍历顺序(见 exportBaseName 的注释)。这里必须精确取"另一个 base",不能用
        // hasPrefix 筛:普通名恰好是带哈希名的前缀("X" 是 "X~00fad0" 的前缀),用 hasPrefix
        // 在 base 是普通名时一个都清不掉。
        let plainBase = EnrichCacheKeys.sanitizeFilename(key)
        let staleBase = base == plainBase ? EnrichCacheKeys.disambiguatedName(forKey: key) : plainBase
        for suffix in EnrichCacheKeys.lyricsFileSuffixes {
            try? FileManager.default.removeItem(at: Self.lyricsDir.appendingPathComponent(staleBase + suffix))
        }
        var header = "[ar:\(parts.artist)]\n[ti:\(parts.title)]\n[al:\(parts.album)]\n"
        if !source.isEmpty { header += "[source:\(source)]\n" }
        if manual { header += "[manual:1]\n" }
        header += "\n"

        let variants: [(suffix: String, content: String)] = [
            (".lrc", lyrics), (".tr.lrc", tr), (".roma.lrc", roma), (".yrc", yrc),
        ]
        try? FileManager.default.createDirectory(at: Self.lyricsDir, withIntermediateDirectories: true)
        for v in variants {
            let url = Self.lyricsDir.appendingPathComponent(base + v.suffix)
            if v.content.isEmpty {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            try? (header + v.content).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // Serialized persist chain: Prevents concurrent file reads/writes when consecutive save
    // requests are triggered while an asynchronous persist task is awaiting completion.
    private var persistChain: Task<Bool, Never>?

    /// Persists raw cache entries to disk without modifying collector state. Returns whether save succeeded.
    ///
    /// The entire read-modify-write workflow (disk read, JSON deserialization, merge, serialization, atomic write)
    /// runs on a detached background task to prevent blocking the MainActor.
    /// - Parameter replacingEverything: When true (e.g., clearing the entire cache), skips read-modify-write
    ///   merging with on-disk state.
    @discardableResult
    private func persist(replacingEverything: Bool = false) async -> Bool {
        let previous = persistChain
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value // 串行化:等上一笔完全落盘再开始
            guard let self else { return false }
            return await self.performPersist(replacingEverything: replacingEverything)
        }
        persistChain = task
        return await task.value
    }

    private func performPersist(replacingEverything: Bool) async -> Bool {
        guard JSONSerialization.isValidJSONObject(raw),
              let memoryData = try? JSONSerialization.data(withJSONObject: raw) else {
            lastError = L10n.t("内部数据不是合法 JSON,已放弃保存")
            logger.error("raw dict is not valid JSON, aborting save")
            return false
        }
        // 快照本笔的输入并**立即取走**意图集合 —— 后台写盘期间新发生的编辑/删除会重新
        // 填这两个集合、由链上排队的下一笔 persist 负责;失败时把本笔意图放回(union)。
        let edited = locallyEditedKeys
        let deleted = locallyDeletedKeys
        locallyEditedKeys.removeAll()
        locallyDeletedKeys.removeAll()
        let cacheURL = Self.cacheURL

        struct PersistResult: Sendable {
            var mergedData: Data?
            var pulledNew: Bool = false
            var errorMessage: String?
            var ok: Bool = false
        }

        let result = await Task.detached(priority: .userInitiated) { () -> PersistResult in
            // Read-modify-write: uses the current on-disk content as the base, overlaying only
            // explicitly edited or deleted keys. This preserves concurrent background updates written by
            // the collector (such as translation, word-by-word timestamps, or cover art) while the
            // Lyrics Manager window is open. Merge logic is tested in LyrimuseCore.EnrichCacheMerge.
            guard let memoryObj = (try? JSONSerialization.jsonObject(with: memoryData)) as? [String: [String: Any]] else {
                return PersistResult(mergedData: nil, pulledNew: false, errorMessage: "Failed to deserialize memory snapshot", ok: false)
            }
            var target = memoryObj
            var pulledNew = false
            if !replacingEverything,
               let disk = try? Data(contentsOf: cacheURL),
               let diskObj = try? JSONSerialization.jsonObject(with: disk) as? [String: [String: Any]] {
                let merged = EnrichCacheMerge.merge(
                    disk: diskObj, memory: memoryObj, edited: edited, deleted: deleted)
                pulledNew = !Set(merged.keys).subtracting(memoryObj.keys).isEmpty
                target = merged
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: target)
                try data.write(to: cacheURL, options: .atomic)
                return PersistResult(mergedData: data, pulledNew: pulledNew, errorMessage: nil, ok: true)
            } catch {
                return PersistResult(mergedData: nil, pulledNew: false, errorMessage: error.localizedDescription, ok: false)
            }
        }.value

        guard result.ok else {
            // 失败:把本笔意图放回,让调用方的回滚/下一次保存还带着它们。
            locallyEditedKeys.formUnion(edited)
            locallyDeletedKeys.formUnion(deleted)
            lastError = String(format: L10n.t("写入本地记录文件失败: %@"), result.errorMessage ?? "")
            logger.error("write failed: \(result.errorMessage ?? "", privacy: .public)")
            lastPersistPulledInNewKeys = false
            return false
        }
        lastPersistPulledInNewKeys = result.pulledNew
        if let data = result.mergedData,
           let merged = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] {
            if locallyEditedKeys.isEmpty && locallyDeletedKeys.isEmpty {
                // 常态:后台写盘期间没有新修改,回写整份 merged("写完之后 raw 就是盘上
                // 最新内容,列表标记不再停留在开窗那一刻"的既有语义)。
                raw = merged
                knownKeys = Set(merged.keys)
            } else {
                // 罕见:await 窗口里用户又编辑/删除了 —— 整份回写会把那些还没落盘的新
                // 修改用盘上旧值盖掉(真丢数据)。只并入盘上新增的 key,新意图对应的
                // 条目保持内存现状,由链上排队的下一笔 persist 落盘。
                for (k, v) in merged where raw[k] == nil && !locallyDeletedKeys.contains(k) {
                    raw[k] = v
                }
                knownKeys = Set(raw.keys)
            }
        }
        return true
    }

    // 删完之后把工具栏那个"缓存占用"数字刷新一遍。它原来只有 reload() 会重算、clearAll()
    // 会硬置 0,单条 delete 完全不碰——删一条时误差小到没人注意,但批量删掉几百条之后,那个
    // 数字还挂着删之前的值,而它恰好就是"清空全部缓存"这个破坏性入口的标签,显示一个明显
    // 偏大的陈旧值容易让人误判。
    //
    // 只重算大小,不走 reload():reload() 会把 9.4MB JSON 重新读盘+解析一遍,而 raw 此刻
    // 已经是最新的权威内容(我们刚 persist 过),没必要再解析一次;而且 reload() 会顺手把
    // lastError 清掉,会吞掉刚刚可能产生的错误提示。
    private func refreshSizeBytes() {
        let cacheURL = Self.cacheURL
        let lyricsDir = Self.lyricsDir
        Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                Self.directorySizeBytes(lyricsDir) + Self.fileSizeBytes(cacheURL)
            }.value
            self?.totalSizeBytes = bytes
        }
    }

    // 不阻塞界面的 collector 重启,并且**合并**连续多次请求:已经有一次在飞就直接返回。
    // 合并是安全的——collector 启动时重新读盘,读到的必然是当时磁盘上最新的内容(我们
    // 总是先 persist() 再排队重启);而排队只会让 launchd 的 10 秒 minimum-runtime 惩罚
    // 一次次叠加,连删几条会越来越慢,却不会让最终结果更正确。
    private var pendingRestart: Task<Void, Never>?
    // 有重启在飞期间又落盘过——收尾时需要再补一次重启,见下面的注释。
    private var needsFollowUpRestart = false

    private func scheduleCollectorRestart() {
        if pendingRestart != nil {
            // ⚠️ 不能简单地"已经有一次在飞就直接丢弃这次请求":在飞的那一次可能已经把
            // collector 杀掉重启、而新进程已经读完盘了,此刻才发生的这次落盘它就看不到,
            // collector 内存里的旧值之后会把刚删的条目写回磁盘、复活它。窗口很窄(新进程
            // 启动读盘 与 kickstart 进程退出后本任务恢复执行 几乎同时),但不是不存在。
            // 记一个标记,等在飞那次收尾时补一次重启——不管期间删了多少条,最多只补一次,
            // 重启次数仍然有界。
            needsFollowUpRestart = true
            return
        }
        pendingRestart = Task { [weak self] in
            let ok = await CollectorControl.restartAndWaitAsync()
            guard let self else { return }
            self.pendingRestart = nil
            if !ok { self.lastError = L10n.t("后台采集服务重启失败") }
            PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
            if self.needsFollowUpRestart {
                self.needsFollowUpRestart = false
                self.scheduleCollectorRestart()
            }
        }
    }

}

// collector 固化的解析决策记录 —— 跟 collector/decision.go 的 lyricsDecision 逐字段对应
// (snake_case 由 JSONDecoder 的 convertFromSnakeCase 兜),只读展示,永远不写回。
// 得分明细直接复用 LyricsSearchService.ScoreTerm:collector 两条路径吐的是同一套
// scoreTerm(kind/points),这边的本地化文案(label/detail)天然通用。
struct LyricsResolutionDecision: Decodable {
    let path: String
    let decidedAt: Int?
    let scoringVersion: Int?
    let queryArtist: String?
    let queryTitle: String?
    let queryAlbum: String?
    let durationSecs: Double?
    let sourcesResponded: [String]?
    let winner: String?
    let applied: Bool?
    let candidates: [Candidate]?
    /// Retry method used for title lookups (collector retry_method: `title-from-album` or
    /// `title-from-artist-search`) and the resulting corrected title. Displayed as a banner
    /// when present, indicating the lyrics were matched using an alternative title.
    let retryMethod: String?
    let correctedTitle: String?
    /// Record of queries dispatched during this resolution cycle (collector querylog.go).
    /// Historical entries lacking this field decode as nil.
    let queriesTried: [TriedQuery]?

    /// 一组真正发出去的查询词。字段名对着 collector 的 lyricQueryRecord;这个类型走
    /// `.convertFromSnakeCase`,而这几个键都是单词、没有下划线,所以不用手写 CodingKeys。
    struct TriedQuery: Decodable, Identifiable {
        var id: String { "\(reason ?? "")|\(artist)|\(title ?? "")|\((sources ?? []).joined(separator: ","))" }
        let artist: String
        let title: String?
        /// 这一组是哪一轮问的。空 / nil = 首轮。取值全集见 collector 的 lyricQueryReason*,
        /// 中文译名在 LyricsDecisionSheet.queryReasonLabel(漏补就会在界面上印英文串)。
        let reason: String?
        /// 这一轮**只**问了这几个源(别名轮的定向重查)。空 = 没有限制。
        let sources: [String]?
    }

    struct Candidate: Decodable, Identifiable {
        var id: String { source }
        let source: String
        let score: Int
        let scoreTerms: [LyricsSearchService.ScoreTerm]?
        let title: String?
        let artist: String?
        let album: String?
        /// Source-provided cover URL recorded at resolution time.
        ///
        /// Property name must remain `coverUrl` (lowercase 'rl') because decoding uses
        /// `.convertFromSnakeCase`, mapping `cover_url` directly to `coverUrl`.
        /// Note that `LyricsSearchService.RawCandidate` uses manual CodingKeys mapping instead.
        let coverUrl: String?
        let sourceReportedDurationSecs: Double?
        let hasWordTiming: Bool?
        let instrumental: Bool?
        /// Other sources whose lyrics content matched this candidate during consensus evaluation.
        /// Historical cache entries lacking this field decode as nil.
        let consensusPeers: [String]?
    }
}
