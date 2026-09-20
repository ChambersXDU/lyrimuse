import Foundation
import LyrimuseCore

@MainActor
func runSettingsSearchTests() {
    let entries = SettingsSearchCatalog.entries
    expectEqual(entries.isEmpty, false)
    expectEqual(Set(entries.map(\.id)).count, entries.count)
    expectEqual(entries.filter { $0.titleKey.isEmpty || $0.pathKeys.isEmpty }, [])

    let accountNames = entries.compactMap { entry -> String? in
        guard case .account(let name) = entry.destination else { return nil }
        return name
    }
    expectEqual(Set(accountNames), ["listenBrainz", "stateRelay", "bark"])

    let sectionValues = Set(entries.compactMap(\.sectionValue))
    expectEqual(sectionValues, ["overlay", "menuBar", "display", "manage", "translation", "fetch"])

    for entry in entries {
        switch entry.destination {
        case .tab(let tab):
            expectEqual(["lyrics", "player", "appearance", "shortcuts", "general", "about"].contains(tab), true)
        case .account(let account):
            expectEqual(["listenBrainz", "stateRelay", "bark"].contains(account), true)
        }
    }

    expectEqual(SettingsSearchMatcher.rank(query: "字号", title: "字号", secondary: []), 0)
    expectEqual(SettingsSearchMatcher.rank(query: "font", title: "字号", secondary: ["font size"]), 2)
    expectEqual(SettingsSearchMatcher.rank(query: "xyz", title: "字号", secondary: ["font size"]), nil)
    expectEqual(SettingsSearchMatcher.normalize("  Font   Size \n"), "font size")

    let ranked = SettingsSearchMatcher.ranked(
        [("字体", ["背景"]), ("毛玻璃背景", [String]()), ("背景颜色", [String]())],
        query: "背景", title: { $0.0 }, secondary: { $0.1 })
    expectEqual(ranked.map(\.0), ["背景颜色", "毛玻璃背景", "字体"])
}
