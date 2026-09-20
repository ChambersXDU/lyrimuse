import CoreGraphics
import Foundation

public enum ArtworkThumbnail {

    public static func squareBitmap(from source: CGImage, pixelSide: Int) -> CGImage? {
        guard pixelSide > 0, source.width > 0, source.height > 0 else { return nil }
        let w = source.width, h = source.height
        let side = min(w, h)
        let square: CGImage
        if side == w && side == h {
            square = source
        } else {
            let crop = CGRect(x: CGFloat((w - side) / 2), y: CGFloat((h - side) / 2),
                              width: CGFloat(side), height: CGFloat(side))
            guard let cropped = source.cropping(to: crop) else { return nil }
            square = cropped
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelSide, height: pixelSide, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: CGFloat(pixelSide), height: CGFloat(pixelSide)))
        return ctx.makeImage()
    }
}
