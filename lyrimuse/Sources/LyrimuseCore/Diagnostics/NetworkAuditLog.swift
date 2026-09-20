import Foundation
import OSLog

public enum NetworkAuditLog {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "network-audit")

    public static func record(service: String, operation: String, host: String,
                               statusCode: Int?, durationMs: Double, error: Error?) {
        if let error {
            logger.notice("\(service, privacy: .public) \(operation, privacy: .public) host=\(host, privacy: .public) FAILED after \(durationMs, privacy: .public)ms: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.notice("\(service, privacy: .public) \(operation, privacy: .public) host=\(host, privacy: .public) -> \(statusCode ?? -1, privacy: .public) (\(durationMs, privacy: .public)ms)")
        }
    }
}
