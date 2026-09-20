import CoreGraphics
import Foundation

public struct ConfettiField {

    public struct Piece: Equatable {

        public let colorIndex: Int
        public let width: CGFloat
        public let height: CGFloat

        public let xFraction: CGFloat

        public let delay: Double

        public let fall: Double

        public let swayAmplitude: CGFloat
        public let swayFrequency: Double
        public let swayPhase: Double

        public let drift: CGFloat

        public let spinTurns: Double
        public let spinPhase: Double

        public let tilt: Double

        public var span: CGFloat { (width * width + height * height).squareRoot() / 2 }
    }

    public struct PieceState: Equatable {
        public let center: CGPoint

        public let width: CGFloat
        public let height: CGFloat

        public let angle: Double
        public let colorIndex: Int
    }

    public let pieces: [Piece]

    public let duration: Double

    public static let minRenderedWidth: CGFloat = 0.7

    public static let exitMargin: CGFloat = 1

    public init(pieceCount: Int = 130, seed: UInt64 = 0x4C79_7269_4D75_7365) {
        var rng = Random(seed: seed)
        let count = max(0, pieceCount)
        var made: [Piece] = []
        made.reserveCapacity(count)
        for index in 0 ..< count {
            let width = CGFloat(rng.double(5, 8.5))
            made.append(Piece(

                colorIndex: index % Self.colorCount,
                width: width,
                height: width * CGFloat(rng.double(1.25, 2.1)),
                xFraction: CGFloat(rng.double(-0.04, 1.04)),
                delay: rng.double(0, Self.spawnWindow),
                fall: rng.double(1.5, 2.6),
                swayAmplitude: CGFloat(rng.double(4, 16)),
                swayFrequency: rng.double(0.35, 1.1),
                swayPhase: rng.double(0, 2 * .pi),
                drift: CGFloat(rng.double(-30, 30)),
                spinTurns: rng.double(0.8, 3.2),
                spinPhase: rng.double(0, 2 * .pi),
                tilt: rng.double(0, 2 * .pi)))
        }
        pieces = made
        duration = made.map { $0.delay + $0.fall }.max() ?? 0
    }

    public static let colorCount = 7

    public static let spawnWindow: Double = 1.5

    public func state(of piece: Piece, elapsed: Double, in size: CGSize) -> PieceState? {
        guard size.width > 0, size.height > 0, piece.fall > 0 else { return nil }
        let local = elapsed - piece.delay
        guard local >= 0 else { return nil }
        let progress = local / piece.fall
        guard progress <= 1 else { return nil }

        let span = piece.span

        let y = Double(-span) + (Double(size.height) + 2 * Double(span) + Double(Self.exitMargin)) * progress
        let sway = Double(piece.swayAmplitude) * sin(2 * .pi * piece.swayFrequency * local + piece.swayPhase)
        let x = Double(piece.xFraction) * Double(size.width) + sway + Double(piece.drift) * progress
        let spin = 2 * .pi * piece.spinTurns * progress + piece.spinPhase
        let rendered = max(Self.minRenderedWidth, piece.width * CGFloat(abs(cos(spin))))
        return PieceState(
            center: CGPoint(x: x, y: y),
            width: rendered,
            height: piece.height,

            angle: piece.tilt + spin * 0.35,
            colorIndex: piece.colorIndex)
    }

    private struct Random {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }

        mutating func double(_ lower: Double, _ upper: Double) -> Double {
            lower + (upper - lower) * unit()
        }
    }
}
