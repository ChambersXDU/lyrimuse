import Foundation
import LyrimuseCore

@MainActor
func runSourceContractTests() {
    expectEqual(LyricsSurface.allCases.map(\.rawValue), ["overlay", "menuBar"])
    expectEqual(LyricsSurface.appearanceSectionStorageKey, "settings:appearanceSection")
    expectEqual(LyricsSurface.overlay.appearanceSectionRawValue, "overlay")
    expectEqual(LyricsSurface(rawValue: "menuBar"), .menuBar)
    expectEqual(LyricsSurface(rawValue: "other"), nil)

    let destinations = SettingsSearchCatalog.entries.map(\.destination)
    expectEqual(destinations.contains { destination in
        if case .tab("appearance") = destination { return true }
        return false
    }, true)

    expectEqual(CollectorRestartPolicy.hotReloadedKeys, [])
    expectEqual(CollectorRestartPolicy.needsRestart(changedKeys: ["players"]), true)
    expectEqual(CollectorRestartPolicy.changedKeys(from: ["a": 1], to: ["a": 2]), ["a"])
}
