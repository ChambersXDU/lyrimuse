import AppKit

let width = 660.0
let height = 400.0

let appIconCenter = CGPoint(x: 180, y: 170)
let applicationsCenter = CGPoint(x: 480, y: 170)

let iconRadius = 64.0

let brandPink = NSColor(calibratedRed: 254 / 255, green: 190 / 255, blue: 214 / 255, alpha: 1)
let brandPeach = NSColor(calibratedRed: 254 / 255, green: 217 / 255, blue: 170 / 255, alpha: 1)
let brandYellow = NSColor(calibratedRed: 255 / 255, green: 247 / 255, blue: 169 / 255, alpha: 1)
let brandLavender = NSColor(calibratedRed: 251 / 255, green: 209 / 255, blue: 229 / 255, alpha: 1)

let brandCoral = blend(brandPink, brandPeach, 0.5)

func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    NSColor(calibratedRed: a.redComponent * (1 - t) + b.redComponent * t,
            green: a.greenComponent * (1 - t) + b.greenComponent * t,
            blue: a.blueComponent * (1 - t) + b.blueComponent * t,
            alpha: 1)
}

func glow(_ color: NSColor, center: CGPoint, radius: CGFloat, peakAlpha: CGFloat) {
    let gradient = NSGradient(colors: [
        color.withAlphaComponent(peakAlpha),
        color.withAlphaComponent(0),
    ])
    gradient?.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let pixelsWide = Int(width * scale)
    let pixelsHigh = Int(height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("cannot allocate bitmap") }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor(calibratedRed: 1.0, green: 0.992, blue: 0.988, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

    func flipped(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }
    let appCenter = flipped(appIconCenter)
    let appsCenter = flipped(applicationsCenter)

    glow(brandPink, center: CGPoint(x: 40, y: height - 40), radius: 420, peakAlpha: 0.20)
    glow(brandYellow, center: CGPoint(x: width - 60, y: height - 20), radius: 380, peakAlpha: 0.18)
    glow(brandLavender, center: CGPoint(x: width * 0.55, y: 30), radius: 420, peakAlpha: 0.16)

    glow(brandCoral, center: appCenter, radius: iconRadius + 90, peakAlpha: 0.30)

    glow(brandPeach, center: appsCenter, radius: iconRadius + 24, peakAlpha: 0.20)
    let ringRadius = iconRadius + 6
    let ring = NSBezierPath(ovalIn: NSRect(
        x: appsCenter.x - ringRadius, y: appsCenter.y - ringRadius,
        width: ringRadius * 2, height: ringRadius * 2))
    ring.lineWidth = 1.5
    brandCoral.withAlphaComponent(0.5).setStroke()
    ring.setLineDash([6, 6], count: 2, phase: 0)
    ring.stroke()

    let inset = iconRadius + 20
    let start = CGPoint(x: appCenter.x + inset, y: appCenter.y)
    let end = CGPoint(x: appsCenter.x - inset, y: appsCenter.y)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.4, alpha: 0.22)
    shadow.shadowBlurRadius = 4
    shadow.shadowOffset = NSSize(width: 0, height: -1.5)
    shadow.set()

    brandCoral.withAlphaComponent(0.68).setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: CGPoint(x: end.x - 12, y: end.y))
    shaft.lineWidth = 3
    shaft.lineCapStyle = .round
    shaft.stroke()

    brandCoral.withAlphaComponent(0.75).setFill()
    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: CGPoint(x: end.x - 16, y: end.y + 8))
    head.line(to: CGPoint(x: end.x - 16, y: end.y - 8))
    head.close()
    head.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make_dmg_background.swift <out.tiff>\n".data(using: .utf8)!)
    exit(2)
}
let reps = [draw(scale: 1), draw(scale: 2)]

guard let data = NSBitmapImageRep.representationOfImageReps(in: reps, using: .tiff, properties: [:]) else {
    FileHandle.standardError.write("failed to encode tiff\n".data(using: .utf8)!)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: args[1]))
