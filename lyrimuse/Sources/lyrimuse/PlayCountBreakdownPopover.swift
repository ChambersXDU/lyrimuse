import LyrimuseCore
import SwiftUI

struct PlayCountBadge: View {
    let artist: String
    let title: String

    let count: Int?

    let unavailable: Bool

    let anchorDate: Date?

    let expectedTotal: Int?

    @State private var showing = false
    @State private var hovered = false

    var body: some View {
        if let count {
            Button {
                showing.toggle()
            } label: {
                Text(String(format: L10n.t("第 %@ 次听"), "\(count)"))
                    .font(.caption)
                    .foregroundStyle(hovered || showing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .monospacedDigit()
                    .underline(hovered || showing, color: .secondary.opacity(0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(L10n.t("这首歌在你 Last.fm 上的第几次收听，点一下看合并了哪些写法"))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                PlayCountBreakdownPopover(artist: artist, title: title,
                                          anchorDate: anchorDate, expectedTotal: expectedTotal)
            }
        } else if !unavailable {
            Text("···")
                .font(.caption).foregroundStyle(.quaternary).monospacedDigit()
                .help(L10n.t("次数还在解析中"))
        }
    }
}

struct PlayCountBreakdownPopover: View {
    @StateObject private var loader: PlayCountBreakdownLoader
    let anchorDate: Date?
    let expectedTotal: Int?

    init(artist: String, title: String, anchorDate: Date?, expectedTotal: Int?) {
        _loader = StateObject(wrappedValue: PlayCountBreakdownLoader(artist: artist, title: title))
        self.anchorDate = anchorDate
        self.expectedTotal = expectedTotal
    }

    private static let palette: [Color] = [.accentColor, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint]
    private static func color(_ index: Int) -> Color { palette[index % palette.count] }

    var body: some View {

        SettingsPopoverShell(
            title: L10n.t("合并明细"),
            help: L10n.t("「第 N 次听」把同一首歌的不同写法（繁简、括号风格、合唱署名等）合并计数。这里列出并进这一行的每种写法、各自的次数和原因，以及逐次的时刻"),
            width: 440
        ) {
            switch loader.state {
            case .loading:
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 22)
            case .failed:
                HStack(spacing: 8) {
                    Text(L10n.t("加载失败")).font(.callout).foregroundStyle(.secondary)
                    Button(L10n.t("重试")) { Task { await loader.load() } }.buttonStyle(.link)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            case .loaded:
                if let b = loader.breakdown { content(b) }
            }
        }
        .task { await loader.load() }
    }

    @ViewBuilder private func content(_ b: PlayCountBreakdown) -> some View {
        summary(b)
        if b.variants.count > 1 {

            CardDivider()
            ForEach(Array(b.variants.enumerated()), id: \.element.id) { i, v in
                variantRow(i, v)
                albumRows(b, variantIndex: i, indented: true)
            }
        } else if b.albumGroups(variantIndex: 0).count > 1 {

            CardDivider()
            albumRows(b, variantIndex: 0, indented: false)
        }
        if !b.plays.isEmpty {
            CardDivider()
            playsList(b)
        }
        footer(b)
    }

    @ViewBuilder private func albumRows(_ b: PlayCountBreakdown, variantIndex: Int, indented: Bool) -> some View {
        let groups = b.albumGroups(variantIndex: variantIndex)
        if groups.count > 1 {
            let exhausted = b.variants[variantIndex].exhausted
            let base = groups[0].album
            ForEach(Array(groups.enumerated()), id: \.offset) { j, g in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(g.album ?? "—")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)

                    Text(String(format: exhausted ? L10n.t("%@ 次") : L10n.t("至少 %@ 次"), "\(g.count)"))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if j > 0, let r = PlayCountFoldExplainer.albumReason(base: base, variant: g.album) {
                        tag(Self.reasonLabel(r), emphasized: false)
                    }
                }
                .padding(.leading, SettingsRowMetrics.horizontalPadding + (indented ? 15 : 0))
                .padding(.trailing, SettingsRowMetrics.horizontalPadding)
                .padding(.vertical, 3)
            }
        }
    }

    private func summary(_ b: PlayCountBreakdown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(loader.title).font(.system(size: 13)).lineLimit(1)
                Text(loader.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text(String(format: L10n.t("共 %@ 次"), "\(b.total)"))
                if b.variants.count > 1 {
                    Text("·")
                    Text(String(format: L10n.t("%@ 种写法"), "\(b.variants.count)"))
                }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, 9)
    }

    private func variantRow(_ index: Int, _ v: PlayCountBreakdown.Variant) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Self.color(index)).frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                Text(v.title).font(.system(size: 12)).lineLimit(1)
                Text(v.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if v.failed {
                Text(L10n.t("未取到")).font(.caption).foregroundStyle(.tertiary)
            } else {
                Text(String(format: L10n.t("%@ 次"), "\(v.total)"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if v.isSelf {
                tag(L10n.t("本条"), emphasized: true)
            } else if v.reasons.isEmpty {

                tag(Self.reasonLabel(.caseOrSpacing), emphasized: false)
            } else {
                ForEach(v.reasons, id: \.self) { tag(Self.reasonLabel($0), emphasized: false) }
            }
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, 5)
    }

    private func tag(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: emphasized ? .semibold : .regular))
            .foregroundStyle(emphasized ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                Capsule().fill(emphasized ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12)))
            .lineLimit(1)
            .fixedSize()
    }

    static func reasonLabel(_ r: PlayCountFoldReason) -> String {
        switch r {
        case .caseOrSpacing: return L10n.t("大小写/空格")
        case .fullwidth: return L10n.t("全角/半角")
        case .hanScript: return L10n.t("繁简")
        case .catalogNoise: return L10n.t("Remaster/feat. 等标注")
        case .versionSuffix: return L10n.t("版本尾缀写法")
        case .bilingualTitle: return L10n.t("双语歌名")
        case .artistCredit: return L10n.t("合唱署名")
        case .artistAlias: return L10n.t("歌手别名")
        case .titleAlias: return L10n.t("歌名别名")
        case .other: return L10n.t("其他折叠规则")
        }
    }

    private func playsList(_ b: PlayCountBreakdown) -> some View {
        let ordinals = b.ordinals
        let multi = b.variants.count > 1
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(b.plays.enumerated()), id: \.element.id) { i, p in

                if i == 0 || !Calendar.current.isDate(p.date, inSameDayAs: b.plays[i - 1].date) {
                    Text(Self.dayLabel(p.date))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
                        .padding(.top, i == 0 ? 8 : 10)
                        .padding(.bottom, 3)
                }
                playRow(p, ordinal: ordinals[i], multi: multi)
            }
        }
        .padding(.bottom, 6)
    }

    private func playRow(_ p: PlayCountBreakdown.Play, ordinal: Int?, multi: Bool) -> some View {

        let isAnchor = anchorDate.map { abs($0.timeIntervalSince(p.date)) < 1 } ?? false
        return HStack(spacing: 8) {
            if multi {
                Circle().fill(Self.color(p.variantIndex)).frame(width: 6, height: 6)
            }
            Text(ordinal.map { String(format: L10n.t("第 %@ 次"), "\($0)") } ?? "—")
                .font(.caption).foregroundStyle(isAnchor ? .primary : .secondary).monospacedDigit()
                .frame(width: 64, alignment: .leading)
            Text(Self.timeLabel(p.date))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .help(LastfmStatsSection.absolute(p.date))

            Spacer(minLength: 8)
            if let album = p.album {

                Text(album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 240, alignment: .trailing)
                    .help(album)
            }
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isAnchor ? Color.accentColor.opacity(0.12) : .clear)
                .padding(.horizontal, 6))
    }

    @ViewBuilder private func footer(_ b: PlayCountBreakdown) -> some View {
        let showsMismatch = !b.hasFailure && expectedTotal.map { $0 != b.total } ?? false
        if b.hasFailure || showsMismatch || b.canLoadOlder {
            CardDivider()
            VStack(alignment: .leading, spacing: 6) {
                if b.hasFailure {
                    HStack(spacing: 8) {
                        Text(L10n.t("部分写法没取到")).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.t("重试")) { Task { await loader.load() } }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                if showsMismatch, let expected = expectedTotal {
                    HStack(spacing: 4) {
                        Text(String(format: L10n.t("行上按 %1$@ 次计，明细合计 %2$@ 次"), "\(expected)", "\(b.total)"))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        HelpButton(text: L10n.t("两个数来自 Last.fm 的两条接口：行上的次数由 track.getInfo（autocorrect）按写法族求和，明细由 user.getTrackScrobbles 按精确写法逐条列出。不相等通常意味着有一种写法只被其中一边合并了"))
                            .font(.system(size: 11))
                    }
                }
                if b.canLoadOlder {
                    HStack(spacing: 8) {
                        if loader.loadingOlder {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(L10n.t("加载更早的")) { Task { await loader.loadOlder() } }
                                .buttonStyle(.link).font(.caption)
                        }
                        if b.ordinalCutoff != nil {
                            Text(L10n.t("还有更早的记录没加载，这些行暂不编号"))
                                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, 8)
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) || cal.isDateInYesterday(date) { return RelativeDayFormat.dayLabel(date) }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        return (sameYear ? dayFormatter : dayWithYearFormatter).string(from: date)
    }

    private static func timeLabel(_ date: Date) -> String { RelativeDayFormat.timeFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()
    private static let dayWithYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMd")
        return f
    }()
}
