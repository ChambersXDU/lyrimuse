import Foundation

public enum LocalArtistAliases {

    public struct MusicBrainzCaches {
        public var aliasCache: [String: String]
        public var identityZh: [String: String]
        public var primaryAliases: [String: [String]]
        public init(aliasCache: [String: String] = [:], identityZh: [String: String] = [:],
                    primaryAliases: [String: [String]] = [:]) {
            self.aliasCache = aliasCache
            self.identityZh = identityZh
            self.primaryAliases = primaryAliases
        }
    }

    public static let minSharedSongIDs = 2
    public static let minAliasLength = 3

    public static func artistKey(_ name: String) -> String {
        PlayCountFold.stripSpaces(PlayCountFold.normalized(ArtistCredit.mergeArtist(name)))
    }

    public static func canonicalArtistKey(_ name: String, table: [String: String]) -> String {
        let primary = ArtistCredit.mergeArtist(name)
        let canon = table[artistKey(primary)] ?? primary
        return PlayCountFold.stripSpaces(PlayCountFold.normalized(canon))
    }

    public static func derive(caches: MusicBrainzCaches, entries: [EnrichTitleAliases.Entry]) -> [String: String] {
        var uf = UnionFind()

        var spellings: [String: [String: Int]] = [:]
        func note(_ name: String, weight: Int = 0) -> String? {
            let primary = ArtistCredit.mergeArtist(name).trimmingCharacters(in: .whitespaces)
            guard !primary.isEmpty else { return nil }
            let key = artistKey(primary)
            guard !key.isEmpty else { return nil }
            spellings[key, default: [:]][primary, default: 0] += weight
            uf.add(key)
            return key
        }

        func single(_ name: String) -> Bool {
            ArtistCredit.mergeArtist(name).trimmingCharacters(in: .whitespaces) == name.trimmingCharacters(in: .whitespaces)
        }
        func usable(_ alias: String) -> Bool {
            let squeezed = PlayCountFold.stripSpaces(alias)
            return !PlayCountFold.hasNoHanLikeChars(squeezed) || squeezed.count >= minAliasLength
        }

        for (raw, zh) in caches.aliasCache where !zh.isEmpty && single(raw) && single(zh) {
            guard let a = note(raw), let b = note(zh) else { continue }
            uf.union(a, b)
        }
        for (name, zh) in caches.identityZh where !zh.isEmpty && single(name) && single(zh) {
            guard let a = note(name), let b = note(zh) else { continue }
            uf.union(a, b)
        }
        for (name, aliases) in caches.primaryAliases where single(name) {
            guard let a = note(name) else { continue }
            for alias in aliases where usable(alias) && single(alias) {
                guard let b = note(alias) else { continue }
                uf.union(a, b)
            }
        }

        var artistsByID: [String: Set<String>] = [:]
        for e in entries {
            guard let key = note(e.artist, weight: 1) else { continue }
            for id in EnrichTitleAliases.songIDs(neteaseURL: e.neteaseURL, qqMusicURL: e.qqMusicURL) {
                artistsByID[id, default: []].insert(key)
            }
        }
        var shared: [String: Set<String>] = [:]
        for (id, keys) in artistsByID where keys.count > 1 {
            let sorted = keys.sorted()
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    shared[sorted[i] + "\u{1F}" + sorted[j], default: []].insert(id)
                }
            }
        }
        for (pair, ids) in shared where ids.count >= minSharedSongIDs {
            let parts = pair.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            uf.union(parts[0], parts[1])
        }

        var groups: [String: [String]] = [:]
        for key in spellings.keys { groups[uf.find(key), default: []].append(key) }
        var out: [String: String] = [:]
        for (_, keys) in groups where keys.count > 1 {
            var candidates: [(name: String, han: Bool, weight: Int)] = []
            for key in keys {
                for (name, weight) in spellings[key] ?? [:] {
                    candidates.append((name, !PlayCountFold.hasNoHanLikeChars(name), weight))
                }
            }
            guard let rep = candidates.min(by: { a, b in
                if a.han != b.han { return a.han }
                if a.weight != b.weight { return a.weight > b.weight }
                return a.name < b.name
            }) else { continue }
            let repKey = artistKey(rep.name)
            for key in keys where key != repKey { out[key] = rep.name }
        }
        return out
    }

    struct UnionFind {
        private var parent: [String: String] = [:]
        mutating func add(_ k: String) { if parent[k] == nil { parent[k] = k } }
        mutating func find(_ k: String) -> String {
            add(k)
            var root = k
            while let p = parent[root], p != root { root = p }
            var cur = k
            while let p = parent[cur], p != root { parent[cur] = root; cur = p }
            return root
        }
        mutating func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }

            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }
    }
}

public enum ArtistIdentityCaches {
    public static func load(configDir: URL = LyrimusePaths.configDir) -> LocalArtistAliases.MusicBrainzCaches {
        var out = LocalArtistAliases.MusicBrainzCaches()
        if let data = try? Data(contentsOf: configDir.appendingPathComponent("lyrimuse-artist-alias-cache.json")),
           let m = try? JSONDecoder().decode([String: String].self, from: data) {
            out.aliasCache = m
        }
        struct Identity: Decodable { var zh: String? }
        if let data = try? Data(contentsOf: configDir.appendingPathComponent("lyrimuse-artist-identity-cache.json")),
           let m = try? JSONDecoder().decode([String: Identity].self, from: data) {
            out.identityZh = m.compactMapValues { $0.zh }.filter { !$0.value.isEmpty }
        }
        if let data = try? Data(contentsOf: configDir.appendingPathComponent("lyrimuse-artist-primary-cache.json")),
           let m = try? JSONDecoder().decode([String: [String]].self, from: data) {
            out.primaryAliases = m
        }
        return out
    }
}
