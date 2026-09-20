import CoreGraphics
import Foundation
import LyrimuseCore

func runOnboardingTests() {

    do {
        let a = ConfettiField(pieceCount: 40, seed: 12345)
        let b = ConfettiField(pieceCount: 40, seed: 12345)
        expectEqual(a.pieces, b.pieces)
        expectEqual(a.duration, b.duration)
        let c = ConfettiField(pieceCount: 40, seed: 12346)
        expectNotEqual(c.pieces, a.pieces)
    }

    do {
        expectEqual(ConfettiField(pieceCount: 90, seed: 7).pieces.count, 90)
        let empty = ConfettiField(pieceCount: 0, seed: 7)
        expectEqual(empty.pieces.isEmpty, true)
        expectEqual(empty.duration, 0)
        expectEqual(ConfettiField(pieceCount: -5, seed: 7).pieces.isEmpty, true)

        let field = ConfettiField(pieceCount: 90, seed: 7)
        let latest = field.pieces.map { $0.delay + $0.fall }.max() ?? 0
        expectEqual(field.duration, latest)

        let lateComers = field.pieces.filter { $0.delay > ConfettiField.spawnWindow || $0.fall <= 0 }.count
        expectEqual(lateComers, 0)
    }

    do {
        let size = CGSize(width: 480, height: 420)
        let field = ConfettiField(pieceCount: 90, seed: 7)

        var stillVisibleAtEnd: [String] = []
        var alreadyVisibleAtStart: [String] = []
        var neverCrossed: [String] = []
        var badColor: [String] = []
        var badWidth: [String] = []
        var wentBackUp: [String] = []

        for (index, piece) in field.pieces.enumerated() {
            if piece.colorIndex < 0 || piece.colorIndex >= ConfettiField.colorCount {
                badColor.append("#\(index)=\(piece.colorIndex)")
            }
            if let end = field.state(of: piece, elapsed: field.duration, in: size),
               end.center.y - piece.span < size.height {
                stillVisibleAtEnd.append("#\(index)@y=\(end.center.y)")
            }
            if let begin = field.state(of: piece, elapsed: 0, in: size),
               begin.center.y + piece.span > 0 {
                alreadyVisibleAtStart.append("#\(index)@y=\(begin.center.y)")
            }

            let middle = piece.delay + piece.fall / 2
            guard let mid = field.state(of: piece, elapsed: middle, in: size) else {
                neverCrossed.append("#\(index)=没落点")
                continue
            }
            if mid.center.y <= 0 || mid.center.y >= size.height {
                neverCrossed.append("#\(index)@y=\(mid.center.y)")
            }

            if mid.width > piece.width || mid.width < ConfettiField.minRenderedWidth {
                badWidth.append("#\(index)=\(mid.width)/\(piece.width)")
            }

            let quarter = field.state(of: piece, elapsed: piece.delay + piece.fall / 4, in: size)
            if let quarter, quarter.center.y > mid.center.y {
                wentBackUp.append("#\(index)")
            }
        }

        expectEqual(stillVisibleAtEnd, [])
        expectEqual(alreadyVisibleAtStart, [])
        expectEqual(neverCrossed, [])
        expectEqual(badColor, [])
        expectEqual(badWidth, [])
        expectEqual(wentBackUp, [])
    }

    do {
        let size = CGSize(width: 480, height: 420)
        let field = ConfettiField(pieceCount: 24, seed: 99)

        if let piece = field.pieces.first(where: { $0.delay > 0.05 }) {
            expectEqual(field.state(of: piece, elapsed: piece.delay - 0.01, in: size) == nil, true)
            expectEqual(field.state(of: piece, elapsed: piece.delay + piece.fall + 0.01, in: size) == nil, true)
            expectEqual(field.state(of: piece, elapsed: piece.delay + 0.1, in: .zero) == nil, true)
        } else {
            expectEqual(true, false)
        }
    }
}
