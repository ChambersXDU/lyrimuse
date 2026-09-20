import AppKit

@MainActor
enum NotchIdleAppIcon {
    private static var cache: [String: CGImage] = [:]

    static func bitmap(pixelSide: Int) -> CGImage? {
        guard let source = NSApplication.shared.applicationIconImage else { return nil }
        return bitmap(of: source, cacheKey: "app", pixelSide: pixelSide)
    }

    static func bitmap(of source: NSImage, cacheKey: String, pixelSide: Int) -> CGImage? {
        guard pixelSide > 0 else { return nil }
        let key = "\(cacheKey)@\(pixelSide)"
        if let hit = cache[key] { return hit }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelSide, height: pixelSide, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        gc.imageInterpolation = .high
        source.draw(in: CGRect(x: 0, y: 0, width: pixelSide, height: pixelSide),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        cache[key] = image
        return image
    }
}
