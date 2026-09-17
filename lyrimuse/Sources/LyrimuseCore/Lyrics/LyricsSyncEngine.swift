import Foundation

public struct SyncedLyricWord: Equatable {
    public let text: String
    // 真实起止时间戳(绝对播放位置,毫秒)——填色进度不在这里预烤成一个数字,改由 View 层
    // 用 TimelineView 按渲染帧频、从连续时钟直接现算 fillFraction。原来在这里预算好
    // fillFraction 再靠 20Hz tick 塞进 @Published 结构体、View 端用
    // .animation(.linear(duration:), value:) 补一段小动画的做法,在补间时长(60ms)比
    // tick 间隔(50ms)长时几乎总在上一段没放完就被重新触发——SwiftUI 对 .linear 这类
    // "不可合并"的曲线动画是把新旧两段位移矢量相加而不是从当前值接续,这正是逐字流转
    // 卡顿的结构性根源,不是调个补间时长能治本的。
    public let startMs: Int
    public let durationMs: Int

    public init(text: String, startMs: Int, durationMs: Int) {
        self.text = text
        self.startMs = startMs
        self.durationMs = durationMs
    }
}

/// 一组「共享同一段罗马音」的逐字词。
///
/// Apple Music 的日文歌词是把罗马音标在**对应内容的正下方**、而不是整行堆在上面一行,
/// 而且罗马音跟着逐字一起填色。要做到这个,就得知道"这段读音对应原文的哪几个字"——
/// 分词器给的片段边界跟歌词源的逐字切分**不一定对齐**(酷狗常常一个汉字一个词,而
/// 「いつか」在分词器眼里是一个词),所以按片段把逐字词并成组:一组一列,列宽取
/// 「主文字」和「罗马音」里更宽的那个 —— Apple 那边日文行间距不均匀,正是被下面的罗马音
/// 撑开的。
public struct SyncedLyricWordGroup: Equatable, Identifiable {
    public let id: Int
    public let words: [SyncedLyricWord]
    public let romanization: String?

    public init(id: Int, words: [SyncedLyricWord], romanization: String?) {
        self.id = id
        self.words = words
        self.romanization = romanization
    }

    /// 这一组整体的起止,用来给下面那行罗马音算填色进度(跟着整组走,不跟着单个字跳)。
    public var startMs: Int { words.first?.startMs ?? 0 }
    public var endMs: Int { words.last.map { $0.startMs + $0.durationMs } ?? 0 }
}

public struct SyncedLyricLine: Equatable {
    public let romanization: String?
    public let translation: String?
    public let mainText: String?         // 整行高亮时用(没有逐字数据)
    public let words: [SyncedLyricWord]? // 逐字高亮时用(有 yrc 数据)
    /// 逐字词按读音分好的组,只有"这一行确实能标罗马音"时才非空。视图可以选择用它做
    /// Apple 那种逐词标注,拿不到时退回 `romanization` 那一整行。
    public let wordGroups: [SyncedLyricWordGroup]?
    /// 这一行摆在哪一边 —— 对唱歌词的左右分栏,见 LyricDuet。
    /// **nil = 这首歌没有演唱者标记**(或还没到第一个标记),不是"靠左";各视图按自己的
    /// 默认排版兜底(歌词窗口 `?? .leading`、悬浮窗 `?? .center`)。
    public var side: LyricDuet.Side?

    /// 这一行的纯文本（无逐字填色进度），mainText 与 words 两种形态优先取逐字内容。
    public let plainText: String?

    /// `plainText` 传 nil 时按默认推导链（mainText 优先于 words 拼接）。
    public init(romanization: String?, translation: String?, mainText: String?,
                words: [SyncedLyricWord]?, wordGroups: [SyncedLyricWordGroup]?,
                side: LyricDuet.Side?, plainText: String? = nil) {
        self.romanization = romanization
        self.translation = translation
        self.mainText = mainText
        self.words = words
        self.wordGroups = wordGroups
        self.side = side
        // 显式传入空串时退回推导链；若 words 为空则置 nil，便于展示面显示占位音符。
        if let plainText, !plainText.isEmpty {
            self.plainText = plainText
        } else if let mainText {
            self.plainText = mainText
        } else if let words, !words.isEmpty {
            self.plainText = words.map(\.text).joined()
        } else {
            self.plainText = nil
        }
    }

    /// 这一行的整行形态：清除逐字数据，将正文降级至 mainText，保留译文、罗马音及声部。
    /// 供关闭卡拉OK效果的展示面使用，避免在各处渲染分支中重复判断开关。
    public var lineLevel: SyncedLyricLine {
        guard words != nil || wordGroups != nil else { return self }
        return SyncedLyricLine(
            romanization: romanization, translation: translation,
            mainText: mainText ?? plainText, words: nil, wordGroups: nil,
            side: side, plainText: plainText)
    }
}

// 供歌词窗口一次性获取整首歌全部行数据。
extension CharacterSet {
    /// 汉字 + 假名。给 LyricsSyncEngine 的抬头分段判定用(见 scriptRuns)。
    static let hanLike: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "\u{3040}"..."\u{30FF}")   // 平假名 + 片假名
        s.insert(charactersIn: "\u{3400}"..."\u{4DBF}")   // 扩展 A
        s.insert(charactersIn: "\u{4E00}"..."\u{9FFF}")   // 基本区
        s.insert(charactersIn: "\u{F900}"..."\u{FAFF}")   // 兼容表意
        return s
    }()
}

public struct LyricsWindowLine: Identifiable, Equatable {
    public let id: String
    public let timeMs: Int
    public let line: SyncedLyricLine
}

/// 歌词间奏点（index == -1 为前奏，其余为该行唱完后的间奏）。
/// startMs 与 endMs 为原始时间轴上的间奏活跃窗口。
public struct LyricsGapMarker: Equatable, Identifiable {
    public let index: Int
    public let startMs: Int
    public let endMs: Int
    public var id: Int { index }
}

// 按当前歌曲的四个歌词字段选基准 + 按外推位置算当前应该展示哪一行,算法照抄
// web/index.html 的 setLyrics()/syncLyrics():有 yrc(逐字)优先用,否则退化到 lyrics
// 整行;roma/tr 各自独立解析、用 700ms 容差的最近邻匹配贴到对应原文行。
public final class LyricsSyncEngine {
    private var baseLines: [LyricLine] = []
    private var wordLines: [LyricLineWords] = []
    // 跟上面两个数组逐行对应的左右分栏结果(对唱歌词)。没有演唱者标记的歌全是 .leading。
    private var baseSides: [LyricDuet.Side?] = []
    private var wordSides: [LyricDuet.Side?] = []
    private var romaLines: [LyricLine] = []
    private var trLines: [LyricLine] = []
    private var usingWords = false

    /// 内容匹配用字典：优先按归一化纯文本精确匹配译文/罗马音，未命中时退回时间最近邻匹配。
    private var trTextByPlainText: [String: String] = [:]
    private var romaTextByPlainText: [String: String] = [:]

    /// 归一化文本键：仅保留小写字母与数字，剥离空白字符、标点及括号排版变体。
    private static func contentMatchKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 用户/播放器/单曲层级的外部时间轴偏移量（毫秒，正数提前，负数延后）。
    public var offsetMs: Int = 0

    /// LRC 歌词自带的 `[offset:]` 偏移量（毫秒），与外部用户偏好 offsetMs 独立存储。
    public private(set) var lrcOffsetMs: Int = 0

    /// 实际用于定位的总偏移。**所有**查询入口都必须用它,不能再直接用 `offsetMs`。
    public var effectiveOffsetMs: Int { offsetMs + lrcOffsetMs }

    // 署名/制作人员这类噪声行(作词/作曲/编曲/制作人等,常见于 LRC 开头几秒)在喂进
    // 同步引擎之前(而不是显示时)就剔除——这样歌曲刚开始播放、真歌词还没开始的那几秒
    // 会正确判定成"还没到第一句真歌词"(退回♪占位符,双行预览提前露出第一句真歌词),
    // 而不是把署名行当成一句正常歌词展示出来。
    //
    // 正则要覆盖三种写法,分别对应不同来源的实际格式:两字全称(作词/作曲等,网易云常见)、
    // 常见署名行正则:支持单字缩写(词/曲/编/唱/录/混/监)、"by:" 等形式，
    // 以及连写(「词曲：」)与连接词(「制作和编曲：」)。
    private static let creditLinePattern = try! NSRegularExpression(
        pattern: #"^(所有|全部|中文|英文|韩文|日文|粤语|中|英|韩|日)?\s*(唱片公司|发行公司|出品公司|专辑|翻译|作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|P\s*-\s*Line|C\s*-\s*Line|℗|©|lyrics|music|composed|produced|arranged|mixed|mastered|written)(\s*(和|与|及|、|/|&|＆)?\s*(唱片公司|发行公司|出品公司|专辑|翻译|作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|lyrics|music|composed|produced|arranged|mixed|mastered|written))*\s*(by\s*)?[:：]"#,
        options: [.caseInsensitive]
    )

    // 双字角色词表:用于 matchesRoleWordCredit(冒号前 1~8 个汉字包含任一双字角色词)。
    // 仅收双字词可避免误杀「曲婉婷：」等歌手名对唱标签。
    // 刻意不收「合唱」「主唱」「顾问」等词，避免误伤分声部标记或正文歌词。
    private static let creditRoleWords: [String] = [
        "作词", "作曲", "编曲", "编辑", "编程", "制作", "监制", "混音", "母带", "处理",
        "录音", "录制", "和声", "吉他", "贝斯", "键盘", "弦乐", "乐器", "工程", "企划",
        "统筹", "发行", "出品", "演奏", "指挥", "后期", "音效", "版权", "鸣谢", "摄影",
        "设计", "封面",
        "演唱", "原唱", "翻唱",
        // 日文汉字形态标签(含新字体「収」「挿」与繁体写法)
        "収録", "主題", "片頭", "片尾", "挿入",
        "收录", "主题", "片头", "插入",
        "歌手", "歌曲", "歌词",
        // 乐器与编制角色
        "钢琴", "箱琴", "笛子", "童声", "口琴", "二胡", "琵琶", "古筝", "长笛", "提琴",
        "唢呐", "手鼓", "打击", "合成", "采样", "编写", "小号", "萨克",
        "竖琴", "长号", "副唱", "和音", "三和",
        // 版权与推广角色
        "著作", "推广",
        // 制作与艺术职能
        "指导", "总监", "策划", "导演",
    ]

    /// 标签里允许出现的分隔符(如「录音师/录音室：」「作词/作曲：」「混音&母带：」)。
    /// 校验汉字标签时先剔除这些分隔符。
    private static let creditLabelSeparators = CharacterSet(charactersIn: "/／、&＆·・和与及,，")

    /// 标签尾巴上那段**英文对照**里出现的角色名。
    ///
    /// 只在"汉字头 + 拉丁尾"的双语标签里当第二判据用(见 matchesRoleWordCredit):汉字头是
    /// 「曲」「词」「鼓」这种单字时,表里那些双字词一个都够不着,而把单字加进 creditRoleWords
    /// 会把真歌词里的对白吃掉(「他：我不走」那一类,2026-08-16 已经踩过一次并回滚)。
    /// 有英文对照在旁边,歧义就没了 —— 「曲 Composer：」不可能是对白。
    private static let englishRoleNounPattern = try! NSRegularExpression(
        pattern: #"\b(producers?|composers?|lyricists?|lyrics|arrang(?:er|ement|ed)|"#
            + #"engineers?|engineering|studios?|drums?|bass|guitars?|keyboards?|strings|"#
            + #"vocals?|chorus|programming|mixing|mixed|mastering|mastered|recording|recorded|"#
            + #"assistant|producti?on|publisher|label|orchestra|conductor|percussion|piano|"#
            + #"synth(?:esizer)?|sax(?:ophone)?|trumpet|violin|cello|harmonica|"#
            + #"photograph(?:y|er)|artwork|design(?:er)?|mv|director)\b"#,
        options: [.caseInsensitive]
    )

    /// 把双语标签拆成「汉字头」和「拉丁尾」。拆不出干净的两段时原样返回(拉丁尾为空),
    /// 让调用方走原来那条纯汉字的路。
    ///
    /// 判据刻意收紧:拉丁尾只允许字母/空白/少量标点(不许出现数字、汉字),长度 ≤ 40 —— 它
    /// 应该是"Recording Studio""Background vocals by"这种角色名对照,不是一整句话。
    private static func splitBilingualLabel(_ label: String) -> (han: String, latin: String) {
        var han = ""
        var idx = label.startIndex
        while idx < label.endIndex {
            let ch = label[idx]
            let isHan = ch.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
            let isSep = ch.unicodeScalars.allSatisfy { creditLabelSeparators.contains($0) }
            guard isHan || isSep else { break }
            han.append(ch)
            idx = label.index(after: idx)
        }
        let tail = label[idx...].trimmingCharacters(in: .whitespaces)
        guard !han.isEmpty, !tail.isEmpty, tail.count <= 40 else { return (label, "") }
        // 守卫：冒号前不含括号且拉丁尾以字母开头，避免将含行内注解的歌词误判为双语标签。
        let brackets = CharacterSet(charactersIn: "()（）[]【】{}〔〕")
        guard !label.unicodeScalars.contains(where: { brackets.contains($0) }),
              tail.first?.isLetter == true
        else { return (label, "") }
        let allowed = CharacterSet.letters.union(.whitespaces)
            .union(CharacterSet(charactersIn: "&/.,'()-＆"))
        guard tail.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              tail.unicodeScalars.allSatisfy({ !$0.properties.isIdeographic })
        else { return (label, "") }
        return (han, tail)
    }

    /// 双语标签形状匹配（汉字头 + 拉丁尾 + 冒号 + 值，免词表）。
    /// 需配合全篇出现频次阈值（至少 2 行）作为守卫，避免误伤正文。
    public static func matchesBilingualCreditShape(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return false }
        let (han, latin) = splitBilingualLabel(String(label))
        guard !latin.isEmpty else { return false }
        let core = han.components(separatedBy: creditLabelSeparators).joined()
        guard !core.isEmpty, (1...10).contains(core.count),
              core.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }
        // 说话人标签豁免走同一份名单(「男 Male:」这种对唱标注真实存在)。
        return !speakerLabels.contains(core)
    }

    public static func matchesRoleWordCredit(_ text: String) -> Bool {
        // 分隔符支持冒号与中点（适配 QQ 音乐等源转换工具）。
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" || $0 == "·" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        // 冒号后必须有内容 —— 纯粹以冒号结尾的句子是真歌词里的语气停顿,不算。
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // 拆分「汉字角色词 + 英文对照」双语标签（如「制作人 Producer：陶喆」）。
        let (hanLabel, latinLabel) = splitBilingualLabel(String(label))
        // 长度按剔掉分隔符后的纯汉字计算。
        var core = hanLabel.components(separatedBy: creditLabelSeparators).joined()
        // 标签若包含拉丁字母、括号或型号修饰（如「Protools编辑：」），提取纯汉字部分校验。
        if !core.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }) || core.isEmpty {
            let hanOnly = String(label).unicodeScalars
                .filter { $0.properties.isIdeographic }
                .map(Character.init)
            let nonHanOK = String(label).unicodeScalars.allSatisfy { u in
                u.properties.isIdeographic || CharacterSet.alphanumerics.contains(u)
                    || " ./&()'’-：:".unicodeScalars.contains(u)
            }
            if nonHanOK, !hanOnly.isEmpty { core = String(hanOnly) }
        }
        guard !rest.isEmpty, (1...10).contains(core.count), !core.isEmpty,
              core.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }
        // 角色词匹配同时支持繁简体孪生写法。
        let forms = [core, HanScript.sibling(core)].compactMap { $0 }
        if creditRoleWords.contains(where: { word in forms.contains { $0.contains(word) } }) {
            return true
        }
        // 汉字未命中但英文对照命中角色名词（见 englishRoleNounPattern）。
        guard !latinLabel.isEmpty else { return false }
        let range = NSRange(latinLabel.startIndex..., in: latinLabel)
        return englishRoleNounPattern.firstMatch(in: latinLabel, range: range) != nil
    }

    /// 纯英文或前缀带中文角色词的职员表行（形如 "Mixed by X at Y"、"编曲 Arrangement by X"）。
    /// 匹配整行以角色词开头紧跟 by/at 且后接人名/地点的无冒号署名。
    private static let englishCreditPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:\#(creditRoleWords.joined(separator: "|")))\p{Han}{0,4}\s*)?(mixed|mastered|produced|written|composed|arranged|arrangement|recorded|engineered|performed|lyrics|music|vocals?|guitars?|bass|drums|keyboards?|strings|programming|artwork|photography|design)\b[^\n]{0,20}?\s+(by|at)\s+\S"#,
        options: [.caseInsensitive]
    )

    public static func matchesEnglishCredit(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return englishCreditPattern.firstMatch(in: text, range: range) != nil
    }

    private static let genericHanCreditLinePattern = try! NSRegularExpression(
        pattern: #"^\p{Han}{1,8}\s*[:：]\s*\S"#
    )

    // 拉丁字母标签职员表：支持全角冒号署名，或半角冒号且冒号后含中日假名/汉字的版权行。
    private static let latinCreditFullWidthPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9 .&/'’()\-]{0,40}：\s*\S"#
    )
    private static let latinCreditHalfWidthPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9 .&/'’()\-]{0,40}:[^\p{Han}\p{Hiragana}\p{Katakana}]{0,24}[\p{Han}\p{Hiragana}\p{Katakana}]"#
    )

    /// 冒号右侧句子判据：包含代词、助词、谓语动词或句末标点时判定为正文对白而非人名。
    private static let nonNameWordsLatin: Set<String> = [
        "i", "im", "i'm", "you", "you're", "youre", "we", "we're", "he", "she", "they",
        "me", "my", "your", "our", "am", "is", "are", "was", "were", "be", "been",
        "do", "dont", "don't", "doesnt", "doesn't", "did", "can", "cant", "can't",
        "will", "wont", "won't", "not", "never", "gonna", "wanna", "gotta",
        "love", "know", "feel", "need", "want", "say", "said", "tell", "come",
        "go", "going", "gone", "let", "lets", "let's", "get", "got", "make", "made",
        "why", "how", "when", "where", "what", "who", "yeah", "oh", "ooh",
    ]

    static func latinCreditRestLooksLikeSentence(_ rest: String) -> Bool {
        if rest.contains(where: { nonNameChars.contains($0) }) { return true }
        let punct = CharacterSet(charactersIn: "()[]{}'’\"“”,.!?;:/&-_~…")
        let words = rest.lowercased()
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: punct) }
            .filter { !$0.isEmpty }
        if words.contains(where: { nonNameWordsLatin.contains($0) }) { return true }
        if rest.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }),
           rest.filter({ $0 == " " }).count >= 2 { return true }
        if let last = rest.last, "，。！？!?…；;".contains(last) { return true }
        return false
    }

    /// 国际标准录音码 (ISRC) 行（形如 `ISRC TWB870211301` / `ISRC: TW-B87-02-11301`）。
    private static let isrcPattern = try! NSRegularExpression(
        pattern: #"^ISRC[\s:：-]*[A-Za-z]{2}[-\s]?[A-Za-z0-9]{3}[-\s]?\d{2}[-\s]?\d{5}\b"#,
        options: [.caseInsensitive]
    )

    /// 英文白名单角色名与半角冒号署名（如 `Publisher : Sam Duann`，不含段落标记词）。
    private static let latinRoleColonPattern = try! NSRegularExpression(
        pattern: #"^(?:executive\s+|assistant\s+|co-)?"#
            + #"(producers?|production|publishers?|labels?|composers?|lyricists?|"#
            + #"arrang(?:er|ement|ed)|engineers?|engineering|studios?|"#
            + #"mixing|mixed|mastering|mastered|recording|recorded|"#
            + #"orchestra|conductor|photograph(?:y|er)|artwork|design(?:er)?|director)"#
            + #"\s*:\s*\S"#,
        options: [.caseInsensitive]
    )

    private static func matchesLatinCreditPattern(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        let shapeHit = latinCreditFullWidthPattern.firstMatch(in: text, range: r) != nil
            || latinCreditHalfWidthPattern.firstMatch(in: text, range: r) != nil
            || latinRoleColonPattern.firstMatch(in: text, range: r) != nil
        guard shapeHit else { return false }
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return !latinCreditRestLooksLikeSentence(rest)
    }

    /// 歌词文件首行「曲名 - 歌手」抬头判定。要求首行能够严格拆分为与歌名等值段以及包含歌手名的段。
    public static func looksLikeHeaderLine(_ text: String, trackTitle: String, trackArtist: String) -> Bool {
        guard !trackTitle.isEmpty, !trackArtist.isEmpty else { return false }
        func norm(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        func stripBrackets(_ s: String) -> String {
            var out = "", depth = 0
            for c in s {
                if c == "(" || c == "[" || c == "（" || c == "［" { depth += 1 }
                else if c == ")" || c == "]" || c == "）" || c == "］" { depth = max(0, depth - 1) }
                else if depth == 0 { out.append(c) }
            }
            return out
        }
        for (lhs, rhs) in headerSplitCandidates(text) {
            let leftTitle = norm(stripBracketsForHeaderMatch(lhs))
            let rightTitle = norm(stripBracketsForHeaderMatch(rhs))
            let leftRaw = norm(lhs), rightRaw = norm(rhs)
            guard !leftRaw.isEmpty, !rightRaw.isEmpty else { continue }
            let titles = Set(headerTitleForms(trackTitle).map(norm)).subtracting([""])
            let artists = headerMatchVariants(of: trackArtist).map(norm).filter { !$0.isEmpty }
            if titles.contains(leftTitle), artists.contains(where: { rightRaw.contains($0) }) { return true }
            if titles.contains(rightTitle), artists.contains(where: { leftRaw.contains($0) }) { return true }
        }
        return false
    }

    /// 把一行切成"抬头的两段"的所有候选切法。
    ///
    /// 先试**带空格的** " - "(抬头最常见的写法);只有它唯一出现时才用,这样
    /// 「W-H-Y - 王力宏」这种歌名自带连字符的也能正确切开。带空格的没有或不唯一时,
    /// 退回"整行只有一个裸连字符"的情形(「陳柏宇-最後的擁抱」)。
    private static func headerSplitCandidates(_ text: String) -> [(String, String)] {
        for sep in [" - ", " – ", " — "] {
            let parts = text.components(separatedBy: sep)
            if parts.count == 2 { return [(parts[0], parts[1])] }
        }
        let dashes: Set<Character> = ["-", "–", "—"]
        guard text.filter({ dashes.contains($0) }).count == 1,
              let idx = text.firstIndex(where: { dashes.contains($0) })
        else { return [] }
        return [(String(text[text.startIndex..<idx]), String(text[text.index(after: idx)...]))]
    }

    /// 歌名可以长成的样子:原样、去括号、按字形切出的段(双语拼接靠它),各自加简繁孪生。
    /// **不设长度下限** —— 上面是等值判定,一两个字的歌名(「追」「GF」)不会因此误杀。
    private static func headerTitleForms(_ s: String) -> [String] {
        var out = [s, stripBracketsForHeaderMatch(s)]
        out.append(contentsOf: scriptRuns(stripBracketsForHeaderMatch(s)))
        var seen = Set<String>()
        var result: [String] = []
        for raw in out {
            let p = raw.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty, seen.insert(p).inserted else { continue }
            result.append(p)
            if let sib = HanScript.sibling(p), seen.insert(sib).inserted { result.append(sib) }
        }
        return result
    }

    /// 把标签拆成"可以单独比对"的若干段——整串、去括号、按分隔符拆出的每一段、按字形
    /// (汉字段 / 拉丁段)切出的每一段,以及每一段的简繁孪生写法。只给抬头判定用。
    ///
    /// 长度下限是刻意分开的:汉字段 ≥2 字,拉丁段 ≥4 字。拉丁段放宽到 2 会把 "The"/"You"
    /// 这类冠词代词当成歌名段,而英文歌词里几乎必然出现,那就成了误杀机器。
    private static func headerMatchVariants(of s: String) -> [String] {
        var pieces: [String] = []
        let separators = CharacterSet(charactersIn: "&/、,，;；|-–—")
        for base in [s, stripBracketsForHeaderMatch(s)] where !base.isEmpty {
            pieces.append(base)
            let flattened = base.replacingOccurrences(
                of: "feat.", with: "/", options: .caseInsensitive)
            pieces.append(contentsOf: flattened.components(separatedBy: separators))
            pieces.append(contentsOf: scriptRuns(base))
        }
        var out: [String] = []
        var seen = Set<String>()
        for raw in pieces {
            let p = raw.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty, longEnoughForHeaderMatch(p) else { continue }
            if seen.insert(p).inserted { out.append(p) }
            if let sib = HanScript.sibling(p), seen.insert(sib).inserted { out.append(sib) }
        }
        return out
    }

    /// 汉字段和拉丁段各自的长度下限,见 headerMatchVariants 的注释。
    private static func longEnoughForHeaderMatch(_ s: String) -> Bool {
        let han = s.unicodeScalars.filter { CharacterSet.hanLike.contains($0) }.count
        if han > 0 { return han >= 2 }
        return s.filter { $0.isLetter || $0.isNumber }.count >= 4
    }

    /// 按字形把一段文本切成"连续汉字/假名"和"连续拉丁"两类子串——双语拼接的标签
    /// (「日出 The Dawn」「月食 The Weeping Woman」)靠它拆开。
    private static func scriptRuns(_ s: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var currentIsHan: Bool?
        for ch in s {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { runs.append(current) }
                current = ""; currentIsHan = nil
                continue
            }
            let isHan = ch.unicodeScalars.allSatisfy { CharacterSet.hanLike.contains($0) }
            if let was = currentIsHan, was != isHan {
                if !current.isEmpty { runs.append(current) }
                current = ""
            }
            currentIsHan = isHan
            current.append(ch)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func stripBracketsForHeaderMatch(_ s: String) -> String {
        var out = "", depth = 0
        for c in s {
            if c == "(" || c == "[" || c == "（" || c == "［" { depth += 1 }
            else if c == ")" || c == "]" || c == "）" || c == "］" { depth = max(0, depth - 1) }
            else if depth == 0 { out.append(c) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // 版权/免责声明行。跟职员表不是一回事:它**没有冒号**,上面所有以"角色+冒号"为形状的
    // 规则全都够不着,所以要单独一条。
    //
    // 2026-08-18 全库扫描实测:郭顶《飞行器的执行周期》整张专辑(10 首)的末行都是
    // 「未经著作权人许可不得翻录翻唱或使用」,一条都没被滤掉。
    //
    // 判据用"关键短语必须成对出现"而不是单个词:光有「未经」可能是真歌词(「未经允许的
    // 心动」),必须同时出现"未经/不得/版权/权利"这类法务词与"许可/翻录/翻唱/复制/授权/
    // 保留"里的一个,才认。英文那条同理只认成句的 All rights reserved 之类。
    private static let copyrightNoticePattern = try! NSRegularExpression(
        pattern: #"(未经[^。]{0,12}(许可|授权|同意))|(不得(翻录|翻唱|复制|转载|使用|下载))|(版权所有)|(保留(所有)?权利)|(all rights reserved)|(unauthor(i[sz]ed)? (copying|reproduction|duplication))"#,
        options: [.caseInsensitive]
    )

    /// 整行只有符号/标点的行(实测到过单独一行 `-`)。它不是歌词,也不是署名,就是分隔用的
    /// 排版残渣;逐行规则里没有任何一条够得着它。
    ///
    /// 判据故意写成"去掉标点/符号/空白之后什么都不剩",而不是枚举符号:这样破折号、省略号、
    /// 全角波浪线、下划线一次覆盖完。⚠️ 不能把它并进"整行括号注释"一起治 —— 那一类
    /// (`（開心啊）`)里有真歌词。
    /// 标点+符号+空白的并集,一次查询顶原来三次(CharacterSet.contains 每次都是一趟
    /// ObjC 桥接,strippingCreditLines 对每行每字符跑,合并是纯赚)。
    private static let symbolOnlyIgnorable: CharacterSet =
        CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)

    public static func isSymbolOnlyLine(_ text: String) -> Bool {
        // 单遍 + 早退:出现任何"真内容"字符立刻 false(绝大多数歌词行第一个字符就退出),
        // 不再 filter 物化一个数组。语义与旧实现逐位一致:旧的 `trimmed(.whitespaces)
        // 非空` ⟺ 存在不属于 .whitespaces 的字符(注意 .whitespaces 不含换行,与
        // ignorable 里的 .whitespacesAndNewlines 刻意不同,这是旧行为,别"顺手统一")。
        var sawNonWhitespace = false
        for scalar in text.unicodeScalars {
            if !symbolOnlyIgnorable.contains(scalar) { return false }
            if !sawNonWhitespace, !CharacterSet.whitespaces.contains(scalar) {
                sawNonWhitespace = true
            }
        }
        return sawNonWhitespace
    }

    /// 厂牌/平台的**宣传出品语**,没有冒号 —— 「网易云音乐特别企划“星辰集”出品」
    /// (2026-08-31 用户在歌曲末尾看到它被当成一句歌词)。
    ///
    /// 为什么现有规则一条都够不着:上面那两条主力(creditLinePattern 的关键词表、
    /// genericHanCreditLinePattern 的结构化"短标签+冒号")**都要求冒号**,而这种宣传语是一句
    /// 完整的话、根本没有冒号。这不是"再补一个角色词"能解决的形状,所以另起一条,跟
    /// matchesCopyrightNotice / matchesDateStampLine 同属"无冒号、靠形状锚定"那一档。
    ///
    /// 判据是**两个条件同时成立**:去掉尾部标点引号后以出品/出版/发行/企划/呈现/呈献结尾,
    /// **并且**整行里出现平台/厂牌词。
    ///
    /// ⚠️ 平台词那半边不是保险起见,是**必需**的。拿这台机器上 156433 行真实歌词量过:
    ///   - 只要求"以角色词结尾":命中 8 条不同的行,其中 **6 条是真歌词**,全部栽在「呈现」上
    ///     ——「下一页结局已经慢慢呈现」「少一点 完美的呈现」「机械的唇语不太够呈现」
    ///     「让你画面一直呈现」「发光的立体呈现」「发光的 立体呈现」。
    ///   - 加上平台词:命中 2 条,`网易云音乐特别企划“星辰集”出品` 和 `索尼唱片出版`,
    ///     两条都是真的署名,**0 误杀**。
    /// 仅在包含知名音乐平台/厂牌名称时才判定为宣传行，避免误杀带类似词尾的正常歌词。
    private static let promoRoleTailPattern = try! NSRegularExpression(
        pattern: #"(出品|出版|发行|企划|呈现|呈献)$"#
    )
    private static let promoLabelPattern = try! NSRegularExpression(
        pattern: #"网易云音乐|网易音乐|QQ ?音乐|酷狗|酷我|腾讯音乐|环球|索尼|华纳|摩登天空|唱片|娱乐|传媒|文化|厂牌|Records|Entertainment"#,
        options: [.caseInsensitive]
    )
    /// 尾部要剥掉的标点/引号/括号 —— 「…“星辰集”出品」结尾干净,但「…出品。」「…出品）」
    /// 这类同样要认出来。
    private static let promoTrailingTrim = CharacterSet.punctuationCharacters
        .union(.symbols)
        .union(.whitespacesAndNewlines)

    public static func matchesPromoCreditLine(_ text: String) -> Bool {
        // 有冒号的写法交给上面那两条主力规则,这里只管没有冒号的 —— 不重复判定,也避免
        // 两条规则对同一行给出不同结论时难查是谁干的。
        guard !text.contains(":"), !text.contains("：") else { return false }
        let tail = String(text.unicodeScalars.reversed()
            .drop { promoTrailingTrim.contains($0) }.reversed().map(Character.init))
        guard !tail.isEmpty else { return false }
        let tailRange = NSRange(tail.startIndex..., in: tail)
        guard promoRoleTailPattern.firstMatch(in: tail, range: tailRange) != nil else { return false }
        let full = NSRange(text.startIndex..., in: text)
        return promoLabelPattern.firstMatch(in: text, range: full) != nil
    }

    /// 版权/免责声明行——见 copyrightNoticePattern 上的注释。
    public static func matchesCopyrightNotice(_ text: String) -> Bool {
        copyrightNoticePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 匹配包含版权标记（©, ℗ 等及其圆圈或括号变体）和四位年份的著作权行。
    private static let copyrightMarks: Set<Character> = ["©", "℗", "Ⓒ", "Ⓟ", "ⓒ", "ⓟ"]
    private static let parenCopyrightPattern = try! NSRegularExpression(
        pattern: #"\(\s*[CP]\s*\)"#, options: [.caseInsensitive])
    private static let fourDigitYearPattern = try! NSRegularExpression(
        pattern: #"(?:19|20)\d{2}"#)

    public static func matchesCopyrightMarkLine(_ text: String) -> Bool {
        let full = NSRange(text.startIndex..., in: text)
        guard fourDigitYearPattern.firstMatch(in: text, range: full) != nil else { return false }
        if text.contains(where: { copyrightMarks.contains($0) }) { return true }
        return parenCopyrightPattern.firstMatch(in: text, range: full) != nil
    }

    /// 匹配形如 "July 18, 2012 at 5:25 PM" 的无冒号纯创作日期戳行。
    private static let dateStampPattern = try! NSRegularExpression(
        pattern: #"^(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\.?\s+\d{1,2},\s*\d{4}(\s+at\s+\d{1,2}:\d{2}\s*[ap]m)?$"#,
        options: [.caseInsensitive]
    )

    /// 见 `isrcPattern`。
    public static func matchesISRCLine(_ text: String) -> Bool {
        isrcPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func matchesDateStampLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return dateStampPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    /// internal(不是 private):LyricDuet 拿它来否决"长得像角色名"的说话人标签,
    /// 复用同一张词表,免得两边各维护一份还对不齐。
    static func matchesKeywordCreditPattern(_ text: String) -> Bool {
        creditLinePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 对唱与对白歌词说话人标签豁免名单，防止被误判为署名行。
    private static let speakerLabels: Set<String> = [
        "男", "女", "合", "男合", "女合", "男女", "众", "齐",
        "白", "旁白", "念", "说", "对白", "口白",
        "男声", "女声", "合唱", "伴唱",
    ]

    private static func matchesStructuralCreditPattern(
        _ text: String, exemptions: Set<String> = []
    ) -> Bool {
        guard genericHanCreditLinePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
            return false
        }
        guard let sep = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<sep].trimmingCharacters(in: .whitespaces)
        return !speakerLabels.contains(label) && !exemptions.contains(String(label))
    }

    /// 结构化规则仅在整篇大部分为署名格式时生效（命中 >= 3 且过半），防止纯音乐配乐误录整篇职员表。
    private static func shouldApplyStructuralCreditFilter(
        _ texts: [String], exemptions: Set<String> = []
    ) -> Bool {
        guard !texts.isEmpty else { return false }
        let hits = texts.filter { matchesStructuralCreditPattern($0, exemptions: exemptions) }.count
        return hits >= 3 && hits * 2 > texts.count
    }

    /// 冒号右侧绝不会出现在人名/团名里的字(虚词、代词、否定、语气词)。
    /// 用于 `matchesNameListCreditShape` 辨识纯人名列表，杜绝包含口语对话的歌词(如「他说：我不走」)。
    private static let nonNameChars = Set("的了是不我你他她它们在也都就很没着过吗呢吧啊呀什么谁别把被让这那要会能又再却但而已经没有想")

    /// 冒号右侧的分隔符(一个角色多个人:「赵雷/喜子」「朵朵、天天」)。
    private static let nameListSeparators = CharacterSet(charactersIn: "/／、&＆,，")

    /// 匹配「汉字标签 + 冒号 + 纯人名列表」免词表形状。
    /// 需配合整篇命中 >= 2 行的阈值生效，并通过字符集与非人名字词过滤规避正文歌词。
    public static func matchesNameListCreditShape(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !rest.isEmpty, !speakerLabels.contains(String(label)) else { return false }
        let labelCore = String(label).components(separatedBy: creditLabelSeparators).joined()
        guard (2...20).contains(labelCore.count),
              labelCore.unicodeScalars.allSatisfy({ $0.properties.isIdeographic })
        else { return false }
        let segments = rest.components(separatedBy: nameListSeparators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard segments.count >= 2 || !latinCreditRestLooksLikeSentence(rest) else { return false }
        guard rest.count <= 60, (1...6).contains(segments.count) else { return false }
        return segments.allSatisfy { seg in
            let hasLatin = seg.unicodeScalars.contains { CharacterSet.letters.contains($0) && !$0.properties.isIdeographic }
            let limit = hasLatin ? 30 : 8
            return (2...limit).contains(seg.count)
                && seg.unicodeScalars.allSatisfy { u in
                    u.properties.isIdeographic || CharacterSet.alphanumerics.contains(u)
                        || " ()'’.-".unicodeScalars.contains(u)
                }
        }
    }

    /// 测试接缝:把一整份行文本过一遍署名行过滤,返回"这一行删不删"。
    ///
    /// 存在的理由:整份闸门(≥2 行、过半…)是这套规则的一半,只测单行匹配函数测不到它;
    /// 而从 `allLines()` 的输出反推"哪行被删了"会被另外两件事污染 —— 对唱标记会被
    /// LyricDuet 从正文里剥掉、一行多时间戳会被展开成多行,两者都让"文本对不上"却不是
    /// 过滤造成的(2026-08-20 拿全库 925 首做回归语料时踩到,误判出上百条"被误杀的真歌词")。
    /// 直接曝光这一层,语料统计和单测都拿它当唯一判据。
    public static func creditLineDropDecisions(
        _ texts: [String], trackTitle: String = "", trackArtist: String = "",
        speakerExemptions: Set<String> = []
    ) -> [Bool] {
        strippingCreditLines(
            texts, trackTitle: trackTitle, trackArtist: trackArtist,
            speakerExemptions: speakerExemptions)
    }

    /// 过滤掉署名/职员表行。关键词表逐行生效(它枚举的都是明确的角色名,误判空间很小);
    /// 结构化规则只在整份被主导时才生效,见 shouldApplyStructuralCreditFilter。
    private static func strippingCreditLines(
        _ texts: [String], trackTitle: String = "", trackArtist: String = "",
        speakerExemptions: Set<String> = []
    ) -> [Bool] {
        let useStructural = shouldApplyStructuralCreditFilter(texts, exemptions: speakerExemptions)
        // 免词表的双语形状:整份 ≥2 行才认(理由见 matchesBilingualCreditShape)。
        let bilingualHits = texts.filter(matchesBilingualCreditShape).count
        let useBilingualShape = bilingualHits >= 2
        // 免词表的「标签 + 名字串」形状:同样整份 ≥2 行才认(理由见 matchesNameListCreditShape)。
        let nameListHits = texts.filter(matchesNameListCreditShape).count
        let useNameListShape = nameListHits >= 2
        let drop = texts.enumerated().map { i, text -> Bool in
            // 演唱者标签行一律放行(2026-08-23)。放在所有规则**最前面**,而不是只补进
            // 结构化那一条:人名标签同时够得着好几条规则,逐条打补丁迟早漏。
            //
            // 独占一行的标记(`周杰伦：` 后面什么都没有)也走这里保留下来 —— 它确实不该
            // 显示,但该由 LyricDuet 按"剥完为空"丢掉,不是由署名过滤删:两者判据不同,
            // 让署名过滤兼这个职,等于把"这行是不是署名"和"这行有没有正文"混成一件事。
            if let (label, _, _) = LyricDuet.splitLabel(text), speakerExemptions.contains(label) {
                return false
            }
            if useBilingualShape, matchesBilingualCreditShape(text) { return true }
            if useNameListShape, matchesNameListCreditShape(text) { return true }
            if matchesKeywordCreditPattern(text) { return true }
            if matchesLatinCreditPattern(text) { return true }
            // 双字角色词判定跟关键词表一样逐行生效(不受"整份主导"闸门管):双字词的
            // 误杀面足够小,见 creditRoleWords 上的注释。
            if matchesRoleWordCredit(text) { return true }
            // 纯英文、没有冒号的那类("Mixed by X at Y")。同样逐行生效:它要求整行以角色词
            // 开头且紧跟 by/at,误杀面很小。
            if matchesEnglishCredit(text) { return true }
            // 版权/免责声明("未经著作权人许可不得翻录翻唱或使用")——没有冒号,上面几条
            // 以"角色+冒号"为形状的规则一条都够不着,见 copyrightNoticePattern。
            if matchesCopyrightNotice(text) { return true }
            // 带版权标记的著作权行(「著作权人：+© 2019、赋音乐」「℗ 2016 北京享耳音乐」)。
            // 跟上面那条"成句的法务声明"不是一回事:那条认法务词,这条认版权标记 + 年份,
            // 见 matchesCopyrightMarkLine(那里记着四条现有规则各差在哪一步)。
            if matchesCopyrightMarkLine(text) { return true }
            // 纯日期戳注解("July 18, 2012 at 5:25 PM")——同样没有冒号也不是角色词开头,
            // 见 dateStampPattern。
            if matchesDateStampLine(text) { return true }
            // 国际标准录音码行(`ISRC TWB870211301`)——没有冒号、也不是角色词开头,
            // 上面所有以"角色+冒号"为形状的规则都够不着,见 isrcPattern。
            if matchesISRCLine(text) { return true }
            // 厂牌/平台的宣传出品语(「网易云音乐特别企划"星辰集"出品」)——同样没有冒号,
            // 见 matchesPromoCreditLine(那里记着平台词这道闸是拿 15 万行真实歌词量出来的,
            // 不加会误杀 6 条含「呈现」的真歌词)。
            if matchesPromoCreditLine(text) { return true }
            // 整行只有符号(单独一行 `-` 之类),见 isSymbolOnlyLine。
            if isSymbolOnlyLine(text) { return true }
            // 抬头只在第一行认 —— 别的位置出现同样的字样多半是真歌词。
            if i == 0, looksLikeHeaderLine(text, trackTitle: trackTitle, trackArtist: trackArtist) {
                return true
            }
            return useStructural && matchesStructuralCreditPattern(text, exemptions: speakerExemptions)
        }
        // 兜底闸门:展示过滤**永远不把整份删空**。走到这一步说明判据出了我没预料到的偏差
        // (某种全篇都长成职员表形状、但其实是真歌词的写法),此时"整片空白/一直显示♪"对用户
        // 来说比"多显示几行职员表"糟糕得多——宁可漏治,不可删空。跟 collector 侧
        // isCreditOnlyLRC 的"整份拒收"是两回事:那边拒收之后还有别的源可以顶上,这边删空了
        // 就真的什么都没有了。
        //
        // 兜底保护：展示过滤不将整篇歌词完全删空；若全部被标记删除则全量保留。
        if drop.allSatisfy({ $0 }) && !texts.isEmpty {
            return texts.map { _ in false }
        }
        return drop
    }

    public init() {}

    /// load 入参快照，用于跳过重复的解析与派生计算。
    private struct LoadFingerprint: Equatable {
        let lyrics, lyricsTr, lyricsRoma, lyricsYRC: String
        let trackTitle, trackArtist: String
        let romanizationScripts: RomanizationScripts
        let songIsCantonese: Bool
    }
    private var loadedFingerprint: LoadFingerprint?

    /// 加载并解析歌词。若入参快照与上次一致则直接早退并保留缓存。
    @discardableResult
    public func load(
        lyrics: String, lyricsTr: String, lyricsRoma: String, lyricsYRC: String,
        trackTitle: String = "", trackArtist: String = "",
        romanizationScripts: RomanizationScripts = .default, songIsCantonese: Bool = false
    ) -> Bool {
        let fingerprint = LoadFingerprint(
            lyrics: lyrics, lyricsTr: lyricsTr, lyricsRoma: lyricsRoma, lyricsYRC: lyricsYRC,
            trackTitle: trackTitle, trackArtist: trackArtist,
            romanizationScripts: romanizationScripts, songIsCantonese: songIsCantonese)
        if fingerprint == loadedFingerprint { return false }
        loadedFingerprint = fingerprint
        self.romanizationScripts = romanizationScripts
        let normalizedYRC = LyricTimelineNormalizer.normalize(YRCParser.parse(lyricsYRC))
        let yrc = normalizedYRC.lines
        LyricTimelineNormalizer.logSummary(normalizedYRC.report, track: trackTitle)
        // 自带 offset：优先取 LRC 正文，为 0 则尝试从 YRC 解析。
        lrcOffsetMs = {
            let fromBase = LRCParser.parseOffsetMs(lyrics)
            return fromBase != 0 ? fromBase : LRCParser.parseOffsetMs(lyricsYRC)
        }()
        let parsedBase = LRCParser.parse(lyrics)
        let baseTexts = parsedBase.map(\.text)
        let baseSpeakers = LyricDuet.speakers(in: baseTexts)
        let baseDrop = Self.strippingCreditLines(
            baseTexts, trackTitle: trackTitle, trackArtist: trackArtist,
            speakerExemptions: baseSpeakers)
        let filteredBase = zip(parsedBase, baseDrop).compactMap { $0.1 ? nil : $0.0 }
        var candidateWords: [LyricLineWords] = []
        if !yrc.isEmpty {
            let texts = yrc.map { $0.words.map(\.text).joined() }
            let drop = Self.strippingCreditLines(
                texts, trackTitle: trackTitle, trackArtist: trackArtist,
                speakerExemptions: LyricDuet.speakers(in: texts))
            candidateWords = zip(yrc, drop).compactMap { $0.1 ? nil : $0.0 }
        }
        // 逐字覆盖率校验：若逐字行数不足整行 LRC 的一半，则退回整行模式。
        usingWords = !candidateWords.isEmpty
            && (filteredBase.isEmpty || candidateWords.count * 2 >= filteredBase.count)
        // 对唱分栏与独立标签行剔除。
        if usingWords {
            let plan = LyricDuet.planWords(candidateWords)
            let kept = zip(zip(plan.lines, plan.sides), plan.dropped).filter { !$0.1 }
            wordLines = kept.map { $0.0.0 }
            wordSides = kept.map { $0.0.1 }
            baseLines = []
            baseSides = []
        } else {
            let plan = LyricDuet.plan(lineTexts: filteredBase.map(\.text))
            wordLines = []
            wordSides = []
            let kept = zip(zip(zip(filteredBase, plan.texts), plan.sides), plan.dropped)
                .filter { !$0.1 }
            baseLines = kept.map { LyricLine(timeMs: $0.0.0.0.timeMs, text: $0.0.0.1) }
            baseSides = kept.map { $0.0.1 }
        }
        romaLines = LRCParser.parse(lyricsRoma)
        trLines = LRCParser.parse(lyricsTr)
        // 构建原文到译文/罗马音的内容匹配字典。
        do {
            let trByTime = Dictionary(trLines.map { ($0.timeMs, $0.text) }, uniquingKeysWith: { _, new in new })
            let romaByTime = Dictionary(romaLines.map { ($0.timeMs, $0.text) }, uniquingKeysWith: { _, new in new })
            trTextByPlainText = Dictionary(
                filteredBase.compactMap { line -> (String, String)? in
                    let key = Self.contentMatchKey(line.text)
                    guard !key.isEmpty, let tr = trByTime[line.timeMs], !tr.isEmpty else { return nil }
                    return (key, tr)
                }, uniquingKeysWith: { _, new in new })
            romaTextByPlainText = Dictionary(
                filteredBase.compactMap { line -> (String, String)? in
                    let key = Self.contentMatchKey(line.text)
                    guard !key.isEmpty, let roma = romaByTime[line.timeMs], !roma.isEmpty else { return nil }
                    return (key, roma)
                }, uniquingKeysWith: { _, new in new })
        }
        // 语言与罗马音判定：以过滤掉署名行后的正文为样本，避免署名中外文作者干扰。
        let contentSample = filteredBase.map(\.text).joined(separator: "\n")
        let contentWordSample = candidateWords
            .map { $0.words.map(\.text).joined() }
            .joined(separator: "\n")
        let scriptSample: String = {
            if !contentSample.isEmpty { return contentSample }
            if !contentWordSample.isEmpty { return contentWordSample }
            return lyrics.isEmpty ? lyricsYRC : lyrics
        }()
        songLooksJapanese = Romanizer.looksJapaneseSong(contentSample)
            || Romanizer.looksJapaneseSong(contentWordSample)
            || (contentSample.isEmpty && contentWordSample.isEmpty
                && (Romanizer.looksJapaneseSong(lyrics) || Romanizer.looksJapaneseSong(lyricsYRC)))
        // 整首歌的文字种类,给"按语言开关罗马音"兜底用(逐行判不出来的纯汉字行)。
        // 粒度/样本跟上面完全一致。
        songScript = Romanizer.songScript(of: scriptSample)
        // 粤语汉字跟普通话汉字长得一模一样,songScript(of:) 纯靠文字分析永远只会判成
        // .chinese——粤语这一档必须由调用方喂进来的外部信号(collector 的 SongLanguage
        // 真值)覆盖,不能指望从歌词文字里分析出来。只在判成 .chinese 时才覆盖:已经因为
        // 假名/谚文判成日文/韩文的行(比如粤语歌里引用了一句日文)不该被这个信号打断。
        if songScript == .chinese, songIsCantonese {
            songScript = .cantonese
        }
        // 歌词源自带的假名标注(酷狗的 [kana:] 标签)。对不齐时 parse 返回 nil,读音自动
        // 退回形态分析 —— 见 KanaAnnotation 顶部注释里"半对半错比不标更糟"那段。
        kanaAnnotation = KanaAnnotation.parse(lrc: lyrics)
        // 换歌词内容清空——见 romanizationText() 的缓存注释,纯粹是内存卫生考虑(避免
        // 常年挂着的进程把每一句听过的歌词文本都无限期缓存下去),不清空也不会算错,
        // 只是没必要让它跨曲目继续增长。
        romanizerFallbackCache.removeAll()
        wordGroupCache.removeAll()
        segmentsCache.removeAll()
        builtLinesCache.removeAll()
        // 换歌词内容后,按下标记忆化的缓存一并失效
        cachedActiveIdx = Int.min
        cachedActiveLine = nil
        cachedNextIdx = Int.min
        cachedNextText = nil
        cachedNextSide = nil
        cachedLeadIdx = Int.min
        cachedLeadLine = nil
        cachedCompactIdx = Int.min
        cachedCompactTrackEndMs = nil
        cachedCompactDwellMs = nil
        cachedCompactLeadInMs = nil
        lastScanIdx = Int.min
        return true
    }

    private var songLooksJapanese = false
    private var songScript: LyricScript = .other
    private var romanizationScripts: RomanizationScripts = .default

    /// **这一行**该不该标罗马音 —— 由它的文字种类和用户开关共同决定。
    /// `.other`(拉丁/泰文/西里尔…)不受管辖,始终允许,保持历来的行为。
    ///
    /// ⚠️ 2026-08-24 从"按整首歌"改成"按行":一首中文歌里引用的日文行(《这样吧》里的
    /// 「サヨナラ」)该按**日文**开关走、出罗马字,而同一首歌的中文行该按**中文**开关走
    /// (默认关 → 不显示)。按整首歌判做不到这件事,只能二选一:要么中文行被塞注音
    /// (用户报的就是这个),要么中日混唱歌(陶喆《My Anata》,41% 的行是日文)的日文行
    /// 一起丢掉罗马音。判定本身在 Romanizer.script(ofLine:song:)。
    private func romanizationAllowed(for line: String) -> Bool {
        guard let option = Romanizer.script(ofLine: line, song: songScript).option else {
            return true
        }
        return romanizationScripts.contains(option)
    }
    private var kanaAnnotation: KanaAnnotation?

    public var hasContent: Bool { usingWords ? !wordLines.isEmpty : !baseLines.isEmpty }

    /// 判定是否为冒号后无正文内容的独立说话人标签行（如「合：」），防止此类过渡行就近抢占译文/罗马音。
    private static func isBareSpeakerTag(_ text: String) -> Bool {
        guard let sep = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = text[text.startIndex..<sep].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: sep)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty && speakerLabels.contains(String(label))
    }

    /// 获取翻译文本：优先内容匹配，未命中退回基于时间戳的最近邻匹配。
    private func translationText(timeMs: Int, plainText: String) -> String? {
        guard !Self.isBareSpeakerTag(plainText) else { return nil }
        if let byContent = trTextByPlainText[Self.contentMatchKey(plainText)] {
            return byContent
        }
        return nearestText(trLines, timeMs)
    }

    /// 二分查找时间戳最接近的行文本（带 tolerance 容差）。
    private func nearestText(_ arr: [LyricLine], _ t: Int, tolerance: Int = 700) -> String? {
        guard !arr.isEmpty else { return nil }
        // upperBound:第一个 timeMs > t 的下标。
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].timeMs > t { hi = mid } else { lo = mid + 1 }
        }
        var best: String?
        var bestDiff = tolerance
        if lo > 0 {
            let d = t - arr[lo - 1].timeMs
            if d <= bestDiff { bestDiff = d; best = arr[lo - 1].text }
        }
        if lo < arr.count {
            let d = arr[lo].timeMs - t
            if d <= bestDiff {
                var r = lo
                while r + 1 < arr.count, arr[r + 1].timeMs == arr[lo].timeMs { r += 1 }
                best = arr[r].text
            }
        }
        return best
    }

    /// 客户端罗马音兜底缓存，按 plainText 记忆化以避免 20Hz tick 下重复运行 ICU 音译。
    private var romanizerFallbackCache: [String: String?] = [:]

    private func romanizationText(timeMs: Int, plainText: String) -> String? {
        // 用户开关前置，关闭对应语言罗马音时不展示也不兜底。
        guard romanizationAllowed(for: plainText) else { return nil }
        guard !Self.isBareSpeakerTag(plainText) else { return nil }
        // 优先内容匹配，其次源文件时间戳最近邻匹配。
        if let byContent = romaTextByPlainText[Self.contentMatchKey(plainText)] {
            return byContent
        }
        if let fromSource = nearestText(romaLines, timeMs) { return fromSource }
        // 仅在整首歌完全无服务端罗马音时走客户端兜底。
        guard romaLines.isEmpty else { return nil }
        if let cached = romanizerFallbackCache[plainText] { return cached }
        // 日语行使用分词片段派生读音；契约与 collector 保持统一。
        let result = Romanizer.lineReading(
            plainText,
            songLooksJapanese: songLooksJapanese,
            segments: cachedJapaneseSegments(for: plainText))
        romanizerFallbackCache[plainText] = result
        return result
    }

    // 行文本 → 分词片段。romanizationText(整行读音兜底)和 wordGroups(逐词罗马音)各要
    // 一份同一行的分词结果,原来各自跑一遍 CFStringTokenizer —— 这里按行缓存一份共用。
    // ⚠️ 两个消费方的启用门**不一样**(wordGroups 要求行内有假名,整行读音只要有汉字即可,
    // 见 buildWordGroups 的 guard),所以缓存必须放在两道门之前、由各自的门决定用不用,
    // 不能拿 wordGroupCache 的结果互相顶替 —— 纯汉字的日文行那样会把整行罗马音弄丢。
    private var segmentsCache: [String: [Romanizer.JapaneseSegment]] = [:]

    private func cachedJapaneseSegments(for line: String) -> [Romanizer.JapaneseSegment] {
        if let cached = segmentsCache[line] { return cached }
        let segs = Romanizer.japaneseSegments(
            line, marks: kanaAnnotation?.marks(forLine: line) ?? [])
        segmentsCache[line] = segs
        return segs
    }

    // 行文本 → 词组。跟 romanizerFallbackCache 同样按行缓存:同一行在播放期间会被反复
    // 查询(20Hz 定位 + 每帧填色),分词是纯 CPU 活,不该每次重算。
    private var wordGroupCache: [String: [SyncedLyricWordGroup]?] = [:]

    /// 把逐字词按读音分好组,并给每组配上罗马音——日文按分词器的片段边界并组,中文/粤语
    /// 按字数一一对应(见 buildWordGroups 的分支注释)。
    ///
    /// 日文关键点是**整行一次性分词**再按 UTF-16 范围对回去,而不是逐词单独求读音 ——
    /// 日文读音吃上下文,单独喂「明日」和放在句子里给出的读音可能不一样。
    ///
    /// 边界不对齐是常态:酷狗的逐字常常一个汉字一个词,而分词器眼里「いつか」是一个词。
    /// 所以一个片段横跨几个词时就把这几个词并成一组(下面那段罗马音标在整组底下);反过来
    /// 一个词里落进好几个片段时,把这些片段的读音拼起来给这一个词。
    /// `line` 由调用方传入(= words.map(\.text).joined()):activeLine/allLines 本来就要为
    /// romanizationText 拼这一份,这里复用,别再拼第二遍。
    private func wordGroups(for words: [SyncedLyricWord], line: String) -> [SyncedLyricWordGroup]? {
        guard !words.isEmpty else { return nil }
        // 缓存 key 必须带上时间身份(首词 startMs),不能只按行文本:词组里内嵌**绝对**
        // 时间戳,副歌重复句(同文本、不同时间)只按文本缓存会让第二次出现拿到第一次的
        // 时间轴 —— 逐词罗马音那一组从一开始就显示成已唱满(2026-08-20 对抗审查抓出的
        // 预存在 bug,非本轮引入;segmentsCache/romanizerFallbackCache 只存文本派生物、
        // 与时间无关,仍按纯文本共享)。
        let key = "\(words[0].startMs)|\(line)"
        if let cached = wordGroupCache[key] { return cached }
        // 逐词读音受同一道按语言开关的管辖 —— 关掉某种语言的罗马音之后,逐字歌词下面
        // 也不该再标读音。哪种语言能真的标出来(日文分词 / 中文粤语一字一音节)由
        // buildWordGroups 内部按 segments/hanRomanization 是否非空决定。
        let allowed = romanizationAllowed(for: line)
        // 分词结果与 romanizationText 共用 segmentsCache;门先于分词,门不开就不白分。
        let segments: [Romanizer.JapaneseSegment]? =
            (allowed && Romanizer.looksJapanese(line)) ? cachedJapaneseSegments(for: line) : nil
        // 中文/粤语/韩语的逐字(逐词)对齐(2026-08-29 加):只在这一行确证不是日文行时
        // (segments 为 nil,日文优先)才取整行罗马音——直接复用 romanizationText 那套
        // "内容匹配优先 + 时间兜底 + ICU 现算兜底"完整优先级链,不能自己另起一份简化版,
        // 否则两处一旦命中不一致,画面上会出现"整行罗马音"跟"逐字/逐词罗马音"文字对不上
        // 的诡异情况。哪种语言真能标出来(字数/词数对不对得上)由 buildWordGroups 内部判定。
        var hanRoma: String?
        var koreanRoma: String?
        if allowed, segments == nil {
            let script = Romanizer.script(ofLine: line, song: songScript)
            if script == .chinese || script == .cantonese {
                hanRoma = romanizationText(timeMs: words[0].startMs, plainText: line)
            } else if script == .korean {
                koreanRoma = romanizationText(timeMs: words[0].startMs, plainText: line)
            }
        }
        let result = Self.buildWordGroups(
            words: words, line: line, japanese: allowed,
            marks: kanaAnnotation?.marks(forLine: line) ?? [],
            segments: segments, hanRomanization: hanRoma, koreanRomanization: koreanRoma)
        wordGroupCache[key] = result
        return result
    }

    // nonisolated static:纯函数,不碰引擎自身状态,selftest 直接覆盖。
    //
    // 三条独立路径,互斥,按优先级尝试:
    // - 日文:分词器切出变长片段,片段跟逐字词的边界不对齐时把几个词并成一组
    //   (见 mergeSegmentsIntoWordGroups)——「いつか」分词器眼里是一个词,逐字数据却
    //   常常一字一词。
    // - 中文/粤语(hanRomanization,2026-08-29 加):汉字没有"一个字对应半个词"的歧义,
    //   collector 生成拼音/粤拼时就是**严格一字一音节、空格分隔**(见 jyutping.go
    //   toJyutpingLine 的注释),不需要分词,直接按下标一一配对;字数与音节数对不上
    //   (标点/多字词等边界情形)时保守放弃,让视图退回整行罗马音,不猜、不硬凑。
    // - 韩语(koreanRomanization,2026-08-29 加):跟日语一样可能有"一个词横跨好几个
    //   逐字词"的情况(酷狗式逐字切分一个谚文字一个词很常见),但韩语原文本来就按
    //   空格分词、罗马字转写保留同样的空格(见 Romanizer.koreanSegments 的实测注释),
    //   不需要跟日语一样现分词,片段直接从空格切出来,复用同一套合并算法。
    public static func buildWordGroups(
        words: [SyncedLyricWord], line: String, japanese: Bool,
        marks: [KanaAnnotation.Mark] = [],
        segments: [Romanizer.JapaneseSegment]? = nil,
        hanRomanization: String? = nil,
        koreanRomanization: String? = nil
    ) -> [SyncedLyricWordGroup]? {
        if japanese, Romanizer.looksJapanese(line) {
            // segments 非 nil 时是调用方(引擎的 segmentsCache)预分好的同一行结果,别再分一遍。
            let segs = segments ?? Romanizer.japaneseSegments(line, marks: marks)
            return mergeSegmentsIntoWordGroups(words: words, segs: segs)
        }
        if let hanRomanization, !hanRomanization.isEmpty {
            let tokens = hanRomanization.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count == words.count, !words.isEmpty else { return nil }
            return zip(words, tokens).enumerated().map { i, pair in
                SyncedLyricWordGroup(id: i, words: [pair.0], romanization: String(pair.1))
            }
        }
        if let koreanRomanization, !koreanRomanization.isEmpty,
           let segs = Romanizer.koreanSegments(line, romanization: koreanRomanization)
        {
            return mergeSegmentsIntoWordGroups(words: words, segs: segs)
        }
        return nil
    }

    /// 把"片段"(带 UTF16 范围和读音)跟逐字词按边界合并成组——日语/韩语共用同一套算法,
    /// 片段是怎么来的(分词器 vs 按空格切词)对这段逻辑透明,它只关心 UTF16 范围。
    ///
    /// 边界不对齐是常态:酷狗的逐字常常一个字一个词,而片段(日语的词/韩语的空格分词)
    /// 可能横跨好几个逐字词。所以一个片段跨过这一组的右边界时就把下一个词也吃进来
    /// (下面那段罗马音标在整组底下);反过来一个词里落进好几个片段时,把这些片段的
    /// 读音拼起来给这一个词。
    private static func mergeSegmentsIntoWordGroups(
        words: [SyncedLyricWord], segs: [Romanizer.JapaneseSegment]
    ) -> [SyncedLyricWordGroup]? {
        guard !segs.isEmpty else { return nil }

        var starts: [Int] = []
        var cursor = 0
        for w in words {
            starts.append(cursor)
            cursor += w.text.utf16.count
        }

        var groups: [SyncedLyricWordGroup] = []
        var i = 0
        while i < words.count {
            var j = i
            var end = starts[j] + words[j].text.utf16.count
            // 有片段跨过这一组的右边界 → 把下一个词也吃进来,直到边界落在片段之间。
            var grew = true
            while grew {
                grew = false
                for seg in segs where seg.utf16Start < end && seg.utf16End > end {
                    guard j + 1 < words.count else { break }
                    j += 1
                    end = starts[j] + words[j].text.utf16.count
                    grew = true
                    break
                }
            }
            let start = starts[i]
            let latins = segs.filter { $0.utf16Start < end && $0.utf16End > start }.map(\.latin)
            groups.append(SyncedLyricWordGroup(
                id: groups.count,
                words: Array(words[i...j]),
                romanization: latins.isEmpty ? nil : Romanizer.joinLatin(latins)))
            i = j + 1
        }
        // 一组罗马音都配不上(整行都是拉丁字母之类)时当作没有,让视图退回原来的整行罗马音。
        return groups.contains { $0.romanization != nil } ? groups : nil
    }

    // ---- 20Hz 热路径优化 ----------------------------------------------------
    /// 构建结果按行下标记忆化与全曲缓存：避免 20Hz 查询高频重复构建与深比较。
    private var builtLinesCache: [Int: SyncedLyricLine] = [:]
    public var cachedLinesCount: Int { builtLinesCache.count }
    private var cachedActiveIdx = Int.min
    private var cachedActiveLine: SyncedLyricLine?
    private var cachedNextIdx = Int.min
    private var cachedNextText: String?
    private var cachedNextSide: LyricDuet.Side?
    private var cachedLeadIdx = Int.min
    private var cachedLeadLine: SyncedLyricLine?
    private var cachedCompactIdx = Int.min
    private var cachedCompactTrackEndMs: Int?
    private var cachedCompactDwellMs: Int?
    private var cachedCompactLeadInMs: Int?

    /// 最后一个 timeMs <= posMs 的行下标,没有则 -1。二分查找定位(O(log N))。
    private static func lastIndex(atOrBefore posMs: Int, times: (Int) -> Int, count: Int) -> Int {
        guard count > 0 else { return -1 }
        var low = 0
        var high = count - 1
        var idx = -1
        while low <= high {
            let mid = (low + high) / 2
            if times(mid) <= posMs {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return idx
    }

    /// 定位扫描的单调窗口记忆化:常规单调推进时 O(1) 步进，跳转/拖动时二分查找。
    private var lastScanIdx = Int.min

    private func activeIndexCorrected(_ posMs: Int) -> Int {
        let count = usingWords ? wordLines.count : baseLines.count
        guard count > 0 else { return -1 }
        let time: (Int) -> Int =
            usingWords ? { self.wordLines[$0].timeMs } : { self.baseLines[$0].timeMs }
        if lastScanIdx >= -1, lastScanIdx < count {
            let lowOK = lastScanIdx == -1 || time(lastScanIdx) <= posMs
            let highOK = lastScanIdx + 1 >= count || time(lastScanIdx + 1) > posMs
            if lowOK && highOK { return lastScanIdx }
            let next = lastScanIdx + 1
            if next < count && time(next) <= posMs {
                let nextHighOK = next + 1 >= count || time(next + 1) > posMs
                if nextHighOK {
                    lastScanIdx = next
                    return next
                }
            }
        }
        let idx = Self.lastIndex(atOrBefore: posMs, times: time, count: count)
        lastScanIdx = idx
        return idx
    }

    public func activeLine(atMs rawPosMs: Int) -> SyncedLyricLine? {
        lineAt(activeIndexCorrected(rawPosMs + effectiveOffsetMs))
    }

    /// Queries the active lyric line at the specified millisecond position (upstream 761df776).
    @inlinable
    public func currentLine(at rawPosMs: Int) -> SyncedLyricLine? {
        activeLine(atMs: rawPosMs)
    }

    /// activeLine 的按下标查询本体。
    private func lineAt(_ idx: Int) -> SyncedLyricLine? {
        if idx == cachedActiveIdx { return cachedActiveLine }
        let line = buildLine(idx)
        cachedActiveIdx = idx
        cachedActiveLine = line
        return line
    }

    /// 单行展示面的「领先行」取词(在提前量窗口内提前一排)。
    private func leadLineAt(_ idx: Int) -> SyncedLyricLine? {
        if idx == cachedActiveIdx { return cachedActiveLine }
        if idx == cachedLeadIdx { return cachedLeadLine }
        let line = buildLine(idx)
        cachedLeadIdx = idx
        cachedLeadLine = line
        return line
    }

    /// lineAt / leadLineAt / allLines 共用的构建与行级缓存本体。
    private func buildLine(_ idx: Int) -> SyncedLyricLine? {
        guard idx >= 0 else { return nil }
        if let cached = builtLinesCache[idx] { return cached }
        let line: SyncedLyricLine?
        if usingWords {
            guard idx < wordLines.count else { return nil }
            let ln = wordLines[idx]
            let words = KaraokeFill.tailClamped(
                ln.words.map { w in
                    SyncedLyricWord(text: w.text, startMs: w.startMs, durationMs: w.durationMs)
                },
                nextLineStartMs: idx + 1 < wordLines.count ? wordLines[idx + 1].timeMs : nil)
            let joined = words.map(\.text).joined()
            line = SyncedLyricLine(
                romanization: romanizationText(timeMs: ln.timeMs, plainText: joined),
                translation: translationText(timeMs: ln.timeMs, plainText: joined),
                mainText: nil,
                words: words,
                wordGroups: wordGroups(for: words, line: joined),
                side: wordSides.indices.contains(idx) ? wordSides[idx] : nil,
                plainText: joined
            )
        } else {
            guard idx < baseLines.count else { return nil }
            let ln = baseLines[idx]
            line = SyncedLyricLine(
                romanization: romanizationText(timeMs: ln.timeMs, plainText: ln.text),
                translation: translationText(timeMs: ln.timeMs, plainText: ln.text),
                mainText: ln.text,
                words: nil,
                wordGroups: nil,
                side: baseSides.indices.contains(idx) ? baseSides[idx] : nil,
                plainText: ln.text
            )
        }
        if let line {
            builtLinesCache[idx] = line
        }
        return line
    }

    /// fastTick(20Hz) 打包查询：单次定位获取当前行、下一句预览、行下标与间奏下标。
    public struct TickResolution {
        public let index: Int?
        /// 歌词窗口滚动锚下标：间奏与空档期提前指向下一行，非空档与 index 一致。
        public let scrollIndex: Int?
        public let line: SyncedLyricLine?
        /// 单行展示面(灵动岛/菜单栏)当前行：唱完即提前切至下一句。
        public let compactLine: SyncedLyricLine?
        /// 唱完且下一句尚早时为 true(显示音符占位)，未开唱或无词为 false。
        public let compactPlaceholder: Bool
        /// compactLine 总展示时长(毫秒)，供菜单栏跑马灯配速。
        public let compactDwellMs: Int?
        /// compactLine 出现至开唱前的提前量(毫秒)，用于控制滚动首停等待。
        public let compactLeadInMs: Int?
        public let nextText: String?
        /// 下一行对唱分栏声部，独立于当前行声部。
        public let nextSide: LyricDuet.Side?
        public let gapIndex: Int?
    }

    /// - Parameter trackEndMs: 曲目总时长(毫秒)，用于计算末句显示窗口。
    public func tickQuery(atMs rawPosMs: Int, trackEndMs: Int? = nil) -> TickResolution {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        let gap: Int?
        if let window = gapWindow(after: idx), posMs >= window.start, posMs < window.end {
            gap = idx
        } else {
            gap = nil
        }
        // 单行展示面的取词:跟上面的 index/scrollIndex 共用同一次定位,不再扫一遍数组。
        let compact = CompactLyricLead.resolve(
            activeIdx: idx, posMs: posMs,
            lineEndMs: gapLineEndMs(at: idx),
            nextStartMs: gapLineStartMs(at: idx + 1))
        let compactLine: SyncedLyricLine?
        let compactPlaceholder: Bool
        let compactDwellMs: Int?
        let compactLeadInMs: Int?
        switch compact {
        case .line(let i):
            compactLine = leadLineAt(i)
            compactPlaceholder = false
            if i == cachedCompactIdx && trackEndMs == cachedCompactTrackEndMs {
                compactDwellMs = cachedCompactDwellMs
                compactLeadInMs = cachedCompactLeadInMs
            } else {
                let start = gapLineStartMs(at: i)
                let dwell = start.flatMap { s in
                    CompactLyricLead.displayDurationMs(
                        prevLineEndMs: gapLineEndMs(at: i - 1),
                        startMs: s,
                        lineEndMs: gapLineEndMs(at: i),
                        nextStartMs: gapLineStartMs(at: i + 1),
                        fallbackEndMs: trackEndMs)
                }
                let leadIn = start.map { s in
                    CompactLyricLead.leadInMs(prevLineEndMs: gapLineEndMs(at: i - 1), startMs: s)
                }
                cachedCompactIdx = i
                cachedCompactTrackEndMs = trackEndMs
                cachedCompactDwellMs = dwell
                cachedCompactLeadInMs = leadIn
                compactDwellMs = dwell
                compactLeadInMs = leadIn
            }
        case .placeholder:
            compactLine = nil
            compactPlaceholder = true
            compactDwellMs = nil
            compactLeadInMs = nil
        }
        let next = nextAt(idx + 1)
        return TickResolution(
            index: idx >= 0 ? idx : nil,
            scrollIndex: scrollLeadIndex(activeIdx: idx, posMs: posMs),
            line: lineAt(idx),
            compactLine: compactLine,
            compactPlaceholder: compactPlaceholder,
            compactDwellMs: compactDwellMs,
            compactLeadInMs: compactLeadInMs,
            nextText: next.text,
            nextSide: next.side,
            gapIndex: gap)
    }

    /// 滚动锚下标(TickResolution.scrollIndex 的本体):空档里指向下一行,其余时刻等于 activeIdx。
    private func scrollLeadIndex(activeIdx idx: Int, posMs: Int) -> Int? {
        if idx < 0 {
            if let w = gapWindow(after: -1), posMs >= w.end, gapLineCount > 0 { return 0 }
            return nil
        }
        guard idx + 1 < gapLineCount else { return idx }
        if let w = gapWindow(after: idx) {
            return posMs >= w.end ? idx + 1 : idx
        }
        if let end = gapLineEndMs(at: idx), posMs >= end { return idx + 1 }
        return idx
    }

    /// 双行显示用:当前行的下一行纯文本预览。
    public func upcomingLineText(afterMs rawPosMs: Int) -> String? {
        nextAt(activeIndexCorrected(rawPosMs + effectiveOffsetMs) + 1).text
    }

    /// upcomingLineText 的按下标本体(含对唱分栏声部)。
    private func nextAt(_ nextIdx: Int) -> (text: String?, side: LyricDuet.Side?) {
        if nextIdx == cachedNextIdx { return (cachedNextText, cachedNextSide) }
        let text: String?
        let side: LyricDuet.Side?
        if let line = buildLine(nextIdx) {
            text = line.plainText
            side = line.side
        } else {
            text = nil
            side = nil
        }
        cachedNextIdx = nextIdx
        cachedNextText = text
        cachedNextSide = side
        return (text, side)
    }

    // 供歌词窗口一次性获取全部行数据。复用 buildLine 避免重复构建，并填充 builtLinesCache。
    public func allLines(idPrefix: String) -> [LyricsWindowLine] {
        if usingWords {
            return (0 ..< wordLines.count).compactMap { i in
                guard let line = buildLine(i) else { return nil }
                return LyricsWindowLine(id: "\(idPrefix)#\(i)", timeMs: wordLines[i].timeMs, line: line)
            }
        }
        return (0 ..< baseLines.count).compactMap { i in
            guard let line = buildLine(i) else { return nil }
            return LyricsWindowLine(id: "\(idPrefix)#\(i)", timeMs: baseLines[i].timeMs, line: line)
        }
    }

    // "歌词窗口"用:跟 activeLine(atMs:) 扫的是同一个数组、加同一个 offsetMs 校正,
    // 只是返回下标而不是内容——故意不用"拿 activeLine 的内容去 allLines() 里找相同
    // 内容的下标"这种实现,副歌重复句会有多个内容相同的行,内容匹配选不准具体是哪一次
    // 出现,必须像这里一样直接按时间戳扫下标。
    public func activeLineIndex(atMs rawPosMs: Int) -> Int? {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        return idx >= 0 ? idx : nil
    }

    // ---- 间奏点(2026-08-19,歌词窗口的 Apple Music 式「•••」) --------------------

    /// 间奏判定参数。逐字歌词知道每一行唱到几点(最后一个词的结束),真实静默 ≥ minGapMs
    /// 才算间奏;行级 LRC 不知道一行唱多久,只能保守地要求两句**起点**差 ≥
    /// minPlainIntervalMs(一句歌词很少唱超过 15 秒),并假定前一句最多唱了间隔的三分之一
    /// (封顶 8 秒)。前奏单独一档:第一句开始得晚于 minIntroMs 才配一个间奏点。
    /// 窗口两端留余量:词尾后 tailMarginMs 才亮(别跟收尾的余音抢),下一句前 leadMs
    /// 熄灭(给滚动/换行让路)。
    public enum GapRule {
        public static let minGapMs = 6000
        public static let minIntroMs = 5000
        public static let minPlainIntervalMs = 15000
        public static let tailMarginMs = 1200
        public static let leadMs = 800
        public static let plainAssumedSingingCapMs = 8000
    }

    private var gapLineCount: Int { usingWords ? wordLines.count : baseLines.count }

    private func gapLineStartMs(at index: Int) -> Int? {
        if usingWords {
            return wordLines.indices.contains(index) ? wordLines[index].timeMs : nil
        }
        return baseLines.indices.contains(index) ? baseLines[index].timeMs : nil
    }

    /// 这一行唱完的时间:逐字取最后一个词的结束;行级不可知,给 nil。
    private func gapLineEndMs(at index: Int) -> Int? {
        guard usingWords, wordLines.indices.contains(index),
              let last = wordLines[index].words.last else { return nil }
        return last.startMs + last.durationMs
    }

    /// 第 index 行之后(index == -1 为前奏)的间奏活跃窗口。nil = 这里没有值得标记的间奏。
    public func gapWindow(after index: Int) -> (start: Int, end: Int)? {
        if index == -1 {
            guard let first = gapLineStartMs(at: 0), first >= GapRule.minIntroMs else { return nil }
            return (0, first - GapRule.leadMs)
        }
        guard let start = gapLineStartMs(at: index),
              let next = gapLineStartMs(at: index + 1) else { return nil }
        if let end = gapLineEndMs(at: index) {
            guard next - end >= GapRule.minGapMs else { return nil }
            return (end + GapRule.tailMarginMs, next - GapRule.leadMs)
        }
        guard next - start >= GapRule.minPlainIntervalMs else { return nil }
        let assumedEnd = start + min((next - start) / 3, GapRule.plainAssumedSingingCapMs)
        return (assumedEnd, next - GapRule.leadMs)
    }

    /// 整首歌全部间奏点(含前奏的 -1)。纯由时间轴决定,换歌/换词源后重算一次即可。
    public func gapMarkers() -> [LyricsGapMarker] {
        var out: [LyricsGapMarker] = []
        if let w = gapWindow(after: -1) {
            out.append(LyricsGapMarker(index: -1, startMs: w.start, endMs: w.end))
        }
        for i in 0 ..< max(0, gapLineCount - 1) {
            if let w = gapWindow(after: i) {
                out.append(LyricsGapMarker(index: i, startMs: w.start, endMs: w.end))
            }
        }
        return out
    }

    /// 此刻在不在某个间奏里(返回间奏点的 index,-1 = 前奏)。offsetMs 校正跟
    /// activeLine 同一处、同一方向 —— 这里已经加过,内部不能再调 activeLineIndex。
    public func activeGapIndex(atMs rawPosMs: Int) -> Int? {
        let posMs = rawPosMs + effectiveOffsetMs
        let idx = activeIndexCorrected(posMs)
        guard let window = gapWindow(after: idx) else { return nil }
        return (posMs >= window.start && posMs < window.end) ? idx : nil
    }
}
