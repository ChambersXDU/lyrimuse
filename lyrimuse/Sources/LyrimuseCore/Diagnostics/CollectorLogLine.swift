import Foundation

public enum CollectorLogLine {
    private static let slogFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let legacyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func timestamp(of line: String) -> Date? {
        if line.hasPrefix("time=") {
            let token = line.dropFirst("time=".count).prefix { $0 != " " }
            return slogFormatter.date(from: String(token))
        }

        guard line.utf8.count >= 19 else { return nil }
        return legacyFormatter.date(from: String(line.prefix(19)))
    }
}
