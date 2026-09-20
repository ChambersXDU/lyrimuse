import AppKit
import LyrimuseCore
import SwiftUI

struct RecentListensPanel: View {
    let onOpenTrack: (String, String) -> Void

    var showsCard = true

    var onArtwork = false

    @ObservedObject private var stats = LastfmStatsService.shared
    @State private var hoveredID: String?

    private enum Item: Identifiable {
        case header(String)
        case row(LastfmStatsService.RecentTrack, Int?)

        var id: String {
            switch self {
            case .header(let s): return "h:" + s
            case .row(let t, _): return "r:" + t.id
            }
        }
    }

    private var primaryTextColor: Color { onArtwork ? .white : .primary }
    private var secondaryTextColor: Color { onArtwork ? .white.opacity(0.6) : .secondary }
    private var tertiaryTextColor: Color { onArtwork ? .white.opacity(0.4) : Color(nsColor: .tertiaryLabelColor) }
    private var hoverFillColor: Color { onArtwork ? .white.opacity(0.10) : Color.primary.opacity(0.07) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            content
                .frame(maxHeight: .infinity, alignment: .top)
            if stats.recentTotalPages > 1 { pager }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if showsCard {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1))
            }
        }
        .onDisappear {
            if stats.recentPage != 1 { stats.goToPage(1) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t("最近听过"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondaryTextColor)
            Spacer(minLength: 0)
            if let updated = stats.recentUpdatedAt {

                HStack(spacing: 3) {
                    if stats.baselineFailed {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 9))
                    }
                    Text(Self.agoText(updated))
                }
                .font(.system(size: 10))
                .foregroundStyle(tertiaryTextColor.opacity(stats.baselineFailed ? 0.6 : 1))
                .help(stats.baselineFailed
                      ? String(format: L10n.t("上次刷新没有成功，显示的是 %@ 的内容"),
                               updated.formatted(date: .abbreviated, time: .standard))
                      : updated.formatted(date: .abbreviated, time: .standard))
            }
            Button {
                stats.refreshBaseline(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryTextColor)
            .disabled(stats.recentPaging)
            .help(L10n.t("刷新"))
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if items.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .header(let label):
                            Text(label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(tertiaryTextColor)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .padding(.horizontal, 4)
                        case .row(let track, let count):
                            row(track, count)
                        }
                    }
                }
            }
            .scrollIndicators(.never)

            .refreshable { await stats.refreshBaselineAndWait(force: true) }
        }
    }

    private func row(_ track: LastfmStatsService.RecentTrack, _ count: Int?) -> some View {
        let hovering = hoveredID == track.id
        return HStack(spacing: 10) {
            CachedImage(url: stats.coverURL(for: track)) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LastfmStatsSection.stableColor(for: track.artist).opacity(0.5))
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text("\(track.title) · \(track.artist)")
                .font(.system(size: 12.5))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if let count {
                Text(String(format: L10n.t("第 %@ 次"), "\(count)"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(secondaryTextColor)
            }
            if let date = track.date {
                Text(RelativeDayFormat.timeFormatter.string(from: date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(tertiaryTextColor)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? hoverFillColor : .clear))
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? track.id : (hoveredID == track.id ? nil : hoveredID) }

        .onTapGesture { onOpenTrack(track.title, track.artist) }
        .help(L10n.t("在 Apple Music 中打开"))
    }

    @ViewBuilder private var emptyState: some View {
        if stats.recentPaging {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .padding(.vertical, 24)
        } else if stats.baselineFailed {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("没拉到最近记录"))
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryTextColor)
                Button(L10n.t("重试")) { stats.refreshBaseline(force: true) }
                    .controlSize(.small)
            }
            .padding(.vertical, 16)
        } else {
            Text(L10n.t("还没有收听记录"))
                .font(.system(size: 12))
                .foregroundStyle(tertiaryTextColor)
                .padding(.vertical, 16)
        }
    }

    private var pager: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button(L10n.t("上一页")) { stats.goToPage(stats.recentPage - 1) }
                .disabled(stats.recentPage <= 1 || stats.recentPaging)
            Text("\(stats.recentPage) / \(max(stats.recentTotalPages, 1))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(secondaryTextColor)
            Button(L10n.t("下一页")) { stats.goToPage(stats.recentPage + 1) }
                .disabled(stats.recentPage >= stats.recentTotalPages || stats.recentPaging)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.top, 10)
    }

    private var items: [Item] {
        let rows = stats.recent.filter { $0.date != nil }
        guard !rows.isEmpty else { return [] }
        let counts = RecentPlayOrdinal.ordinals(
            rows: rows.map { (artist: $0.artist, title: $0.title) },
            totals: stats.trackPlayCounts,
            playCountKey: { LastfmStatsService.playCountKey(artist: $0, title: $1) })
        var out: [Item] = []
        var lastLabel: String?
        for (row, count) in zip(rows, counts) {
            guard let date = row.date else { continue }
            let label = Self.dayLabel(date)
            if label != lastLabel {
                out.append(.header(label))
                lastLabel = label
            }
            out.append(.row(row, count))
        }
        return out
    }

    private static func dayLabel(_ date: Date) -> String { RelativeDayFormat.dayLabel(date) }

    private static func agoText(_ date: Date) -> String {
        let mins = Int(Date().timeIntervalSince(date) / 60)
        if mins < 1 { return L10n.t("刚刚更新") }
        if mins < 60 { return String(format: L10n.t("%@ 分钟前更新"), "\(mins)") }
        return String(format: L10n.t("%@ 小时前更新"), "\(mins / 60)")
    }
}

enum RelativeDayFormat {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()

    static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L10n.t("今天") }
        if cal.isDateInYesterday(date) { return L10n.t("昨天") }
        return dayFormatter.string(from: date)
    }
}

struct PendingListensPanel: View {

    var onOpenTrack: (String, String) -> Void
    var showsCard = true
    var onArtwork = false

    @ObservedObject private var backfill = ScrobbleBackfillService.shared
    @State private var hoveredID: String?

    private enum Item: Identifiable {
        case header(String)
        case row(ScrobbleBackfillService.Item)
        var id: String {
            switch self {
            case .header(let s): return "h:" + s
            case .row(let i): return "r:\(i.uts)"
            }
        }
    }

    private var primaryTextColor: Color { onArtwork ? .white : .primary }
    private var secondaryTextColor: Color { onArtwork ? .white.opacity(0.6) : .secondary }
    private var tertiaryTextColor: Color { onArtwork ? .white.opacity(0.4) : Color(nsColor: .tertiaryLabelColor) }
    private var hoverFillColor: Color { onArtwork ? .white.opacity(0.10) : Color.primary.opacity(0.07) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if showsCard {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1))
            }
        }
        .onAppear { backfill.refreshPending() }

        .task {
            var seen = ScrobbleBackfillService.listenLogModifiedAt()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                let now = ScrobbleBackfillService.listenLogModifiedAt()
                guard now != seen, !backfill.busy else { continue }
                seen = now
                backfill.refreshPending()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t("待推送的收听"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondaryTextColor)
            Spacer(minLength: 0)
            if backfill.busy { ProgressView().controlSize(.small) }

            Button {
                AppActions.shared.requestSettings(.account(.lastfm))
                NSApp.activate(ignoringOtherApps: true)
                AppActions.shared.openSettings?()
            } label: {
                Text(L10n.t("连接 Last.fm…"))
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryTextColor)
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if items.isEmpty {
            Text(L10n.t("本地还没有待推送的收听"))
                .font(.system(size: 12))
                .foregroundStyle(tertiaryTextColor)
                .padding(.vertical, 16)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .header(let label):
                            Text(label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(tertiaryTextColor)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .padding(.horizontal, 4)
                        case .row(let listen):
                            row(listen)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func row(_ item: ScrobbleBackfillService.Item) -> some View {
        let hovering = hoveredID == "r:\(item.uts)"
        return HStack(spacing: 10) {

            CachedImage(url: EnrichCacheReader.coverURL(
                artist: item.artist, title: item.title, album: item.album ?? "")) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LastfmStatsSection.stableColor(for: item.artist).opacity(0.5))
                    Image(systemName: "music.note")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text("\(item.title) · \(item.artist)")
                .font(.system(size: 12.5))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(RelativeDayFormat.timeFormatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(item.uts))))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(tertiaryTextColor)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? hoverFillColor : .clear))
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? "r:\(item.uts)" : (hoveredID == "r:\(item.uts)" ? nil : hoveredID) }

        .onTapGesture { onOpenTrack(item.title, item.artist) }
        .help(L10n.t("在 Apple Music 中打开"))
    }

    private var items: [Item] {
        let rows = (backfill.pending?.items ?? []).sorted { $0.uts > $1.uts }
        guard !rows.isEmpty else { return [] }
        var out: [Item] = []
        var lastLabel: String?
        for listen in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(listen.uts))
            let label = RelativeDayFormat.dayLabel(date)
            if label != lastLabel {
                out.append(.header(label))
                lastLabel = label
            }
            out.append(.row(listen))
        }
        return out
    }
}
