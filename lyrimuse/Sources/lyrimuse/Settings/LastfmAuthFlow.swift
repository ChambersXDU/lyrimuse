import Foundation
import CryptoKit
import AppKit
import OSLog
import LyrimuseCore

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lastfm-connect")

enum LastfmConnectState: Equatable {
    case idle
    case requestingToken
    case waitingForBrowserAuth(token: String)
    case exchanging
    case success(username: String)
    case failed(String)
}

enum LastfmAuthError: Error, LocalizedError {
    case api(String)
    case parse

    var errorDescription: String? {
        switch self {
        case .api(let msg): return String(format: L10n.t("Last.fm 返回错误: %@"), msg)
        case .parse: return L10n.t("解析 Last.fm 响应失败")
        }
    }
}

enum LastfmAuthFlow {
    private static let apiRoot = "https://ws.audioscrobbler.com/2.0/"

    static func signParams(_ params: [String: String], secret: String) -> String {
        let sorted = params.sorted { $0.key < $1.key }
        var s = ""
        for (k, v) in sorted {
            s += k + v
        }
        s += secret
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func buildURL(_ params: [String: String]) -> URL {
        var comps = URLComponents(string: apiRoot)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url!
    }

    private static func auditedGet(_ url: URL, operation: String) async throws -> Data {
        let start = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "lastfm", operation: operation, host: url.host ?? "ws.audioscrobbler.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return data
        } catch {
            NetworkAuditLog.record(service: "lastfm", operation: operation, host: url.host ?? "ws.audioscrobbler.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            throw error
        }
    }

    static func requestToken(apiKey: String) async throws -> String {
        let url = buildURL(["method": "auth.gettoken", "api_key": apiKey, "format": "json"])
        let data = try await auditedGet(url, operation: "auth.gettoken")
        struct Resp: Decodable { let token: String?; let message: String? }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data) else { throw LastfmAuthError.parse }
        if let token = decoded.token, !token.isEmpty { return token }
        throw LastfmAuthError.api(decoded.message ?? L10n.t("未知错误"))
    }

    static func authorizeURL(apiKey: String, token: String) -> URL {
        var comps = URLComponents(string: "https://www.last.fm/api/auth/")!
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),

            URLQueryItem(name: "cb", value: "\(LyrimuseIdentity.urlScheme)://lastfm-auth-callback"),
        ]
        return comps.url!
    }

    static func exchangeSession(apiKey: String, secret: String, token: String) async throws -> (sessionKey: String, username: String) {
        let signed = signParams(["method": "auth.getsession", "api_key": apiKey, "token": token], secret: secret)
        let url = buildURL([
            "method": "auth.getsession", "api_key": apiKey, "token": token,
            "api_sig": signed, "format": "json",
        ])
        let data = try await auditedGet(url, operation: "auth.getsession")
        struct Resp: Decodable {
            struct Session: Decodable { let name: String; let key: String }
            let session: Session?
            let message: String?
        }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data) else { throw LastfmAuthError.parse }
        if let session = decoded.session { return (session.key, session.name) }
        throw LastfmAuthError.api(decoded.message ?? L10n.t("未知错误"))
    }
}

@MainActor
final class LastfmConnectController: ObservableObject {
    static let shared = LastfmConnectController()

    @Published private(set) var state: LastfmConnectState = .idle

    private var pendingAPIKey = ""
    private var pendingSecret = ""

    private var gen = 0

    func start(apiKey: String, secret: String) {

        guard !apiKey.isEmpty else {
            logger.error("start: blocked — API Key is empty")
            state = .failed(L10n.t("请先填写 API Key"))
            return
        }

        guard !secret.isEmpty else {
            logger.error("start: blocked — Secret is empty")
            state = .failed(L10n.t("请先填写 Secret"))
            return
        }
        pendingAPIKey = apiKey
        pendingSecret = secret
        gen += 1
        let myGen = gen
        logger.info("start: requesting token")
        state = .requestingToken
        Task {
            do {
                let token = try await LastfmAuthFlow.requestToken(apiKey: apiKey)
                guard myGen == self.gen else { return }
                logger.info("start: got token, opening browser auth page")
                NSWorkspace.shared.open(LastfmAuthFlow.authorizeURL(apiKey: apiKey, token: token))
                state = .waitingForBrowserAuth(token: token)
            } catch {
                guard myGen == self.gen else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("start: requestToken failed — \(message, privacy: .public)")
                state = .failed(message)
            }
        }
    }

    func confirmBrowserAuth() {
        guard case .waitingForBrowserAuth(let token) = state else {
            logger.error("confirmBrowserAuth: called while not waitingForBrowserAuth (state=\(String(describing: self.state), privacy: .public)) — ignored")
            return
        }

        let apiKey = pendingAPIKey
        let secret = pendingSecret
        let myGen = gen
        logger.info("confirmBrowserAuth: exchanging session")
        state = .exchanging
        Task {
            do {
                let result = try await LastfmAuthFlow.exchangeSession(apiKey: apiKey, secret: secret, token: token)
                guard myGen == self.gen else { return }
                logger.info("confirmBrowserAuth: connected successfully")
                ConfigStore.shared.lastfmScrobbleSessionKey = result.sessionKey
                ConfigStore.shared.lastfmScrobbleUsername = result.username

                LastfmMirrorStatus.clear()

                LastfmStatsService.shared.resetAll()

                LastfmStatsService.shared.ensureFirstSyncBootstrap()

                if ConfigStore.shared.lastfmUser.isEmpty {
                    ConfigStore.shared.lastfmUser = result.username
                }
                await ConfigStore.shared.save()
                state = .success(username: result.username)
            } catch {
                guard myGen == self.gen else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("confirmBrowserAuth: exchangeSession failed — \(message, privacy: .public)")
                state = .failed(message)
            }
        }
    }

    func reopenBrowserAuth() {
        guard case .waitingForBrowserAuth(let token) = state else { return }
        NSWorkspace.shared.open(LastfmAuthFlow.authorizeURL(apiKey: pendingAPIKey, token: token))
    }

    func reset() {
        gen += 1
        state = .idle
    }

    func handleAuthCallback() {
        guard case .waitingForBrowserAuth = state else {
            logger.notice("handleAuthCallback: ignored — not currently waiting for browser auth (state=\(String(describing: self.state), privacy: .public))")
            return
        }
        logger.info("handleAuthCallback: browser redirected back automatically, confirming without user click")
        confirmBrowserAuth()
    }
}
