import Foundation
import LyrimuseCore

@MainActor
final class LyricSourceTestService {
    static let shared = LyricSourceTestService()

    enum Status: String, Decodable { case ok, warn, fail }

    struct Result {
        let source: String
        let status: Status
        let reasonCode: String
        let networkLooksDown: Bool
    }

    enum TestError: LocalizedError {
        case cancelled
        var errorDescription: String? { L10n.t("测试已取消") }
    }

    private var runningTask: Task<Void, Never>?
    private init() {}

    func cancelRunning() {
        runningTask?.cancel()
        runningTask = nil
    }

    func test(source: LyricsSource? = nil, onUpdate: @escaping @MainActor (Result) -> Void) async throws {
        cancelRunning()
        let providers = LyricsResolver.defaultProviders().filter { provider in
            source == nil || provider.id == source?.rawValue
        }
        let query = LyricsQuery(title: "Hey Jude", artist: "The Beatles", duration: 431)
        let task = Task { () -> [(Result, [LyricsCandidate])] in
            await withTaskGroup(of: (Result, [LyricsCandidate]).self, returning: [(Result, [LyricsCandidate])].self) { group in
                for provider in providers {
                    group.addTask {
                        do {
                            let candidates = try await provider.search(query)
                            let result = Result(source: provider.id,
                                                status: candidates.isEmpty ? .warn : .ok,
                                                reasonCode: candidates.isEmpty ? "no_response" : "",
                                                networkLooksDown: false)
                            return (result, candidates)
                        } catch {
                            return (Result(source: provider.id, status: .fail,
                                           reasonCode: Self.failureCode(error.localizedDescription), networkLooksDown: true), [])
                        }
                    }
                }
                var values: [(Result, [LyricsCandidate])] = []
                for await value in group { values.append(value) }
                return values
            }
        }
        runningTask = Task { @MainActor [weak self] in
            let values = await task.value
            guard !Task.isCancelled else { return }
            for value in values { onUpdate(value.0) }
            self?.runningTask = nil
        }
        await runningTask?.value
        if Task.isCancelled { throw TestError.cancelled }
    }

    nonisolated private static func failureCode(_ message: String) -> String {
        let value = message.lowercased()
        if value.contains("timed out") || value.contains("timeout") { return "connect_failed" }
        if value.contains("http 5") { return "server_error" }
        if value.contains("dns") || value.contains("name") { return "dns_failed" }
        return "upstream_unreachable"
    }
}
