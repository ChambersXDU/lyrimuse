import SwiftUI
import AppKit
import CoreText
import LyrimuseCore

extension NSColor {

    var hexStringWithAlpha: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#FFFFFFFF" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        let a = Int(round(rgb.alphaComponent * 255))
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    convenience init?(hexStringWithAlpha hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 24) & 0xFF) / 255,
            green: CGFloat((v >> 16) & 0xFF) / 255,
            blue: CGFloat((v >> 8) & 0xFF) / 255,
            alpha: CGFloat(v & 0xFF) / 255
        )
    }
}

extension Color {

    init(hexWithAlpha hex: String, fallback: Color = .white) {
        guard let ns = NSColor(hexStringWithAlpha: hex) else {
            self = fallback
            return
        }
        self.init(nsColor: ns)
    }

    var hexStringWithAlpha: String { NSColor(self).hexStringWithAlpha }
}

extension OverlayFontWeight {
    fileprivate var swiftUIWeight: Font.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    var displayName: String {
        switch self {
        case .light: return L10n.t("细")
        case .regular: return L10n.t("常规")
        case .medium: return L10n.t("稍粗")
        case .semibold: return L10n.t("较粗")
        case .bold: return L10n.t("加粗")
        case .heavy: return L10n.t("特粗")
        }
    }
}

extension Font {

    static func overlayFont(familyName: String, size: CGFloat, weight: OverlayFontWeight) -> Font {
        guard !familyName.isEmpty,
              let nsFont = NSFontManager.shared.font(
                  withFamily: familyName, traits: [], weight: weight.appKitWeight, size: size
              )
        else {
            return .system(size: size, weight: weight.swiftUIWeight)
        }
        return Font(nsFont as CTFont)
    }
}
