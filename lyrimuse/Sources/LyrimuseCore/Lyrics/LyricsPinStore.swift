import Combine
import Foundation

@MainActor
public final class LyricsPinStore: ObservableObject {
    public static let shared = LyricsPinStore()

    private struct File: Codable {
        var version: Int
        var pins: [String: Int]
    }

    private static let fileVersion = 1

    private static let defaultURL = LyrimusePaths.configFile("lyrimuse-lyrics-pins.json")

    private static let url = defaultURL

    @Published public private(set) var pins: [String: Int]

    private init() {
        pins = Self.load()
    }

    public var count: Int { pins.count }

    public func isPinned(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return pins[key] != nil
    }

    public func setPinned(_ pinned: Bool, forKey key: String, now: Date = Date()) {
        guard !key.isEmpty else { return }
        if pinned {
            guard pins[key] == nil else { return }
            pins[key] = Int(now.timeIntervalSince1970)
        } else {
            guard pins.removeValue(forKey: key) != nil else { return }
        }
        persist()
    }

    public func remove(keys: Set<String>) {
        let before = pins.count
        for key in keys { pins.removeValue(forKey: key) }
        guard pins.count != before else { return }
        persist()
    }

    public func removeAll() {
        guard !pins.isEmpty else { return }
        pins.removeAll()
        persist()
    }

    @discardableResult
    public func merge(_ incoming: [String: Int]) -> Int {
        var added = 0
        for (key, ts) in incoming where !key.isEmpty {
            if let existing = pins[key] {
                if ts < existing { pins[key] = ts }
            } else {
                pins[key] = ts
                added += 1
            }
        }
        guard added > 0 || !incoming.isEmpty else { return 0 }
        persist()
        return added
    }

    private func persist() {
        let file = File(version: Self.fileVersion, pins: pins)
        guard let data = try? JSONEncoder().encode(file) else { return }

        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)

        try? data.write(to: Self.url, options: [.atomic])
    }

    private static func load() -> [String: Int] {
        guard
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            return [:]
        }
        return file.pins
    }
}
