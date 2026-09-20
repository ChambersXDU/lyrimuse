import AppKit
import LyrimuseCore
import SwiftUI

struct IdleStandbyView: View {
    let player: PlaybackPlayer

    let onResume: () -> Void
    let onOpenPlayer: () -> Void

    let onOpenAlbum: (String, String) -> Void

    let onOpenTrack: (String, String) -> Void

    @ObservedObject private var stats = LastfmStatsService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 20) {

                if stats.isConnected { IdleOverviewCard() }
                IdleLastTrackHero(player: player, onResume: onResume,
                                  onOpenPlayer: onOpenPlayer, onOpenAlbum: onOpenAlbum)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Group {
                if stats.isConnected {
                    RecentListensPanel(onOpenTrack: onOpenTrack)
                } else {
                    PendingListensPanel(onOpenTrack: onOpenTrack)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            .padding(.top, 18)
        }
        .padding(EdgeInsets(top: 22, leading: 34, bottom: 26, trailing: 34))

        .task {
            var tick = 0
            while !Task.isCancelled {

                if stats.isConnected {
                    stats.refreshBaseline()
                    if tick % 20 == 0 { stats.refreshDailyCounts() }
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 180_000_000_000)
            }
        }
    }
}

struct IdleStandbyBackground: View {

    let wide: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let dark = scheme == .dark
            let unit = max(geo.size.width, geo.size.height)
            ZStack {
                (dark ? Color(red: 0.043, green: 0.039, blue: 0.039)
                      : Color(red: 0.867, green: 0.859, blue: 0.851))
                RadialGradient(
                    colors: [Color.white.opacity(dark ? 0.075 : 0.85), .clear],
                    center: wide ? UnitPoint(x: 0.26, y: 0.62) : UnitPoint(x: 0.5, y: 0.52),
                    startRadius: unit * 0.014, endRadius: unit * 0.42)
                RadialGradient(
                    colors: [.clear, Color.black.opacity(dark ? 0.30 : 0.06)],
                    center: .center, startRadius: unit * 0.26, endRadius: unit * 0.67)
            }
        }
    }
}

private struct IdleOverviewCard: View {
    @ObservedObject private var stats = LastfmStatsService.shared

    private static let sparkDays = 30

    private static let sparkHeight: CGFloat = 52

    @State private var hoverIndex: Int?

    @State private var hoverX: CGFloat?
    @State private var chartWidth: CGFloat = 0
    @State private var captionWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 34) {
                bigStat(value: stats.overview?.today, label: L10n.t("今天"))
                bigStat(value: weekValue, label: weekLabel)
                bigStat(value: stats.overview?.total, label: totalLabel)
            }

            if let note = syncNote {

                Color.clear
                    .frame(height: Self.sparkHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 1)
                    }
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                    .lineLimit(1)
            } else if !series.isEmpty, series.contains(where: { $0 > 0 }) {
                trendChart

                Text(trendCaption)
                    .font(.system(size: 11, weight: hoverIndex == nil ? .regular : .semibold))
                    .foregroundStyle(hoverIndex == nil
                                     ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                     : AnyShapeStyle(Color.accentColor))
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TrendCaptionWidthKey.self, value: g.size.width)
                    })
                    .onPreferenceChange(TrendCaptionWidthKey.self) { captionWidth = $0 }
                    .offset(x: trendCaptionOffsetX)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(nil, value: hoverIndex)
            } else {

                Color.clear
                    .frame(height: Self.sparkHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 1)
                    }
                Text(" ")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
        }
    }

    private func bigStat(value: Int?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {

            Text(value.map { Self.grouped($0) } ?? "—")
                .font(.system(size: 30, weight: .semibold))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var series: [Int] {
        var s = IdleListeningStats.series(
            dailyCounts: stats.dailyCounts, endingAt: Date(), days: Self.sparkDays,
            dayKey: { LastfmStatsService.dayKey($0) })
        if let today = stats.overview?.today, !s.isEmpty { s[s.count - 1] = today }
        return s
    }

    private var weekValue: Int? {
        guard !stats.dailySyncing else { return stats.overview?.week }
        return IdleListeningStats.lastSevenDays(
            dailyCounts: stats.dailyCounts, today: Date(),
            todayCount: stats.overview?.today,
            dayKey: { LastfmStatsService.dayKey($0) })
    }

    private var weekLabel: String {
        let base = L10n.t("近 7 天")
        guard !stats.dailySyncing,
              let d = IdleListeningStats.weekOverWeekDelta(
                dailyCounts: stats.dailyCounts, today: Date(),

                todayCount: stats.overview?.today,
                dayKey: { LastfmStatsService.dayKey($0) })
        else { return base }
        let pct = Int((d * 100).rounded())

        guard pct != 0 else { return base }
        return base + " · " + String(format: L10n.t("较上周 %@"), pct > 0 ? "+\(pct)%" : "\(pct)%")
    }

    private var totalLabel: String {
        let base = L10n.t("累计")
        guard !stats.dailySyncing,
              let avg = IdleListeningStats.dailyAverage(dailyCounts: stats.dailyCounts)
        else { return base }
        return base + " · " + String(format: L10n.t("日均 %1$@ · %2$@ 天"),
                                     "\(avg.average)", "\(avg.days)")
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private var trendChart: some View {
        let s = series
        let peak = max(1, s.max() ?? 1)

        let inset: CGFloat = 7

        return GeometryReader { geo in
            plot(size: geo.size, series: s, peak: peak, inset: inset)
        }
        .frame(height: Self.sparkHeight)
    }

    private func plot(size: CGSize, series s: [Int], peak: Int,
                      inset: CGFloat) -> some View {
        let w = size.width
        let h = size.height
        let n = max(1, s.count - 1)
        let usable = max(1, w - inset * 2)
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: inset + usable * CGFloat(i) / CGFloat(n),
                    y: h - (h - 3) * CGFloat(s[i]) / CGFloat(peak))
        }
        return ZStack {

            Path {
                $0.move(to: CGPoint(x: 0, y: h))
                $0.addLine(to: CGPoint(x: w, y: h))
            }
            .stroke(Color.primary.opacity(0.10), lineWidth: 1)

            Path { p in
                guard !s.isEmpty else { return }
                p.move(to: CGPoint(x: inset, y: h))
                for i in s.indices { p.addLine(to: pt(i)) }
                p.addLine(to: CGPoint(x: inset + usable, y: h))
                p.closeSubpath()
            }
            .fill(LinearGradient(
                colors: [Color.accentColor.opacity(0.38), Color.accentColor.opacity(0.03)],
                startPoint: .top, endPoint: .bottom))

            Path { p in
                guard !s.isEmpty else { return }
                p.move(to: pt(0))
                for i in s.indices.dropFirst() { p.addLine(to: pt(i)) }
            }
            .stroke(Color.accentColor.opacity(0.9),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            if let hi = hoverIndex, s.indices.contains(hi) {
                Path {
                    $0.move(to: CGPoint(x: pt(hi).x, y: 0))
                    $0.addLine(to: CGPoint(x: pt(hi).x, y: h))
                }
                .stroke(Color.primary.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)

                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor),
                                                   lineWidth: 2))
                    .position(pt(hi))
            }

            if let last = s.indices.last {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor),
                                                   lineWidth: 2))
                    .position(pt(last))
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let raw = (p.x - inset) / usable * CGFloat(n)
                let idx = min(max(0, Int(raw.rounded())), max(0, s.count - 1))
                hoverIndex = idx

                hoverX = inset + usable * CGFloat(idx) / CGFloat(n)
                chartWidth = w
            case .ended:
                hoverIndex = nil
                hoverX = nil
            }
        }
    }

    private var trendCaption: String {
        let s = series
        let dates = IdleListeningStats.days(endingAt: Date(), days: Self.sparkDays)
        if let hi = hoverIndex, s.indices.contains(hi), dates.indices.contains(hi) {
            return String(format: L10n.t("%1$@ · %2$@ 首"),
                          Self.dayFormatter.string(from: dates[hi]), Self.grouped(s[hi]))
        }
        guard let peak = s.max(), peak > 0,
              let idx = s.firstIndex(of: peak), dates.indices.contains(idx)
        else { return "" }
        return String(format: L10n.t("近 %1$@ 天 · 最高 %2$@（%3$@）"),
                      "\(Self.sparkDays)", Self.grouped(peak),
                      Self.dayFormatter.string(from: dates[idx]))
    }

    private var syncNote: String? {
        if case .syncing(let page, let total) = stats.bootstrapState {
            return String(format: L10n.t("首次同步历史中（%1$@/%2$@ 页）"), "\(page)", "\(total)")
        }
        if stats.dailySyncing {

            return stats.dailySyncProgress ?? L10n.t("正在同步历史")
        }
        return nil
    }

    private var trendCaptionOffsetX: CGFloat {
        guard let hx = hoverX, chartWidth > 0, captionWidth > 0 else { return 0 }
        return min(max(0, hx - captionWidth / 2), max(0, chartWidth - captionWidth))
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()
}

private struct IdleLastTrackHero: View {
    let player: PlaybackPlayer
    let onResume: () -> Void
    let onOpenPlayer: () -> Void
    let onOpenAlbum: (String, String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coverURL: URL?

    @State private var quotes: [[String]] = []
    @State private var quoteIndex = 0
    @State private var breath = false

    private var lastTitle: String { UserDefaults.standard.string(forKey: "np:lastTrackTitle") ?? "" }
    private var lastArtist: String { UserDefaults.standard.string(forKey: "np:lastTrackArtist") ?? "" }

    private var lastAlbum: String { UserDefaults.standard.string(forKey: "np:lastTrackAlbum") ?? "" }

    private var canResume: Bool { player == .appleMusic || player == .spotify }
    private var trackKey: String { lastArtist + "|" + lastTitle + "|" + lastAlbum }

    var body: some View {
        VStack(spacing: 0) {
            if lastTitle.isEmpty {
                noTrackHero
            } else {
                trackHero
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: trackKey) { load() }
    }

    private var trackHero: some View {
        VStack(spacing: 0) {
            cover
                .frame(width: 216, height: 216)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            Text(L10n.t("刚才在听"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
            Text(lastTitle)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 2)
            Text(lastAlbum.isEmpty ? lastArtist : "\(lastArtist) · \(lastAlbum)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 10) {
                if canResume {
                    Button(action: onResume) {
                        Label(L10n.t("继续播放"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if canResume {
                    Button(L10n.t("前往专辑")) { onOpenAlbum(lastTitle, lastArtist) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                } else {
                    Button(L10n.t("前往专辑")) { onOpenAlbum(lastTitle, lastArtist) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button(String(format: L10n.t("打开 %@"), player.displayName), action: onOpenPlayer)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }

                Button {
                    AppActions.shared.openSettings?()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(L10n.t("设置…"))
                .accessibilityLabel(L10n.t("设置…"))
            }
            .padding(.top, 18)
            if !quotes.isEmpty {
                quoteBand
                    .padding(.top, 30)
            }
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder private var cover: some View {
        if let coverURL {
            CachedImage(url: coverURL, variant: .original) { coverPlaceholder }
        } else {
            coverPlaceholder
        }
    }

    private var coverPlaceholder: some View {
        ZStack {
            LastfmStatsSection.stableColor(for: lastArtist.isEmpty ? lastTitle : lastArtist)
                .opacity(0.65)
            Text(String(lastTitle.prefix(1)))
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var quoteBand: some View {
        VStack(spacing: 7) {

            Text(quotes[quoteIndex % quotes.count].joined(separator: "\n"))
                .font(.system(size: 17))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary.opacity(0.82))
                .id(quoteIndex)
                .transition(.opacity)
            HStack(spacing: 10) {
                Text("—《\(lastTitle)》\(lastArtist)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if quotes.count > 1 {
                    Button(L10n.t("换一句")) {
                        withAnimation(.easeInOut(duration: 0.28)) { quoteIndex += 1 }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 440)
    }

    private var noTrackHero: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.accentColor.opacity(0.12), .clear],
                                         center: .center, startRadius: 8, endRadius: 90))
                    .frame(width: 180, height: 180)
                Image(systemName: "music.note")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .scaleEffect(breath ? 1.05 : 0.96)
            .opacity(breath ? 1 : 0.8)
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                       value: breath)
            .onAppear { breath = true }
            .onDisappear { breath = false }
            Text(L10n.t("没有在播放"))
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 4)
            Text(String(format: L10n.t("在 %@ 播放任意歌曲，歌词会自动出现"), player.displayName))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Button(String(format: L10n.t("打开 %@"), player.displayName), action: onOpenPlayer)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 20)
        }
    }

    private func load() {
        let a = lastArtist, t = lastTitle, al = lastAlbum
        guard !t.isEmpty else {
            coverURL = nil
            quotes = []
            return
        }
        Task.detached(priority: .userInitiated) {
            let raw = EnrichCacheReader.coverURL(artist: a, title: t, album: al)

            let cover = raw.map { EnrichCacheReader.nativeSizedCoverURL($0) }
            var picked: [[String]] = []
            if let entry = EnrichCacheReader.lookup(artist: a, title: t, album: al),
               !entry.lyrics.isEmpty {

                let parsed = LRCParser.parse(entry.lyrics)
                    .map { LyricQuotePicker.Line(timeMs: $0.timeMs, text: $0.text) }
                picked = LyricQuotePicker.phrases(parsed, trackTitle: t, trackArtist: a)
            }
            await MainActor.run {
                coverURL = cover
                quotes = picked
                quoteIndex = picked.isEmpty ? 0 : Int.random(in: 0 ..< picked.count)
            }
        }
    }
}

private struct TrendCaptionWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
