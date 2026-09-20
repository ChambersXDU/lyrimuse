import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "github-stars")

@MainActor
final class GitHubStarsService: ObservableObject {
    static let shared = GitHubStarsService()

    @Published private(set) var starCount: Int?

    private var fetchedAt: Date?

    private var retryNotBefore: Date?
    private var inflight: Task<Void, Never>?

    private static let countKey = "githubStarCount"
    private static let fetchedAtKey = "githubStarCountFetchedAt"

    private init() {
        let defaults = UserDefaults.standard

        if let stored = defaults.object(forKey: Self.countKey) as? Int, stored >= 0 {
            starCount = stored
        }
        if let stamp = defaults.object(forKey: Self.fetchedAtKey) as? Date {
            fetchedAt = stamp
        }
    }

    func refreshIfStale() async {
        guard GitHubStars.shouldRefresh(now: Date(), fetchedAt: fetchedAt, retryNotBefore: retryNotBefore) else {
            return
        }

        if let inflight {
            await inflight.value
            return
        }

        let task = Task { await self.fetch() }
        inflight = task
        await task.value
        inflight = nil
    }

    private func fetch() async {
        let url = GitHubStars.repoAPIURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        request.setValue("Lyrimuse/\(version)", forHTTPHeaderField: "User-Agent")

        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode

            NetworkAuditLog.record(service: "github", operation: "repo-stars", host: url.host ?? "api.github.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)

            if status == 403 || status == 429 {
                let reset = http?.value(forHTTPHeaderField: "X-RateLimit-Reset")
                retryNotBefore = GitHubStars.retryDate(now: Date(), rateLimitReset: reset)
                logger.notice("repo-stars: http \(status ?? -1, privacy: .public), backing off until \(self.retryNotBefore?.description ?? "-", privacy: .public)")
                return
            }
            guard status == 200, let count = GitHubStars.parseStarCount(data) else {
                retryNotBefore = Date().addingTimeInterval(GitHubStars.failureBackoff)
                logger.notice("repo-stars: http \(status ?? -1, privacy: .public) or response parse failed, keeping cached value")
                return
            }
            let now = Date()
            starCount = count
            fetchedAt = now
            retryNotBefore = nil
            UserDefaults.standard.set(count, forKey: Self.countKey)
            UserDefaults.standard.set(now, forKey: Self.fetchedAtKey)
        } catch {
            NetworkAuditLog.record(service: "github", operation: "repo-stars", host: url.host ?? "api.github.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            retryNotBefore = Date().addingTimeInterval(GitHubStars.failureBackoff)
        }
    }
}
