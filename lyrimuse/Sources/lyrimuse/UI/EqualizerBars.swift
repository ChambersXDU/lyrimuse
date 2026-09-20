import Foundation
import SwiftUI
import LyrimuseCore

struct EqualizerBars: View {
    var color: Color
    var isPlaying: Bool

    var amplitude: (Date) -> Double = { _ in 1 }

    private static let interval: TimeInterval = WordKaraokeGradient.refreshInterval

    private static let barCount = 5

    private static func barPhase(_ i: Int) -> Double { Double(i) * 2.399963 }

    private static let barWidth: CGFloat = 1.8
    private static let spacing: CGFloat = 1.5

    private static let maxHeight: CGFloat = 16

    private static let minHeight: CGFloat = 2.5

    static var width: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.interval, paused: !isPlaying)) { context in

            let t = context.date.timeIntervalSinceReferenceDate

            let amp = amplitude(context.date)

            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(0..<Self.barCount, id: \.self) { i in

                    Capsule()
                        .fill(color)
                        .frame(width: Self.barWidth, height: height(bar: i, time: t, amplitude: amp))
                        .frame(width: Self.barWidth, height: Self.maxHeight)
                }
            }
            .frame(width: Self.width, height: Self.maxHeight, alignment: .center)
        }
        .frame(width: Self.width, height: Self.maxHeight)

        .accessibilityHidden(true)
    }

    private func height(bar: Int, time: Double, amplitude: Double) -> CGFloat {
        guard isPlaying else { return Self.minHeight }
        let phase = Self.barPhase(bar)
        let f1 = 2.2 + Double(bar) * 0.34
        let f2 = 3.6 + Double(bar) * 0.26
        let raw = 0.62 * sin(time * f1 + phase) + 0.38 * sin(time * f2 + phase * 1.7)

        let unit = (raw + 1) / 2

        let scaled = EqualizerBarCurve.level(unit: unit, amplitude: amplitude)
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * CGFloat(scaled)
    }
}
