import Foundation

public enum ImportPolicy {

    public static func isAcceptableRelayURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased()
        else { return false }

        switch scheme {
        case "https":

            return !(url.host ?? "").isEmpty
        case "http":
            let host = (url.host ?? "").lowercased()
            return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        default:
            return false
        }
    }
}
