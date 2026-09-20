import Foundation

public enum LastfmQuery {

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    public static func escape(_ value: String) -> String {
        let doubled = value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "+", with: "%2B")
        return doubled.addingPercentEncoding(withAllowedCharacters: unreserved) ?? doubled
    }

    public static func queryString(_ pairs: [(name: String, value: String)]) -> String {
        pairs.map { escape($0.name) + "=" + escape($0.value) }.joined(separator: "&")
    }
}
