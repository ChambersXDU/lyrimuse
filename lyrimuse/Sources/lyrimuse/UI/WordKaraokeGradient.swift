import SwiftUI
import LyrimuseCore

enum WordKaraokeGradient {
    static let minWordDurationMs = KaraokeFill.minWordDurationMs
    static let wordEdgeSoftenBand = KaraokeFill.wordEdgeSoftenBand

    static func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        KaraokeFill.fillFraction(for: w, atMs: ms)
    }

    static let refreshInterval: Double = 1.0 / 30.0

    static let windowRefreshInterval: Double = 1.0 / 60.0

    static let dimOpacity: Double = 0.35

    static func gradient(fg: Color, left: Double, right: Double) -> LinearGradient {
        let stops = KaraokeFill.stops(left: left, right: right).map { stop in
            Gradient.Stop(
                color: fg.opacity(dimOpacity + stop.intensity * (1 - dimOpacity)),
                location: stop.location)
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    struct Palette {
        let fg: Color
        let dimStyle: AnyShapeStyle
        let fullStyle: AnyShapeStyle

        init(fg: Color) {
            self.fg = fg
            let dim = fg.opacity(WordKaraokeGradient.dimOpacity)
            dimStyle = AnyShapeStyle(LinearGradient(
                colors: [dim, dim], startPoint: .leading, endPoint: .trailing))
            fullStyle = AnyShapeStyle(LinearGradient(
                colors: [fg, fg], startPoint: .leading, endPoint: .trailing))
        }

        func style(left: Double, right: Double) -> AnyShapeStyle {
            if right <= 0 { return dimStyle }
            if left >= 1 { return fullStyle }
            return AnyShapeStyle(WordKaraokeGradient.gradient(fg: fg, left: left, right: right))
        }
    }

    @MainActor private static var paletteCache: [Palette] = []

    @MainActor static func palette(fg: Color) -> Palette {
        if let hit = paletteCache.first(where: { $0.fg == fg }) { return hit }
        let p = Palette(fg: fg)
        paletteCache.append(p)
        if paletteCache.count > 8 { paletteCache.removeFirst() }
        return p
    }
}
