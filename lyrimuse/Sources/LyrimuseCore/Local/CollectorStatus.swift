import Foundation

public enum CollectorStatus {
    public struct Info: Decodable, Equatable, Sendable {
        public let networkDown: Bool
        public let at: Int64
    }

    private static let url = LyrimusePaths.configFile("lyrimuse-collector-status.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: Info?

    public static var current: Info? {
        lock.lock()
        defer { lock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
        return cached
    }

    public static var networkLooksDown: Bool {
        current?.networkDown ?? false
    }
}
