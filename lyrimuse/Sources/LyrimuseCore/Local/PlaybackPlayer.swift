import Foundation

public enum PlaybackPlayer: String, CaseIterable, Identifiable, Codable, Hashable {
    case appleMusic = "apple_music"

    public var id: Self { self }
    public var bundleIdentifier: String { "com.apple.Music" }
}

public enum PlaybackPlayerPreference {
    public static var selected: Set<PlaybackPlayer> { [.appleMusic] }
    public static var isExclusivelyAppleMusic: Bool { true }
    public static var soleExplicitPlayer: PlaybackPlayer? { .appleMusic }
}
