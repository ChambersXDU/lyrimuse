import AppKit
import LyrimuseCore
import SwiftUI

struct LyricsSearchSheet: View {

    let originalArtist: String
    let originalTitle: String
    let originalAlbum: String

    let currentSource: String?

    let currentFingerprint: String?

    let durationSecs: Double

    let keepsOpenAfterApply: Bool

    let onApply: (LyricsSearchService.Candidate) async -> Bool

    @State private var applyingSource: String?

    @State private var appliedSource: String?

    @State private var appliedFingerprint: String?
    @State private var applyFeedback: ApplyFeedback?
    @State private var applyFeedbackGeneration = 0

    private struct ApplyFeedback: Equatable {
        let text: String
        let ok: Bool
    }

    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var languageSettings = AppLanguageObserver.shared

    @State private var candidates: [LyricsSearchService.Candidate] = []

    private var searchProgressSuffix: String {
        guard sourcesTotal > 0 else { return "" }
        let roundSuffix = searchRound >= 2 ? "［\(searchRound)］" : ""
        return "（\(sourcesDone)/\(sourcesTotal)）\(roundSuffix)"
    }

    private static let allLyricSourceNames = LyricsSource.allCases.map(\.rawValue)

    private var respondedSources: Set<String> {
        Set(candidates.map(\.source))
    }

    private static let transportFailureCodes = ["dns_failed", "connect_failed", "server_error", "upstream_unreachable"]

    private var unreachableSourcesByCode: [(code: String, sources: [String])] {
        Self.transportFailureCodes.compactMap { code in
            let sources = Self.allLyricSourceNames.filter {
                !respondedSources.contains($0) && sourceFailureReasonCodes[$0] == code
            }
            return sources.isEmpty ? nil : (code, sources)
        }
    }

    private static func transportFailureLine(_ code: String, sources: [String]) -> Text {
        let names = sources.map(sourceDisplayName).joined(separator: "、")

        let template: String
        switch code {
        case "dns_failed": template = L10n.t("域名解析失败（DNS）：%@")
        case "connect_failed": template = L10n.t("连接失败或超时：%@")
        case "server_error": template = L10n.t("服务器报错（5xx）：%@")
        case "upstream_unreachable": template = L10n.t("上游源没连上、没法查：%@")
        default: template = code + ": %@"
        }
        let sentinel = "\u{FFFC}"
        let parts = String(format: template, sentinel).components(separatedBy: sentinel)

        guard parts.count >= 2 else { return Text(parts[0]).bold() + Text("：" + names) }
        return Text(parts[0]).bold() + Text(names) + Text(parts.dropFirst().joined(separator: sentinel))
    }

    @State private var showSourceAvailability = false

    @State private var enabledSources: Set<String> = []

    @ViewBuilder
    private var sourceAvailabilityBadge: some View {
        if sourcesTotal > 0 {
            Button {
                showSourceAvailability = true
            } label: {
                Text("\(respondedSources.count)/\(sourcesTotal)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("这一轮有几个歌词源给出了候选，点击查看明细"))
            .popover(isPresented: $showSourceAvailability, arrowEdge: .bottom) {
                sourceAvailabilityList
            }
        }
    }

    private var sourceAvailabilityRows: [(source: String, enabled: Bool)] {
        let names = Self.allLyricSourceNames
        let enabled = enabledSources.isEmpty ? Set(names) : enabledSources
        return names.filter { enabled.contains($0) }.map { ($0, true) }
            + names.filter { !enabled.contains($0) }.map { ($0, false) }
    }

    private var sourceAvailabilityList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("歌词源可用情况"))
                .font(.headline)

            ForEach(sourceAvailabilityRows, id: \.source) { row in
                if row.enabled {
                    sourceAvailabilityRow(row.source)
                } else {
                    disabledSourceRow(row.source)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: 360)
    }

    private func sourceAvailabilityRow(_ source: String) -> some View {
        let responded = respondedSources.contains(source)

        let reason = responded ? nil : sourceFailureReasonCodes[source]
            .map(LyricSourceFailureReason.text(forCode:))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: responded ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(responded ? .green : .secondary)
                Text(sourceDisplayName(source))
                Spacer()
                Text(responded ? L10n.t("已给出候选") : L10n.t("未给出候选"))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
    }

    private func disabledSourceRow(_ source: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
            Text(sourceDisplayName(source))
                .foregroundStyle(.secondary)
            Spacer()
            Text(L10n.t("未启用"))
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .help(L10n.t("在「设置 → 歌词 → 歌词来源」里关掉的源，这一轮没有查它"))
    }

    @State private var sourceFailureReasonCodes: [String: String] = [:]

    @State private var isSearching = false

    @State private var sourcesDone = 0
    @State private var sourcesTotal = 0

    @State private var searchRound = 1

    @State private var searchGeneration = 0
    @State private var loadError: String?

    @State private var networkLooksDown = false

    @State private var instrumental = false
    @State private var selectedSource: String?

    @State private var userPickedSource = false

    private var selectedSourceBinding: Binding<String?> {
        Binding(
            get: { selectedSource },
            set: { newValue in
                selectedSource = newValue
                userPickedSource = true
            }
        )
    }

    @State private var artist: String
    @State private var title: String
    @State private var album: String

    init(artist: String, title: String, album: String, currentSource: String?, currentFingerprint: String? = nil,
         durationSecs: Double, keepsOpenAfterApply: Bool = false,
         onApply: @escaping (LyricsSearchService.Candidate) async -> Bool) {
        self.originalArtist = artist
        self.originalTitle = title
        self.originalAlbum = album
        self.currentSource = currentSource
        self.currentFingerprint = currentFingerprint
        self.durationSecs = durationSecs
        self.keepsOpenAfterApply = keepsOpenAfterApply
        self.onApply = onApply
        self._artist = State(initialValue: artist)
        self._title = State(initialValue: title)
        self._album = State(initialValue: album)
    }

    private var isDirty: Bool {
        artist != originalArtist || title != originalTitle || album != originalAlbum
    }

    private var searchSubject: String {
        originalArtist + "\u{1F}" + originalTitle + "\u{1F}" + originalAlbum
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("搜索候选歌词")).font(.title3.weight(.semibold))
                applyFeedbackView
                Spacer()
                sourceAvailabilityBadge
                Button(L10n.t("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            .background(WindowDragHandle())

            Divider()

            queryFieldsBar

            Divider()

            content
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)

        .background(WindowResizeEnabler(minWidth: 720, minHeight: 480))

        .onChange(of: searchSubject) { _, _ in
            artist = originalArtist
            title = originalTitle
            album = originalAlbum

            appliedSource = nil
            appliedFingerprint = nil
            applyFeedback = nil
        }
        .task(id: searchSubject) { await load() }

        .onDisappear { LyricsSearchService.shared.cancelRunning() }
    }

    private var queryFieldsBar: some View {
        HStack(spacing: 10) {

            ProportionalFieldsLayout(
                desired: [
                    Self.desiredFieldWidth(title, placeholder: L10n.t("歌名")),
                    Self.desiredFieldWidth(artist, placeholder: L10n.t("歌手")),
                    Self.desiredFieldWidth(album, placeholder: L10n.t("专辑")),
                ],
                spacing: 10, minWidth: 88
            ) {
                TextField(L10n.t("歌名"), text: $title).textFieldStyle(.roundedBorder).help(title)
                TextField(L10n.t("歌手"), text: $artist).textFieldStyle(.roundedBorder).help(artist)
                TextField(L10n.t("专辑"), text: $album).textFieldStyle(.roundedBorder).help(album)
            }
            if isDirty {
                Button(L10n.t("恢复原信息")) {
                    artist = originalArtist
                    title = originalTitle
                    album = originalAlbum
                }
                .buttonStyle(.link)
            }

            Button(L10n.t("重新搜索")) { Task { await load() } }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onSubmit { Task { await load() } }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let msg = loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(msg).font(.callout).multilineTextAlignment(.center).padding(.horizontal, 40)
                Button(L10n.t("重试")) { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            if isSearching {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.t("正在查询网易云 / QQ音乐 / 酷狗 / Musixmatch / LRCLIB…")
                        + searchProgressSuffix)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if networkLooksDown {

                ContentUnavailableView {
                    Label(L10n.t("网络似乎不通"), systemImage: "wifi.slash")
                } description: {
                    Text(L10n.t("十个源的请求全部失败，很可能是网络连接有问题，不是这首歌真的没有歌词——检查网络后可以点下面的「重试」"))
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !unreachableSourcesByCode.isEmpty {

                let groups = unreachableSourcesByCode
                let unreachableCount = groups.reduce(0) { $0 + $1.sources.count }

                let allUnreachable = sourcesTotal > 0 && unreachableCount >= sourcesTotal
                let otherCount = max(0, sourcesTotal - unreachableCount)
                ContentUnavailableView {
                    Label(allUnreachable
                          ? L10n.t("歌词源全都没连上")
                          : String(format: L10n.t("有 %@ 个歌词源没连上"), "\(unreachableCount)"),
                          systemImage: "wifi.exclamationmark")
                } description: {
                    VStack(spacing: 4) {
                        ForEach(groups, id: \.code) { group in

                            Self.transportFailureLine(group.code, sources: group.sources)
                        }
                        if groups.contains(where: { $0.code == "dns_failed" }) {
                            Text(L10n.t("常见于 VPN / 公司网络接管了 DNS；浏览器能开网页不代表这里能通"))
                        }
                        if instrumental {

                            Text(L10n.t("有源明确说这首是纯音乐，没有可用的歌词候选"))
                        } else if !allUnreachable {
                            Text(String(format: L10n.t("其余 %@ 个源没有给出候选"), "\(otherCount)"))
                        }
                    }
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if instrumental {

                ContentUnavailableView {
                    Label(L10n.t("纯音乐"), systemImage: "waveform")
                } description: {
                    Text(L10n.t("有源明确说这首是纯音乐，没有可用的歌词候选"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L10n.t("十个源都没找到可用的候选"), systemImage: "text.badge.xmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                if isSearching {

                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("其它源仍在搜索中…") + searchProgressSuffix)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                }
                HSplitView {
                    List(candidates, selection: selectedSourceBinding) { c in
                        candidateRow(c)
                    }

                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)

                    if let c = candidates.first(where: { $0.source == selectedSource }) ?? candidates.first {
                        previewPane(c)
                    }
                }
            }
        }
    }

    private func candidateRow(_ c: LyricsSearchService.Candidate) -> some View {

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                coverThumbnail(c.coverURL, size: 40)
                VStack(alignment: .leading, spacing: 3) {

                    candidateMatchInfo(c, titleFont: .body.weight(.medium))
                    scoreLine(c, font: .caption2)
                }
                Spacer(minLength: 0)

                sourceBadge(c.source)
                    .fixedSize()
            }

            characteristicBadges(c, source: c.source, showsSource: false, isCurrent: isCurrentCandidate(c), duplicateOf: duplicateAnchors[c.source])
        }
        .tag(c.source)
        .padding(.vertical, 3)
    }

    private var effectiveCurrentSource: String? { appliedSource ?? currentSource }

    private var effectiveCurrentFingerprint: String? { appliedSource != nil ? appliedFingerprint : currentFingerprint }

    private func isCurrentCandidate(_ c: LyricsSearchService.Candidate) -> Bool {
        LyricsCandidateDuplicates.isCurrent(
            candidateSource: c.source, candidateFingerprint: c.fingerprint,
            currentSource: effectiveCurrentSource, currentFingerprint: effectiveCurrentFingerprint)
    }

    private var duplicateAnchors: [String: String] {
        LyricsCandidateDuplicates.firstMatches(candidates.map { (source: $0.source, fingerprint: $0.fingerprint) })
    }

    private func applyButtonTitle(for c: LyricsSearchService.Candidate) -> String {
        if applyingSource == c.source { return L10n.t("正在采用…") }

        return c.isPlainTextOnly ? L10n.t("采纳为静态文本") : L10n.t("采用此候选")
    }

    private func apply(_ c: LyricsSearchService.Candidate) async {
        guard applyingSource == nil else { return }
        let subject = searchSubject
        applyingSource = c.source
        let saved = await onApply(c)
        applyingSource = nil
        guard subject == searchSubject else { return }
        if saved {
            appliedSource = c.source
            appliedFingerprint = c.fingerprint
        }
        guard keepsOpenAfterApply else {
            dismiss()
            return
        }
        if saved {
            let name = LyricsSource(rawValue: c.source)?.displayName ?? c.source
            showApplyFeedback(String(format: L10n.t("已采用 %@ 的歌词"), name), ok: true)
        } else {
            showApplyFeedback(L10n.t("未能保存，请再试一次"), ok: false)
        }
    }

    private func showApplyFeedback(_ text: String, ok: Bool) {
        applyFeedbackGeneration += 1
        let generation = applyFeedbackGeneration
        withAnimation { applyFeedback = ApplyFeedback(text: text, ok: ok) }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard generation == applyFeedbackGeneration else { return }
            withAnimation { applyFeedback = nil }
        }
    }

    @ViewBuilder
    private var applyFeedbackView: some View {
        if let applyFeedback {
            Label(applyFeedback.text,
                  systemImage: applyFeedback.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(applyFeedback.ok ? Color.secondary : Color.orange)
                .lineLimit(1)
                .padding(.leading, 8)
                .transition(.opacity)
        }
    }

    private func previewPane(_ c: LyricsSearchService.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                coverThumbnail(c.coverURL, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    candidateMatchInfo(c, titleFont: .headline)
                    scoreLine(c, font: .caption)
                }
                Spacer()

                Button(applyButtonTitle(for: c)) {
                    Task { await apply(c) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(applyingSource != nil)
            }

            characteristicBadges(c, source: c.source, showsSource: true, isCurrent: isCurrentCandidate(c), duplicateOf: duplicateAnchors[c.source])
            if c.isPlainTextOnly {
                Label(
                    L10n.t("这份歌词没有时间戳，采纳后只能作为静态文字展示，不会逐字/逐行跟随播放高亮"),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ScrollView {

                Text(LyricsPreviewText.forPreview(c.lyrics, title: c.title, artist: c.artist))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
        .frame(minWidth: 380)
    }

    private static func desiredFieldWidth(_ text: String, placeholder: String) -> CGFloat {
        let shown = text.isEmpty ? placeholder : text
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let width = (shown as NSString).size(withAttributes: [.font: font]).width
        return width + 22
    }

    @ViewBuilder
    private func candidateMatchInfo(
        _ c: LyricsSearchService.Candidate, titleFont: Font
    ) -> some View {
        if !c.title.isEmpty {
            Text(c.title)
                .font(titleFont)
                .lineLimit(2)
                .help(c.title)
        }
        if !c.artist.isEmpty {
            Text(c.artist)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(c.artist)
        }
        if !c.album.isEmpty {
            Text(c.album)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(c.album)
        }
    }

    @ViewBuilder
    private func coverThumbnail(_ url: URL?, size: CGFloat) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        coverPlaceholder
                    }
                }
            } else {
                coverPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.quaternary)
            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
    }

    @ViewBuilder
    private func characteristicBadges(
        _ c: LyricsSearchService.Candidate, source: String, showsSource: Bool,
        isCurrent: Bool, duplicateOf: String?
    ) -> some View {

        if hasAnyCharacteristicBadge(c, showsSource: showsSource, isCurrent: isCurrent, duplicateOf: duplicateOf) {

            WrapLayout(horizontalSpacing: 5, verticalSpacing: 4, rowAlignment: .leading) {

                if c.isPlainTextOnly {
                    characteristicBadge(L10n.t("无时间戳"), "exclamationmark.triangle.fill", .orange)
                }
                if c.hasWordTiming {
                    characteristicBadge(L10n.t("逐字时间戳"), "text.word.spacing", .blue)
                }
                if c.hasTranslation {
                    characteristicBadge(L10n.t("译文"), "character.book.closed", .green)
                }
                if c.hasRomanization {
                    characteristicBadge(L10n.t("罗马音"), "textformat.abc", .purple, latinIcon: true)
                }

                if showsSource {
                    sourceBadge(source)
                }
                if let duplicateOf {

                    characteristicBadge(
                        String(format: L10n.t("歌词文字与 %@ 相同"), LyricsSource(rawValue: duplicateOf)?.displayName ?? duplicateOf),
                        "equal.circle", .secondary)
                        .help(L10n.t("只比对歌词文字，不含时间戳、逐字与译文；这条候选仍可能带别的来源没有的逐字轨或译文"))
                }
                if isCurrent {

                    Label(L10n.t("当前使用"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .font(.caption2)
        }
    }

    private func hasAnyCharacteristicBadge(
        _ c: LyricsSearchService.Candidate, showsSource: Bool, isCurrent: Bool, duplicateOf: String?
    ) -> Bool {
        c.isPlainTextOnly || c.hasWordTiming || c.hasTranslation || c.hasRomanization
            || showsSource || duplicateOf != nil || isCurrent
    }

    private func sourceBadge(_ source: String) -> some View {
        let known = LyricsSource(rawValue: source)
        let tint = known?.color ?? .secondary
        return Text(known?.displayName ?? source)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func scoreLine(_ c: LyricsSearchService.Candidate, font: Font) -> some View {
        let label = Text(String(format: L10n.t("分数 %@ · %@ 行"), "\(c.score)", "\(c.lineCount)"))
        label
        .font(font)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func characteristicBadge(
        _ text: String, _ icon: String, _ tint: Color, latinIcon: Bool = false
    ) -> some View {
        Group {
            if latinIcon {
                LatinIconLabel(text, systemImage: icon)
            } else {
                Label(text, systemImage: icon)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private func load() async {
        searchGeneration += 1
        let generation = searchGeneration
        candidates = []
        loadError = nil
        selectedSource = nil
        userPickedSource = false
        networkLooksDown = false
        instrumental = false
        sourcesDone = 0
        sourcesTotal = 0
        searchRound = 1
        sourceFailureReasonCodes = [:]

        enabledSources = Set(FeatureSettingsStore.shared.lyricsSources.map(\.rawValue))
        isSearching = true
        do {
            try await LyricsSearchService.shared.search(artist: artist, title: title, album: album, durationSecs: durationSecs) { update in
                guard generation == searchGeneration else { return }
                candidates = update.candidates
                networkLooksDown = update.networkLooksDown
                instrumental = update.instrumental
                sourcesDone = update.sourcesDone
                sourcesTotal = update.sourcesTotal
                searchRound = update.round
                sourceFailureReasonCodes = update.sourceFailureReasonCodes

                guard !userPickedSource else { return }
                if let current = effectiveCurrentSource, update.candidates.contains(where: { $0.source == current }) {
                    selectedSource = current
                } else if selectedSource == nil {
                    selectedSource = update.candidates.first?.source
                }
            }
        } catch {
            if generation == searchGeneration { loadError = error.localizedDescription }
        }
        guard generation == searchGeneration else { return }
        isSearching = false
    }
}

private struct ProportionalFieldsLayout: Layout {
    let desired: [CGFloat]
    let spacing: CGFloat
    let minWidth: CGFloat

    private func widths(for subviews: Subviews, in total: CGFloat) -> [CGFloat] {
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))

        let want = (0..<subviews.count).map { $0 < desired.count ? desired[$0] : minWidth }
        return LyricsQueryFieldLayout.widths(
            desired: want, available: max(total - gaps, 0), minWidth: minWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0

        let natural = desired.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: proposal.width ?? natural, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let ws = widths(for: subviews, in: bounds.width)
        var x = bounds.minX
        for (i, sub) in subviews.enumerated() {
            let w = i < ws.count ? ws[i] : 0
            sub.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}
