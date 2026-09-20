import Foundation
import CoreGraphics

public enum ReorderDrag {

    public static let defaultHysteresis: CGFloat = 6

    public static func targetIndex(rowMidYs: [CGFloat], source: Int, current: Int, draggedMidY: CGFloat,
                                   hysteresis: CGFloat = defaultHysteresis) -> Int {
        let n = rowMidYs.count
        guard n > 1, rowMidYs.indices.contains(source) else { return current }

        if draggedMidY <= rowMidYs[0] + 0.5 { return 0 }
        if draggedMidY >= rowMidYs[n - 1] - 0.5 { return n - 1 }

        let others = rowMidYs.indices.filter { $0 != source }.map { rowMidYs[$0] }
        var t = min(max(current, 0), n - 1)

        while t < n - 1, draggedMidY > others[t] + hysteresis { t += 1 }

        while t > 0, draggedMidY < others[t - 1] - hysteresis { t -= 1 }
        return t
    }

    public static func displacement(row: Int, source: Int, target: Int, rowMidYs: [CGFloat]) -> CGFloat {
        guard row != source, rowMidYs.indices.contains(row), rowMidYs.indices.contains(source) else { return 0 }
        if source < row, row <= target {

            return rowMidYs[row - 1] - rowMidYs[row]
        }
        if target <= row, row < source {

            return rowMidYs[row + 1] - rowMidYs[row]
        }
        return 0
    }

    public static func clampedTranslation(_ translation: CGFloat, source: Int, rowMidYs: [CGFloat]) -> CGFloat {
        guard let first = rowMidYs.first, let last = rowMidYs.last, rowMidYs.indices.contains(source) else {
            return translation
        }
        let mid = rowMidYs[source]
        return min(max(translation, first - mid), last - mid)
    }

    public static func moved<Element>(_ order: [Element], isVisible: (Element) -> Bool, from: Int, to: Int) -> [Element] {
        var visible = order.filter(isVisible)
        guard visible.indices.contains(from), visible.indices.contains(to), from != to else { return order }
        let item = visible.remove(at: from)
        visible.insert(item, at: to)
        var result = order
        var k = 0
        for i in result.indices where isVisible(result[i]) {
            result[i] = visible[k]
            k += 1
        }
        return result
    }
}
