import SwiftUI

struct AboutHeroBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Glyph {
        let symbol: String

        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let tint: Color
        let opacity: Double

        let period: Double
        let phase: Double
        let rotation: Double
        let amplitude: CGFloat
    }

    private static let pink = Color(red: 0.98, green: 0.60, blue: 0.74)
    private static let peach = Color(red: 0.99, green: 0.72, blue: 0.52)
    private static let yellow = Color(red: 0.97, green: 0.82, blue: 0.40)
    private static let lavender = Color(red: 0.72, green: 0.66, blue: 0.94)

    private static let glyphs: [Glyph] = [

        Glyph(symbol: "music.note", x: 0.12, y: 0.20, size: 24, tint: pink, opacity: 0.42,
              period: 7.0, phase: 0.0, rotation: -14, amplitude: 5),
        Glyph(symbol: "music.quarternote.3", x: 0.25, y: 0.44, size: 18, tint: peach, opacity: 0.38,
              period: 8.5, phase: 1.3, rotation: 8, amplitude: 4),
        Glyph(symbol: "music.note", x: 0.06, y: 0.58, size: 14, tint: lavender, opacity: 0.40,
              period: 6.4, phase: 2.6, rotation: 12, amplitude: 3),
        Glyph(symbol: "text.alignleft", x: 0.19, y: 0.08, size: 15, tint: pink, opacity: 0.28,
              period: 9.2, phase: 4.0, rotation: -6, amplitude: 3),

        Glyph(symbol: "music.note.list", x: 0.87, y: 0.16, size: 21, tint: peach, opacity: 0.40,
              period: 7.6, phase: 0.8, rotation: 10, amplitude: 4),
        Glyph(symbol: "music.note", x: 0.94, y: 0.42, size: 16, tint: pink, opacity: 0.40,
              period: 6.0, phase: 2.0, rotation: -10, amplitude: 4),
        Glyph(symbol: "music.quarternote.3", x: 0.77, y: 0.31, size: 14, tint: yellow, opacity: 0.45,
              period: 8.0, phase: 3.4, rotation: -4, amplitude: 3),
        Glyph(symbol: "quote.opening", x: 0.90, y: 0.58, size: 14, tint: lavender, opacity: 0.36,
              period: 9.6, phase: 5.1, rotation: 0, amplitude: 3),
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {

                glow(Self.pink, opacity: 0.22)
                    .position(x: width * 0.16, y: height * 0.34)

                glow(Self.peach, opacity: 0.22)
                    .position(x: width * 0.84, y: height * 0.30)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ForEach(Array(Self.glyphs.enumerated()), id: \.offset) { _, glyph in
                        let drift = reduceMotion ? 0 : glyph.amplitude * CGFloat(sin(t * 2 * .pi / glyph.period + glyph.phase))
                        Image(systemName: glyph.symbol)
                            .font(.system(size: glyph.size, weight: .medium))
                            .foregroundStyle(glyph.tint.opacity(glyph.opacity))
                            .rotationEffect(.degrees(glyph.rotation))
                            .position(x: width * glyph.x, y: height * glyph.y + drift)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)

        .environment(\.locale, Locale(identifier: "en"))
    }

    private func glow(_ color: Color, opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: 150))
            .frame(width: 300, height: 300)
            .blur(radius: 24)
    }
}
