import LyrimuseCore
import Foundation

@MainActor
func runSettingsSearchTests() {
    let entries = SettingsSearchCatalog.entries
    let sourcesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appDir = sourcesDir.appendingPathComponent("lyrimuse")
    let catalogPath = sourcesDir.deletingLastPathComponent()
        .appendingPathComponent("Localization/Localizable.xcstrings").path

    func source(_ relative: String) -> String {
        let text = (try? String(contentsOfFile: appDir.appendingPathComponent(relative).path, encoding: .utf8)) ?? ""
        expectEqual(text.isEmpty, false)
        return text
    }

    func enumCaseNames(after marker: String, in text: String) -> [String] {
        guard let range = text.range(of: marker) else { return [] }
        var names: [String] = []
        for rawLine in text[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("var ") || line.hasPrefix("func ") || line.hasPrefix("init") || line == "}" { break }
            guard line.hasPrefix("case "), !line.contains(":"), !line.contains(".") else { continue }
            names += line.dropFirst("case ".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return names
    }

    expectEqual(entries.count >= 100, true)
    let ids = entries.map(\.id)
    expectEqual(Set(ids).count, ids.count)
    expectEqual(entries.filter { $0.pathKeys.isEmpty }.map(\.titleKey), [])
    expectEqual(entries.filter { $0.titleKey.isEmpty }.count, 0)

    let settingsView = source("SettingsView.swift")
    let accountTab = source("AccountLinkingTab.swift")
    let tabCases = enumCaseNames(after: "enum SettingsTab:", in: settingsView)
    expectEqual(tabCases, ["lyrics", "player", "appearance", "shortcuts", "general", "about"])
    let accountCases = enumCaseNames(after: "enum AccountDestination:", in: accountTab)
    expectEqual(accountCases, ["listenBrainz", "lastfm", "stateRelay", "bark"])
    let lyricsSectionCases: [String] = {
        guard let structRange = settingsView.range(of: "struct LyricsSettingsTab") else { return [] }
        return enumCaseNames(after: "private enum Section:", in: String(settingsView[structRange.upperBound...]))
    }()
    expectEqual(lyricsSectionCases, ["fetch", "translation", "display", "manage"])
    let lastfmSectionCases = enumCaseNames(after: "private enum LastfmSection:", in: accountTab)
    expectEqual(lastfmSectionCases.contains("settings"), true)
    expectEqual(settingsView.contains("@AppStorage(\"\(SettingsSearchCatalog.lyricsSectionKey)\")"), true)
    expectEqual(accountTab.contains("@AppStorage(\"\(SettingsSearchCatalog.lastfmSectionKey)\")"), true)

    var badDestinations: [String] = []
    var badSections: [String] = []
    var badDrawers: [String] = []
    for entry in entries {
        switch entry.destination {
        case .tab(let raw): if !tabCases.contains(raw) { badDestinations.append("\(entry.titleKey)→tab:\(raw)") }
        case .account(let name): if !accountCases.contains(name) { badDestinations.append("\(entry.titleKey)→account:\(name)") }
        case .softwareUpdate: break
        }
        switch (entry.sectionKey, entry.sectionValue) {
        case (nil, nil): break
        case (SettingsSearchCatalog.lyricsSectionKey?, let value?):
            if !lyricsSectionCases.contains(value) { badSections.append("\(entry.titleKey)→\(value)") }
        case (LyricsSurface.appearanceSectionStorageKey?, let value?):
            if LyricsSurface(rawValue: value) == nil { badSections.append("\(entry.titleKey)→\(value)") }
        case (SettingsSearchCatalog.lastfmSectionKey?, let value?):
            if !lastfmSectionCases.contains(value) { badSections.append("\(entry.titleKey)→\(value)") }
        default:
            badSections.append("\(entry.titleKey)→\(entry.sectionKey ?? "nil")/\(entry.sectionValue ?? "nil")")
        }
        if let drawer = entry.drawer {

            if entry.destination != .tab("appearance") || entry.sectionValue != drawer.appearanceSectionRawValue {
                badDrawers.append(entry.titleKey)
            }
        }
    }
    expectEqual(badDestinations, [])
    expectEqual(badSections, [])
    expectEqual(badDrawers, [])

    var catalogKeys: Set<String> = []
    if let data = FileManager.default.contents(atPath: catalogPath),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let strings = obj["strings"] as? [String: Any] {
        catalogKeys = Set(strings.keys)
    }
    expectEqual(catalogKeys.isEmpty, false)
    let missingKeys = entries.flatMap(\.localizedKeys)
        .filter { !SettingsSearchCatalog.brandPathComponents.contains($0) && !catalogKeys.contains($0) }
    expectEqual(Array(Set(missingKeys)).sorted(), [])

    let indexedTitles = Set(entries.map(\.titleKey) + entries.flatMap(\.alternateTitleKeys))

    let intentionallyUnindexed: Set<String> = [
        "主题", "文字", "背景", "排版", "行为",
        "封面", "菜单栏与 Dock", "语言与启动", "备份与迁移",
        "更新", "反馈与社区", "许可与版权", "诊断与数据",
        "自动更新", "已安装",
        "已改用自定义位置",
        "译文", "已缓存罗马音",
    ]
    let scannedFiles = [
        "SettingsView.swift", "AccountLinkingTab.swift",
        "UI/OverlayEditorStage.swift", "UI/NotchEditorStage.swift", "UI/MenuBarEditorStage.swift",
        "UI/OverlayStyleSettingsRows.swift", "UI/OverlayBehaviorSettingsRows.swift", "UI/AutoHideSettingsRows.swift",
        "UI/OverlayAllSettingsDrawer.swift",
        "Settings/LanguagePackRow.swift", "Settings/PlayerLinkageRow.swift", "Settings/LyricsLibraryStats.swift",
        "Settings/SoftwareUpdatePage.swift",
    ]
    let titlePattern = #/title:\s*L10n\.t\("((?:[^"\\]|\\.)*)"\)/#
    var scannedTitles: [String: [String]] = [:]
    for relative in scannedFiles {
        let text = source(relative)
        for marker in ["SettingsRow(", "SettingsSubRow(", "SettingsCardHeader("] {
            var searchStart = text.startIndex
            while let found = text.range(of: marker, range: searchStart..<text.endIndex) {

                var depth = 1
                var index = found.upperBound
                while index < text.endIndex, depth > 0 {
                    let ch = text[index]
                    if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 } else if ch == "{", depth == 1 { break }
                    index = text.index(after: index)
                }
                let segment = text[found.upperBound..<index]
                if let match = segment.firstMatch(of: titlePattern) {
                    scannedTitles[String(match.1), default: []].append(relative)
                }
                searchStart = found.upperBound
            }
        }
    }

    let enumTitleBlocks: [(file: String, marker: String)] = [
        ("UI/OverlayBehaviorSettingsRows.swift", "enum OverlayBehaviorItem"),
        ("UI/AutoHideSettingsRows.swift", "enum AutoHideItem"),
        ("SettingsView.swift", "enum NotchBehaviorItem"),
    ]
    let returnPattern = #/return L10n\.t\("((?:[^"\\]|\\.)*)"\)/#
    for block in enumTitleBlocks {
        let text = source(block.file)
        guard let enumRange = text.range(of: block.marker),
              let titleRange = text.range(of: "var title: String {", range: enumRange.upperBound..<text.endIndex) else {
            expectEqual(false, true)
            continue
        }

        let rest = text[titleRange.upperBound...]
        let blockEnd = rest.range(of: "\n    }")?.lowerBound ?? rest.endIndex
        var count = 0
        for match in rest[..<blockEnd].matches(of: returnPattern) {
            scannedTitles[String(match.1), default: []].append(block.file + "#" + block.marker)
            count += 1
        }
        expectEqual(count >= 2, true)
    }
    expectEqual(scannedTitles.count >= 100, true)
    let unindexed = scannedTitles.keys.filter { !indexedTitles.contains($0) && !intentionallyUnindexed.contains($0) }.sorted()
    expectEqual(unindexed.map { "\($0) @ \(scannedTitles[$0]!.joined(separator: ","))" }, [])
    let staleAllowlist = intentionallyUnindexed.filter { scannedTitles[$0] == nil }.sorted()
    expectEqual(staleAllowlist, [])
    let allowlistedButIndexed = intentionallyUnindexed.filter { indexedTitles.contains($0) }.sorted()
    expectEqual(allowlistedButIndexed, [])

    expectEqual(SettingsSearchMatcher.rank(query: "字号", title: "字号", secondary: []), 0)
    expectEqual(SettingsSearchMatcher.rank(query: "字", title: "字号", secondary: []), 0)
    expectEqual(SettingsSearchMatcher.rank(query: "号", title: "字号", secondary: []), 1)
    expectEqual(SettingsSearchMatcher.rank(query: "font", title: "字号", secondary: ["font size"]), 2)
    expectEqual(SettingsSearchMatcher.rank(query: "SPOTIFY", title: "播放器", secondary: ["Spotify"]), 2)
    expectEqual(SettingsSearchMatcher.rank(query: "xyz", title: "字号", secondary: ["font size"]), nil)
    expectEqual(SettingsSearchMatcher.rank(query: "   ", title: "字号", secondary: []), nil)
    expectEqual(SettingsSearchMatcher.rank(query: "菜单栏 字号", title: "字号", secondary: ["歌词显示 › 菜单栏"]), 0)
    expectEqual(SettingsSearchMatcher.rank(query: "菜单栏 abc", title: "字号", secondary: ["歌词显示 › 菜单栏"]), nil)
    expectEqual(SettingsSearchMatcher.normalize("  Font   Size \n"), "font size")
    let ranked = SettingsSearchMatcher.ranked(
        [("字体", ["背景"]), ("毛玻璃背景", [String]()), ("背景颜色", [String]())],
        query: "背景", title: { $0.0 }, secondary: { $0.1 })
    expectEqual(ranked.map(\.0), ["背景颜色", "毛玻璃背景", "字体"])
    expectEqual(SettingsSearchMatcher.ranked([("a", [String]())], query: "", title: { $0.0 }, secondary: { $0.1 }).count, 0)

    let fontSizeHits = SettingsSearchMatcher.ranked(entries, query: "字号", title: { $0.titleKey }, secondary: { $0.keywords + $0.pathKeys })
    expectEqual(fontSizeHits.map(\.sectionValue), ["overlay", "notch", "menuBar"])
    let qqHits = SettingsSearchMatcher.ranked(entries, query: "QQ", title: { $0.titleKey }, secondary: { $0.keywords + $0.pathKeys })
    expectEqual(qqHits.map(\.titleKey).contains("歌词来源"), true)
    expectEqual(qqHits.map(\.titleKey).contains("播放器"), true)
}
