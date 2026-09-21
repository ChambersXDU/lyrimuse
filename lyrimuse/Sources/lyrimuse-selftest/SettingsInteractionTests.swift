import LyrimuseCore
import Foundation

@MainActor
func runSettingsInteractionTests() {

    do {
        print("\n== 顺序优先列表拖拽排序 ==")
        typealias R = ReorderDrag
        let mids: [CGFloat] = (0..<5).map { 17.5 + 36 * CGFloat($0) }

        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 53.5), 1)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 89.5 + 5.9), 1)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 89.5 + 6.1), 2)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 2, draggedMidY: 89.5 - 5.9), 2)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 2, draggedMidY: 89.5 - 6.1), 1)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: 89.5 - 5.9), 3)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: 89.5 - 6.1), 2)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 500), 4)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: -100), 0)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 89.5 + 0.1, hysteresis: 0), 2)
        expectEqual(R.targetIndex(rowMidYs: [10], source: 0, current: 0, draggedMidY: 999), 0)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 9, current: 1, draggedMidY: 999), 1)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 42, draggedMidY: 53.5), 1)

        var t = 0
        for y in stride(from: 17.5, through: 200, by: 7) { t = R.targetIndex(rowMidYs: mids, source: 0, current: t, draggedMidY: CGFloat(y)) }
        expectEqual(t, 4)
        var back = t
        for y in stride(from: 200, through: 0, by: -7) { back = R.targetIndex(rowMidYs: mids, source: 0, current: back, draggedMidY: CGFloat(y)) }
        expectEqual(back, 0)

        expectEqual(R.displacement(row: 2, source: 1, target: 3, rowMidYs: mids), CGFloat(-36))
        expectEqual(R.displacement(row: 3, source: 1, target: 3, rowMidYs: mids), CGFloat(-36))
        expectEqual(R.displacement(row: 4, source: 1, target: 3, rowMidYs: mids), CGFloat(0))
        expectEqual(R.displacement(row: 0, source: 1, target: 3, rowMidYs: mids), CGFloat(0))
        expectEqual(R.displacement(row: 1, source: 1, target: 3, rowMidYs: mids), CGFloat(0))
        expectEqual(R.displacement(row: 2, source: 3, target: 1, rowMidYs: mids), CGFloat(36))
        expectEqual(R.displacement(row: 1, source: 3, target: 1, rowMidYs: mids), CGFloat(36))
        expectEqual(R.displacement(row: 2, source: 2, target: 2, rowMidYs: mids), CGFloat(0))
        expectEqual(R.displacement(row: 7, source: 2, target: 4, rowMidYs: mids), CGFloat(0))
        let uneven: [CGFloat] = [10, 50, 70]
        expectEqual(R.displacement(row: 1, source: 0, target: 2, rowMidYs: uneven), CGFloat(-40))
        expectEqual(R.displacement(row: 2, source: 0, target: 2, rowMidYs: uneven), CGFloat(-20))

        let toTop = R.clampedTranslation(-1000, source: 3, rowMidYs: mids)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: mids[3] + toTop), 0)
        let toBottom = R.clampedTranslation(1000, source: 1, rowMidYs: mids)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: mids[1] + toBottom), 4)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: mids[0] + 0.3), 0)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: mids[0] + 1), 1)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 0, draggedMidY: mids[0] + 1), 0)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 0, current: 0, draggedMidY: mids[0]), 0)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 4, current: 4, draggedMidY: mids[4]), 4)

        var top = 3
        for raw in stride(from: 0.0, through: -300, by: -5) {
            let tr = R.clampedTranslation(CGFloat(raw), source: 3, rowMidYs: mids)
            top = R.targetIndex(rowMidYs: mids, source: 3, current: top, draggedMidY: mids[3] + tr)
        }
        expectEqual(top, 0)

        expectEqual(R.clampedTranslation(-1000, source: 2, rowMidYs: mids), mids[0] - mids[2])
        expectEqual(R.clampedTranslation(1000, source: 2, rowMidYs: mids), mids[4] - mids[2])
        expectEqual(R.clampedTranslation(10, source: 2, rowMidYs: mids), CGFloat(10))
        expectEqual(R.clampedTranslation(10, source: 9, rowMidYs: mids), CGFloat(10))

        let order = ["A", "x", "B", "C", "y", "D"]
        let enabled: Set<String> = ["A", "B", "C", "D"]
        let vis: (String) -> Bool = { enabled.contains($0) }
        expectEqual(R.moved(order, isVisible: vis, from: 3, to: 0), ["D", "x", "A", "B", "y", "C"])
        expectEqual(R.moved(order, isVisible: vis, from: 0, to: 3), ["B", "x", "C", "D", "y", "A"])
        expectEqual(R.moved(order, isVisible: vis, from: 1, to: 2), ["A", "x", "C", "B", "y", "D"])
        expectEqual(R.moved(order, isVisible: vis, from: 2, to: 2), order)
        expectEqual(R.moved(order, isVisible: vis, from: 7, to: 0), order)
        expectEqual(R.moved(order, isVisible: vis, from: 0, to: 4), order)
        expectEqual(R.moved(order, isVisible: vis, from: 3, to: 0).filter(vis), ["D", "A", "B", "C"])
        expectEqual(Set(R.moved(order, isVisible: vis, from: 3, to: 0)), Set(order))
        expectEqual(R.moved([1, 2, 3, 4], isVisible: { _ in true }, from: 3, to: 1), [1, 4, 2, 3])
        var stepwise = order
        for (f, to) in [(3, 2), (2, 1), (1, 0)] { stepwise = R.moved(stepwise, isVisible: vis, from: f, to: to) }
        expectEqual(stepwise, R.moved(order, isVisible: vis, from: 3, to: 0))
    }

    do {
        print("\n== 比例条分段宽度 ==")
        typealias P = ProportionBar
        let real = [3325, 232, 9, 38, 65]
        let w = P.widths(values: real, available: 540, gap: 1.5, minWidth: 3)
        expectEqual(w.count, 5)
        expectEqual(abs(w.reduce(0, +) + 1.5 * 4 - 540) < 0.001, true)
        expectEqual(w.allSatisfy { $0 >= 3 - 0.001 }, true)
        expectEqual(w[2], 3)
        expectEqual(w[0] < 540 * 3325 / 3669, true)
        expectEqual(w[1] > w[4] && w[4] > w[3] && w[3] > w[2], true)

        expectEqual(P.widths(values: [], available: 540, gap: 1.5, minWidth: 3), [])
        expectEqual(P.widths(values: [0, 0], available: 540, gap: 1.5, minWidth: 3), [0, 0])
        expectEqual(P.widths(values: [7], available: 540, gap: 1.5, minWidth: 3), [540])
        expectEqual(P.widths(values: [1, 1], available: 0, gap: 1.5, minWidth: 3), [0, 0])

        let crowded = P.widths(values: Array(repeating: 1, count: 100), available: 100, gap: 0, minWidth: 3)
        expectEqual(abs(crowded.reduce(0, +) - 100) < 0.001, true)
        expectEqual(crowded.allSatisfy { abs($0 - 1) < 0.001 }, true)

        let cascade = P.widths(values: [40, 30, 1, 1, 1], available: 73, gap: 0, minWidth: 12)
        expectEqual(cascade.map { ($0 * 1000).rounded() / 1000 }, [12, 25, 12, 12, 12])
        expectEqual(abs(cascade.reduce(0, +) - 73) < 0.001, true)
    }

    do {
        typealias G = ChipFlowGeometry
        let chip: CGFloat = 28, gap: CGFloat = 6, limit: CGFloat = 320
        func widths(_ n: Int) -> [CGFloat] { Array(repeating: chip, count: n) }

        let nine = G.rows(widths: widths(9), spacing: gap, limit: limit)
        expectEqual(nine.count, 1)
        expectEqual(nine.first?.width, 300)
        expectEqual(G.size(rows: nine, rowHeight: chip, spacing: gap), CGSize(width: 300, height: 28))

        let ten = G.rows(widths: widths(10), spacing: gap, limit: limit)
        expectEqual(ten.count, 2)
        expectEqual(ten.map(\.indices.count), [9, 1])
        expectEqual(G.size(rows: ten, rowHeight: chip, spacing: gap).height, 62)

        expectEqual(G.rows(widths: [100, 100, 100], spacing: 10, limit: 320).count, 1)
        expectEqual(G.rows(widths: [100, 100, 100], spacing: 10, limit: 319).count, 2)

        let oversize = G.rows(widths: [400, 28], spacing: gap, limit: limit)
        expectEqual(oversize.map(\.indices), [[0], [1]])
        expectEqual(oversize.first?.width, 400)

        expectEqual(G.rows(widths: widths(9), spacing: gap, limit: 0).count, 1)
        expectEqual(G.rows(widths: [], spacing: gap, limit: limit), [])
        expectEqual(G.size(rows: [], rowHeight: chip, spacing: gap), .zero)
    }

    expectEqual(LyricsResolver.sourceIDs.count, 5)
}
