import Foundation

public enum LyricsFillSweep {
    public struct Info: Decodable, Equatable, Sendable {
        public let running: Bool
        public let manual: Bool
        public let total: Int
        public let done: Int
        public let filled: Int
        public let current: String?
        public let startedAt: Int64
        public let updatedAt: Int64
        public let finishedAt: Int64?
        public let cancelled: Bool?

        public init(running: Bool, manual: Bool, total: Int, done: Int, filled: Int, current: String?,
                    startedAt: Int64, updatedAt: Int64, finishedAt: Int64?, cancelled: Bool?) {
            self.running = running
            self.manual = manual
            self.total = total
            self.done = done
            self.filled = filled
            self.current = current
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.finishedAt = finishedAt
            self.cancelled = cancelled
        }
    }

    static let requestURL = LyrimusePaths.configFile("lyrimuse-lyrics-fill-request.txt")
    static let statusURL = LyrimusePaths.configFile("lyrimuse-lyrics-fill-status.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: Info?

    public static var current: Info? {
        lock.lock()
        defer { lock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: statusURL.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = (try? Data(contentsOf: statusURL)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
        return cached
    }

    public static func requestBody(keys: [String]) -> String {
        if keys.isEmpty { return "all\n" }
        return keys.joined(separator: "\n") + "\n"
    }

    @discardableResult
    public static func request(keys: [String]) -> Bool {
        (try? requestBody(keys: keys).write(to: requestURL, atomically: true, encoding: .utf8)) != nil
    }

    @discardableResult
    public static func requestCancel() -> Bool {
        (try? "cancel\n".write(to: requestURL, atomically: true, encoding: .utf8)) != nil
    }
}
