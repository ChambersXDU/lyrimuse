import Foundation

public enum PlayerLinkage {

    public static func candidates(selectedPlayers: Set<PlaybackPlayer>) -> Set<PlaybackPlayer> {
        if selectedPlayers.contains(.auto) {
            return Set(PlaybackPlayer.allCases).subtracting([.auto])
        }
        return selectedPlayers.subtracting([.auto])
    }

    public static func effective(_ chosen: Set<PlaybackPlayer>, selectedPlayers: Set<PlaybackPlayer>) -> Set<PlaybackPlayer> {
        chosen.intersection(candidates(selectedPlayers: selectedPlayers))
    }

    public static func shouldQuit(terminatedBundleID: String, boundBundleIDs: Set<String>, runningBundleIDs: Set<String>) -> Bool {
        guard boundBundleIDs.contains(terminatedBundleID) else { return false }
        return boundBundleIDs.isDisjoint(with: runningBundleIDs)
    }

    public static let quitGraceSeconds: TimeInterval = 5

    public static func migratedLaunchSet(legacyEnabled: Bool, selectedPlayers: Set<PlaybackPlayer>, requiresSole: Bool) -> Set<PlaybackPlayer> {
        guard legacyEnabled else { return [] }
        if requiresSole {
            return selectedPlayers.soleExplicitPlayer.map { [$0] } ?? []
        }
        return candidates(selectedPlayers: selectedPlayers)
    }
}
