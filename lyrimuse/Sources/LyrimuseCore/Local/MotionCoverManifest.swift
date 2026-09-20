import Foundation

public enum MotionCoverManifest {

    public struct Variant: Equatable, Sendable {

        public let uri: String
        public let width: Int
        public let height: Int

        public let bandwidth: Int

        public let isHEVC: Bool

        public init(uri: String, width: Int, height: Int, bandwidth: Int, isHEVC: Bool) {
            self.uri = uri
            self.width = width
            self.height = height
            self.bandwidth = bandwidth
            self.isHEVC = isHEVC
        }
    }

    public static func parseVariants(master: String) -> [Variant] {
        var out: [Variant] = []
        let lines = master.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { i += 1; continue }
            let attrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))

            var j = i + 1
            var uri: String?
            while j < lines.count {
                let candidate = lines[j]
                if candidate.isEmpty { j += 1; continue }
                if candidate.hasPrefix("#") { break }
                uri = candidate
                break
            }
            if let uri, !uri.isEmpty,
               let res = attribute("RESOLUTION", in: attrs),
               let size = parseResolution(res) {
                let bw = attribute("AVERAGE-BANDWIDTH", in: attrs) ?? attribute("BANDWIDTH", in: attrs)
                let codecs = attribute("CODECS", in: attrs)?.lowercased() ?? ""
                out.append(Variant(uri: uri, width: size.0, height: size.1,
                                   bandwidth: bw.flatMap { Int($0) } ?? 0,
                                   isHEVC: codecs.contains("hvc1") || codecs.contains("hev1")))
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    public static func pick(_ variants: [Variant], minimumWidth: Int) -> Variant? {
        guard !variants.isEmpty else { return nil }
        let fits = variants.filter { $0.width >= minimumWidth }
        let pool = fits.isEmpty ? variants : fits

        let targetWidth = fits.isEmpty ? (pool.map(\.width).max() ?? 0) : (pool.map(\.width).min() ?? 0)
        let sameSize = pool.filter { $0.width == targetWidth }

        return sameSize.sorted { a, b in
            if a.isHEVC != b.isHEVC { return !a.isHEVC }
            return a.bandwidth < b.bandwidth
        }.first
    }

    public static func mediaFileName(fromVariant playlist: String) -> String? {
        for raw in playlist.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-MAP:") else { continue }
            let attrs = String(line.dropFirst("#EXT-X-MAP:".count))
            if let uri = attribute("URI", in: attrs), !uri.isEmpty { return uri }
        }
        return nil
    }

    public static func absolute(_ uri: String, relativeTo base: URL) -> URL? {
        if let u = URL(string: uri), u.scheme != nil { return u }
        return URL(string: uri, relativeTo: base)?.absoluteURL
    }

    public static func attribute(_ key: String, in attrs: String) -> String? {
        let chars = Array(attrs)
        let needle = Array(key + "=")
        var i = 0
        while i + needle.count <= chars.count {

            let atBoundary = i == 0 || chars[i - 1] == ","
            if atBoundary, Array(chars[i..<(i + needle.count)]) == needle {
                var j = i + needle.count
                if j < chars.count, chars[j] == "\"" {
                    j += 1
                    var v = ""
                    while j < chars.count, chars[j] != "\"" { v.append(chars[j]); j += 1 }
                    return v
                }
                var v = ""
                while j < chars.count, chars[j] != "," { v.append(chars[j]); j += 1 }
                return v.trimmingCharacters(in: .whitespaces)
            }
            i += 1
        }
        return nil
    }

    public static func parseResolution(_ s: String) -> (Int, Int)? {
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        return (w, h)
    }
}
