import AppKit
import LyrimuseCore

@MainActor
enum WebPlatformIcon {

    static func image(_ platformID: String) -> NSImage? {
        switch platformID {
        case "youtubeMusic": return youtubeMusicIcon
        case "spotifyWeb": return spotifyIcon
        default: return nil
        }
    }

    private static let spotifyIcon: NSImage = {
        guard let path = Bundle.main.path(forResource: "SpotifyIcon", ofType: "png"),
              let image = NSImage(contentsOfFile: path)
        else {
            return NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) ?? NSImage()
        }
        return image
    }()

    private static let youtubeMusicIcon: NSImage = {
        guard let path = Bundle.main.path(forResource: "YouTubeMusicIcon", ofType: "png"),
              let image = NSImage(contentsOfFile: path)
        else {

            return whiteFilledCutouts(image: nil)
        }
        return whiteFilledCutouts(image: image)
    }()

    private static func whiteFilledCutouts(image: NSImage?) -> NSImage {
        guard let image else {
            return NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) ?? NSImage()
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        return NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            let inset = min(rect.width, rect.height) * 0.08
            NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
            image.draw(in: rect)
            return true
        }
    }
}
