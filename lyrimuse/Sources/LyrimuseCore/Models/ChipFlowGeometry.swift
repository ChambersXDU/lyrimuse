import CoreGraphics

public enum ChipFlowGeometry {

    public struct Row: Equatable, Sendable {
        public let indices: [Int]
        public let width: CGFloat
        public init(indices: [Int], width: CGFloat) {
            self.indices = indices
            self.width = width
        }
    }

    public static func rows(widths: [CGFloat], spacing: CGFloat, limit: CGFloat) -> [Row] {
        guard !widths.isEmpty else { return [] }
        let bound = limit > 0 ? limit : .greatestFiniteMagnitude
        var rows: [Row] = []
        var indices: [Int] = []
        var width: CGFloat = 0
        for (index, itemWidth) in widths.enumerated() {
            let widthIfAppended = indices.isEmpty ? itemWidth : width + spacing + itemWidth
            if !indices.isEmpty, widthIfAppended > bound {
                rows.append(Row(indices: indices, width: width))
                indices = []
                width = 0
            }
            width = indices.isEmpty ? itemWidth : width + spacing + itemWidth
            indices.append(index)
        }
        if !indices.isEmpty { rows.append(Row(indices: indices, width: width)) }
        return rows
    }

    public static func size(rows: [Row], rowHeight: CGFloat, spacing: CGFloat) -> CGSize {
        guard !rows.isEmpty else { return .zero }
        let width = rows.map(\.width).max() ?? 0
        let height = rowHeight * CGFloat(rows.count) + spacing * CGFloat(rows.count - 1)
        return CGSize(width: width, height: height)
    }
}
