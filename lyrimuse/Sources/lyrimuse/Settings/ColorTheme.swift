import AppKit
import AppKit
import Foundation

public struct ColorTheme: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var foregroundColorHex: String
    public var backgroundColorHex: String
    public var textStrokeEnabled: Bool
    public var textStrokeColorHex: String

    public init(
        id: String = UUID().uuidString, name: String,
        foregroundColorHex: String, backgroundColorHex: String,
        textStrokeEnabled: Bool, textStrokeColorHex: String
    ) {
        self.id = id
        self.name = name
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.textStrokeEnabled = textStrokeEnabled
        self.textStrokeColorHex = textStrokeColorHex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        foregroundColorHex = try c.decode(String.self, forKey: .foregroundColorHex)
        backgroundColorHex = try c.decode(String.self, forKey: .backgroundColorHex)
        textStrokeEnabled = try c.decodeIfPresent(Bool.self, forKey: .textStrokeEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .legacyTextShadowEnabled)
            ?? false
        textStrokeColorHex = try c.decodeIfPresent(String.self, forKey: .textStrokeColorHex)
            ?? c.decodeIfPresent(String.self, forKey: .legacyTextShadowColorHex)
            ?? "#000000A6"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(foregroundColorHex, forKey: .foregroundColorHex)
        try c.encode(backgroundColorHex, forKey: .backgroundColorHex)
        try c.encode(textStrokeEnabled, forKey: .textStrokeEnabled)
        try c.encode(textStrokeColorHex, forKey: .textStrokeColorHex)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, foregroundColorHex, backgroundColorHex
        case textStrokeEnabled, textStrokeColorHex
        case legacyTextShadowEnabled = "textShadowEnabled"
        case legacyTextShadowColorHex = "textShadowColorHex"
    }
}

extension ColorTheme {

    public static var darkCard: ColorTheme {
        ColorTheme(
            id: "builtin-card", name: L10n.t("深色卡片"),
            foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#000000B3",
            textStrokeEnabled: false, textStrokeColorHex: "#000000A6"
        )
    }

    public static var classicBlack: ColorTheme {
        ColorTheme(
            id: "builtin-classic-black", name: L10n.t("经典黑字"),
            foregroundColorHex: "#000000FF", backgroundColorHex: "#00000000",

            textStrokeEnabled: false, textStrokeColorHex: "#FFFFFFFF"
        )
    }

    public static var classicBlackStroke: ColorTheme {
        ColorTheme(
            id: "builtin-classic-black-stroke", name: L10n.t("黑字描边"),
            foregroundColorHex: classicBlack.foregroundColorHex, backgroundColorHex: classicBlack.backgroundColorHex,
            textStrokeEnabled: true, textStrokeColorHex: classicBlack.textStrokeColorHex
        )
    }

    public static var builtInPresets: [ColorTheme] { [
        ColorTheme(
            id: "builtin-classic", name: L10n.t("经典白字"),
            foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
            textStrokeEnabled: false, textStrokeColorHex: "#000000A6"
        ),

        ColorTheme(
            id: "builtin-classic-white-stroke", name: L10n.t("白字描边"),
            foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
            textStrokeEnabled: true, textStrokeColorHex: "#000000A6"
        ),
        classicBlack,
        classicBlackStroke,
        darkCard,

        ColorTheme(
            id: "builtin-light-card", name: L10n.t("浅色卡片"),
            foregroundColorHex: "#000000FF", backgroundColorHex: "#FFFFFFB3",
            textStrokeEnabled: false, textStrokeColorHex: "#FFFFFFA6"
        ),
    ] }

    public static var defaultTheme: ColorTheme { classicBlackStroke }

    public func hasSameColors(as other: ColorTheme) -> Bool {
        foregroundColorHex == other.foregroundColorHex
            && backgroundColorHex == other.backgroundColorHex
            && textStrokeEnabled == other.textStrokeEnabled
            && (!textStrokeEnabled || textStrokeColorHex == other.textStrokeColorHex)
    }

    @MainActor
    func apply(to settings: AppSettings) {

        settings.followsCoverArt = false
        settings.foregroundColorHex = foregroundColorHex
        settings.backgroundColorHex = backgroundColorHex
        settings.textStrokeEnabled = textStrokeEnabled
        settings.textStrokeColorHex = textStrokeColorHex
    }
}

extension ColorTheme {

    func swatchImage() -> NSImage {
        ThemeSwatch.image(
            foregroundHex: foregroundColorHex, backgroundHex: backgroundColorHex,
            strokeEnabled: textStrokeEnabled, strokeHex: textStrokeColorHex
        )
    }
}
