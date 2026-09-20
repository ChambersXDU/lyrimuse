import Foundation

public enum LogRedactor {

    static let minimumSecretLength = 8

    public static func redact(_ text: String, secrets: [String: String]) -> String {
        var out = text
        let usable = secrets
            .filter { $0.value.count >= minimumSecretLength }
            .sorted { $0.value.count > $1.value.count }
        for (field, value) in usable {
            out = out.replacingOccurrences(of: value, with: "<redacted:\(field)>")
        }
        return out
    }

    private static let sensitiveQueryKeys = [
        "api_key", "apikey", "api_sig", "access_token", "token", "sk",
        "secret", "password", "passwd", "pwd", "sign", "signature", "key",
        "session_key", "sessionkey", "auth",
    ]

    private static let pathCredentialHosts: [(host: String, pattern: String)] = [
        ("api.day.app", #"(api\.day\.app/)(?!<redacted)[^/\s"']+"#),
        ("sctapi.ftqq.com", #"(sctapi\.ftqq\.com/)(?!<redacted)[^/\s"'.]+"#),
        ("open.feishu.cn", #"(open\.feishu\.cn/open-apis/bot/v2/hook/)(?!<redacted)[^/\s"']+"#),
    ]

    public static func redactPatterns(_ text: String) -> String {
        var out = text

        let joined = sensitiveQueryKeys.joined(separator: "|")
        out = replace(out, pattern: "(?i)\\b(\(joined))=(?!<redacted)[^&\\s\"'\\\\]+", template: "$1=<redacted>")

        for (_, pattern) in pathCredentialHosts {
            out = replace(out, pattern: pattern, template: "$1<redacted>")
        }

        out = replace(out, pattern: #"(?i)(authorization:\s*bearer\s+)\S+"#, template: "$1<redacted>")
        out = replace(out, pattern: #"(?i)(x-token:\s*)\S+"#, template: "$1<redacted>")

        return out
    }

    public static func redactAll(_ text: String, secrets: [String: String]) -> String {
        redactPatterns(redact(text, secrets: secrets))
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
