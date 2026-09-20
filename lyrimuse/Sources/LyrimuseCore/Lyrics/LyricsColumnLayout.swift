import Foundation

public struct LyricsColumnWidths: Equatable, Sendable {
    public var artist: CGFloat
    public var album: CGFloat
    public var source: CGFloat

    public init(artist: CGFloat, album: CGFloat, source: CGFloat) {
        self.artist = artist
        self.album = album
        self.source = source
    }

    public static let defaults = LyricsColumnWidths(artist: 96, album: 110, source: 84)

    public static let minColumn: CGFloat = 56
    public static let minSourceColumn: CGFloat = 70

    public static let minTitle: CGFloat = 140

    public static let maxColumn: CGFloat = 280

    public var total: CGFloat { artist + album + source }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {

        hi < lo ? lo : min(max(v, lo), hi)
    }

    public static func dragged(
        from start: LyricsColumnWidths, divider: Int, dx: CGFloat,
        totalWidth: CGFloat, chrome: CGFloat
    ) -> LyricsColumnWidths {
        var out = start
        switch divider {
        case 0:

            let room = totalWidth > 0
                ? totalWidth - chrome - minTitle - start.album - start.source
                : maxColumn
            out.artist = clamp(start.artist - dx, minColumn, min(maxColumn, room))
        case 1:

            let d = clamp(dx, minColumn - start.artist, min(start.album - minColumn, maxColumn - start.artist))
            out.artist = start.artist + d
            out.album = start.album - d
        default:
            let d = clamp(dx, minColumn - start.album, min(start.source - minSourceColumn, maxColumn - start.album))
            out.album = start.album + d
            out.source = start.source - d
        }
        return out
    }

    public static func fitted(_ w: LyricsColumnWidths, totalWidth: CGFloat, chrome: CGFloat) -> LyricsColumnWidths {
        let budget = totalWidth - chrome - minTitle
        guard budget > 0, w.total > budget else { return w }
        let floorTotal = minColumn + minColumn + minSourceColumn

        guard budget > floorTotal else {
            return LyricsColumnWidths(artist: minColumn, album: minColumn, source: minSourceColumn)
        }

        let excess = w.total - budget
        let slack = (w.artist - minColumn) + (w.album - minColumn) + (w.source - minSourceColumn)
        guard slack > 0 else { return w }
        let k = min(1, excess / slack)
        return LyricsColumnWidths(
            artist: w.artist - (w.artist - minColumn) * k,
            album: w.album - (w.album - minColumn) * k,
            source: w.source - (w.source - minSourceColumn) * k
        )
    }

    public static func sanitized(_ w: LyricsColumnWidths) -> LyricsColumnWidths {
        for v in [w.artist, w.album, w.source] where !v.isFinite { return defaults }
        guard w.artist >= minColumn, w.artist <= maxColumn,
              w.album >= minColumn, w.album <= maxColumn,
              w.source >= minSourceColumn, w.source <= maxColumn else { return defaults }
        return w
    }
}
