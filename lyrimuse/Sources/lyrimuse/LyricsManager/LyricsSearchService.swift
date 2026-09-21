import Foundation
import LyrimuseCore

@MainActor
final class LyricsSearchService {
    static let shared = LyricsSearchService()

    private let resolver = LyricsResolver()
    private var runningTask: Task<LyricsResolution, Never>?

    struct ScoreTerm: Equatable, Decodable {
        let kind: String
        let points: Int

        var label: String {
            switch kind {
            case "duration": return L10n.t("时长吻合")
            case "corroborated": return L10n.t("结束点获印证")
            case "wordTiming": return L10n.t("逐字时间轴")
            case "nativeSource": return L10n.t("与当前播放器同源")
            case "lines": return L10n.t("行数")
            case "versionTags": return L10n.t("版本不符")
            case "durationOff": return L10n.t("时长不符")
            case "sourceDurationOff": return L10n.t("源自报曲长不符")
            case "wordTimingOverride": return L10n.t("标题吻合度更高的候选存在，撤销逐字加分")
            case "liveAlbumConflict": return L10n.t("是另一场演出的现场版")
            case "durationOvershoot": return L10n.t("歌词超出曲长")
            case "album": return L10n.t("专辑吻合")
            case "titleMatch": return L10n.t("标题吻合")
            case "artistMatch": return L10n.t("歌手吻合")
            case "consensus": return L10n.t("内容获印证")
            case "translation": return L10n.t("自带译文")
            case "romanization": return L10n.t("自带罗马音")
            case "rejectNotTimed": return L10n.t("不是带时间戳的歌词")
            case "rejectWrongArtist": return L10n.t("歌手跟这首歌对不上")
            case "rejectCreditOnly": return L10n.t("整份只有署名行，没有正文")
            case "rejectNoLastTimestamp": return L10n.t("取不到最后一句的时间")
            case "rejectDurationMismatch": return L10n.t("时长明显对不上，也没有别的源印证")
            case "rejectPlainTextOnly": return L10n.t("仅有纯文本，没有时间戳")
            case "instrumental": return L10n.t("纯音乐")
            default: return kind
            }
        }

        var detail: String {
            switch kind {
            case "duration": return L10n.t("最后一句的时间跟曲长越接近分越高")
            case "wordTiming": return L10n.t("带逐字（卡拉 OK）时间轴")
            case "lines": return L10n.t("歌词行数")
            case "album": return L10n.t("源返回的专辑与本地资料一致")
            case "titleMatch": return L10n.t("标题标准化后匹配")
            case "artistMatch": return L10n.t("歌手标准化后匹配")
            case "consensus": return L10n.t("歌词正文与其他源高度一致")
            case "translation": return L10n.t("带有可用译文")
            case "romanization": return L10n.t("带有可用罗马音")
            case "versionTags": return L10n.t("Live、Remix、Demo 等版本标记不一致")
            case "sourceDurationOff": return L10n.t("源声明的曲长与本地差异较大")
            case "durationOff": return L10n.t("歌词结束时间与曲长差异较大")
            case "durationOvershoot": return L10n.t("歌词结束时间超过歌曲结束")
            case "wordTimingOverride": return L10n.t("标题更吻合的候选优先")
            case "rejectPlainTextOnly": return L10n.t("可以作为静态文字阅读，但不能跟随播放高亮")
            default: return ""
            }
        }

        var isRejection: Bool { kind.hasPrefix("reject") }

        static func explanation(score: Int, terms: [ScoreTerm]) -> String {
            guard let first = terms.first else { return "" }
            if first.isRejection {
                let detail = first.detail
                return String(format: L10n.t("不可用：%@"), first.label)
                    + (detail.isEmpty ? "" : "\n" + detail)
            }
            var lines = [String(format: L10n.t("总分 %@"), "\(score)")]
            for term in terms.sorted(by: { abs($0.points) > abs($1.points) }) {
                let signed = "\(term.points > 0 ? "+" : "")\(term.points)"
                let detail = term.detail
                lines.append(detail.isEmpty ? "\(signed)  \(term.label)" : "\(signed)  \(term.label) · \(detail)")
            }
            return lines.joined(separator: "\n")
        }
    }

    struct Candidate: Identifiable, Equatable {
        var id: String { "\(source)|\(fingerprint)" }
        let source: String
        let lyrics: String
        let lyricsTr: String
        let lyricsRoma: String
        let lyricsYRC: String
        let hasWordTiming: Bool
        let score: Int
        let scoreTerms: [ScoreTerm]
        let title: String
        let artist: String
        let album: String
        let coverURL: URL?
        let isPlainTextOnly: Bool
        let lineCount: Int
        let fingerprint: String

        var hasTranslation: Bool { !lyricsTr.isEmpty }
        var hasRomanization: Bool { !lyricsRoma.isEmpty }

        static func countLines(of lyrics: String) -> Int {
            lyrics.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    struct Pick: Decodable {
        var winner: String = ""
        var winnerScore: Int = 0
        var scoringVersion: Int = 18
        var decidable = false
        var sourcesSeen: [String] = []
        var sourcesResponded: [String] = []
        var resolvedDurationSecs: Double = 0
        var mode = "native-swift"
        var decisionJSON = ""

        private enum CodingKeys: String, CodingKey {
            case winner, winnerScore, scoringVersion, decidable, sourcesSeen, sourcesResponded
            case resolvedDurationSecs, mode, decisionJSON
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            winner = try c.decodeIfPresent(String.self, forKey: .winner) ?? ""
            winnerScore = try c.decodeIfPresent(Int.self, forKey: .winnerScore) ?? 0
            scoringVersion = try c.decodeIfPresent(Int.self, forKey: .scoringVersion) ?? 18
            decidable = try c.decodeIfPresent(Bool.self, forKey: .decidable) ?? false
            sourcesSeen = try c.decodeIfPresent([String].self, forKey: .sourcesSeen) ?? []
            sourcesResponded = try c.decodeIfPresent([String].self, forKey: .sourcesResponded) ?? []
            resolvedDurationSecs = try c.decodeIfPresent(Double.self, forKey: .resolvedDurationSecs) ?? 0
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "native-swift"
            decisionJSON = try c.decodeIfPresent(String.self, forKey: .decisionJSON) ?? ""
        }
    }

    struct SearchUpdate {
        let candidates: [Candidate]
        let networkLooksDown: Bool
        let sourcesDone: Int
        let sourcesTotal: Int
        let round: Int
        let sourceFailureReasonCodes: [String: String]
        let instrumental: Bool
        let pick: Pick?
    }

    enum SearchError: LocalizedError {
        case searchFailed(String)
        var errorDescription: String? {
            switch self { case .searchFailed(let message): return String(format: L10n.t("搜索失败: %@"), message) }
        }
    }

    private init() {}

    func cancelRunning() {
        let task = runningTask
        runningTask = nil
        task?.cancel()
    }

    func startAutomaticSearch() {
        let source = LocalPlaybackSource.shared
        source.onTrackChanged = { [weak self] artist, title, album, duration in
            guard let self, !title.isEmpty, !artist.isEmpty else { return }
            Task { await self.searchAndSave(artist: artist, title: title, album: album, duration: duration) }
        }
        if !source.title.isEmpty, !source.artist.isEmpty {
            let artist = source.artist
            let title = source.title
            let album = source.album
            let duration = Double(source.currentDurationMs ?? 0) / 1000
            Task { await self.searchAndSave(artist: artist, title: title, album: album, duration: duration) }
        }
    }

    func search(
        artist: String, title: String, album: String, durationSecs: Double = 0,
        pickWinner: Bool = false, currentSource: String = "",
        onUpdate: @escaping @MainActor (SearchUpdate) -> Void
    ) async throws {
        cancelRunning()
        let query = LyricsQuery(title: title, artist: artist, album: album.isEmpty ? nil : album,
                                duration: durationSecs > 0 ? durationSecs : nil)
        let enabledSourceIDs = FeatureSettingsStore.shared.lyricsSourceOrder
            .filter { FeatureSettingsStore.shared.lyricsSources.contains($0) }
            .map(\.rawValue)
        let task = Task { [resolver] in await resolver.resolve(query, enabledIDs: enabledSourceIDs) }
        runningTask = task
        await withTaskCancellationHandler(operation: {
            let resolution = await task.value
            guard !Task.isCancelled else { return }
            LocalPlaybackSource.shared.setNetworkDown(resolution.sourcesResponded.isEmpty)
            let candidates = resolution.matches.map(Candidate.init)
            let pick = makePick(resolution: resolution, candidates: candidates, duration: durationSecs)
            let update = SearchUpdate(
                candidates: candidates,
                networkLooksDown: resolution.sourcesResponded.isEmpty,
                sourcesDone: resolution.sourcesSeen.count,
                sourcesTotal: resolution.sourcesSeen.count,
                round: 1,
                sourceFailureReasonCodes: Dictionary(uniqueKeysWithValues: resolution.failures.map { ($0.key, failureCode($0.value)) }),
                instrumental: resolution.instrumental,
                pick: pick)
            onUpdate(update)
        }, onCancel: { task.cancel() })
        runningTask = nil
    }

    private func makePick(resolution: LyricsResolution, candidates: [Candidate], duration: Double) -> Pick? {
        var pick = Pick()
        pick.sourcesSeen = resolution.sourcesSeen
        pick.sourcesResponded = resolution.sourcesResponded
        pick.resolvedDurationSecs = duration
        guard let winner = resolution.winner, let candidate = candidates.first(where: { $0.source == winner.source && $0.fingerprint == ManualPickLock.fingerprint(lyrics: winner.candidate.lyrics) }) else {
            pick.decisionJSON = decisionJSON(resolution: resolution, candidates: candidates, winner: nil)
            return pick
        }
        pick.winner = candidate.source
        pick.winnerScore = candidate.score
        pick.decidable = true
        pick.decisionJSON = decisionJSON(resolution: resolution, candidates: candidates, winner: candidate)
        return pick
    }

    private func decisionJSON(resolution: LyricsResolution, candidates: [Candidate], winner: Candidate?) -> String {
        let rows = candidates.map { candidate in
            ["source": candidate.source, "score": candidate.score,
             "score_terms": candidate.scoreTerms.map { ["kind": $0.kind, "points": $0.points] },
             "title": candidate.title, "artist": candidate.artist, "album": candidate.album,
             "has_word_timing": candidate.hasWordTiming,
             "consensus_peers": resolution.matches.first(where: { $0.source == candidate.source && $0.candidate.lyrics == candidate.lyrics })?.consensusPeers ?? []] as [String: Any]
        }
        let object: [String: Any] = [
            "path": "native-swift", "decided_at": Int(Date().timeIntervalSince1970), "scoring_version": 18,
            "winner": winner?.source ?? NSNull(), "applied": false, "candidates": rows,
            "sources_responded": resolution.sourcesResponded,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func failureCode(_ message: String) -> String {
        let value = message.lowercased()
        if value.contains("timed out") || value.contains("timeout") { return "connect_failed" }
        if value.contains("http 5") { return "server_error" }
        if value.contains("dns") || value.contains("name") { return "dns_failed" }
        return "upstream_unreachable"
    }

    private func decisionObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        object["applied"] = true
        return object
    }

    private func searchAndSave(artist: String, title: String, album: String, duration: Double) async {
        let cached = EnrichCacheReader.lookup(artist: artist, title: title, album: album)
        if cached?.resolved == true || cached?.instrumental == true || !(cached?.lyrics.isEmpty ?? true) { return }
        do {
            var update: SearchUpdate?
            try await search(artist: artist, title: title, album: album, durationSecs: duration, pickWinner: true) { value in update = value }
            guard let update, let winner = update.pick.flatMap({ pick in update.candidates.first { $0.source == pick.winner } }) else {
                if update?.instrumental == true {
                    await EnrichCacheStore.shared.markInstrumental(key: EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album))
                }
                return
            }
            let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
            _ = await EnrichCacheStore.shared.saveEdit(key: key, lyrics: winner.lyrics, tr: winner.lyricsTr,
                                                        roma: winner.lyricsRoma, yrc: winner.lyricsYRC,
                                                        source: winner.source, markManual: false,
                                                        score: winner.score, scoringVersion: 18,
                                                        resolvedDurationSecs: duration,
                                                        sourcesSeen: update.pick?.sourcesSeen ?? [],
                                                        sourcesResponded: update.pick?.sourcesResponded ?? [],
                                                        decision: update.pick.flatMap { decisionObject($0.decisionJSON) },
                                                        coverURL: winner.coverURL)
            await MainActor.run { LocalPlaybackSource.shared.forceReloadLyricsForCurrentTrack() }
        } catch {
            return
        }
    }
}

private extension LyricsSearchService.Candidate {
    init(_ match: LyricsMatch) {
        self.init(source: match.source, lyrics: match.candidate.lyrics,
                  lyricsTr: match.candidate.translation ?? "", lyricsRoma: match.candidate.romanization ?? "",
                  lyricsYRC: match.candidate.wordTiming ?? "", hasWordTiming: match.candidate.hasWordTiming,
                  score: match.score, scoreTerms: match.terms.map { .init(kind: $0.kind, points: $0.points) },
                  title: match.candidate.title, artist: match.candidate.artist,
                  album: match.candidate.album ?? "", coverURL: match.candidate.coverURL,
                  isPlainTextOnly: match.candidate.plainTextOnly,
                  lineCount: Self.countLines(of: match.candidate.lyrics),
                  fingerprint: ManualPickLock.fingerprint(lyrics: match.candidate.lyrics))
    }
}
