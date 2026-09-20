import Foundation
import LyrimuseCore

enum LastfmMirrorStatus {
    struct Info: Decodable, Equatable {
        let error: Int
        let message: String
        let at: Int64
    }

    private static let url = LyrimusePaths.configFile("lyrimuse-lastfm-status.json")

    private static var cachedMTime: Date?
    private static var cached: Info?

    static var current: Info? {
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

    static func clear() {
        try? FileManager.default.removeItem(at: url)
        cachedMTime = nil
        cached = nil

        LastfmMirrorStatusWatcher.shared.refresh()
    }
}

final class LastfmMirrorStatusWatcher: ObservableObject {
    static let shared = LastfmMirrorStatusWatcher()

    @Published private(set) var info: LastfmMirrorStatus.Info?

    private var timer: Timer?

    private init() {
        info = LastfmMirrorStatus.current
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }

        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let now = LastfmMirrorStatus.current
        if now != info { info = now }
    }
}
