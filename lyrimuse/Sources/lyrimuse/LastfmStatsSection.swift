import Combine
import LyrimuseCore
import SwiftUI

struct LastfmStatsSection: View {

    enum Tab: String, CaseIterable, Identifiable {
        case stats, chart, onThisDay

        case settings
        var id: Self { self }
    }

    var selected: Tab

    @ObservedObject private var stats = LastfmStatsService.shared

    @AppStorage("np:lastfmChartCollapsed") private var chartCollapsed = false
    @AppStorage("np:lastfmRecentCollapsed") private var recentCollapsed = false
    @AppStorage("np:lastfmOnThisDayCollapsed") private var onThisDayCollapsed = false
    @AppStorage("np:lastfmFootprintCollapsed") private var footprintCollapsed = false
    @AppStorage("np:lastfmChartKind") private var kindRaw = LastfmStatsService.ChartKind.artists.rawValue
    @AppStorage("np:lastfmChartPeriod") private var periodRaw = LastfmStatsService.Period.month.rawValue

    @State private var pageInput = "1"

    @State private var recentRefreshing = false

    @State private var showHeatmap = false

    private var kind: LastfmStatsService.ChartKind {
        .init(rawValue: kindRaw) ?? .artists
    }
    private var period: LastfmStatsService.Period {
        .init(rawValue: periodRaw) ?? .month
    }

    var body: some View {
        Group {
            switch selected {
            case .stats:
                statsCard
                recentCard
            case .chart: chartCard
            case .onThisDay:

                listeningFootprintCard
                onThisDayCard

            case .settings: EmptyView()
            }
        }

        .onAppear {
            stats.refreshBaseline()

            if !chartCollapsed { stats.refreshChart(kind: kind, period: period) }
            stats.refreshOnThisDay()
            pageInput = "\(stats.recentPage)"
        }
        .onChange(of: stats.recentPage) { _, page in pageInput = "\(page)" }

        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            stats.refreshBaseline()
            stats.refreshOnThisDay()
        }

        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { break }

                stats.refreshOnThisDay()

                stats.refreshLocalCoversIfCacheChanged()

                stats.refreshBaseline()
            }
        }
    }

    private var statsCard: some View {
        SettingsCard {

            ZStack(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    statCell(value: stats.overview?.today, label: L10n.t("今天"))
                    Divider().padding(.vertical, 10)

                    statCell(value: weekValue, label: L10n.t("近 7 天"))
                    Divider().padding(.vertical, 10)
                    statCell(value: stats.overview?.total, label: L10n.t("总 scrobble"))
                }
                Button {
                    showHeatmap = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("播放热力图"))
                .padding(8)
                .popover(isPresented: $showHeatmap, arrowEdge: .bottom) {
                    LastfmHeatmapView()
                }
            }

            if case .syncing(let page, let total) = stats.bootstrapState, total > 3 {
                CardDivider()

                Text(String(format: L10n.t("首次同步历史中（%1$@/%2$@ 页）"), "\(page)", "\(total)"))
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }

            if stats.baselineFailed, stats.overview == nil {
                CardDivider()
                retryRow { stats.refreshBaseline() }
            }
        }
    }

    private var weekValue: Int? {
        guard !stats.dailySyncing else { return stats.overview?.week }
        return IdleListeningStats.lastSevenDays(
            dailyCounts: stats.dailyCounts, today: Date(),
            todayCount: stats.overview?.today,
            dayKey: { LastfmStatsService.dayKey($0) })
    }

    private func statCell(value: Int?, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map { $0.formatted() } ?? "—")
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var chartCard: some View {
        SettingsCard {
            collapsibleHeader(icon: "chart.bar", title: L10n.t("听得最多"),
                              collapsed: $chartCollapsed) {

                if !chartCollapsed {
                HStack(spacing: 10) {
                    Picker("", selection: Binding(
                        get: { kindRaw },
                        set: { kindRaw = $0; stats.refreshChart(kind: kind, period: period) }
                    )) {
                        ForEach(LastfmStatsService.ChartKind.allCases) { k in
                            Text(k.displayName).tag(k.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Picker("", selection: Binding(
                        get: { periodRaw },
                        set: { periodRaw = $0; stats.refreshChart(kind: kind, period: period) }
                    )) {
                        ForEach(LastfmStatsService.Period.allCases) { p in
                            Text(p.displayName).tag(p.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                }
            }
            if !chartCollapsed {
            CardDivider()
            if let entries = stats.chart(kind, period) {
                if entries.isEmpty {
                    placeholderRow(L10n.t("这个时段还没有记录"))
                } else {
                    chartList(entries)
                }
            } else if stats.chartFailed(kind, period) {
                retryRow { stats.refreshChart(kind: kind, period: period) }
            } else {

                chartList((1...10).map {
                    .init(rank: $0, name: "占位占位", detail: kind == .artists ? "" : "占位",
                          playcount: 0, imageURL: nil)
                }, interactive: false)
                .redacted(reason: .placeholder)
            }
            }
        }

        .onChange(of: chartCollapsed) { _, nowCollapsed in
            if !nowCollapsed { stats.refreshChart(kind: kind, period: period) }
        }
    }

    private func chartList(_ entries: [LastfmStatsService.ChartEntry], interactive: Bool = true) -> some View {
        let maxCount = max(entries.map(\.playcount).max() ?? 1, 1)
        return VStack(spacing: 0) {
            ForEach(entries) { e in
                Button {
                    guard interactive else { return }
                    if let url = Self.lastfmURL(kind: kind, entry: e) { NSWorkspace.shared.open(url) }
                } label: {
                HStack(spacing: 10) {
                    Text("\(e.rank)")
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                        .frame(width: 16, alignment: .trailing)
                    thumb(for: e)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.name).font(.system(size: 13)).lineLimit(1)
                        if !e.detail.isEmpty {
                            Text(e.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(width: 170, alignment: .leading)

                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(geo.size.width * CGFloat(e.playcount) / CGFloat(maxCount), 3))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 5)
                    Text(String(format: L10n.t("%d 次"), e.playcount))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!interactive)
                .rowHoverHighlight(enabled: interactive)
            }
        }
        .padding(.vertical, 5)
    }

    static func lastfmURL(kind: LastfmStatsService.ChartKind, entry: LastfmStatsService.ChartEntry) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        func enc(_ s: String) -> String? { s.addingPercentEncoding(withAllowedCharacters: allowed) }
        switch kind {
        case .artists:
            guard let a = enc(entry.name) else { return nil }
            return URL(string: "https://www.last.fm/music/\(a)")
        case .albums:
            guard let a = enc(entry.detail), let al = enc(entry.name) else { return nil }
            return URL(string: "https://www.last.fm/music/\(a)/\(al)")
        case .tracks:
            guard let a = enc(entry.detail), let t = enc(entry.name) else { return nil }
            return URL(string: "https://www.last.fm/music/\(a)/_/\(t)")
        }
    }

    static func trackURL(artist: String, title: String) -> URL? {
        lastfmURL(kind: .tracks, entry: .init(rank: 0, name: title, detail: artist, playcount: 0, imageURL: nil))
    }

    @ViewBuilder
    private func thumb(for e: LastfmStatsService.ChartEntry) -> some View {

        if e.imageURL == nil, !e.detail.isEmpty, let cover = stats.trackCovers["\(e.detail)|\(e.name)"] {
            CachedImage(url: cover) {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        } else if e.imageURL == nil, e.detail.isEmpty, let avatar = stats.artistAvatars[e.name] {
            CachedImage(url: avatar) {
                Circle().fill(Self.stableColor(for: e.name))
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
        } else if let url = e.imageURL {
            CachedImage(url: url) {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Circle()
                .fill(Self.stableColor(for: e.name))
                .frame(width: 26, height: 26)
                .overlay(
                    Text(e.name.prefix(1).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    static func stableColor(for name: String) -> Color {
        var hash: UInt32 = 5381
        for u in name.unicodeScalars { hash = hash &* 33 &+ u.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.62)
    }

    private var recentCard: some View {
        SettingsCard {

            collapsibleHeader(icon: "clock", title: L10n.t("最近记录"),
                              help: L10n.t("Last.fm 规则：需长于 30 秒且播完一半（或满 4 分钟）。专辑过场轨常达不到。"),
                              collapsed: $recentCollapsed) {
                if let at = stats.recentUpdatedAt {

                    HStack(spacing: 3) {
                        if stats.baselineFailed {
                            Image(systemName: "exclamationmark.circle").font(.system(size: 9))
                        }
                        Text(String(format: L10n.t("%@更新"), Self.coarseRelative(at)))
                    }
                    .font(.caption)
                    .foregroundStyle(stats.baselineFailed ? .quaternary : .tertiary)
                    .help(stats.baselineFailed
                          ? String(format: L10n.t("上次刷新没有成功，显示的是 %@ 的内容"), Self.absolute(at))
                          : String(format: L10n.t("上次刷新:%@"), Self.absolute(at)))
                }

                if recentRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        recentRefreshing = true
                        stats.refreshBaseline(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.t("立即刷新"))
                }
            }
            if !recentCollapsed {
            CardDivider()
            if stats.recent.isEmpty {
                if stats.baselineFailed {
                    retryRow { stats.refreshBaseline() }
                } else {
                    placeholderRow(L10n.t("还没有 scrobble 记录"))
                }
            } else {

                LazyVStack(spacing: 0) {

                    if stats.recentPage == 1 {
                        LiveScrobbleRow()
                    }

                    ForEach(recentRows.filter { $0.track.id != stats.liveAbsorbedRecentID },
                            id: \.track.id) { entry in
                        let t = entry.track

                        HStack(spacing: 10) {

                            CachedImage(url: stats.coverURL(for: t)) {
                                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                            }
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(t.title).font(.system(size: 13)).lineLimit(1)
                                Text(t.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()

                            PlayCountBadge(
                                artist: t.artist, title: t.title, count: entry.count,
                                unavailable: stats.isPlayCountUnavailable(artist: t.artist, title: t.title),
                                anchorDate: t.date,
                                expectedTotal: stats.trackPlayCounts[
                                    LastfmStatsService.playCountKey(artist: t.artist, title: t.title)])
                            if let date = t.date {
                                Text(Self.relative(date))
                                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()

                                    .help(Self.absolute(date))

                                    .frame(minWidth: recentRowTrailingMinWidth, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let url = Self.trackURL(artist: t.artist, title: t.title) { NSWorkspace.shared.open(url) }
                        }
                        .rowHoverHighlight()
                    }

                    if stats.recentTotalPages > 1 {
                        Divider().padding(.horizontal, 14).padding(.vertical, 4)
                        HStack(spacing: 12) {
                            pagerButton(systemImage: "chevron.left", label: L10n.t("上一页"),
                                        enabled: stats.recentPage > 1) {
                                stats.goToPage(stats.recentPage - 1)
                            }
                            Spacer()
                            if stats.recentPaging {
                                ProgressView().controlSize(.small)
                            }

                            HStack(spacing: 5) {
                                Text(L10n.t("第")).font(.caption).foregroundStyle(.secondary)
                                TextField("", text: $pageInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .multilineTextAlignment(.center)
                                    .frame(width: 54)
                                    .disabled(stats.recentPaging)
                                    .onSubmit { submitPageInput() }
                                Text(String(format: L10n.t("/ %@ 页"), "\(stats.recentTotalPages)"))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            pagerButton(systemImage: "chevron.right", label: L10n.t("下一页"),
                                        enabled: stats.recentPage < stats.recentTotalPages) {
                                stats.goToPage(stats.recentPage + 1)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 5)
            }
            }
        }

        .onChange(of: stats.recentUpdatedAt) { _, _ in recentRefreshing = false }
        .onChange(of: stats.baselineFailed) { _, failed in if failed { recentRefreshing = false } }
    }

    private var recentHistory: [LastfmStatsService.RecentTrack] {
        stats.recent.filter { $0.date != nil }
    }

    private var recentRows: [(track: LastfmStatsService.RecentTrack, count: Int?)] {
        let counts = RecentPlayOrdinal.ordinals(
            rows: recentHistory.map { (artist: $0.artist, title: $0.title) },
            totals: stats.trackPlayCounts,
            playCountKey: { LastfmStatsService.playCountKey(artist: $0, title: $1) })
        return zip(recentHistory, counts).map { (track: $0, count: $1) }
    }

    private func submitPageInput() {
        let raw = Int(pageInput.trimmingCharacters(in: .whitespaces)) ?? stats.recentPage
        let target = max(1, min(raw, max(stats.recentTotalPages, 1)))

        pageInput = "\(target)"
        guard target != stats.recentPage else { return }
        stats.goToPage(target)
    }

    private static func coarseRelative(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? L10n.t("刚刚") : relative(date)
    }

    private func collapsibleHeader<Trailing: View>(
        icon: String, title: String, subtitle: String? = nil,
        help: String? = nil,
        collapsed: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: help == nil ? 12 : 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { collapsed.wrappedValue.toggle() }
            } label: {
                HStack(alignment: .top, spacing: SettingsRowMetrics.iconTextSpacing) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                        .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(title).font(.system(size: 13))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(collapsed.wrappedValue ? -90 : 0))
                        }
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if help == nil { Spacer(minLength: 12) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed.wrappedValue ? L10n.t("展开") : L10n.t("收起"))
            if let help {

                QuickHelpLabel(text: help) { EmptyView() }
                    .font(.system(size: 11))
                    .padding(.top, 2)
                Spacer(minLength: 12)
            }

            trailing().labelsHidden().settingsGlassButtons()
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }

    private func pagerButton(systemImage: String, label: String,
                             enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || stats.recentPaging)
    }

    private func placeholderRow(_ text: String) -> some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }

    private func retryRow(_ action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(L10n.t("加载失败")).font(.callout).foregroundStyle(.secondary)
            Button(L10n.t("重试"), action: action).buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private static var fmtLang = ""
    private static var absFmt = DateFormatter()
    private static var relFmt = RelativeDateTimeFormatter()

    private static func ensureFormatters() {
        let lang = L10n.current == "en" ? "en_US" : "zh_CN"
        guard lang != fmtLang else { return }
        fmtLang = lang
        absFmt = DateFormatter()
        absFmt.dateStyle = .medium
        absFmt.timeStyle = .short
        absFmt.locale = Locale(identifier: lang)
        relFmt = RelativeDateTimeFormatter()
        relFmt.unitsStyle = .short
        relFmt.locale = Locale(identifier: lang)
    }

    static func absolute(_ date: Date) -> String {
        ensureFormatters()
        return absFmt.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        ensureFormatters()
        return relFmt.localizedString(for: date, relativeTo: Date())
    }

    private var onThisDayCard: some View {
        Group {
            if let o = stats.onThisDay {
                SettingsCard {

                    collapsibleHeader(
                        icon: "calendar",
                        title: L10n.t("那年今日"),

                        subtitle: o.isWeek
                            ? (o.yearsAgo == 1
                                ? String(format: L10n.t("去年的这一周听了 %@ 次，最常循环的是这几首"), "\(o.total)")
                                : String(format: L10n.t("%1$@ 年前的这一周听了 %2$@ 次，最常循环的是这几首"),
                                         "\(o.yearsAgo)", "\(o.total)"))
                            : (o.yearsAgo == 1
                                ? String(format: L10n.t("去年今天听了 %@ 次，最常循环的是这几首"), "\(o.total)")
                                : String(format: L10n.t("%1$@ 年前的今天听了 %2$@ 次，最常循环的是这几首"),
                                         "\(o.yearsAgo)", "\(o.total)")),
                        collapsed: $onThisDayCollapsed
                    ) {
                        if let at = stats.onThisDayUpdatedAt {

                            Text(String(format: L10n.t("%@更新"), Self.coarseRelative(at)))
                                .font(.caption).foregroundStyle(.tertiary)
                                .help(String(format: L10n.t("上次刷新:%@"), Self.absolute(at)))
                        }
                    }
                    if !onThisDayCollapsed {
                    CardDivider()
                    VStack(spacing: 0) {
                        ForEach(o.top) { entry in
                            let t = entry.track
                            Button {
                                if let url = Self.trackURL(artist: t.artist, title: t.title) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    CachedImage(url: stats.coverURL(for: t)) {
                                        RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                                    }
                                    .frame(width: 26, height: 26)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(t.title).font(.system(size: 13)).lineLimit(1)
                                        Text(t.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()

                                    Text(String(format: L10n.t("%@ 次"), "\(entry.count)"))
                                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .rowHoverHighlight()
                            .help(entry.lastPlayed.map {
                                String(format: L10n.t("那天最后一次:%@"), Self.absolute($0))
                            } ?? "")
                        }
                    }
                    .padding(.vertical, 5)
                    }
                }
            } else {
                SettingsCard {
                    SettingsRawRow(insetToText: true) {
                        HStack(spacing: 8) {
                            switch stats.onThisDayOutcome {
                            case .pending, .loaded:

                                ProgressView().controlSize(.small)
                                Text(L10n.t("正在查那年今日…"))
                                    .foregroundStyle(.secondary)
                            case .empty:
                                Label(L10n.t("过去三年的今天和那几周都没有收听记录"),
                                      systemImage: "calendar.badge.exclamationmark")
                                    .foregroundStyle(.secondary)
                            case .failed:
                                Label(L10n.t("没能取到那年今日——Last.fm 没有响应"),
                                      systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                                Spacer()

                                Button(L10n.t("重试")) { stats.refreshOnThisDay(force: true) }
                            }
                            if stats.onThisDayOutcome != .failed { Spacer() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var listeningFootprintCard: some View {
        if stats.dailySyncing || stats.dailyCounts.isEmpty {
            SettingsCard {
                SettingsRawRow(insetToText: true) {
                    HStack(spacing: 8) {
                        if stats.dailySyncing { ProgressView().controlSize(.small) }
                        Text(L10n.t("首次同步历史之后，这里会出现你的收听足迹"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        } else {
            let today = Date()
            let sum = ListeningMilestones.summarize(
                dailyCounts: stats.dailyCounts, today: today,
                dayKey: { LastfmStatsService.dayKey($0) })
            let avg = IdleListeningStats.dailyAverage(dailyCounts: stats.dailyCounts)
            SettingsCard {
                collapsibleHeader(icon: "figure.walk", title: L10n.t("收听足迹"),
                                  collapsed: $footprintCollapsed) { EmptyView() }
                if !footprintCollapsed {
                    CardDivider()
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                        if let days = sum.daysSinceFirst, let first = sum.firstDay {
                            footprintCell(value: String(format: L10n.t("%@ 天"), days.formatted()),
                                          label: String(format: L10n.t("自 %@ 起"), Self.dayLabel(first)))
                        }
                        footprintCell(value: String(format: L10n.t("%@ 天"), sum.recordedDays.formatted()),
                                      label: String(format: L10n.t("有记录 · 日均 %@ 首"), (avg?.average ?? 0).formatted()))
                        if let peak = sum.peak {
                            footprintCell(value: String(format: L10n.t("%@ 首"), peak.count.formatted()),
                                          label: String(format: L10n.t("单日最高 · %@"), Self.dayLabel(peak.day)))
                        }
                        footprintCell(value: String(format: L10n.t("%@ 天"), sum.currentStreak.formatted()),
                                      label: String(format: L10n.t("当前连续 · 最长 %@ 天"), sum.longestStreak.formatted()))
                        footprintCell(value: String(format: L10n.t("%@ 首"), sum.yearToDate.formatted()),
                                      label: sum.priorYearSameSpan.map {
                                          String(format: L10n.t("今年至今 · %1$@ 年同期 %2$@ 首"), "\($0.year)", $0.count.formatted())
                                      } ?? L10n.t("今年至今"))
                        if let total = stats.overview?.total, total > 0 {
                            let next = ListeningMilestones.nextMilestone(total: total)
                            footprintCell(value: String(format: L10n.t("还差 %@ 首"), next.remaining.formatted()),
                                          label: String(format: L10n.t("到第 %@ 次 scrobble"), next.target.formatted()))
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func footprintCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    private static func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return key }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L10n.locale))
    }
}

private let lastfmBrandRed = Color(nsColor: NSColor(name: "LastfmBrandRed") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 255 / 255, green: 36 / 255, blue: 25 / 255, alpha: 1)
        : NSColor(srgbRed: 213 / 255, green: 16 / 255, blue: 7 / 255, alpha: 1)
})

@MainActor
private final class LiveRowPlayback: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var isAdBreak = false
    @Published private(set) var artworkImage: NSImage?

    @Published private(set) var highResArtworkImage: NSImage?

    var displayArtworkImage: NSImage? { highResArtworkImage ?? artworkImage }
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isAdBreak = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },

            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
        ]
    }
}

private let recentRowTrailingMinWidth: CGFloat = 62

private struct LiveScrobbleRow: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    @StateObject private var playback = LiveRowPlayback()
    @ObservedObject private var features = FeatureSettingsStore.shared
    @State private var hovered = false
    @State private var pendingForceRefresh: Task<Void, Never>?

    @Environment(\.displayScale) private var displayScale

    private struct LiveSource {
        var title: String
        var artist: String

        var artwork: NSImage?
        var imageURL: URL?
        var confirmed: Bool
        var remote: Bool
    }

    private var live: LiveSource? {

        if features.lastfmMirrorScrobble, playback.isPlayingNow, !playback.title.isEmpty,
           !playback.isAdBreak {

            let listCover = stats.liveCoverURL(artist: playback.artist, title: playback.title,
                                               album: playback.album)
            return LiveSource(title: playback.title,
                              artist: canonicalLiveArtist(localArtist: playback.artist),
                              artwork: playback.displayArtworkImage, imageURL: listCover,
                              confirmed: serverConfirms(playback.title), remote: false)
        }

        if let np = stats.apiNowPlaying, stats.apiNowPlayingIsFresh, !matchesLocalTrack(np.title) {
            return LiveSource(title: np.title, artist: np.artist, artwork: nil,
                              imageURL: stats.coverURL(for: np), confirmed: true, remote: true)
        }
        return nil
    }

    private func serverConfirms(_ localTitle: String) -> Bool {
        guard let np = stats.apiNowPlaying else { return false }
        return looseSameTitle(np.title, localTitle)
    }

    private func canonicalLiveArtist(localArtist: String) -> String {
        guard let np = stats.apiNowPlaying, !np.artist.isEmpty,
              matchesLocalTrack(np.title) else { return localArtist }
        return np.artist
    }

    private func matchesLocalTrack(_ title: String) -> Bool {
        !playback.title.isEmpty && looseSameTitle(title, playback.title)
    }

    private func looseSameTitle(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).lowercased()
            == b.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var remoteSessionLikelyActive: Bool {
        if stats.apiNowPlaying != nil { return true }
        guard let newest = stats.recent.first(where: { $0.date != nil })?.date else { return false }
        return Date().timeIntervalSince(newest) < 10 * 60
    }

    private var liveKey: String {
        guard let live else { return "" }
        return "\(live.remote ? "r" : "l")|\(live.artist)|\(live.title)"
    }

    private var absorbedRecent: (id: String, count: Int?)? {
        guard let live, !live.remote, let anchor = PlaybackCoordinator.shared.anchor else { return nil }
        guard let row = stats.recent.first(where: { $0.date != nil }), let date = row.date,
              looseSameTitle(row.title, live.title) else { return nil }
        let playStart = anchor.fetchedAt.addingTimeInterval(-Double(anchor.progressMs) / 1000)
        guard abs(date.timeIntervalSince(playStart)) < 120 else { return nil }
        let key = LastfmStatsService.playCountKey(artist: row.artist, title: row.title)
        return (row.id, stats.trackPlayCounts[key])
    }

    var body: some View {
        Group {
            if let live {

                HStack(spacing: 10) {
                    Group {

                        if let url = live.imageURL {
                            CachedImage(url: url) {
                                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                            }
                        } else if let img = live.artwork {

                            let scale = max(1, displayScale)
                            if let bitmap = ArtworkThumbnailCache.bitmap(for: img, pixelSide: Int((26 * scale).rounded())) {
                                Image(decorative: bitmap, scale: scale)
                            } else {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                        }
                    }
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(live.title).font(.system(size: 13)).lineLimit(1)
                        Text(live.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()

                    PlayCountBadge(
                        artist: live.artist, title: live.title,
                        count: absorbedRecent?.count ?? stats.nowPlayingCount,
                        unavailable: true, anchorDate: nil, expectedTotal: nil)
                    if live.confirmed {
                        Label(L10n.t("正在记录"), systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(lastfmBrandRed)
                            .labelStyle(.titleAndIcon)
                            .imageScale(.small)

                            .frame(minWidth: recentRowTrailingMinWidth, alignment: .trailing)
                            .help(live.remote
                                  ? L10n.t("在其他设备上播放，Last.fm 已收到")
                                  : L10n.t("Last.fm 已确认收到这次播放"))
                    } else {
                        Label(L10n.t("正在播放"), systemImage: "circle.dotted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                            .imageScale(.small)

                            .frame(minWidth: recentRowTrailingMinWidth, alignment: .trailing)
                            .help(L10n.t("等待 Last.fm 确认（通常几秒内）"))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovered ? Color.secondary.opacity(0.10) : .clear)
                        .padding(.horizontal, 6))
                .contentShape(Rectangle())
                .onTapGesture {
                    if let url = LastfmStatsSection.trackURL(artist: live.artist, title: live.title) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .onHover { hovered = $0 }
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .onAppear {
            if let live { stats.refreshNowPlayingCount(title: live.title, artist: live.artist) }
            stats.liveAbsorbedRecentID = absorbedRecent?.id
        }
        .onChange(of: liveKey) { _, _ in

            if let live { stats.refreshNowPlayingCount(title: live.title, artist: live.artist) }
        }

        .onChange(of: absorbedRecent?.id) { _, id in
            if stats.liveAbsorbedRecentID != id { stats.liveAbsorbedRecentID = id }
        }
        .onChange(of: playback.title) { _, _ in

            pendingForceRefresh?.cancel()
            pendingForceRefresh = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, stats.recentPage == 1 else { return }

                guard !stats.feedIsFresh else { return }
                stats.refreshBaseline(force: true)
            }
        }

        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled else { break }

                guard stats.recentPage == 1, !playback.isPlayingNow, remoteSessionLikelyActive,
                      !stats.feedIsFresh else { continue }
                stats.refreshBaseline(force: true)
            }
        }
        .onDisappear { pendingForceRefresh?.cancel() }
    }
}

private struct RowHoverHighlight: ViewModifier {
    var enabled: Bool = true
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered && enabled ? Color.secondary.opacity(0.10) : .clear)
                    .padding(.horizontal, 6))
            .onHover { hovered = $0 }
    }
}

extension View {
    func rowHoverHighlight(enabled: Bool = true) -> some View {
        modifier(RowHoverHighlight(enabled: enabled))
    }
}
