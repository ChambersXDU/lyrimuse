import CoreGraphics

public enum WrapLayoutMath {

    public enum RowAlignment: Sendable {
        case center, leading, trailing
    }

    public struct Row: Equatable, Sendable {
        public let indices: [Int]
        public let width: CGFloat
        public let height: CGFloat
    }

    public struct Placement: Equatable, Sendable {
        public let index: Int
        public let origin: CGPoint
        public let size: CGSize
    }

    public static func rows(
        sizes: [CGSize], maxWidth: CGFloat, horizontalSpacing: CGFloat
    ) -> [Row] {
        var rows: [Row] = []
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            let spacingIfContinuing = indices.isEmpty ? 0 : horizontalSpacing
            if !indices.isEmpty && width + spacingIfContinuing + size.width > maxWidth {
                rows.append(Row(indices: indices, width: width, height: height))
                indices = []
                width = 0
                height = 0
            }
            let spacing = indices.isEmpty ? 0 : horizontalSpacing
            width += spacing + size.width
            height = max(height, size.height)
            indices.append(i)
        }
        if !indices.isEmpty {
            rows.append(Row(indices: indices, width: width, height: height))
        }
        return rows
    }

    public static func totalSize(
        sizes: [CGSize], maxWidth: CGFloat, horizontalSpacing: CGFloat, verticalSpacing: CGFloat
    ) -> CGSize {
        totalSize(
            rows: rows(sizes: sizes, maxWidth: maxWidth, horizontalSpacing: horizontalSpacing),
            maxWidth: maxWidth, verticalSpacing: verticalSpacing)
    }

    public static func totalSize(
        rows: [Row], maxWidth: CGFloat, verticalSpacing: CGFloat
    ) -> CGSize {
        let totalHeight = rows.reduce(0) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        return CGSize(width: maxWidth, height: totalHeight)
    }

    public static func contentBounds(
        rows: [Row], bounds: CGRect, verticalSpacing: CGFloat, rowAlignment: RowAlignment
    ) -> CGRect {
        guard !rows.isEmpty else { return .zero }
        let widest = rows.reduce(CGFloat(0)) { max($0, $1.width) }
        let height = rows.reduce(0) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        guard widest > 0, height > 0 else { return .zero }
        let slack = max(0, bounds.width - widest)
        let x: CGFloat
        switch rowAlignment {
        case .leading: x = bounds.minX
        case .trailing: x = bounds.minX + slack
        case .center: x = bounds.minX + slack / 2
        }
        return CGRect(x: x, y: bounds.minY, width: min(widest, bounds.width), height: height)
    }

    public static func unconstrainedSize(sizes: [CGSize], horizontalSpacing: CGFloat) -> CGSize {
        let totalWidth = sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, sizes.count - 1)) * horizontalSpacing
        return CGSize(width: totalWidth, height: sizes.map(\.height).max() ?? 0)
    }

    public static func placements(
        sizes: [CGSize], bounds: CGRect, horizontalSpacing: CGFloat, verticalSpacing: CGFloat,
        rowAlignment: RowAlignment
    ) -> [Placement] {
        placements(
            rows: rows(sizes: sizes, maxWidth: bounds.width, horizontalSpacing: horizontalSpacing),
            sizes: sizes, bounds: bounds,
            horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing,
            rowAlignment: rowAlignment)
    }

    public static func placements(
        rows: [Row], sizes: [CGSize], bounds: CGRect,
        horizontalSpacing: CGFloat, verticalSpacing: CGFloat,
        rowAlignment: RowAlignment
    ) -> [Placement] {
        var result: [Placement] = []
        result.reserveCapacity(sizes.count)
        var y = bounds.minY
        for row in rows {
            let slack = max(0, bounds.width - row.width)
            let indent: CGFloat
            switch rowAlignment {
            case .center: indent = slack / 2
            case .leading: indent = 0
            case .trailing: indent = slack
            }
            var x = bounds.minX + indent
            for i in row.indices {
                let size = sizes[i]
                result.append(Placement(
                    index: i,
                    origin: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    size: size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
        return result
    }
}
