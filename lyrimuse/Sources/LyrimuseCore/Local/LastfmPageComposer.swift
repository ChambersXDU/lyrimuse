import Foundation

public enum LastfmPageComposer {

    public struct Source<Row> {
        public let firstPosition: Int
        public let rows: [Row]

        public init(firstPosition: Int, rows: [Row]) {
            self.firstPosition = firstPosition
            self.rows = rows
        }
    }

    public static func firstPosition(page: Int, pageSize: Int, totalAtFetch: Int, totalNow: Int) -> Int? {
        guard page >= 1, pageSize > 0, totalNow >= totalAtFetch else { return nil }
        return (page - 1) * pageSize + (totalNow - totalAtFetch)
    }

    public static func compose<Row>(
        page: Int, pageSize: Int, total: Int,
        sources: [Source<Row>], identity: (Row) -> String
    ) -> [Row]? {
        guard page >= 1, pageSize > 0, total > 0 else { return nil }
        let lo = (page - 1) * pageSize
        let hi = min(page * pageSize, total)
        guard lo < hi else { return nil }
        var slots = [Row?](repeating: nil, count: hi - lo)
        for src in sources {
            guard src.firstPosition >= 0 else { continue }
            for (j, row) in src.rows.enumerated() {
                let pos = src.firstPosition + j
                guard pos >= lo, pos < hi else { continue }
                if slots[pos - lo] == nil { slots[pos - lo] = row }
            }
        }
        var out: [Row] = []
        out.reserveCapacity(slots.count)
        var seen = Set<String>()
        for slot in slots {
            guard let row = slot else { return nil }
            guard seen.insert(identity(row)).inserted else { return nil }
            out.append(row)
        }
        return out
    }
}
