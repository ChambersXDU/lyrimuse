import AppKit
import SwiftUI

@MainActor
struct OverlayDesktopSurface: View {
    var body: some View {
        if let wallpaper = DesktopWallpaperSample.image {
            Image(nsImage: wallpaper)
                .resizable()
                .scaledToFill()
        } else {

            Canvas { context, size in
                let cell: CGFloat = 8
                let cols = Int(size.width / cell) + 1
                let rows = Int(size.height / cell) + 1
                for row in 0 ..< rows {
                    for col in 0 ..< cols where (row + col).isMultiple(of: 2) {
                        let rect = CGRect(
                            x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                            width: cell, height: cell)
                        context.fill(Path(rect), with: .color(.gray.opacity(0.22)))
                    }
                }
            }
        }
    }
}

@MainActor
enum DesktopWallpaperSample {
    private static var loaded = false
    private static var cache: NSImage?

    static var image: NSImage? {
        if !loaded {
            loaded = true
            cache = load()
        }
        return cache
    }

    private static func load() -> NSImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let original = NSImage(contentsOf: url)
        else { return nil }

        let targetWidth: CGFloat = 640
        guard original.size.width > targetWidth else { return original }
        let scale = targetWidth / original.size.width
        let size = NSSize(
            width: targetWidth, height: (original.size.height * scale).rounded())
        return NSImage(size: size, flipped: false) { rect in
            original.draw(in: rect)
            return true
        }
    }
}
