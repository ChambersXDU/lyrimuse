import LyrimuseCore
import SwiftUI

@MainActor
struct ConfettiOverlay: View {

    var burst: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run: Run?

    private struct Run {
        let field: ConfettiField
        let start: Date
    }

    private static let baseSeed: UInt64 = 0x436F_6E66_6574_7469

    private static let frameInterval: TimeInterval = 1.0 / 60.0

    private static let palette: [Color] = [
        Color(.sRGB, red: 1.00, green: 0.23, blue: 0.19),
        Color(.sRGB, red: 1.00, green: 0.58, blue: 0.00),
        Color(.sRGB, red: 1.00, green: 0.80, blue: 0.00),
        Color(.sRGB, red: 0.20, green: 0.78, blue: 0.35),
        Color(.sRGB, red: 0.20, green: 0.68, blue: 0.90),
        Color(.sRGB, red: 0.00, green: 0.48, blue: 1.00),
        Color(.sRGB, red: 0.69, green: 0.32, blue: 0.87),
    ]

    var body: some View {

        Group {
            if let run {
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { context in
                    Canvas { gc, size in
                        draw(&gc, size: size, run: run, now: context.date)
                    }
                }
            }
        }

        .allowsHitTesting(false)
        .task(id: burst) { await play() }
    }

    private func play() async {
        guard burst > 0, !reduceMotion else {
            run = nil
            return
        }

        let field = ConfettiField(seed: Self.baseSeed &+ UInt64(burst))
        run = Run(field: field, start: Date())
        try? await Task.sleep(for: .seconds(field.duration))

        guard !Task.isCancelled else { return }
        run = nil
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, run: Run, now: Date) {
        let elapsed = now.timeIntervalSince(run.start)
        for piece in run.field.pieces {
            guard let state = run.field.state(of: piece, elapsed: elapsed, in: size) else { continue }
            let rect = CGRect(x: -state.width / 2, y: -state.height / 2,
                              width: state.width, height: state.height)

            let placed = CGAffineTransform(rotationAngle: state.angle)
                .concatenating(CGAffineTransform(translationX: state.center.x, y: state.center.y))
            let path = Path(roundedRect: rect, cornerRadius: min(1.5, state.width / 3))
                .applying(placed)
            context.fill(path, with: .color(Self.palette[state.colorIndex % Self.palette.count]))
        }
    }
}
