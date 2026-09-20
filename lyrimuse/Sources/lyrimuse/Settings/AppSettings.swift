import Foundation
import LyrimuseCore
import SwiftUI
import AppKit

enum NotchCardStyle: String, Codable, Hashable, CaseIterable {
    case solidBlack
    case frostedGlass
    case darkGradient
    case coverArt
}

enum NotchEarModule: String, Codable, Hashable, CaseIterable {
    case title
    case artist
    case album

    case artwork

    case controls

    case elapsed

    case remaining
    case none
}

enum NotchEqualizerEar: String, Codable, Hashable, CaseIterable {
    case left
    case right
}

enum NotchLyricRowArtworkPosition: String, Codable, Hashable, CaseIterable {
    case left, right
}

enum MenuBarLyricsWidthMode: String, Codable, Hashable, CaseIterable {
    case fixed
    case adaptive
}

enum MenuBarLyricsIconPosition: String, Codable, Hashable, CaseIterable {
    case off
    case leading
    case trailing
}

enum LyricsRestingAlignment: String, Codable, Hashable, CaseIterable {

    case automatic
    case leading
    case center
    case trailing
}

extension LyricsRestingAlignment {

    static var notchOptions: [LyricsRestingAlignment] { [.automatic, .leading, .center, .trailing] }

    static var menuBarOptions: [LyricsRestingAlignment] { [.leading, .center, .trailing] }

    func resolved(duetSide: LyricDuet.Side?) -> LyricsRestingAlignment {
        guard self == .automatic else { return self }
        switch duetSide {
        case .leading?: return .leading
        case .trailing?: return .trailing
        case .center?: return .center
        case nil: return .leading
        }
    }

    var swiftUIAlignment: Alignment {
        switch self {

        case .leading, .automatic: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {

        static let preferWordLevelKaraoke = "np:preferWordLevelKaraoke"

        static let overlayLyricsKaraoke = "np:overlayLyricsKaraoke"
        static let notchLyricsKaraoke = "np:notchLyricsKaraoke"
        static let lyricsChineseVariant = "np:lyricsChineseVariant"
        static let hasSeenChineseLyrics = "np:hasSeenChineseLyrics"
        static let hasShownMenuBarPositionHint = "np:hasShownMenuBarPositionHint"
        static let showRomanization = "np:showRomanization"
        static let romanizationScripts = "np:romanizationScripts"
        static let showTranslation = "np:showTranslation"
        static let launchAtLoginEnabled = "np:launchAtLoginEnabled"

        static let launchMusicOnLyrimuseOpen = "np:launchMusicOnLyrimuseOpen"
        static let launchPlayersOnLyrimuseOpen = "np:launchPlayersOnLyrimuseOpen"
        static let quitWithPlayers = "np:quitWithPlayers"
        static let collectorServiceEnabled = "np:collectorServiceEnabled"
        static let showInDock = "np:showInDock"
        static let showNextLinePreview = "np:showNextLinePreview"
        static let overlayDuetAlignmentOverride = "np:overlayDuetAlignmentOverride"
        static let showLyricsInMenuBar = "np:showLyricsInMenuBar"
        static let menuBarLyricsMaxChars = "np:menuBarLyricsMaxChars"
        static let menuBarLyricsWidth = "np:menuBarLyricsMaxWidth"
        static let menuBarLyricsWidthMode = "np:menuBarLyricsWidthMode"
        static let menuBarLyricsAlignment = "np:menuBarLyricsAlignment"
        static let menuBarLyricsKaraoke = "np:menuBarLyricsKaraoke"
        static let menuBarLyricsTextColorHex = "np:menuBarLyricsTextColorHex"
        static let menuBarLyricsFillColorHex = "np:menuBarLyricsFillColorHex"
        static let menuBarLyricsIconPosition = "np:menuBarLyricsIconPosition"
        static let menuBarLyricsFontWeight = "np:menuBarLyricsFontWeight"
        static let menuBarLyricsFontSize = "np:menuBarLyricsFontSize"
        static let menuBarSecondaryLine = "np:menuBarSecondaryLine"
        static let menuBarHoverShowsControls = "np:menuBarHoverShowsControls"
        static let menuBarShowsTitleWhenNoLyrics = "np:menuBarShowsTitleWhenNoLyrics"
        static let menuBarIconStyle = "np:menuBarIconStyle"
        static let menuBarIconAnimates = "np:menuBarIconAnimates"
        static let lyricsOffsetStepMs = "np:lyricsOffsetStepMs"
        static let manualPickLocksLyrics = "np:manualPickLocksLyrics"
        static let textStrokeEnabled = "np:textStrokeEnabled"
        static let textStrokeColorHex = "np:textStrokeColorHex"
        static let fontFamilyName = "np:fontFamilyName"
        static let fontSize = "np:fontSize"
        static let overlayFontWeight = "np:overlayFontWeight"
        static let overlayWidth = "np:overlayWidth"
        static let notchContentWidth = "np:notchContentWidth"

        static let notchExpandedContentWidth = "np:notchExpandedContentWidth"
        static let foregroundColorHex = "np:foregroundColorHex"
        static let backgroundColorHex = "np:backgroundColorHex"

        static let overlayBackgroundGlass = "np:overlayBackgroundGlass"

        static let followsCoverArt = "np:followsCoverArt"
        static let lockPosition = "np:lockPosition"

        static let hideDuringScreenCapture = "np:hideDuringScreenCapture"
        static let hideWhenNotPlaying = "np:hideWhenNotPlaying"

        static let notchHideDuringScreenCapture = "np:notchHideDuringScreenCapture"
        static let notchHideWhenNotPlaying = "np:notchHideWhenNotPlaying"
        static let overlayFadeOnHover = "np:overlayFadeOnHover"
        static let overlayDragNeedsLongPress = "np:overlayDragNeedsLongPress"

        static let overlayPlacementMode = "np:overlayPlacementMode"
        static let debugHUDEnabled = "np:debugHUD"

        static let appLanguage = "np:appLanguage"
        static let hasShownAutomationOnboarding = "np:hasShownAutomationOnboarding"
        static let hasCompletedOnboarding = "np:hasCompletedOnboarding"
        static let hasOfferedICloudImport = "np:hasOfferedICloudImport"
        static let overlayStyle = "np:overlayStyle"
        static let classicOverlayEnabled = "np:classicOverlayEnabled"
        static let notchOverlayEnabled = "np:notchOverlayEnabled"
        static let notchCardStyle = "np:notchCardStyle"
        static let notchShowLyrics = "np:notchShowLyrics"
        static let motionCoverEnabled = "np:motionCoverEnabled"
        static let notchCollapsesWhenPaused = "np:notchCollapsesWhenPaused"
        static let notchShowsEqualizer = "np:notchShowsEqualizer"
        static let notchEqualizerEar = "np:notchEqualizerEar"
        static let notchExpandedShowsNextLine = "np:notchExpandedShowsNextLine"
        static let notchExpandedShowsControls = "np:notchExpandedShowsControls"
        static let notchExpandedShowsLyricsOffset = "np:notchExpandedShowsLyricsOffset"
        static let notchExpandedShowsArtwork = "np:notchExpandedShowsArtwork"
        static let notchExpandedShowsTrackTitle = "np:notchExpandedShowsTrackTitle"
        static let notchExpandedShowsArtist = "np:notchExpandedShowsArtist"
        static let notchExpandedShowsAlbum = "np:notchExpandedShowsAlbum"
        static let notchExpandedShowsQuickActions = "np:notchExpandedShowsQuickActions"
        static let notchLyricRowShowsArtwork = "np:notchLyricRowShowsArtwork"
        static let notchLyricRowArtworkPosition = "np:notchLyricRowArtworkPosition"
        static let notchLyricsAlignment = "np:notchLyricsAlignment"
        static let notchSecondaryLine = "np:notchSecondaryLine"
        static let notchFontFamilyName = "np:notchFontFamilyName"
        static let notchFontWeight = "np:notchFontWeight"
        static let notchFontSize = "np:notchFontSize"
        static let notchLeftEar = "np:notchLeftEar"
        static let notchRightEar = "np:notchRightEar"
        static let notchScreenID = "np:notchScreenID"
        static let notchAllScreens = "np:notchAllScreens"

        static let legacyClassicOverlayVisible = "np:overlayVisible"
        static let legacyNotchOverlayVisible = "np:notchOverlayVisible"

        static let customColorThemesJSON = "np:customColorThemesJSON"
        static let browserPlatformPairsJSON = "np:browserPlatformPairsJSON"
        static let manualBrowserFamiliesJSON = "np:manualBrowserFamiliesJSON"
        static let browserJSVerifiedAtJSON = "np:browserJSVerifiedAtJSON"

        static let receiveBetaUpdates = "np:receiveBetaUpdates"
    }

    static let defaultFontFamilyName = ""
    static let defaultFontSize = 31.0

    static let defaultOverlayFontWeight: OverlayFontWeight = .semibold

    static let defaultFollowsCoverArt = true

    static let defaultNotchCardStyle = NotchCardStyle.coverArt

    static let defaultNotchContentWidth: Double = 252
    static let defaultNotchExpandedContentWidth: Double = 482
    static let defaultNotchAllScreens = false
    static let defaultNotchScreenID = ""

    static let defaultNotchLeftEar = NotchEarModule.artwork
    static let defaultNotchRightEar = NotchEarModule.none

    static let defaultNotchHideDuringScreenCapture = false
    static let defaultNotchHideWhenNotPlaying = false
    static let defaultNotchShowLyrics = true

    static let defaultMotionCoverEnabled = true

    static let defaultNotchCollapsesWhenPaused = false
    static let defaultNotchShowsEqualizer = true
    static let defaultNotchEqualizerEar = NotchEqualizerEar.right
    static let defaultNotchExpandedShowsNextLine = true
    static let defaultNotchExpandedShowsControls = true

    static let defaultNotchExpandedShowsLyricsOffset = true
    static let defaultNotchExpandedShowsArtwork = false
    static let defaultNotchExpandedShowsTrackTitle = true
    static let defaultNotchExpandedShowsArtist = true
    static let defaultNotchExpandedShowsAlbum = true
    static let defaultNotchExpandedShowsQuickActions = true

    static let defaultNotchLyricRowShowsArtwork = false
    static let defaultNotchLyricRowArtworkPosition = NotchLyricRowArtworkPosition.right

    static let defaultNotchLyricsAlignment = LyricsRestingAlignment.automatic

    static let defaultNotchSecondaryLine = LyricSecondaryLine.nextLine

    static let defaultNotchFontFamilyName = ""
    static let defaultNotchFontWeight: OverlayFontWeight = .semibold
    static let defaultNotchFontSize = Double(NotchLyricRowMetrics.defaultMainFontSize)

    static let defaultMenuBarLyricsWidthMode = MenuBarLyricsWidthMode.adaptive
    static let defaultMenuBarLyricsAlignment = LyricsRestingAlignment.leading
    static let defaultMenuBarLyricsKaraoke = true

    static let defaultMenuBarLyricsIconPosition = MenuBarLyricsIconPosition.leading

    static let defaultMenuBarHoverShowsControls = false

    static let defaultMenuBarShowsTitleWhenNoLyrics = true
    static let defaultMenuBarLyricsTextColorHex = ""
    static let defaultMenuBarLyricsFillColorHex = ""

    static let defaultMenuBarLyricsFontWeight = OverlayFontWeight.regular

    static let defaultMenuBarLyricsFontSize: CGFloat = 0

    static let defaultMenuBarSecondaryLine = LyricSecondaryLine.nextLine

    private let defaults = UserDefaults.standard

    @Published var overlayLyricsKaraoke: Bool {
        didSet { defaults.set(overlayLyricsKaraoke, forKey: Keys.overlayLyricsKaraoke) }
    }
    @Published var notchLyricsKaraoke: Bool {
        didSet { defaults.set(notchLyricsKaraoke, forKey: Keys.notchLyricsKaraoke) }
    }

    @Published var hasSeenChineseLyrics: Bool {
        didSet { defaults.set(hasSeenChineseLyrics, forKey: Keys.hasSeenChineseLyrics) }
    }

    @Published var hasShownMenuBarPositionHint: Bool {
        didSet { defaults.set(hasShownMenuBarPositionHint, forKey: Keys.hasShownMenuBarPositionHint) }
    }

    @Published var receiveBetaUpdates: Bool {
        didSet {
            defaults.set(receiveBetaUpdates, forKey: Keys.receiveBetaUpdates)
            SparkleUpdaterManager.shared.betaChannelPreferenceChanged(enabled: receiveBetaUpdates)
        }
    }

    static let userReadsChinese: Bool = Locale.preferredLanguages.contains {
        $0.lowercased().hasPrefix("zh")
    }

    static let userReadsSimplifiedChinese: Bool = {
        guard let first = Locale.preferredLanguages.first?.lowercased(), first.hasPrefix("zh") else { return false }
        return !UILanguage.isTraditionalChineseTag(first)
    }()

    @Published var lyricsChineseVariant: ChineseVariant {
        didSet { defaults.set(lyricsChineseVariant.rawValue, forKey: Keys.lyricsChineseVariant) }
    }
    @Published var showRomanization: Bool {
        didSet { defaults.set(showRomanization, forKey: Keys.showRomanization) }
    }

    @Published var romanizationScripts: RomanizationScripts {
        didSet { defaults.set(romanizationScripts.rawValue, forKey: Keys.romanizationScripts) }
    }
    @Published var showTranslation: Bool {
        didSet { defaults.set(showTranslation, forKey: Keys.showTranslation) }
    }
    @Published var launchAtLoginEnabled: Bool {
        didSet {
            defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled)
            LoginItemManager.shared.setEnabled(launchAtLoginEnabled)
        }
    }

    @Published var launchPlayersOnLyrimuseOpen: Set<PlaybackPlayer> {
        didSet { defaults.set(launchPlayersOnLyrimuseOpen.map(\.rawValue).sorted(), forKey: Keys.launchPlayersOnLyrimuseOpen) }
    }

    @Published var quitWithPlayers: Set<PlaybackPlayer> {
        didSet { defaults.set(quitWithPlayers.map(\.rawValue).sorted(), forKey: Keys.quitWithPlayers) }
    }

    @Published var collectorServiceEnabled: Bool {
        didSet {
            defaults.set(collectorServiceEnabled, forKey: Keys.collectorServiceEnabled)
            CollectorServiceManager.setEnabled(collectorServiceEnabled)
        }
    }

    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: Keys.showInDock)
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        }
    }
    @Published var showNextLinePreview: Bool {
        didSet { defaults.set(showNextLinePreview, forKey: Keys.showNextLinePreview) }
    }

    @Published var overlayDuetAlignmentOverride: OverlayDuetAlignmentOverride {
        didSet {
            defaults.set(overlayDuetAlignmentOverride.rawValue, forKey: Keys.overlayDuetAlignmentOverride)
        }
    }

    @Published var showLyricsInMenuBar: Bool {
        didSet { defaults.set(showLyricsInMenuBar, forKey: Keys.showLyricsInMenuBar) }
    }

    @Published var menuBarLyricsMaxChars: Int {
        didSet { defaults.set(menuBarLyricsMaxChars, forKey: Keys.menuBarLyricsMaxChars) }
    }

    @Published var menuBarLyricsWidth: CGFloat {
        didSet { defaults.set(Double(menuBarLyricsWidth), forKey: Keys.menuBarLyricsWidth) }
    }

    @Published var menuBarLyricsAlignment: LyricsRestingAlignment {
        didSet { defaults.set(menuBarLyricsAlignment.rawValue, forKey: Keys.menuBarLyricsAlignment) }
    }
    @Published var menuBarLyricsWidthMode: MenuBarLyricsWidthMode {
        didSet { defaults.set(menuBarLyricsWidthMode.rawValue, forKey: Keys.menuBarLyricsWidthMode) }
    }

    @Published var menuBarLyricsKaraoke: Bool {
        didSet { defaults.set(menuBarLyricsKaraoke, forKey: Keys.menuBarLyricsKaraoke) }
    }

    @Published var menuBarLyricsTextColorHex: String {
        didSet { defaults.set(menuBarLyricsTextColorHex, forKey: Keys.menuBarLyricsTextColorHex) }
    }
    @Published var menuBarLyricsFillColorHex: String {
        didSet { defaults.set(menuBarLyricsFillColorHex, forKey: Keys.menuBarLyricsFillColorHex) }
    }

    @Published var menuBarLyricsIconPosition: MenuBarLyricsIconPosition {
        didSet {
            defaults.set(menuBarLyricsIconPosition.rawValue, forKey: Keys.menuBarLyricsIconPosition)
        }
    }

    @Published var menuBarLyricsFontWeight: OverlayFontWeight {
        didSet { defaults.set(menuBarLyricsFontWeight.rawValue, forKey: Keys.menuBarLyricsFontWeight) }
    }

    @Published var menuBarLyricsFontSize: CGFloat {
        didSet { defaults.set(Double(menuBarLyricsFontSize), forKey: Keys.menuBarLyricsFontSize) }
    }

    @Published var menuBarSecondaryLine: LyricSecondaryLine {
        didSet { defaults.set(menuBarSecondaryLine.rawValue, forKey: Keys.menuBarSecondaryLine) }
    }

    @Published var menuBarHoverShowsControls: Bool {
        didSet { defaults.set(menuBarHoverShowsControls, forKey: Keys.menuBarHoverShowsControls) }
    }

    @Published var menuBarShowsTitleWhenNoLyrics: Bool {
        didSet { defaults.set(menuBarShowsTitleWhenNoLyrics, forKey: Keys.menuBarShowsTitleWhenNoLyrics) }
    }

    @Published var menuBarIconStyle: MenuBarIconStyle {
        didSet { defaults.set(menuBarIconStyle.rawValue, forKey: Keys.menuBarIconStyle) }
    }

    @Published var menuBarIconAnimates: Bool {
        didSet { defaults.set(menuBarIconAnimates, forKey: Keys.menuBarIconAnimates) }
    }

    @Published var textStrokeEnabled: Bool {
        didSet { defaults.set(textStrokeEnabled, forKey: Keys.textStrokeEnabled) }
    }

    @Published var textStrokeColorHex: String {
        didSet {
            defaults.set(textStrokeColorHex, forKey: Keys.textStrokeColorHex)
            textStrokeColor = Color(hexWithAlpha: textStrokeColorHex, fallback: .black.opacity(0.65))
        }
    }

    @Published var lockPosition: Bool {
        didSet { defaults.set(lockPosition, forKey: Keys.lockPosition) }
    }

    @Published var hideDuringScreenCapture: Bool {
        didSet { defaults.set(hideDuringScreenCapture, forKey: Keys.hideDuringScreenCapture) }
    }

    @Published var hideWhenNotPlaying: Bool {
        didSet { defaults.set(hideWhenNotPlaying, forKey: Keys.hideWhenNotPlaying) }
    }

    @Published var notchHideDuringScreenCapture: Bool {
        didSet { defaults.set(notchHideDuringScreenCapture, forKey: Keys.notchHideDuringScreenCapture) }
    }
    @Published var notchHideWhenNotPlaying: Bool {
        didSet { defaults.set(notchHideWhenNotPlaying, forKey: Keys.notchHideWhenNotPlaying) }
    }

    @Published var overlayFadeOnHover: Bool {
        didSet { defaults.set(overlayFadeOnHover, forKey: Keys.overlayFadeOnHover) }
    }

    @Published var overlayDragNeedsLongPress: Bool {
        didSet { defaults.set(overlayDragNeedsLongPress, forKey: Keys.overlayDragNeedsLongPress) }
    }

    @Published var overlayPlacementMode: OverlayPlacementMode {
        didSet { defaults.set(overlayPlacementMode.rawValue, forKey: Keys.overlayPlacementMode) }
    }

    @Published var debugHUDEnabled: Bool {
        didSet { defaults.set(debugHUDEnabled, forKey: Keys.debugHUDEnabled) }
    }

    @Published var appLanguage: String {
        didSet { defaults.set(appLanguage, forKey: Keys.appLanguage) }
    }

    @Published var lyricsOffsetStepMs: Int {
        didSet { defaults.set(lyricsOffsetStepMs, forKey: Keys.lyricsOffsetStepMs) }
    }

    @Published var manualPickLocksLyrics: Bool {
        didSet { defaults.set(manualPickLocksLyrics, forKey: Keys.manualPickLocksLyrics) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published var hasOfferedICloudImport: Bool {
        didSet { defaults.set(hasOfferedICloudImport, forKey: Keys.hasOfferedICloudImport) }
    }

    @Published var classicOverlayEnabled: Bool {
        didSet { defaults.set(classicOverlayEnabled, forKey: Keys.classicOverlayEnabled) }
    }
    @Published var notchOverlayEnabled: Bool {
        didSet { defaults.set(notchOverlayEnabled, forKey: Keys.notchOverlayEnabled) }
    }

    @Published var notchAllScreens: Bool {
        didSet { defaults.set(notchAllScreens, forKey: Keys.notchAllScreens) }
    }

    @Published var notchCardStyle: NotchCardStyle {
        didSet { defaults.set(notchCardStyle.rawValue, forKey: Keys.notchCardStyle) }
    }

    @Published var notchShowLyrics: Bool {
        didSet { defaults.set(notchShowLyrics, forKey: Keys.notchShowLyrics) }
    }

    @Published var motionCoverEnabled: Bool {
        didSet { defaults.set(motionCoverEnabled, forKey: Keys.motionCoverEnabled) }
    }

    @Published var notchCollapsesWhenPaused: Bool {
        didSet { defaults.set(notchCollapsesWhenPaused, forKey: Keys.notchCollapsesWhenPaused) }
    }

    @Published var notchShowsEqualizer: Bool {
        didSet { defaults.set(notchShowsEqualizer, forKey: Keys.notchShowsEqualizer) }
    }

    @Published var notchEqualizerEar: NotchEqualizerEar {
        didSet { defaults.set(notchEqualizerEar.rawValue, forKey: Keys.notchEqualizerEar) }
    }

    @Published var notchExpandedShowsNextLine: Bool {
        didSet { defaults.set(notchExpandedShowsNextLine, forKey: Keys.notchExpandedShowsNextLine) }
    }

    @Published var notchExpandedShowsControls: Bool {
        didSet { defaults.set(notchExpandedShowsControls, forKey: Keys.notchExpandedShowsControls) }
    }

    @Published var notchExpandedShowsLyricsOffset: Bool {
        didSet { defaults.set(notchExpandedShowsLyricsOffset, forKey: Keys.notchExpandedShowsLyricsOffset) }
    }

    @Published var notchExpandedShowsArtwork: Bool {
        didSet { defaults.set(notchExpandedShowsArtwork, forKey: Keys.notchExpandedShowsArtwork) }
    }

    @Published var notchExpandedShowsTrackTitle: Bool {
        didSet { defaults.set(notchExpandedShowsTrackTitle, forKey: Keys.notchExpandedShowsTrackTitle) }
    }

    @Published var notchExpandedShowsArtist: Bool {
        didSet { defaults.set(notchExpandedShowsArtist, forKey: Keys.notchExpandedShowsArtist) }
    }

    @Published var notchExpandedShowsAlbum: Bool {
        didSet { defaults.set(notchExpandedShowsAlbum, forKey: Keys.notchExpandedShowsAlbum) }
    }

    @Published var notchExpandedShowsQuickActions: Bool {
        didSet { defaults.set(notchExpandedShowsQuickActions, forKey: Keys.notchExpandedShowsQuickActions) }
    }

    @Published var notchLyricRowShowsArtwork: Bool {
        didSet { defaults.set(notchLyricRowShowsArtwork, forKey: Keys.notchLyricRowShowsArtwork) }
    }

    @Published var notchLyricRowArtworkPosition: NotchLyricRowArtworkPosition {
        didSet { defaults.set(notchLyricRowArtworkPosition.rawValue, forKey: Keys.notchLyricRowArtworkPosition) }
    }

    @Published var notchLyricsAlignment: LyricsRestingAlignment {
        didSet { defaults.set(notchLyricsAlignment.rawValue, forKey: Keys.notchLyricsAlignment) }
    }

    @Published var notchSecondaryLine: LyricSecondaryLine {
        didSet { defaults.set(notchSecondaryLine.rawValue, forKey: Keys.notchSecondaryLine) }
    }

    @Published var notchFontFamilyName: String {
        didSet {
            defaults.set(notchFontFamilyName, forKey: Keys.notchFontFamilyName)
            recomputeNotchFonts()
        }
    }
    @Published var notchFontWeight: OverlayFontWeight {
        didSet {
            defaults.set(notchFontWeight.rawValue, forKey: Keys.notchFontWeight)
            recomputeNotchFonts()
        }
    }

    @Published var notchFontSize: Double {
        didSet {
            defaults.set(notchFontSize, forKey: Keys.notchFontSize)
            recomputeNotchFonts()
        }
    }

    @Published var notchLeftEar: NotchEarModule {
        didSet { defaults.set(notchLeftEar.rawValue, forKey: Keys.notchLeftEar) }
    }
    @Published var notchRightEar: NotchEarModule {
        didSet { defaults.set(notchRightEar.rawValue, forKey: Keys.notchRightEar) }
    }

    @Published var notchScreenID: String {
        didSet { defaults.set(notchScreenID, forKey: Keys.notchScreenID) }
    }

    @Published var fontFamilyName: String {
        didSet {
            defaults.set(fontFamilyName, forKey: Keys.fontFamilyName)
            recomputeFonts()
        }
    }

    @Published var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: Keys.fontSize)
            recomputeFonts()
        }
    }

    @Published var overlayFontWeight: OverlayFontWeight {
        didSet {
            defaults.set(overlayFontWeight.rawValue, forKey: Keys.overlayFontWeight)
            recomputeFonts()
        }
    }

    @Published var overlayWidth: Double {
        didSet { defaults.set(overlayWidth, forKey: Keys.overlayWidth) }
    }

    @Published var notchContentWidth: Double {
        didSet { defaults.set(notchContentWidth, forKey: Keys.notchContentWidth) }
    }

    @Published var notchExpandedContentWidth: Double {
        didSet { defaults.set(notchExpandedContentWidth, forKey: Keys.notchExpandedContentWidth) }
    }

    @Published var foregroundColorHex: String {
        didSet {
            defaults.set(foregroundColorHex, forKey: Keys.foregroundColorHex)
            foregroundColor = Color(hexWithAlpha: foregroundColorHex, fallback: .white)
        }
    }

    @Published var backgroundColorHex: String {
        didSet {
            defaults.set(backgroundColorHex, forKey: Keys.backgroundColorHex)
            backgroundColor = Color(hexWithAlpha: backgroundColorHex, fallback: .clear)
            backgroundIsVisible = Self.backgroundVisible(hex: backgroundColorHex, glass: overlayBackgroundGlass)
        }
    }

    @Published var overlayBackgroundGlass: Bool {
        didSet {
            defaults.set(overlayBackgroundGlass, forKey: Keys.overlayBackgroundGlass)
            backgroundIsVisible = Self.backgroundVisible(hex: backgroundColorHex, glass: overlayBackgroundGlass)
        }
    }

    static func backgroundVisible(hex: String, glass: Bool) -> Bool {
        glass || (NSColor(hexStringWithAlpha: hex)?.alphaComponent ?? 0) > 0.02
    }

    @Published var followsCoverArt: Bool {
        didSet { defaults.set(followsCoverArt, forKey: Keys.followsCoverArt) }
    }

    @Published var customColorThemes: [ColorTheme] {
        didSet {
            let json = (try? JSONEncoder().encode(customColorThemes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            defaults.set(json, forKey: Keys.customColorThemesJSON)
        }
    }

    @Published var browserPlatformPairs: [String: Set<String>] {
        didSet {
            let json = (try? JSONEncoder().encode(browserPlatformPairs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            defaults.set(json, forKey: Keys.browserPlatformPairsJSON)
        }
    }

    @Published var manualBrowserFamilies: [String: String] {
        didSet {
            let json = (try? JSONEncoder().encode(manualBrowserFamilies)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            defaults.set(json, forKey: Keys.manualBrowserFamiliesJSON)
        }
    }

    @Published var browserJSVerifiedAt: [String: Date] {
        didSet {
            let json = (try? JSONEncoder().encode(browserJSVerifiedAt)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            defaults.set(json, forKey: Keys.browserJSVerifiedAtJSON)
        }
    }

    @Published private(set) var foregroundColor: Color = .white
    @Published private(set) var backgroundColor: Color = .clear
    @Published private(set) var backgroundIsVisible: Bool = false
    @Published private(set) var textStrokeColor: Color = .black.opacity(0.65)
    @Published private(set) var mainFont: Font = .system(size: 20, weight: .bold)
    @Published private(set) var romanizationFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var translationFont: Font = .system(size: 14, weight: .regular)
    @Published private(set) var previewFont: Font = .system(size: 14, weight: .medium)

    @Published private(set) var notchMainFont: Font = .system(size: 13, weight: .semibold)
    @Published private(set) var notchMainDetailFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var notchSecondaryFont: Font = .system(size: 11, weight: .medium)

    private func recomputeFonts() {
        let weight = overlayFontWeight
        mainFont = .overlayFont(
            familyName: fontFamilyName, size: CGFloat(fontSize), weight: weight)
        romanizationFont = .overlayFont(
            familyName: fontFamilyName, size: CGFloat(fontSize) * 0.65,
            weight: weight.lighter(by: OverlayFontWeight.romanizationSteps))
        translationFont = .overlayFont(
            familyName: fontFamilyName, size: CGFloat(fontSize) * 0.7,
            weight: weight.lighter(by: OverlayFontWeight.translationSteps))
        previewFont = .overlayFont(
            familyName: fontFamilyName, size: CGFloat(fontSize) * 0.7,
            weight: weight.lighter(by: OverlayFontWeight.nextLinePreviewSteps))
    }

    private func recomputeNotchFonts() {
        let family = notchFontFamilyName
        let size = NotchLyricRowMetrics.clampedMainFontSize(CGFloat(notchFontSize))
        let weight = notchFontWeight
        let lighter = weight.lighter(by: OverlayFontWeight.notchSecondarySteps)
        notchMainFont = .overlayFont(familyName: family, size: size, weight: weight)
        notchMainDetailFont = .overlayFont(familyName: family, size: size, weight: lighter)
        notchSecondaryFont = .overlayFont(
            familyName: family, size: NotchLyricRowMetrics.secondaryFontSize, weight: lighter)
    }

    private init() {

        let legacyKaraoke = defaults.object(forKey: Keys.preferWordLevelKaraoke) as? Bool
        let overlayKaraoke = (defaults.object(forKey: Keys.overlayLyricsKaraoke) as? Bool) ?? legacyKaraoke ?? true
        let notchKaraoke = (defaults.object(forKey: Keys.notchLyricsKaraoke) as? Bool) ?? legacyKaraoke ?? true
        overlayLyricsKaraoke = overlayKaraoke
        notchLyricsKaraoke = notchKaraoke
        if legacyKaraoke != nil {
            defaults.set(overlayKaraoke, forKey: Keys.overlayLyricsKaraoke)
            defaults.set(notchKaraoke, forKey: Keys.notchLyricsKaraoke)
        }
        lyricsChineseVariant = defaults.string(forKey: Keys.lyricsChineseVariant)
            .flatMap(ChineseVariant.init(rawValue:)) ?? .off
        hasSeenChineseLyrics = defaults.bool(forKey: Keys.hasSeenChineseLyrics)
        hasShownMenuBarPositionHint = defaults.bool(forKey: Keys.hasShownMenuBarPositionHint)
        showRomanization = (defaults.object(forKey: Keys.showRomanization) as? Bool) ?? true

        romanizationScripts = (defaults.object(forKey: Keys.romanizationScripts) as? Int)
            .map(RomanizationScripts.init(rawValue:)) ?? .default

        showTranslation = (defaults.object(forKey: Keys.showTranslation) as? Bool) ?? Self.userReadsChinese

        launchAtLoginEnabled = (defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool) ?? true
        receiveBetaUpdates = (defaults.object(forKey: Keys.receiveBetaUpdates) as? Bool) ?? false
        if let raw = defaults.array(forKey: Keys.launchPlayersOnLyrimuseOpen) as? [String] {
            launchPlayersOnLyrimuseOpen = Set(raw.compactMap(PlaybackPlayer.init(rawValue:)))
        } else {

            let legacy = (defaults.object(forKey: Keys.launchMusicOnLyrimuseOpen) as? Bool) ?? false
            launchPlayersOnLyrimuseOpen = PlayerLinkage.migratedLaunchSet(
                legacyEnabled: legacy, selectedPlayers: PlaybackPlayerPreference.selected, requiresSole: true)
        }
        quitWithPlayers = Set(((defaults.array(forKey: Keys.quitWithPlayers) as? [String]) ?? [])
            .compactMap(PlaybackPlayer.init(rawValue:)))
        collectorServiceEnabled = (defaults.object(forKey: Keys.collectorServiceEnabled) as? Bool) ?? false
        showInDock = (defaults.object(forKey: Keys.showInDock) as? Bool) ?? true

        showNextLinePreview = (defaults.object(forKey: Keys.showNextLinePreview) as? Bool) ?? true
        overlayDuetAlignmentOverride = defaults.string(forKey: Keys.overlayDuetAlignmentOverride)
            .flatMap(OverlayDuetAlignmentOverride.init(rawValue:)) ?? .automatic
        showLyricsInMenuBar = (defaults.object(forKey: Keys.showLyricsInMenuBar) as? Bool) ?? false
        menuBarLyricsMaxChars = (defaults.object(forKey: Keys.menuBarLyricsMaxChars) as? Int) ?? 60

        menuBarLyricsWidth = CGFloat(
            (defaults.object(forKey: Keys.menuBarLyricsWidth) as? Double) ?? 250)
        menuBarLyricsWidthMode = defaults.string(forKey: Keys.menuBarLyricsWidthMode)
            .flatMap(MenuBarLyricsWidthMode.init(rawValue:)) ?? Self.defaultMenuBarLyricsWidthMode
        menuBarLyricsAlignment = defaults.string(forKey: Keys.menuBarLyricsAlignment)
            .flatMap(LyricsRestingAlignment.init(rawValue:)) ?? Self.defaultMenuBarLyricsAlignment

        menuBarLyricsKaraoke = (defaults.object(forKey: Keys.menuBarLyricsKaraoke) as? Bool) ?? Self.defaultMenuBarLyricsKaraoke

        if legacyKaraoke == false {
            menuBarLyricsKaraoke = false
            defaults.set(false, forKey: Keys.menuBarLyricsKaraoke)
        }
        menuBarLyricsTextColorHex = defaults.string(forKey: Keys.menuBarLyricsTextColorHex) ?? Self.defaultMenuBarLyricsTextColorHex
        menuBarLyricsFillColorHex = defaults.string(forKey: Keys.menuBarLyricsFillColorHex) ?? Self.defaultMenuBarLyricsFillColorHex
        menuBarLyricsIconPosition = defaults.string(forKey: Keys.menuBarLyricsIconPosition)
            .flatMap(MenuBarLyricsIconPosition.init(rawValue:)) ?? Self.defaultMenuBarLyricsIconPosition
        menuBarLyricsFontWeight = defaults.string(forKey: Keys.menuBarLyricsFontWeight)
            .flatMap(OverlayFontWeight.init(rawValue:)) ?? Self.defaultMenuBarLyricsFontWeight
        menuBarLyricsFontSize = CGFloat(
            (defaults.object(forKey: Keys.menuBarLyricsFontSize) as? Double) ?? Double(Self.defaultMenuBarLyricsFontSize))
        menuBarSecondaryLine = defaults.string(forKey: Keys.menuBarSecondaryLine)
            .flatMap(LyricSecondaryLine.init(rawValue:)) ?? Self.defaultMenuBarSecondaryLine
        menuBarHoverShowsControls = (defaults.object(forKey: Keys.menuBarHoverShowsControls) as? Bool)
            ?? Self.defaultMenuBarHoverShowsControls
        menuBarShowsTitleWhenNoLyrics = (defaults.object(forKey: Keys.menuBarShowsTitleWhenNoLyrics) as? Bool)
            ?? Self.defaultMenuBarShowsTitleWhenNoLyrics
        menuBarIconStyle = defaults.string(forKey: Keys.menuBarIconStyle)
            .flatMap(MenuBarIconStyle.init(rawValue:)) ?? .default
        menuBarIconAnimates = (defaults.object(forKey: Keys.menuBarIconAnimates) as? Bool) ?? true
        lyricsOffsetStepMs = (defaults.object(forKey: Keys.lyricsOffsetStepMs) as? Int) ?? 200
        manualPickLocksLyrics = (defaults.object(forKey: Keys.manualPickLocksLyrics) as? Bool) ?? false
        textStrokeEnabled = (defaults.object(forKey: Keys.textStrokeEnabled) as? Bool) ?? ColorTheme.defaultTheme.textStrokeEnabled
        overlayBackgroundGlass = (defaults.object(forKey: Keys.overlayBackgroundGlass) as? Bool) ?? false
        textStrokeColorHex = defaults.string(forKey: Keys.textStrokeColorHex) ?? ColorTheme.defaultTheme.textStrokeColorHex
        lockPosition = (defaults.object(forKey: Keys.lockPosition) as? Bool) ?? false
        overlayFadeOnHover = (defaults.object(forKey: Keys.overlayFadeOnHover) as? Bool) ?? false
        overlayDragNeedsLongPress =
            (defaults.object(forKey: Keys.overlayDragNeedsLongPress) as? Bool) ?? false
        overlayPlacementMode = defaults.string(forKey: Keys.overlayPlacementMode)
            .flatMap(OverlayPlacementMode.init(rawValue:)) ?? .free
        debugHUDEnabled = (defaults.object(forKey: Keys.debugHUDEnabled) as? Bool) ?? false

        let legacyHideDuringCapture = (defaults.object(forKey: Keys.hideDuringScreenCapture) as? Bool) ?? false
        let legacyHideWhenNotPlaying = (defaults.object(forKey: Keys.hideWhenNotPlaying) as? Bool) ?? false
        hideDuringScreenCapture = legacyHideDuringCapture
        hideWhenNotPlaying = legacyHideWhenNotPlaying
        notchHideDuringScreenCapture =
            (defaults.object(forKey: Keys.notchHideDuringScreenCapture) as? Bool) ?? legacyHideDuringCapture
        notchHideWhenNotPlaying =
            (defaults.object(forKey: Keys.notchHideWhenNotPlaying) as? Bool) ?? legacyHideWhenNotPlaying
        appLanguage = defaults.string(forKey: Keys.appLanguage) ?? "system"
        hasCompletedOnboarding = (defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool)
            ?? (defaults.object(forKey: Keys.hasShownAutomationOnboarding) as? Bool) ?? false
        hasOfferedICloudImport =
            (defaults.object(forKey: Keys.hasOfferedICloudImport) as? Bool) ?? false

        var classicOn: Bool
        var notchOn: Bool
        if let legacyStyle = defaults.string(forKey: Keys.overlayStyle) {
            classicOn = (defaults.object(forKey: Keys.classicOverlayEnabled) as? Bool) ?? (legacyStyle != "notch")
            notchOn = (defaults.object(forKey: Keys.notchOverlayEnabled) as? Bool) ?? (legacyStyle == "notch")
        } else {
            classicOn = (defaults.object(forKey: Keys.classicOverlayEnabled) as? Bool) ?? true
            notchOn = (defaults.object(forKey: Keys.notchOverlayEnabled) as? Bool) ?? false
        }

        if let legacyVisible = defaults.object(forKey: Keys.legacyClassicOverlayVisible) as? Bool {
            if !legacyVisible { classicOn = false }
            defaults.set(classicOn, forKey: Keys.classicOverlayEnabled)
            defaults.removeObject(forKey: Keys.legacyClassicOverlayVisible)
        }
        if let legacyVisible = defaults.object(forKey: Keys.legacyNotchOverlayVisible) as? Bool {
            if !legacyVisible { notchOn = false }
            defaults.set(notchOn, forKey: Keys.notchOverlayEnabled)
            defaults.removeObject(forKey: Keys.legacyNotchOverlayVisible)
        }
        classicOverlayEnabled = classicOn
        notchOverlayEnabled = notchOn
        notchCardStyle = defaults.string(forKey: Keys.notchCardStyle)
            .flatMap(NotchCardStyle.init(rawValue:)) ?? Self.defaultNotchCardStyle
        notchShowLyrics = (defaults.object(forKey: Keys.notchShowLyrics) as? Bool) ?? Self.defaultNotchShowLyrics
        motionCoverEnabled = (defaults.object(forKey: Keys.motionCoverEnabled) as? Bool) ?? Self.defaultMotionCoverEnabled
        notchCollapsesWhenPaused = (defaults.object(forKey: Keys.notchCollapsesWhenPaused) as? Bool)
            ?? Self.defaultNotchCollapsesWhenPaused
        notchShowsEqualizer = (defaults.object(forKey: Keys.notchShowsEqualizer) as? Bool) ?? Self.defaultNotchShowsEqualizer
        notchEqualizerEar = defaults.string(forKey: Keys.notchEqualizerEar)
            .flatMap(NotchEqualizerEar.init(rawValue:)) ?? Self.defaultNotchEqualizerEar
        notchExpandedShowsNextLine = (defaults.object(forKey: Keys.notchExpandedShowsNextLine) as? Bool)
            ?? Self.defaultNotchExpandedShowsNextLine
        notchExpandedShowsControls = (defaults.object(forKey: Keys.notchExpandedShowsControls) as? Bool)
            ?? Self.defaultNotchExpandedShowsControls
        notchExpandedShowsLyricsOffset = (defaults.object(forKey: Keys.notchExpandedShowsLyricsOffset) as? Bool)
            ?? Self.defaultNotchExpandedShowsLyricsOffset
        notchExpandedShowsArtwork = (defaults.object(forKey: Keys.notchExpandedShowsArtwork) as? Bool)
            ?? Self.defaultNotchExpandedShowsArtwork
        notchExpandedShowsTrackTitle = (defaults.object(forKey: Keys.notchExpandedShowsTrackTitle) as? Bool)
            ?? Self.defaultNotchExpandedShowsTrackTitle
        notchExpandedShowsArtist = (defaults.object(forKey: Keys.notchExpandedShowsArtist) as? Bool)
            ?? Self.defaultNotchExpandedShowsArtist
        notchExpandedShowsAlbum = (defaults.object(forKey: Keys.notchExpandedShowsAlbum) as? Bool)
            ?? Self.defaultNotchExpandedShowsAlbum
        notchExpandedShowsQuickActions = (defaults.object(forKey: Keys.notchExpandedShowsQuickActions) as? Bool)
            ?? Self.defaultNotchExpandedShowsQuickActions
        notchLyricRowShowsArtwork = (defaults.object(forKey: Keys.notchLyricRowShowsArtwork) as? Bool)
            ?? Self.defaultNotchLyricRowShowsArtwork
        notchLyricRowArtworkPosition = defaults.string(forKey: Keys.notchLyricRowArtworkPosition)
            .flatMap(NotchLyricRowArtworkPosition.init(rawValue:)) ?? Self.defaultNotchLyricRowArtworkPosition
        notchLyricsAlignment = defaults.string(forKey: Keys.notchLyricsAlignment)
            .flatMap(LyricsRestingAlignment.init(rawValue:)) ?? Self.defaultNotchLyricsAlignment
        notchSecondaryLine = defaults.string(forKey: Keys.notchSecondaryLine)
            .flatMap(LyricSecondaryLine.init(rawValue:)) ?? Self.defaultNotchSecondaryLine

        notchFontFamilyName = defaults.string(forKey: Keys.notchFontFamilyName) ?? Self.defaultNotchFontFamilyName
        notchFontWeight = defaults.string(forKey: Keys.notchFontWeight)
            .flatMap(OverlayFontWeight.init(rawValue:)) ?? Self.defaultNotchFontWeight
        notchFontSize = (defaults.object(forKey: Keys.notchFontSize) as? Double) ?? Self.defaultNotchFontSize
        notchLeftEar = defaults.string(forKey: Keys.notchLeftEar)
            .flatMap(NotchEarModule.init(rawValue:)) ?? Self.defaultNotchLeftEar
        notchRightEar = defaults.string(forKey: Keys.notchRightEar)
            .flatMap(NotchEarModule.init(rawValue:)) ?? Self.defaultNotchRightEar
        notchAllScreens = (defaults.object(forKey: Keys.notchAllScreens) as? Bool) ?? Self.defaultNotchAllScreens
        notchScreenID = defaults.string(forKey: Keys.notchScreenID) ?? Self.defaultNotchScreenID
        fontFamilyName = defaults.string(forKey: Keys.fontFamilyName) ?? Self.defaultFontFamilyName
        fontSize = (defaults.object(forKey: Keys.fontSize) as? Double) ?? Self.defaultFontSize

        overlayFontWeight = defaults.string(forKey: Keys.overlayFontWeight)
            .flatMap(OverlayFontWeight.init(rawValue:)) ?? Self.defaultOverlayFontWeight

        overlayWidth = (defaults.object(forKey: Keys.overlayWidth) as? Double) ?? 488
        notchContentWidth = (defaults.object(forKey: Keys.notchContentWidth) as? Double) ?? Self.defaultNotchContentWidth

        notchExpandedContentWidth = (defaults.object(forKey: Keys.notchExpandedContentWidth) as? Double) ?? Self.defaultNotchExpandedContentWidth
        foregroundColorHex = defaults.string(forKey: Keys.foregroundColorHex) ?? ColorTheme.defaultTheme.foregroundColorHex
        backgroundColorHex = defaults.string(forKey: Keys.backgroundColorHex) ?? ColorTheme.defaultTheme.backgroundColorHex
        followsCoverArt = (defaults.object(forKey: Keys.followsCoverArt) as? Bool) ?? Self.defaultFollowsCoverArt
        if let json = defaults.string(forKey: Keys.customColorThemesJSON),
           let data = json.data(using: .utf8),
           let themes = try? JSONDecoder().decode([ColorTheme].self, from: data) {
            customColorThemes = themes
        } else {
            customColorThemes = []
        }
        if let json = defaults.string(forKey: Keys.browserPlatformPairsJSON),
           let data = json.data(using: .utf8),
           let pairs = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            browserPlatformPairs = pairs
        } else {
            browserPlatformPairs = [:]
        }
        if let json = defaults.string(forKey: Keys.manualBrowserFamiliesJSON),
           let data = json.data(using: .utf8),
           let families = try? JSONDecoder().decode([String: String].self, from: data) {
            manualBrowserFamilies = families
        } else {
            manualBrowserFamilies = [:]
        }
        if let json = defaults.string(forKey: Keys.browserJSVerifiedAtJSON),
           let data = json.data(using: .utf8),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            browserJSVerifiedAt = map
        } else {
            browserJSVerifiedAt = [:]
        }

        recomputeFonts()
        recomputeNotchFonts()
        foregroundColor = Color(hexWithAlpha: foregroundColorHex, fallback: .white)
        backgroundColor = Color(hexWithAlpha: backgroundColorHex, fallback: .clear)
        backgroundIsVisible = Self.backgroundVisible(hex: backgroundColorHex, glass: overlayBackgroundGlass)
        textStrokeColor = Color(hexWithAlpha: textStrokeColorHex, fallback: .black.opacity(0.65))

        ConfigPortability.pruneObsoleteDefaults()
    }

    static func formattedSeconds(ms: Int) -> String {
        var text = String(format: "%.2f", Double(ms) / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text += "0" }
        return text
    }

    static func signedSeconds(ms: Int) -> String {
        guard ms != 0 else { return formattedSeconds(ms: 0) }
        return (ms > 0 ? "+" : "-") + formattedSeconds(ms: abs(ms))
    }
}
