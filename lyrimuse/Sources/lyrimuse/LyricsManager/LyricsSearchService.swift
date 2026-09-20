import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-search")

private let searchLyricsHealthMarkers = ["rejected (code", "backing off", "cooling down"]

final class LyricsSearchService {
    static let shared = LyricsSearchService()

    private let processLock = NSLock()
    private var runningProcess: Process?

    func cancelRunning() {
        processLock.lock()
        let process = runningProcess
        runningProcess = nil
        processLock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

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
            case "consensus": return L10n.t("内容获印证")
            case "translation": return L10n.t("自带译文")
            case "romanization": return L10n.t("自带罗马音")
            case "rejectNotTimed": return L10n.t("不是带时间戳的歌词")
            case "rejectWrongLanguage": return L10n.t("语言跟这首歌对不上")
            case "rejectCreditOnly": return L10n.t("整份只有署名行，没有正文")
            case "rejectNoLastTimestamp": return L10n.t("取不到最后一句的时间")
            case "rejectDurationMismatch": return L10n.t("时长明显对不上，也没有别的源印证")

            case "rejectPlainTextOnly": return L10n.t("仅有纯文本，没有时间戳")
            default: return kind
            }
        }

        var detail: String {
            switch kind {
            case "duration": return L10n.t("最后一句的时间跟曲长越接近分越高，最多 300")
            case "corroborated": return L10n.t("时长对不上，但别的源也在这个时间结束，改信这个印证")
            case "wordTiming": return L10n.t("带逐字（卡拉OK）时间轴，是歌词质量最直接的证据")
            case "nativeSource": return L10n.t("这个源就是你正在用的播放器，时间轴对着同一份音频母版（+250）")
            case "lines": return L10n.t("一行 1 分，最多 200")
            case "durationOvershoot": return L10n.t("最后一句比歌曲结束还晚 5 秒以上，多半是完整版歌词配了精简版曲目")
            case "album": return L10n.t("这个源匹配到的专辑跟本地专辑一致，版本大概率对（最多 150）")
            case "titleMatch": return L10n.t("完全同名 120 · 仅括号差异 60 · 中英双语同名 30")
            case "consensus": return L10n.t("歌词内容跟其它来源高度一致（2 家以上 250 · 1 家 150），串版本的拿不到")
            case "translation": return L10n.t("自带可用的中文译文，同水平候选间优先")
            case "romanization": return L10n.t("日文歌词自带罗马音，同水平候选间优先")
            case "versionTags": return L10n.t("括号里的 Live / Remix / Demo / Club Mix 等跟本地曲名对不上")
            case "sourceDurationOff":
                return L10n.t("这个源自己声明的曲目时长跟本地差了 12% 以上，多半挂在另一次录音上")
            case "wordTimingOverride":
                return L10n.t("逐字时间轴本来赢在这上面，但另一个候选的标题更吻合查询词——大概率是另一次录音（比如不同现场版）的逐字版本，时间轴细不代表轴对得上这次播放")
            case "liveAlbumConflict":
                return L10n.t("两边都是现场版，但这个候选的专辑名指向另一场不同命名的演出（比如另一次巡演）——时间轴是那场演出的，套在这次播放的录音上会对不上")
            case "durationOff":
                return L10n.t("最后一句的时间跟曲长差了 25% 以上；仍可选用，但会排在所有时长对得上的后面")
            case "rejectDurationMismatch":
                return L10n.t("最后一句的时间跟曲长差了 25% 以上，多半是另一个版本")
            case "rejectPlainTextOnly":
                return L10n.t("这个源确实收录了这首歌，但只有不带时间戳的纯文本——可以在「歌词窗口」里当静态文字阅读，无法逐字/逐行跟随播放高亮")
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
                lines.append(detail.isEmpty
                    ? "\(signed)  \(term.label)"
                    : "\(signed)  \(term.label) · \(detail)")
            }
            return lines.joined(separator: "\n")
        }
    }

    struct Candidate: Identifiable, Equatable {
        var id: String { source }
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

        var hasTranslation: Bool { !lyricsTr.isEmpty }
        var hasRomanization: Bool { !lyricsRoma.isEmpty }

        let lineCount: Int

        let fingerprint: String

        static func countLines(of lyrics: String) -> Int {
            lyrics.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    struct Pick: Decodable {

        var winner: String = ""
        var winnerScore: Int = 0
        var scoringVersion: Int = 0

        var decidable: Bool = false
        var sourcesSeen: [String] = []
        var sourcesResponded: [String] = []
        var resolvedDurationSecs: Double = 0

        var mode: String = ""

        var decisionJSON: String = ""

        private enum CodingKeys: String, CodingKey {
            case winner, winnerScore, scoringVersion, decidable
            case sourcesSeen, sourcesResponded, resolvedDurationSecs, mode, decisionJSON
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            winner = try c.decodeIfPresent(String.self, forKey: .winner) ?? ""
            winnerScore = try c.decodeIfPresent(Int.self, forKey: .winnerScore) ?? 0
            scoringVersion = try c.decodeIfPresent(Int.self, forKey: .scoringVersion) ?? 0
            decidable = try c.decodeIfPresent(Bool.self, forKey: .decidable) ?? false
            sourcesSeen = try c.decodeIfPresent([String].self, forKey: .sourcesSeen) ?? []
            sourcesResponded = try c.decodeIfPresent([String].self, forKey: .sourcesResponded) ?? []
            resolvedDurationSecs = try c.decodeIfPresent(Double.self, forKey: .resolvedDurationSecs) ?? 0
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
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
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .processFailed(let msg): return String(format: L10n.t("搜索失败: %@"), msg)
            }
        }
    }

    private static let collectorPath = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/collector").path

    private init() {}

    func search(
        artist: String, title: String, album: String, durationSecs: Double = 0,
        pickWinner: Bool = false, currentSource: String = "",
        onUpdate: @escaping @MainActor (SearchUpdate) -> Void
    ) async throws {

        try await withTaskCancellationHandler {
            try await performSearch(artist: artist, title: title, album: album,
                                    durationSecs: durationSecs, pickWinner: pickWinner,
                                    currentSource: currentSource, onUpdate: onUpdate)
        } onCancel: {
            cancelRunning()
        }
    }

    private func performSearch(
        artist: String, title: String, album: String, durationSecs: Double,
        pickWinner: Bool = false, currentSource: String = "",
        onUpdate: @escaping @MainActor (SearchUpdate) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.collectorPath)

            process.environment = LyrimusePaths.collectorProcessEnvironment()
            process.arguments = [
                "search-lyrics",
                "-artist", artist,
                "-title", title,
                "-album", album,
                "-duration", String(durationSecs),
            ]

            if let playerBundleID = UserDefaults.standard.string(forKey: "np:lastPlayerBundleID"),
               !playerBundleID.isEmpty
            {
                process.arguments?.append(contentsOf: ["-player", playerBundleID])
            }
            if pickWinner {
                process.arguments?.append("-pick")
                if !currentSource.isEmpty {
                    process.arguments?.append(contentsOf: ["-current-source", currentSource])
                }
            }

            self.cancelRunning()
            self.processLock.lock()
            self.runningProcess = process
            self.processLock.unlock()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            final class Box: @unchecked Sendable {
                var outBuffer = Data()
                var errBuffer = Data()
            }
            let box = Box()
            let readQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.search-lyrics.stdout", qos: .utility)
            let readGroup = DispatchGroup()

            @Sendable func drainCompleteLines() {
                while let newlineRange = box.outBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = box.outBuffer.subdata(in: box.outBuffer.startIndex..<newlineRange.lowerBound)
                    box.outBuffer.removeSubrange(box.outBuffer.startIndex..<newlineRange.upperBound)
                    guard !lineData.isEmpty else { continue }
                    guard let raw = try? JSONDecoder().decode(RawSearchUpdate.self, from: lineData) else {
                        logger.error("search-lyrics: failed to decode a stdout line, skipping")
                        continue
                    }
                    let update = SearchUpdate(
                        candidates: raw.candidates.map(Candidate.init),
                        networkLooksDown: raw.networkLooksDown,

                        sourcesDone: raw.sourcesDone ?? 0,
                        sourcesTotal: raw.sourcesTotal ?? 0,
                        round: raw.round ?? 1,
                        sourceFailureReasonCodes: raw.sourceFailureReasonCodes ?? [:],

                        instrumental: raw.instrumental ?? raw.lrclibInstrumental ?? false,
                        pick: raw.pick)
                    Task { @MainActor in onUpdate(update) }
                }
            }

            readGroup.enter()
            readQueue.async {
                let handle = stdoutPipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    box.outBuffer.append(chunk)
                    drainCompleteLines()
                }
                readGroup.leave()
            }

            let stderrQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.search-lyrics.stderr", qos: .utility)
            readGroup.enter()
            stderrQueue.async {
                box.errBuffer = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }

            process.terminationHandler = { proc in

                readGroup.wait()
                guard proc.terminationStatus == 0 else {
                    let msg = String(data: box.errBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.error("search-lyrics exited \(proc.terminationStatus): \(msg ?? "", privacy: .public)")
                    continuation.resume(throwing: SearchError.processFailed(msg?.isEmpty == false ? msg! : String(format: L10n.t("退出码 %@"), "\(proc.terminationStatus)")))
                    return
                }
                Self.logSourceHealthSignals(box.errBuffer)
                continuation.resume(returning: ())
            }

            do {
                try process.run()
            } catch {

                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                continuation.resume(throwing: SearchError.processFailed(error.localizedDescription))
            }
        }
    }
}

private struct RawSearchUpdate: Decodable {
    let candidates: [RawCandidate]
    let networkLooksDown: Bool
    let sourcesDone: Int?
    let sourcesTotal: Int?

    let round: Int?
    let sourceFailureReasonCodes: [String: String]?

    let instrumental: Bool?

    let lrclibInstrumental: Bool?

    let pick: LyricsSearchService.Pick?
}

private struct RawCandidate: Decodable {
    let source: String
    let lyrics: String
    let lyricsTr: String?
    let lyricsRoma: String?
    let lyricsYRC: String?
    let hasWordTiming: Bool
    let score: Int
    let scoreTerms: [LyricsSearchService.ScoreTerm]?
    let title: String?
    let artist: String?
    let album: String?
    let coverURL: String?
    let plainTextOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case source, lyrics, score, title, artist, album
        case lyricsTr = "lyrics_tr"
        case lyricsRoma = "lyrics_roma"
        case lyricsYRC = "lyrics_yrc"
        case hasWordTiming = "has_word_timing"
        case scoreTerms = "score_terms"
        case coverURL = "cover_url"
        case plainTextOnly = "plain_text_only"
    }
}

private extension LyricsSearchService.Candidate {
    init(_ raw: RawCandidate) {
        self.init(
            source: raw.source,
            lyrics: raw.lyrics,
            lyricsTr: raw.lyricsTr ?? "",
            lyricsRoma: raw.lyricsRoma ?? "",
            lyricsYRC: raw.lyricsYRC ?? "",
            hasWordTiming: raw.hasWordTiming,
            score: raw.score,
            scoreTerms: raw.scoreTerms ?? [],
            title: raw.title ?? "",
            artist: raw.artist ?? "",
            album: raw.album ?? "",
            coverURL: raw.coverURL.flatMap(URL.init(string:)),
            isPlainTextOnly: raw.plainTextOnly ?? false,
            lineCount: LyricsSearchService.Candidate.countLines(of: raw.lyrics),
            fingerprint: ManualPickLock.fingerprint(lyrics: raw.lyrics)
        )
    }
}

extension LyricsSearchService {

    fileprivate static func logSourceHealthSignals(_ stderr: Data) {
        guard !stderr.isEmpty, let text = String(data: stderr, encoding: .utf8) else { return }
        let hits = text.split(separator: "\n").filter { line in
            searchLyricsHealthMarkers.contains { line.contains($0) }
        }
        guard !hits.isEmpty else { return }
        let shown = hits.prefix(12)
        for line in shown {
            logger.notice("search-lyrics: \(line.trimmingCharacters(in: .whitespaces), privacy: .public)")
        }
        if hits.count > shown.count {
            logger.notice("search-lyrics: \(hits.count - shown.count, privacy: .public) more lines of the same signal not logged (cap 12 per run)")
        }
    }
}
