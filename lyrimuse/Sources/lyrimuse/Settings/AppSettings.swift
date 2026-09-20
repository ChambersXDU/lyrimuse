import Foundation
import LyrimuseCore
import SwiftUI
import AppKit

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
        static let lyricsChineseVariant = "np:lyricsChineseVariant"
        static let hasSeenChineseLyrics = "np:hasSeenChineseLyrics"
        static let hasShownMenuBarPositionHint = "np:hasShownMenuBarPositionHint"
        static let showRomanization = "np:showRomanization"
        static let romanizationScripts = "np:romanizationScripts"
        static let showTranslation = "np:showTranslation"
        static let launchAtLoginEnabled = "np:launchAtLoginEnabled"

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
        static let foregroundColorHex = "np:foregroundColorHex"
        static let backgroundColorHex = "np:backgroundColorHex"

        static let overlayBackgroundGlass = "np:overlayBackgroundGlass"

        static let followsCoverArt = "np:followsCoverArt"
        static let lockPosition = "np:lockPosition"

        static let hideDuringScreenCapture = "np:hideDuringScreenCapture"
        static let hideWhenNotPlaying = "np:hideWhenNotPlaying"

        static let overlayFadeOnHover = "np:overlayFadeOnHover"
        static let overlayDragNeedsLongPress = "np:overlayDragNeedsLongPress"

        static let overlayPlacementMode = "np:overlayPlacementMode"
        static let debugHUDEnabled = "np:debugHUD"

        static let appLanguage = "np:appLanguage"
        static let classicOverlayEnabled = "np:classicOverlayEnabled"

        static let legacyClassicOverlayVisible = "np:overlayVisible"

        static let customColorThemesJSON = "np:customColorThemesJSON"
    }

    static let defaultFontFamilyName = ""
    static let defaultFontSize = 31.0

    static let defaultOverlayFontWeight: OverlayFontWeight = .semibold

    static let defaultFollowsCoverArt = true

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
    @Published var hasSeenChineseLyrics: Bool {
        didSet { defaults.set(hasSeenChineseLyrics, forKey: Keys.hasSeenChineseLyrics) }
    }

    @Published var hasShownMenuBarPositionHint: Bool {
        didSet { defaults.set(hasShownMenuBarPositionHint, forKey: Keys.hasShownMenuBarPositionHint) }
    }

    static let userReadsChinese: Bool = Locale.preferredLanguages.contains {
        $0.lowercased().hasPrefix("zh")
    }

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

    @Published var classicOverlayEnabled: Bool {
        didSet { defaults.set(classicOverlayEnabled, forKey: Keys.classicOverlayEnabled) }
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

    @Published private(set) var foregroundColor: Color = .white
    @Published private(set) var backgroundColor: Color = .clear
    @Published private(set) var backgroundIsVisible: Bool = false
    @Published private(set) var textStrokeColor: Color = .black.opacity(0.65)
    @Published private(set) var mainFont: Font = .system(size: 20, weight: .bold)
    @Published private(set) var romanizationFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var translationFont: Font = .system(size: 14, weight: .regular)
    @Published private(set) var previewFont: Font = .system(size: 14, weight: .medium)

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

    private init() {

        let legacyKaraoke = defaults.object(forKey: Keys.preferWordLevelKaraoke) as? Bool
        let overlayKaraoke = (defaults.object(forKey: Keys.overlayLyricsKaraoke) as? Bool) ?? legacyKaraoke ?? true
        overlayLyricsKaraoke = overlayKaraoke
        if legacyKaraoke != nil {
            defaults.set(overlayKaraoke, forKey: Keys.overlayLyricsKaraoke)
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
        appLanguage = defaults.string(forKey: Keys.appLanguage) ?? "system"
        var classicOn = (defaults.object(forKey: Keys.classicOverlayEnabled) as? Bool) ?? true

        if let legacyVisible = defaults.object(forKey: Keys.legacyClassicOverlayVisible) as? Bool {
            if !legacyVisible { classicOn = false }
            defaults.set(classicOn, forKey: Keys.classicOverlayEnabled)
            defaults.removeObject(forKey: Keys.legacyClassicOverlayVisible)
        }
        classicOverlayEnabled = classicOn
        fontFamilyName = defaults.string(forKey: Keys.fontFamilyName) ?? Self.defaultFontFamilyName
        fontSize = (defaults.object(forKey: Keys.fontSize) as? Double) ?? Self.defaultFontSize

        overlayFontWeight = defaults.string(forKey: Keys.overlayFontWeight)
            .flatMap(OverlayFontWeight.init(rawValue:)) ?? Self.defaultOverlayFontWeight

        overlayWidth = (defaults.object(forKey: Keys.overlayWidth) as? Double) ?? 488
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
        recomputeFonts()
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
