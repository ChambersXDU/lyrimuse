import Foundation

public struct SettingsSearchEntry: Hashable, Sendable, Identifiable {
    public enum Destination: Hashable, Sendable {

        case tab(String)

        case account(String)
    }

    public let destination: Destination
    public let sectionKey: String?
    public let sectionValue: String?
    public let drawer: LyricsSurface?
    public let titleKey: String
    public let alternateTitleKeys: [String]
    public let subtitleKey: String?
    public let keywords: [String]
    public let pathKeys: [String]

    public init(destination: Destination, sectionKey: String? = nil, sectionValue: String? = nil,
                drawer: LyricsSurface? = nil, titleKey: String, alternateTitleKeys: [String] = [],
                subtitleKey: String? = nil, keywords: [String] = [], pathKeys: [String]) {
        self.destination = destination
        self.sectionKey = sectionKey
        self.sectionValue = sectionValue
        self.drawer = drawer
        self.titleKey = titleKey
        self.alternateTitleKeys = alternateTitleKeys
        self.subtitleKey = subtitleKey
        self.keywords = keywords
        self.pathKeys = pathKeys
    }

    public var id: String {
        let dest: String
        switch destination {
        case .tab(let raw): dest = "tab:\(raw)"
        case .account(let name): dest = "account:\(name)"
        }
        return "\(dest)|\(sectionValue ?? "")|\(pathKeys.joined(separator: "/"))|\(titleKey)"
    }

    public var localizedKeys: [String] {
        [titleKey] + alternateTitleKeys + (subtitleKey.map { [$0] } ?? []) + pathKeys
    }
}

public enum SettingsSearchCatalog {

    public static let lyricsSectionKey = "settings:lyricsSection"

    public static let brandPathComponents: Set<String> = ["ListenBrainz"]

    private static func lyrics(_ section: String, _ title: String, alt: [String] = [], sub: String? = nil,
                               kw: [String] = [], group: String? = nil) -> SettingsSearchEntry {
        let sectionTitle: String
        switch section {
        case "fetch": sectionTitle = "获取"
        case "translation": sectionTitle = "译文"
        case "display": sectionTitle = "效果"
        default: sectionTitle = "管理"
        }
        return SettingsSearchEntry(destination: .tab("lyrics"), sectionKey: lyricsSectionKey, sectionValue: section,
                                   titleKey: title, alternateTitleKeys: alt, subtitleKey: sub, keywords: kw,
                                   pathKeys: ["歌词", sectionTitle] + (group.map { [$0] } ?? []))
    }

    private static func player(_ title: String, sub: String? = nil, kw: [String] = [], group: String? = nil) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("player"), titleKey: title, subtitleKey: sub, keywords: kw,
                            pathKeys: ["播放器"] + (group.map { [$0] } ?? []))
    }

    private static func surface(_ surface: LyricsSurface, _ title: String, alt: [String] = [], sub: String? = nil,
                                kw: [String] = [], group: String? = nil, inDrawer: Bool = true) -> SettingsSearchEntry {
        let sectionTitle: String
        switch surface {
        case .overlay: sectionTitle = "悬浮歌词"
        case .menuBar: sectionTitle = "菜单栏"
        }
        return SettingsSearchEntry(destination: .tab("appearance"),
                                   sectionKey: LyricsSurface.appearanceSectionStorageKey,
                                   sectionValue: surface.appearanceSectionRawValue,
                                   drawer: inDrawer ? surface : nil,
                                   titleKey: title, alternateTitleKeys: alt, subtitleKey: sub, keywords: kw,
                                   pathKeys: ["歌词显示", sectionTitle] + (group.map { [$0] } ?? []))
    }

    private static func shortcut(_ title: String, sub: String? = nil, kw: [String] = []) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("shortcuts"), titleKey: title, subtitleKey: sub,
                            keywords: kw + ["快捷键", "hotkey"], pathKeys: ["快捷键"])
    }

    private static func general(_ title: String, alt: [String] = [], sub: String? = nil, kw: [String] = [],
                                group: String? = nil) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("general"), titleKey: title, alternateTitleKeys: alt, subtitleKey: sub,
                            keywords: kw, pathKeys: ["通用"] + (group.map { [$0] } ?? []))
    }

    private static func about(_ title: String, sub: String? = nil, kw: [String] = [], group: String) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("about"), titleKey: title, subtitleKey: sub, keywords: kw,
                            pathKeys: ["关于", group])
    }

    private static func account(_ name: String, path: [String], sectionValue: String? = nil, _ title: String,
                                kw: [String] = []) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .account(name),
                            sectionKey: nil, sectionValue: sectionValue,
                            titleKey: title, keywords: kw, pathKeys: path)
    }

    public static let entries: [SettingsSearchEntry] = [

        lyrics("fetch", "歌词来源", kw: ["歌词源", "网易云音乐", "QQ音乐", "酷狗", "Musixmatch", "LRCLIB", "AMLL",
                                      "LyricFind", "酷我", "咪咕", "测试", "顺序"]),
        lyrics("fetch", "匹配算法", kw: ["智能", "顺序优先", "打分"]),
        lyrics("fetch", "跟进算法升级", kw: ["重打分", "自动升级"]),
        lyrics("fetch", "提前解析同专辑其它曲目", kw: ["预解析", "专辑"]),
        lyrics("fetch", "锁定手选歌词", kw: ["手动选定", "锁定"]),

        lyrics("translation", "显示译文", kw: ["翻译"]),
        lyrics("translation", "译文语言", kw: ["翻译", "语言"]),
        lyrics("translation", "系统兜底翻译", kw: ["机翻", "MyMemory", "翻译"]),
        lyrics("translation", "翻译语言包", kw: ["下载", "语言包", "Apple 翻译"]),

        lyrics("display", "繁简转换", kw: ["繁体", "简体", "OpenCC"]),
        lyrics("display", "显示罗马音", kw: ["罗马字", "注音", "拼音", "粤拼", "发音"]),
        lyrics("display", "标注哪些语言", kw: ["日语", "韩语", "中文", "罗马音"]),
        lyrics("display", "全局时间轴偏移", kw: ["歌词偏移", "提前", "延后", "校准", "同步"]),

        lyrics("manage", "歌词库", kw: ["歌词管理", "统计", "缓存"]),
        lyrics("manage", "歌词文件夹", kw: ["lyrics", "自定义位置", "目录", "lrc"]),

        player("播放器", kw: ["Apple Music", "QQ音乐", "网易云音乐", "酷狗音乐", "Spotify", "自动识别", "多选"]),
        player("网页播放器", kw: ["YouTube Music", "Spotify", "浏览器", "Chrome", "Safari", "Edge", "Arc"]),
        player("已信任的播放器", kw: ["信任列表", "其它播放器"]),
        player("新播放器提醒", sub: "系统通知已关闭", kw: ["通知", "未知播放器"]),
        player("Apple Music 自动化", kw: ["权限", "AppleScript", "自动化"]),
        player("后台采集服务", kw: ["collector", "launchd", "服务", "运行状态"]),
        player("播放器联动", kw: ["启动", "退出", "联动"]),
        player("打开 Lyrimuse 时启动", kw: ["联动", "启动播放器"], group: "播放器联动"),
        player("跟随播放器启动", kw: ["联动", "自动启动"], group: "播放器联动"),
        player("跟随播放器退出", kw: ["联动", "自动退出"], group: "播放器联动"),

        surface(.overlay, "桌面悬浮歌词", kw: ["开关", "悬浮窗", "总开关"], inDrawer: false),
        surface(.overlay, "跟随封面", kw: ["封面色", "取色", "配色"], group: "主题"),
        surface(.overlay, "配色主题", kw: ["预设", "经典白字", "白字描边", "经典黑字", "黑字描边", "深色卡片", "浅色卡片"], group: "主题"),
        surface(.overlay, "我的配色主题", kw: ["自存", "保存主题"], group: "主题"),
        surface(.overlay, "字体", kw: ["字体族", "font"], group: "文字"),
        surface(.overlay, "粗细", kw: ["字重", "weight"], group: "文字"),
        surface(.overlay, "字号", kw: ["大小", "font size"], group: "文字"),
        surface(.overlay, "卡拉OK效果", kw: ["逐字", "染色", "karaoke"], group: "文字"),
        surface(.overlay, "文字颜色", kw: ["字色", "颜色"], group: "文字"),
        surface(.overlay, "文字描边", kw: ["描边", "outline"], group: "文字"),
        surface(.overlay, "描边颜色", kw: ["描边"], group: "文字"),
        surface(.overlay, "背景颜色", kw: ["背景", "透明"], group: "背景"),
        surface(.overlay, "毛玻璃背景", kw: ["模糊", "玻璃", "blur"], group: "背景"),
        surface(.overlay, "双行显示", kw: ["两行", "副行", "下一句"], group: "排版"),
        surface(.overlay, "对齐方式", kw: ["居中", "左对齐", "右对齐"], group: "排版"),
        surface(.overlay, "宽度", kw: ["窗口宽度", "pt"]),
        surface(.overlay, "锁定位置", kw: ["锁定", "拖动"], group: "行为"),
        surface(.overlay, "长按拖动", kw: ["拖动", "长按"], group: "行为"),
        surface(.overlay, "悬浮淡化", kw: ["鼠标", "指针", "淡出", "让开"], group: "行为"),
        surface(.overlay, "截屏/录屏时隐藏", kw: ["截图", "录屏", "会议", "共享屏幕"], group: "行为"),
        surface(.overlay, "暂停/无播放时隐藏", kw: ["自动隐藏", "暂停"], group: "行为"),

        surface(.overlay, "位置", kw: ["自由", "顶部居中", "底部居中", "Dock", "预设", "对齐"]),
        surface(.overlay, "恢复默认", sub: "不含排版、行为、位置和宽度", kw: ["重置"]),

        surface(.menuBar, "菜单栏歌词", kw: ["开关", "跑马灯", "总开关"], inDrawer: false),
        surface(.menuBar, "宽度模式", kw: ["固定", "自适应", "宽度"], group: "布局"),
        surface(.menuBar, "对齐方式", kw: ["居中", "左对齐", "右对齐"], group: "布局"),
        surface(.menuBar, "副行", kw: ["下一句", "译文", "罗马音", "双排", "两行"], group: "布局"),
        surface(.menuBar, "歌词旁的图标", kw: ["进度图标", "图标"], group: "布局"),
        surface(.menuBar, "卡拉OK效果", kw: ["逐字", "染色", "karaoke"], group: "配色"),
        surface(.menuBar, "文字颜色", alt: ["未唱到的颜色"], kw: ["字色", "颜色", "跟随系统"], group: "配色"),
        surface(.menuBar, "已唱到的颜色", kw: ["染色", "高亮色"], group: "配色"),
        surface(.menuBar, "粗细", kw: ["字重", "weight"], group: "字体"),
        surface(.menuBar, "字号", kw: ["大小", "font size"], group: "字体"),
        surface(.menuBar, "最大宽度", kw: ["宽度", "pt"]),
        surface(.menuBar, "悬停显示播放控制", kw: ["悬停", "播放控制", "鼠标"], group: "行为"),
        surface(.menuBar, "无歌词时显示歌名", kw: ["歌名", "兜底", "没有歌词"], group: "行为"),
        surface(.menuBar, "恢复默认", sub: "不含宽度和总开关", kw: ["重置"]),

        shortcut("显示/隐藏悬浮歌词", kw: ["悬浮歌词", "开关"]),
        shortcut("显示/隐藏菜单栏歌词", kw: ["菜单栏", "开关"]),
        shortcut("锁定/解锁位置", kw: ["锁定", "位置"]),
        shortcut("显示/隐藏译文", kw: ["译文", "翻译"]),
        shortcut("显示/隐藏发音", kw: ["罗马音", "发音"]),
        shortcut("打开歌词管理", kw: ["歌词管理", "窗口"]),
        shortcut("搜索歌词", kw: ["手动搜索", "换歌词"]),
        shortcut("打开设置", kw: ["设置窗口"]),
        shortcut("歌词提前", kw: ["偏移", "时间轴", "校准"]),
        shortcut("歌词延后", kw: ["偏移", "时间轴", "校准"]),
        shortcut("歌词偏移归零", kw: ["偏移", "重置", "时间轴"]),
        shortcut("步长", sub: "每按一次调整的幅度", kw: ["偏移", "幅度"]),
        shortcut("播放/暂停", kw: ["播放控制"]),
        shortcut("下一首", kw: ["播放控制", "切歌"]),
        shortcut("上一首", kw: ["播放控制", "切歌"]),

        general("菜单栏图标", kw: ["图标", "状态栏", "12 款"], group: "菜单栏与 Dock"),
        general("随播放律动", kw: ["动画", "图标", "律动"], group: "菜单栏与 Dock"),
        general("在 Dock 中显示", kw: ["Dock", "程序坞", "图标"], group: "菜单栏与 Dock"),
        general("语言", kw: ["简体中文", "繁體中文", "English", "跟随系统", "界面语言"], group: "语言与启动"),
        general("开机启动", kw: ["登录项", "自动启动", "启动"], group: "语言与启动"),
        general("iCloud 备份", alt: ["备份文件夹"], kw: ["备份", "迁移", "搬家", "同步", "文件夹"], group: "备份与迁移"),
        general("设置文件", sub: "含明文凭证；导入会覆盖全部设置并重启", kw: ["导出", "导入", "备份", "JSON"], group: "备份与迁移"),
        general("动态封面", sub: "桌面悬浮歌词的封面卡：部分专辑在 Apple Music 上有会动的封面，没有的照旧静态显示。低电量或开了「减弱动态效果」时自动暂停", kw: ["封面", "动画", "motion", "artwork", "会动", "视频"], group: "封面"),
        general("清除所有设置", sub: "本机设置，无法撤销", kw: ["重置", "恢复出厂", "删除"]),

        about("反馈问题", sub: "GitHub Issues", kw: ["issue", "bug", "反馈"], group: "反馈与社区"),
        about("想法与建议", sub: "GitHub Discussions", kw: ["discussion", "建议"], group: "反馈与社区"),
        about("版权说明", kw: ["版权", "歌词版权"], group: "许可与版权"),
        about("第三方许可", sub: "开源组件与词典", kw: ["许可证", "开源", "license"], group: "许可与版权"),
        about("开源许可证", sub: "GPL-3.0", kw: ["GPL", "许可证", "license"], group: "许可与版权"),
        about("导出诊断", sub: "不含账号与密钥", kw: ["诊断", "日志", "排查"], group: "诊断与数据"),
        about("配置文件夹", kw: ["config", "配置", "文件夹", "路径"], group: "诊断与数据"),

        account("listenBrainz", path: ["ListenBrainz"], "账户信息", kw: ["ListenBrainz", "token", "令牌", "用户名", "连接"]),
        account("stateRelay", path: ["网页推送"], "连接信息", kw: ["中继", "网页", "relay", "worker", "推送"]),
        account("bark", path: ["推送提醒"], "提醒", kw: ["Bark", "推送", "webhook", "通知"]),
        account("bark", path: ["推送提醒"], "每周听歌小结", kw: ["周报", "推送", "Bark"]),
        account("bark", path: ["推送提醒"], "每日听歌报告", kw: ["日报", "推送", "Bark"]),
    ]
}

public enum SettingsSearchMatcher {

    public static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    public static func rank(query: String, title: String, secondary: [String]) -> Int? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        let terms = q.split(separator: " ").map(String.init)
        let t = normalize(title)
        let others = secondary.map(normalize)
        var best = 3
        for term in terms {
            if t.hasPrefix(term) { best = min(best, 0); continue }
            if t.contains(term) { best = min(best, 1); continue }
            if others.contains(where: { $0.contains(term) }) { best = min(best, 2); continue }
            return nil
        }
        return best == 3 ? nil : best
    }

    public static func ranked<T>(_ items: [T], query: String, title: (T) -> String, secondary: (T) -> [String]) -> [T] {
        let scored: [(Int, Int, T)] = items.enumerated().compactMap { index, item in
            rank(query: query, title: title(item), secondary: secondary(item)).map { ($0, index, item) }
        }
        return scored.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }.map { $0.2 }
    }
}
