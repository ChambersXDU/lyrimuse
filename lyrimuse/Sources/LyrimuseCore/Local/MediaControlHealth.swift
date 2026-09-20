import Foundation
import OSLog

@MainActor
public final class MediaControlHealth: ObservableObject {
    public static let shared = MediaControlHealth()

    public enum State: Equatable {
        case unknown
        case healthy

        case unavailable(message: String)
    }

    @Published public private(set) var state: State = .unknown

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "mc-health")

    private static let timeout: TimeInterval = 8

    private init() {}

    public func checkInBackground() {
        guard case .unknown = state else { return }
        guard let binary = MediaControlClient.binaryPath() else {

            Self.logger.info("media-control binary unavailable; skipping health check")
            return
        }
        Task.detached(priority: .utility) {
            let result = ProcessRunner.run(binary, ["test"], timeout: Self.timeout)
            await MainActor.run {
                self.apply(result)
            }
        }
    }

    private func apply(_ result: ProcessRunner.Result?) {

        guard let result else {
            state = .unavailable(message: "media-control could not be launched")
            Self.logger.error("media-control health check: process failed to launch")
            return
        }
        if result.succeeded {
            state = .healthy
            Self.logger.info("media-control channel healthy")
            return
        }
        if result.timedOut {

            state = .unavailable(message: "media-control test timed out")
            Self.logger.error("media-control health check timed out")
            return
        }
        let detail = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .unavailable(message: detail.isEmpty ? "exit status \(result.status)" : detail)
        Self.logger.error(
            "media-control channel unavailable (status \(result.status, privacy: .public)): \(detail, privacy: .public)")
    }
}
