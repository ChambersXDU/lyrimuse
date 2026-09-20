import SwiftUI
import LyrimuseCore

private let currentLyricsScoringVersion = 18

struct LyricsDecisionSheet: View {
    let summary: EnrichCacheStore.Summary

    private let records: [(label: String, record: LyricsResolutionDecision)]
    @State private var selectedRecord = 0

    @State private var expanded: Set<String> = []

    @State private var inputsOpen = false
    @Environment(\.dismiss) private var dismiss

    init(summary: EnrichCacheStore.Summary,
         latest: LyricsResolutionDecision?,
         applied: LyricsResolutionDecision?) {
        self.summary = summary
        let origin = applied ?? ((latest?.applied == true) ? latest : nil)
        var tabs: [(label: String, record: LyricsResolutionDecision)] = []
        if let origin {
            tabs.append((L10n.t("当前歌词的出处"), origin))
        }
        if let latest, origin == nil || origin?.decidedAt != latest.decidedAt || origin?.path != latest.path {
            tabs.append((L10n.t("最近一次评估"), latest))
        }
        self.records = tabs
    }

    private var decision: LyricsResolutionDecision? {
        records.isEmpty ? nil : records[min(selectedRecord, records.count - 1)].record
    }

    private func pathLabel(_ decision: LyricsResolutionDecision) -> String {
        switch decision.path {
        case "first-resolve": return L10n.t("首次解析")
        case "upgrade": return L10n.t("升级重试")
        case "rescore": return L10n.t("规则换版重选")

        case "refill": return L10n.t("补搜缺失歌词")

        case "manual-rematch": return L10n.t("手动重新匹配")

        default: return decision.path
        }
    }

    private func queryReasonLabel(_ reason: String?) -> String {
        switch reason ?? "" {
        case "": return L10n.t("首轮")
        case "title-split": return L10n.t("按「署名 - 曲名」拆分")
        case "alias-rescue": return L10n.t("别名轮：一个候选都没有")

        case "alias-roma": return L10n.t("别名轮：中日韩歌词但没有源给出罗马音")
        case "alias-missing": return L10n.t("别名轮：补缺席的源")
        case "primary-artist-variant": return L10n.t("只用第一位歌手")
        case "title-from-album": return L10n.t("标题反查：专辑曲目表")
        case "title-from-artist-search": return L10n.t("标题反查：歌手泛搜")
        case "title-from-apple-storefront": return L10n.t("标题反查：Apple 原产地商店")
        default: return reason ?? ""
        }
    }

    private func queryDigest(_ decision: LyricsResolutionDecision) -> LyricQueryDigest? {
        guard let tried = decision.queriesTried, !tried.isEmpty else { return nil }

        guard tried.count > 1 || tried.first?.reason?.isEmpty == false else { return nil }
        return LyricQueryDigestBuilder.build(tried.map {
            LyricQueryRound(artist: $0.artist, title: $0.title ?? "",
                            reason: $0.reason ?? "", sources: $0.sources ?? [])
        })
    }

    private func groupHeading(_ g: LyricQueryGroup) -> String {
        var head = queryReasonLabel(g.reason)
        if !g.sources.isEmpty {
            head += " · " + String(format: L10n.t("只问 %@"),
                                   g.sources.map { sourceDisplayName($0) }.joined(separator: "、"))
        } else if g.reason.hasPrefix("alias-") {
            head += " · " + L10n.t("全部源重问")
        }
        return head
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if records.count > 1 {

                        Picker("", selection: $selectedRecord) {
                            ForEach(records.indices, id: \.self) { i in
                                Text(records[i].label).tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if let decision {

                        verdictSection(decision)
                        chipsRow(decision)
                        candidateSection(decision)
                        sharedTermsLine(decision)
                        inputsSection(decision)
                    }
                }
                .padding(16)
            }
        }

        .frame(
            minWidth: 460, idealWidth: 520, maxWidth: .infinity,
            minHeight: 420, idealHeight: 560, maxHeight: .infinity)
        .background(WindowResizeEnabler(minWidth: 460, minHeight: 420))

        .onChange(of: selectedRecord) { _, _ in expanded.removeAll() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("解析决策")).font(.headline)

                Text(summary.isManual
                     ? L10n.t("记录的是手动修改之前的最后一次自动评估")
                     : L10n.t("当初自动挑选歌词那一刻的存档，现在重新搜索结果可能不同"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button(L10n.t("拷贝")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(plainTextDump, forType: .string)
            }
            .help(L10n.t("把整份决策记录拷到剪贴板（纯文本）"))
            Button(L10n.t("完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)

        .background(WindowDragHandle())
    }

    private var plainTextDump: String {
        var lines: [String] = []
        lines.append("\(summary.title) — \(summary.artist)")
        if !summary.album.isEmpty { lines.append(summary.album) }

        for (i, item) in records.enumerated() {
            if records.count > 1 {
                if i > 0 { lines.append("") }
                lines.append("== \(item.label) ==")
            }
            lines.append(contentsOf: dumpLines(item.record))
        }
        return lines.joined(separator: "\n")
    }

    private struct Row: Identifiable {
        var id: String { core.source }
        let model: LyricsResolutionDecision.Candidate
        let core: LyricsScoredCandidate
    }

    private struct Analysis {

        let rows: [Row]

        let sidelined: [Row]
        let champion: Row?

        let deltas: [String: LyricsScoreDelta]
        let verdict: LyricsVerdict?

        let shared: [LyricsScoreTermValue]
    }

    private func analysis(_ decision: LyricsResolutionDecision) -> Analysis {
        let models = decision.candidates ?? []
        let all = models.map { c in
            Row(model: c,
                core: LyricsScoredCandidate(
                    source: c.source,
                    score: c.score,
                    terms: (c.scoreTerms ?? []).map {
                        LyricsScoreTermValue(kind: $0.kind, points: $0.points)
                    },
                    instrumental: c.instrumental,
                    consensusPeers: c.consensusPeers ?? []))
        }
        let cores = all.map(\.core)
        let rankedSources = LyricsVerdictBuilder.ranked(cores, winner: decision.winner).map(\.source)

        let bySource = Dictionary(all.map { ($0.core.source, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = rankedSources.compactMap { bySource[$0] }
        let sidelined = all.filter { !$0.core.isContender }
        let championCore = LyricsVerdictBuilder.champion(among: cores, winner: decision.winner)
        let champion = championCore.flatMap { bySource[$0.source] }
        var deltas: [String: LyricsScoreDelta] = [:]
        if let championCore {
            let losers = rows.map(\.core).filter { $0.source != championCore.source }
            for d in LyricsVerdictBuilder.deltas(champion: championCore, others: losers) {
                deltas[d.source] = d
            }
        }
        return Analysis(
            rows: rows,
            sidelined: sidelined,
            champion: champion,
            deltas: deltas,
            verdict: LyricsVerdictBuilder.build(candidates: cores, winner: decision.winner),
            shared: LyricsVerdictBuilder.sharedTerms(among: cores))
    }

    private func labeledFields(_ fields: [(String, String?)]) -> String {
        fields.compactMap { label, value -> String? in
            guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return label + "「" + v + "」"
        }.joined()
    }

    private func matchedText(_ c: LyricsResolutionDecision.Candidate) -> String {
        labeledFields([(L10n.t("歌名"), c.title), (L10n.t("歌手"), c.artist), (L10n.t("专辑"), c.album)])
    }

    private func queryText(_ decision: LyricsResolutionDecision) -> String {
        labeledFields([(L10n.t("歌手"), decision.queryArtist),
                       (L10n.t("歌名"), decision.queryTitle),
                       (L10n.t("专辑"), decision.queryAlbum)])
    }

    private func groupQueriesText(_ g: LyricQueryGroup) -> String {
        if g.queries.allSatisfy({ $0.title.isEmpty }) {
            return L10n.t("歌手") + g.queries.map { "「\($0.artist)」" }.joined()
        }
        return g.queries
            .map { labeledFields([(L10n.t("歌手"), $0.artist), (L10n.t("歌名"), $0.title)]) }
            .joined(separator: "  ")
    }

    private func termLabel(_ kind: String) -> String {
        LyricsSearchService.ScoreTerm(kind: kind, points: 0).label
    }

    private func signedText(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }

    private func compactTerms(_ terms: [LyricsScoreTermValue]) -> String {
        terms.map { "\(termLabel($0.kind)) \(signedText($0.points))" }.joined(separator: " · ")
    }

    private func championTerms(_ row: Row) -> [LyricsScoreTermValue] {
        row.core.terms.sorted { abs($0.points) > abs($1.points) }
    }

    private func titleRewrite(_ decision: LyricsResolutionDecision) -> (from: String, to: String)? {
        let to = (decision.correctedTitle ?? "").trimmingCharacters(in: .whitespaces)
        let from = (decision.queryTitle ?? "").trimmingCharacters(in: .whitespaces)
        guard !to.isEmpty, !from.isEmpty, to != from else { return nil }
        return (from, to)
    }

    private func gapPercentText(gap: Int, percent: Double?) -> String {
        guard gap > 0, let percent else { return "" }
        return String(format: "%.1f%%", percent)
    }

    private func verdictText(_ v: LyricsVerdict) -> (title: String, detail: String) {
        switch v {
        case let .sameLyrics(contenders, gap, percent, nearTie, separator):
            var detail = gapSentence(gap: gap, percent: percent, nearTie: nearTie,
                                     sayNearTie: true, separator: separator)

            detail += " " + L10n.t("分差比的是包装（有没有逐字轴、有没有译文），不是内容。")
            return (String(format: L10n.t("%d 个源给的是同一份词"), contenders), detail)

        case let .decisiveNegative(term, loser, gap):
            return (String(format: L10n.t("「%@」是胜负手"), termLabel(term.kind)),
                    String(format: L10n.t("%1$@ 在这一项上被扣 %2$d 分，胜者没有这一项——%3$d 分的分差全在这里。"),
                           sourceDisplayName(loser), abs(term.points), gap))

        case let .tooClose(contenders, corroborated, gap, percent, separator):

            var detail = gapSentence(gap: gap, percent: percent, nearTie: true,
                                     sayNearTie: false, separator: separator)

            detail += " " + String(format: L10n.t("%1$d 条候选里只有 %2$d 条拿到了内容印证，未必都是同一份词。"),
                                   contenders, corroborated)

            return (L10n.t("几乎打平，但内容印证不全"), detail)
        }
    }

    private func gapSentence(gap: Int, percent: Double?, nearTie: Bool, sayNearTie: Bool,
                             separator: LyricsVerdictSeparator) -> String {
        if case .identical = separator {
            return L10n.t("两边打分完全相同，先后由来源顺序决定。")
        }
        let pct = gapPercentText(gap: gap, percent: percent)
        var s: String
        if gap == 0 {

            s = L10n.t("两边同分。")
        } else if nearTie && sayNearTie {
            s = pct.isEmpty
                ? String(format: L10n.t("分差只有 %d 分，几乎打平。"), gap)
                : String(format: L10n.t("分差只有 %1$d 分（%2$@），几乎打平。"), gap, pct)
        } else if nearTie {
            s = pct.isEmpty
                ? String(format: L10n.t("分差只有 %d 分。"), gap)
                : String(format: L10n.t("分差只有 %1$d 分（%2$@）。"), gap, pct)
        } else {
            s = pct.isEmpty
                ? String(format: L10n.t("分差 %d 分。"), gap)
                : String(format: L10n.t("分差 %1$d 分（%2$@）。"), gap, pct)
        }
        if let extra = separatorText(separator) { s += " " + extra }
        return s
    }

    private func separatorText(_ s: LyricsVerdictSeparator) -> String? {
        switch s {
        case .identical:
            return L10n.t("两边打分完全相同，先后由来源顺序决定。")
        case let .single(term) where term.points > 0:
            return String(format: L10n.t("唯一的差别是胜者在「%1$@」上多 %2$d 分。"),
                          termLabel(term.kind), term.points)
        case let .single(term):

            return String(format: L10n.t("唯一的差别在「%@」这一项上。"), termLabel(term.kind))
        case .multiple:
            return nil
        }
    }

    private func dumpLines(_ decision: LyricsResolutionDecision) -> [String] {
        let a = analysis(decision)
        var lines: [String] = []
        var head = [pathLabel(decision)]
        if let applied = decision.applied {
            head.append(applied ? L10n.t("已采用") : L10n.t("评估后维持原状"))
        }
        if let version = decision.scoringVersion, version < currentLyricsScoringVersion {
            head.append(L10n.t("旧打分算法"))
        }
        if let ts = decision.decidedAt, ts > 0 {

            head.append(Date(timeIntervalSince1970: TimeInterval(ts))
                .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))
        }
        lines.append(head.joined(separator: " · "))

        if let v = a.verdict {
            let t = verdictText(v)
            lines.append(t.title + " —— " + t.detail)
        }
        if let rewrite = titleRewrite(decision) {
            lines.append(String(format: L10n.t("曲名对不上：本地叫「%1$@」，找到的是《%2$@》"),
                                rewrite.from, rewrite.to))
            if let how = titleRewriteHow(decision) { lines.append("  " + how) }
        }
        let query = queryText(decision)
        if !query.isEmpty { lines.append(String(format: L10n.t("查询词：%@"), query)) }

        if let digest = queryDigest(decision) {
            lines.append(String(format: L10n.t("这一轮实际问过 %d 组"), digest.total))
            if let t = digest.sharedTitle {
                lines.append("  " + String(format: L10n.t("曲名始终是「%@」"), t))
            }
            for g in digest.groups {
                lines.append("  " + groupHeading(g))
                lines.append("    " + groupQueriesText(g))
            }
        }
        if let secs = decision.durationSecs, secs > 0 {
            lines.append(String(format: L10n.t("按 %@ 秒的曲目时长校验"), String(format: "%.0f", secs)))
        }
        if let responded = decision.sourcesResponded, !responded.isEmpty {
            lines.append(String(format: L10n.t("本轮应答的源：%@"),
                                responded.map { sourceDisplayName($0) }.joined(separator: "、")))
            if let silent = silentSourcesText(responded) { lines.append("  " + silent) }
        }
        if !a.shared.isEmpty {
            lines.append(String(format: L10n.t("所有候选都相同的项：%@"), compactTerms(a.shared)))
        }
        for row in a.rows + a.sidelined {
            lines.append("")
            let c = row.model

            if row.core.isInstrumentalMarker {
                lines.append(sourceDisplayName(c.source) + " · " + L10n.t("纯音乐"))
                lines.append(L10n.t("这个源明确说这首是纯音乐，所以它没有参与打分"))
                continue
            }
            if row.core.isRejected {
                lines.append(sourceDisplayName(c.source))
                if let terms = c.scoreTerms, !terms.isEmpty {
                    lines.append(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
                }
                let matched = matchedText(c)
                if !matched.isEmpty { lines.append(matched) }
                continue
            }
            var tag = [sourceDisplayName(c.source), "\(c.score)"]
            if row.core.source == a.champion?.core.source { tag.append(L10n.t("胜者")) }
            if c.hasWordTiming == true { tag.append(L10n.t("逐字")) }
            lines.append(tag.joined(separator: " · "))

            if let d = a.deltas[row.core.source] {
                lines.append(String(format: L10n.t("落后 %d 分"), abs(d.scoreGap)))
                if !d.terms.isEmpty {
                    lines.append(String(format: L10n.t("差在：%@"), compactTerms(d.terms)))
                }
                if let raw = d.clampedRawSum {
                    lines.append("  " + clampNote(rawSum: raw, score: c.score))
                }
            }
            let matched = matchedText(c)
            if !matched.isEmpty { lines.append(matched) }
            if let terms = c.scoreTerms, !terms.isEmpty {
                lines.append(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
            }
            if let peers = c.consensusPeers, !peers.isEmpty {
                lines.append(String(format: L10n.t("跟 %@ 是同一份词"),
                                    peers.map { sourceDisplayName($0) }.joined(separator: "、")))
            }
        }
        return lines
    }

    @ViewBuilder
    private func verdictSection(_ decision: LyricsResolutionDecision) -> some View {
        let a = analysis(decision)
        let rewrite = titleRewrite(decision)
        if a.verdict != nil || rewrite != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let v = a.verdict {
                    let t = verdictText(v)
                    VerdictCard(title: t.title, detail: t.detail, tint: verdictTint(v))
                }
                if let rewrite {
                    VerdictCard(
                        title: String(format: L10n.t("曲名对不上：本地叫「%1$@」，找到的是《%2$@》"),
                                      rewrite.from, rewrite.to),
                        detail: titleRewriteHow(decision) ?? "",
                        tint: .orange)
                }
            }
        }
    }

    private func verdictTint(_ v: LyricsVerdict) -> Color {
        if case .decisiveNegative = v { return .orange }
        return .accentColor
    }

    private func titleRewriteHow(_ decision: LyricsResolutionDecision) -> String? {
        guard let m = decision.retryMethod, !m.isEmpty else { return nil }
        return String(format: L10n.t("本地那个曲名没搜到，最后靠「%@」问出真名。"),
                      queryReasonLabel(m))
    }

    @ViewBuilder
    private func chipsRow(_ decision: LyricsResolutionDecision) -> some View {
        HStack(spacing: 8) {
            InfoChip(icon: "clock.arrow.circlepath", text: pathLabel(decision), tint: .blue)
            if let applied = decision.applied {
                InfoChip(icon: applied ? "checkmark.circle" : "equal.circle",
                         text: applied ? L10n.t("已采用") : L10n.t("评估后维持原状"),
                         tint: applied ? .green : .secondary)
            }

            if let version = decision.scoringVersion, version < currentLyricsScoringVersion {
                InfoChip(icon: "arrow.triangle.2.circlepath", text: L10n.t("旧打分算法"), tint: .orange)
            }
            if let ts = decision.decidedAt, ts > 0 {

                InfoChip(icon: "calendar",
                         text: Date(timeIntervalSince1970: TimeInterval(ts))
                             .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)),
                         tint: .secondary)
            }
        }
    }

    @ViewBuilder
    private func sharedTermsLine(_ decision: LyricsResolutionDecision) -> some View {
        let a = analysis(decision)
        if !a.shared.isEmpty, a.rows.count >= 2 {
            Text(String(format: L10n.t("%1$d 条候选在这些项上完全相同：%2$@"),
                        a.rows.count, compactTerms(a.shared)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.07)))
        }
    }

    private func silentSourcesText(_ responded: [String]) -> String? {
        let enabled = FeatureSettingsStore.shared.lyricsSources.map(\.rawValue)
        let silent = enabled.filter { !responded.contains($0) }
        guard !silent.isEmpty else { return nil }
        return String(format: L10n.t("当前启用的其余源没有应答：%@"),
                      silent.map { sourceDisplayName($0) }.joined(separator: "、"))
    }

    private func clampNote(rawSum: Int, score: Int) -> String {
        String(format: L10n.t("分项合计 %1$d，被夹到最低分 %2$d"), rawSum, score)
    }

    private func inputsSummary(_ decision: LyricsResolutionDecision) -> String {
        var parts: [String] = []
        let responded = decision.sourcesResponded ?? []
        if !responded.isEmpty {
            parts.append(String(format: L10n.t("%1$d/%2$d 个源应答"),
                                responded.count, LyricsSource.allCases.count))
        }
        if let digest = queryDigest(decision) {
            parts.append(String(format: L10n.t("问过 %d 组词"), digest.total))
        }
        if let secs = decision.durationSecs, secs > 0 {
            parts.append(String(format: L10n.t("按 %@ 秒校验"), String(format: "%.0f", secs)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func inputsSection(_ decision: LyricsResolutionDecision) -> some View {
        let digest = queryDigest(decision)
        let responded = decision.sourcesResponded ?? []
        let total = LyricsSource.allCases.count
        let summary = inputsSummary(decision)
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { inputsOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: inputsOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2).frame(width: 10)
                    Text(L10n.t("这一轮的输入与经过")).font(.caption)
                    if !inputsOpen, !summary.isEmpty {
                        Text("· " + summary)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(String(format: L10n.t("源数分母是当前启用的 %d 个源；老条目当年可用的源可能更少"), total))

            if inputsOpen {
                VStack(alignment: .leading, spacing: 4) {
                    let query = queryText(decision)
                    if !query.isEmpty {
                        Text(String(format: L10n.t("查询词：%@"), query))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let secs = decision.durationSecs, secs > 0 {
                        Text(String(format: L10n.t("按 %@ 秒的曲目时长校验"), String(format: "%.0f", secs)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !responded.isEmpty {

                        Text(String(format: L10n.t("本轮应答的源：%@"),
                                    responded.map { sourceDisplayName($0) }.joined(separator: "、")))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let silent = silentSourcesText(responded) {
                            Text(silent)
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let digest {
                        Text(String(format: L10n.t("这一轮实际问过 %d 组"), digest.total))
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.top, 2)

                        if let t = digest.sharedTitle {
                            Text(String(format: L10n.t("曲名始终是「%@」"), t))
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(digest.groups) { g in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(groupHeading(g))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(groupQueriesText(g))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 10)
                            }
                        }
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder
    private func candidateSection(_ decision: LyricsResolutionDecision) -> some View {
        let a = analysis(decision)
        if a.rows.isEmpty && a.sidelined.isEmpty {
            Text(L10n.t("这一轮没有任何源给出候选"))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {

            let showsCover = (decision.candidates ?? []).contains { !($0.coverUrl ?? "").isEmpty }
            let top = a.rows.first?.core.score ?? 0
            VStack(alignment: .leading, spacing: 4) {
                ForEach(a.rows) { row in
                    candidateRow(row,
                                 delta: a.deltas[row.core.source],
                                 isChampion: row.core.source == a.champion?.core.source,
                                 topScore: top,
                                 showsCover: showsCover)
                }

                ForEach(a.sidelined) { row in
                    sidelinedRow(row, showsCover: showsCover)
                }
            }
        }
    }

    private func candidateRow(_ row: Row, delta: LyricsScoreDelta?, isChampion: Bool,
                              topScore: Int, showsCover: Bool) -> some View {
        let isOpen = expanded.contains(row.core.source)
        let c = row.model
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    if isOpen { expanded.remove(row.core.source) }
                    else { expanded.insert(row.core.source) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 10)
                    if showsCover { candidateCover(c.coverUrl, size: 22) }
                    Text(sourceDisplayName(c.source))
                        .font(.callout.weight(isChampion ? .semibold : .regular))
                        .foregroundStyle(sourceColor(c.source))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(sourceColor(c.source).opacity(0.12), in: Capsule())
                    if isChampion {
                        Label(L10n.t("胜者"), systemImage: "crown.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    if c.hasWordTiming == true {
                        Text(L10n.t("逐字")).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Text("\(c.score)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)

                    Text(delta.map { signedText($0.scoreGap) } ?? "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    scoreBar(score: c.score, top: topScore, tint: sourceColor(c.source))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            if isOpen {
                expandedDetail(row, delta: delta)
            } else {

                let terms = delta?.terms ?? championTerms(row)
                if !terms.isEmpty {
                    Text(compactTerms(terms))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, showsCover ? 39 : 17)
                }
                if let raw = delta?.clampedRawSum {
                    Text(clampNote(rawSum: raw, score: c.score))
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.leading, showsCover ? 39 : 17)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isChampion ? Color.orange.opacity(0.07) : Color.secondary.opacity(0.05)))
    }

    @ViewBuilder
    private func expandedDetail(_ row: Row, delta: LyricsScoreDelta?) -> some View {
        let c = row.model
        VStack(alignment: .leading, spacing: 4) {
            let matched = matchedText(c)
            if !matched.isEmpty {
                Text(matched).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let terms = c.scoreTerms, !terms.isEmpty {

                Text(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let raw = delta?.clampedRawSum ?? row.core.clampedRawSum {
                Text(clampNote(rawSum: raw, score: c.score))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let peers = c.consensusPeers, !peers.isEmpty {
                Text(String(format: L10n.t("跟 %@ 是同一份词"),
                            peers.map { sourceDisplayName($0) }.joined(separator: "、")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 17)
        .padding(.top, 2)
    }

    private func sidelinedRow(_ row: Row, showsCover: Bool) -> some View {
        let c = row.model
        let isInstrumental = row.core.isInstrumentalMarker
        return HStack(alignment: .top, spacing: 7) {

            Color.clear.frame(width: 10, height: 1)
            if showsCover {

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: isInstrumental ? "speaker.wave.2" : "text.badge.xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary))
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(sourceDisplayName(c.source))
                        .font(.callout)
                        .foregroundStyle(sourceColor(c.source))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(sourceColor(c.source).opacity(0.12), in: Capsule())
                    if isInstrumental {
                        Label(L10n.t("纯音乐"), systemImage: "music.note.list")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if isInstrumental {
                    Text(L10n.t("这个源明确说这首是纯音乐，所以它没有参与打分"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if row.core.isRejected, let terms = c.scoreTerms, !terms.isEmpty {

                    Text(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                let matched = matchedText(c)
                if !matched.isEmpty {
                    Text(matched).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.05)))
    }

    private func scoreBar(score: Int, top: Int, tint: Color) -> some View {
        let ratio = top > 0 ? max(0, min(1, Double(score) / Double(top))) : 0
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.18))
            Capsule().fill(tint.opacity(0.7)).frame(width: 62 * ratio)
        }
        .frame(width: 62, height: 5)
    }

    private func candidateCover(_ raw: String?, size: CGFloat) -> some View {
        CachedImage(url: raw.flatMap(URL.init(string:))) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.quaternary)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.caption2)
                        .foregroundStyle(.secondary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct VerdictCard: View {
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1))
    }
}
