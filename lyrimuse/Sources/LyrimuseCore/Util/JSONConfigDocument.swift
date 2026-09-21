import Foundation

public struct JSONConfigDocument {
    public enum LoadState: Equatable {

        case missing

        case loaded

        case corrupt(reason: String)
    }

    public enum Failure: Error, Equatable {

        case refusedCorruptFile(reason: String)

        case notSerializable
    }

    public struct ParseFailure: Error, Equatable {
        public let reason: String
        public init(reason: String) { self.reason = reason }
    }

    public let url: URL

    public private(set) var raw: [String: Any]
    public private(set) var state: LoadState

    public init(url: URL, raw: [String: Any] = [:], state: LoadState = .missing) {
        self.url = url
        self.raw = raw
        self.state = state
    }

    public static func load(url: URL) -> JSONConfigDocument {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return JSONConfigDocument(url: url, raw: [:], state: .missing)
        }
        if isDirectory.boolValue {
            return JSONConfigDocument(url: url, raw: [:], state: .corrupt(reason: "path is a directory"))
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return JSONConfigDocument(url: url, raw: [:], state: .corrupt(reason: "unreadable: \(describe(error))"))
        }
        switch parseObject(data) {
        case .success(let object):
            return JSONConfigDocument(url: url, raw: object, state: .loaded)
        case .failure(let failure):
            return JSONConfigDocument(url: url, raw: [:], state: .corrupt(reason: failure.reason))
        }
    }

    public static func parseObject(_ data: Data) -> Result<[String: Any], ParseFailure> {
        if data.isEmpty { return .failure(ParseFailure(reason: "empty file")) }
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .failure(ParseFailure(reason: "not valid JSON: \(describe(error))"))
        }
        guard let object = any as? [String: Any] else {
            return .failure(ParseFailure(reason: "top-level JSON is not an object"))
        }
        return .success(object)
    }

    public func merging(fields: [String: Any], knownKeys: Set<String>? = nil) -> [String: Any] {
        let known = knownKeys ?? Set(fields.keys)
        var merged = raw.filter { !known.contains($0.key) }
        for (key, value) in fields { merged[key] = value }
        return merged
    }

    public static func serialize(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw Failure.notSerializable }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    public mutating func save(fields: [String: Any], knownKeys: Set<String>? = nil, secure: Bool) throws {
        if case .corrupt(let reason) = state {
            throw Failure.refusedCorruptFile(reason: reason)
        }
        let merged = merging(fields: fields, knownKeys: knownKeys)
        let data = try Self.serialize(merged)
        if secure {
            try data.writeSecurely(to: url)
        } else {
            try data.write(to: url, options: .atomic)
        }
        raw = merged
        state = .loaded
    }

    public mutating func markCorrupt(reason: String) {
        guard state == .loaded else { return }
        raw = [:]
        state = .corrupt(reason: reason)
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let debug = ns.userInfo[NSDebugDescriptionErrorKey] as? String, !debug.isEmpty {
            return debug
        }
        return ns.localizedDescription
    }
}
