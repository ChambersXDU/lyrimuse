import AppKit
import LyrimuseCore

@MainActor
enum ArtworkThumbnailCache {
    private struct Entry {
        let source: NSImage
        var bitmaps: [Int: CGImage]
    }

    private static var entries: [Entry] = []

    static func bitmap(for image: NSImage, pixelSide: Int) -> CGImage? {
        guard pixelSide > 0 else { return nil }
        if let index = entries.firstIndex(where: { $0.source === image }) {
            if let hit = entries[index].bitmaps[pixelSide] { return hit }
            guard let made = render(image, pixelSide: pixelSide) else { return nil }
            entries[index].bitmaps[pixelSide] = made
            return made
        }
        guard let made = render(image, pixelSide: pixelSide) else { return nil }
        entries.insert(Entry(source: image, bitmaps: [pixelSide: made]), at: 0)
        if entries.count > 2 { entries.removeLast(entries.count - 2) }
        return made
    }

    private static func render(_ image: NSImage, pixelSide: Int) -> CGImage? {

        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return ArtworkThumbnail.squareBitmap(from: source, pixelSide: pixelSide)
    }
}
