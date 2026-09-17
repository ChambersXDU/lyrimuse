import SwiftUI
import LyrimuseCore

/// 逐字卡拉OK软边渐变的 SwiftUI 绑定层：将 KaraokeFill 计算好的分段转换为 LinearGradient。
/// 悬浮歌词(LyricsOverlayView)、灵动岛(NotchLyricsView)、歌词窗口(LyricsWindowView)共用。
enum WordKaraokeGradient {
    static let minWordDurationMs = KaraokeFill.minWordDurationMs
    static let wordEdgeSoftenBand = KaraokeFill.wordEdgeSoftenBand

    static func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        KaraokeFill.fillFraction(for: w, atMs: ms)
    }

    /// 逐字填色的刷新上限(30Hz)，逐帧重算式的逐字视图(悬浮歌词/灵动岛)共用。
    static let refreshInterval: Double = 1.0 / 30.0

    /// 歌词窗口专用刷新档位(60Hz)，匹配大屏大字号渲染需求。
    static let windowRefreshInterval: Double = 1.0 / 60.0

    /// 未唱部分前景色透明度。
    static let dimOpacity: Double = 0.35

    static func gradient(fg: Color, left: Double, right: Double) -> LinearGradient {
        let stops = KaraokeFill.stops(left: left, right: right).map { stop in
            Gradient.Stop(
                color: fg.opacity(dimOpacity + stop.intensity * (1 - dimOpacity)),
                location: stop.location)
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    /// 一种前景色对应的跨帧稳定渐变素材。
    /// 未唱(right<=0)与已唱(left>=1)两端复用缓存纯色实例，仅过渡带动态构建渐变。
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

        /// 纯色两端复用缓存实例，过渡带动态计算。
        func style(left: Double, right: Double) -> AnyShapeStyle {
            if right <= 0 { return dimStyle }
            if left >= 1 { return fullStyle }
            return AnyShapeStyle(WordKaraokeGradient.gradient(fg: fg, left: left, right: right))
        }
    }

    /// 前景色调色板 LRU 缓存，避免高频重建。
    @MainActor private static var paletteCache: [Palette] = []

    @MainActor static func palette(fg: Color) -> Palette {
        if let hit = paletteCache.first(where: { $0.fg == fg }) { return hit }
        let p = Palette(fg: fg)
        paletteCache.append(p)
        if paletteCache.count > 8 { paletteCache.removeFirst() }
        return p
    }
}
