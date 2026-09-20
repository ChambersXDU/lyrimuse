import Foundation
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "secret-file")

public extension Data {

    func writeSecurely(to url: URL) throws {
        try write(to: url, options: .atomic)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            logger.error("could not tighten permissions on \(url.lastPathComponent, privacy: .public) — \(String(describing: error), privacy: .public)")
        }
    }
}
