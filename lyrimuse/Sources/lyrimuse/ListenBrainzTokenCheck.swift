import Foundation
import LyrimuseCore

@MainActor
final class ListenBrainzTokenCheck: ObservableObject {
    enum State: Equatable {
        case empty
        case checking
        case valid(user: String)
        case invalid

        case unreachable
    }

    @Published private(set) var state: State = .empty

    private var task: Task<Void, Never>?
    private var lastChecked = ""

    func tokenChanged(_ token: String, knownUser: String = "", onResolvedUser: @escaping (String) -> Void) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard !trimmed.isEmpty else {
            lastChecked = ""
            state = .empty
            return
        }

        if trimmed == lastChecked, case .valid = state { return }

        if lastChecked.isEmpty, !knownUser.isEmpty {
            lastChecked = trimmed
            state = .valid(user: knownUser)

            task = Task { [weak self] in
                let outcome = await Self.validate(token: trimmed)
                guard !Task.isCancelled, let self else { return }
                if outcome != .valid(user: knownUser) {
                    self.state = outcome
                    if case .valid(let user) = outcome { onResolvedUser(user) }
                }
            }
            return
        }

        state = .checking
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let outcome = await Self.validate(token: trimmed)
            guard !Task.isCancelled else { return }
            self?.lastChecked = trimmed
            self?.state = outcome
            if case .valid(let user) = outcome { onResolvedUser(user) }
        }
    }

    private static func validate(token: String) async -> State {
        guard let url = URL(string: "https://api.listenbrainz.org/1/validate-token") else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "listenbrainz", operation: "validate-token", host: url.host ?? "api.listenbrainz.org",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)

            if status == 401 { return .invalid }
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .unreachable }
            guard object["valid"] as? Bool == true else { return .invalid }

            guard let user = object["user_name"] as? String, !user.isEmpty else {
                return .unreachable
            }
            return .valid(user: user)
        } catch {
            NetworkAuditLog.record(service: "listenbrainz", operation: "validate-token", host: url.host ?? "api.listenbrainz.org",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return .unreachable
        }
    }
}
