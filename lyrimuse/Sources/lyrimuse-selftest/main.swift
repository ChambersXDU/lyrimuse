import LyrimuseCore
import Foundation

struct TestGroup {

    let name: String

    let summary: String

    let run: @MainActor () -> Void
}

let groups: [TestGroup] = [
    TestGroup(name: "file-transaction", summary: "文件提交失败回滚 / 歌词与索引一致性", run: runFileTransactionTests),
    TestGroup(name: "parsing", summary: "歌词解析:LRC / YRC / 逐字时间轴归一化", run: runLyricsParsingTests),
    TestGroup(name: "sync-engine", summary: "歌词同步引擎:当前行 / 滚动 / 填色 / 提前量 / 对唱分栏", run: runSyncEngineTests),
    TestGroup(name: "credit-lines", summary: "署名行 / 噪声行过滤(含全库语料回归)", run: runCreditLineTests),
    TestGroup(name: "romanization", summary: "罗马音 / 分词 / 繁简与异体字", run: runRomanizationTests),
    TestGroup(name: "cache-keys", summary: "缓存 key 归一化 / 合唱 credit 归并", run: runCacheKeyTests),
    TestGroup(name: "lyrics-offset", summary: "歌词时间轴偏移:基准 + 单曲微调 / 作用域 / 已校准名单", run: runLyricsOffsetTests),
    TestGroup(name: "lyrics-resolver", summary: "五源并发 / 匹配评分 / 失败隔离 / 缓存命中", run: runLyricsResolverTests),
    TestGroup(name: "lyrics-manager", summary: "歌词管理:列宽 / 写回合并 / 备份归档 / 重匹配 / 锁定 / 排序", run: runLyricsManagerTests),
    TestGroup(name: "cover-art", summary: "封面取图 / 取色", run: runCoverArtTests),
    TestGroup(name: "menu-bar", summary: "菜单栏跑马灯 / 逐字染色 / 进度图标", run: runMenuBarTests),
    TestGroup(name: "overlay", summary: "桌面悬浮歌词的几何与命中测试", run: runOverlayTests),
    TestGroup(name: "identity", summary: "变体身份与落盘路径:正式 / Dev 两套名字、配置目录与日志", run: runIdentityTests),
    TestGroup(name: "settings-ui", summary: "设置页交互纯逻辑:顺序优先列表拖拽排序(滞回 / 让位 / 写回)", run: runSettingsInteractionTests),
    TestGroup(name: "settings-search", summary: "设置搜索:目录 ↔ 源码调用点 ↔ catalog 三方对账 / 匹配排序", run: runSettingsSearchTests),
    TestGroup(name: "contracts", summary: "跨文件契约:歌词表面、设置搜索与已移除功能清理", run: runSourceContractTests),
]

let usage = """
用法: lyrimuse-selftest [--filter <组名子串>]... [--quiet] [--list]
  --filter, -f <子串>   只跑组名包含该子串的组(不区分大小写;可重复)
  --quiet,  -q          不打 ok 行,只留 FAIL 与每组一行汇总
  --list,   -l          列出所有组后退出
  --help,   -h          本说明
"""

var filters: [String] = []
var listOnly = false
var badArgument: String?
var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--quiet", "-q":
        quietOutput = true
    case "--list", "-l":
        listOnly = true
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--filter", "-f":
        if let value = argIterator.next(), !value.isEmpty {
            filters.append(value)
        } else {
            badArgument = arg
        }
    default:
        if arg.hasPrefix("--filter="), arg.count > "--filter=".count {
            filters.append(String(arg.dropFirst("--filter=".count)))
        } else {
            badArgument = arg
        }
    }
}
if let bad = badArgument {
    fputs("lyrimuse-selftest: 参数不认识或缺值: \(bad)\n\(usage)\n", stderr)
    exit(2)
}
if listOnly {
    for group in groups {
        print("\(group.name)\t\(group.summary)")
    }
    exit(0)
}

let selected = filters.isEmpty
    ? groups
    : groups.filter { group in filters.contains { group.name.range(of: $0, options: .caseInsensitive) != nil } }
if selected.isEmpty {
    fputs("lyrimuse-selftest: --filter \(filters) 没有匹配到任何组;用 --list 看全部组名。\n", stderr)
    exit(2)
}

do {
    let selfPath = #filePath
    let dir = URL(fileURLWithPath: selfPath).deletingLastPathComponent()
    let definePattern = try! NSRegularExpression(pattern: #"func (run[A-Za-z0-9_]+Tests)\(\)"#)
    let referencePattern = try! NSRegularExpression(pattern: #"\brun[A-Z][A-Za-z0-9_]*Tests\b"#)
    func matches(_ pattern: NSRegularExpression, in text: String, group: Int) -> [String] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: group)) }
    }
    var defined: [String] = []
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    for name in names where name.hasSuffix(".swift") && name != "main.swift" {
        guard let text = try? String(contentsOfFile: dir.appendingPathComponent(name).path, encoding: .utf8) else { continue }
        defined += matches(definePattern, in: text, group: 1)
    }
    let mainText = (try? String(contentsOfFile: selfPath, encoding: .utf8)) ?? ""
    let referenced = Set(matches(referencePattern, in: mainText, group: 0))
    expectEqual(defined.isEmpty, false)
    expectEqual(defined.filter { !referenced.contains($0) }, [])
    expectEqual(groups.count, defined.count)
}

let runStarted = Date()
for group in selected {
    let assertionsBefore = assertions
    let failuresBefore = failures
    let started = Date()

    MainActor.assumeIsolated { group.run() }
    let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
    let failed = failures - failuresBefore
    print("## \(group.name): \(assertions - assertionsBefore) 条断言\(failed == 0 ? "" : ", \(failed) 条 FAIL"), \(elapsedMs) ms")
}
let totalMs = Int(Date().timeIntervalSince(runStarted) * 1000)
let scope = filters.isEmpty ? "\(groups.count) 组" : "\(selected.count)/\(groups.count) 组(--filter \(filters.joined(separator: ",")))"
let passed = failures == 0
if passed {
    print("\n\(scope) · \(assertions) 条断言 · \(totalMs) ms · ALL PASS")
} else {
    print("\n\(scope) · \(assertions) 条断言 · \(failures) FAILURE(S)")
}
exit(passed ? 0 : 1)
